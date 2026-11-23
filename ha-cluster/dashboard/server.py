#!/usr/bin/env python3
"""Web Control Center cho cụm NFSv4 High Availability (Quốc - NT132.R12.ANTT)."""

import argparse
from collections import deque
from datetime import datetime
import hashlib
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import subprocess
import threading

DASHBOARD_DIR = Path(__file__).resolve().parent
REPO_ROOT = DASHBOARD_DIR.parent.parent
INDEX_PATH = DASHBOARD_DIR / "index.html"
PUBLIC_DIR = REPO_ROOT / "shared-data" / "public"
SETUP_SCRIPT = REPO_ROOT / "ha-cluster" / "glusterfs-or-drbd" / "setup-shared-storage.sh"
FAILOVER_SCRIPT = REPO_ROOT / "ha-cluster" / "scripts" / "failover-test.sh"

VIP_ADDR = "192.168.10.100"
MOUNT_OPTS = "vers=4,hard,timeo=50,retrans=2,proto=tcp"

NODES = [
    {"key": "node1", "name": "nfs-ubuntu-node1", "ip": "192.168.10.11", "configured_role": "MASTER", "priority": 100},
    {"key": "node2", "name": "nfs-ubuntu-node2", "ip": "192.168.10.12", "configured_role": "BACKUP", "priority": 90},
]
CLIENTS = [
    {"key": "client1", "name": "nfs-client-1", "ip": "192.168.10.101", "expected_mode": "rw"},
    {"key": "client2", "name": "nfs-client-2", "ip": "192.168.10.102", "expected_mode": "ro"},
]

TASK_LOCK = threading.Lock()
TASK_LOGS: deque[str] = deque(maxlen=120)
TASK_STATE: dict[str, object] = {"running": False, "action": None, "last_exit_code": None}
_SHA256_CACHE_LOCK = threading.Lock()
_SHA256_CACHE: dict[str, tuple[int, int, str]] = {}


def append_log(message: str) -> None:
    ts = datetime.now().strftime("%H:%M:%S")
    with TASK_LOCK:
        for line in message.rstrip("\r\n").splitlines() or [""]:
            TASK_LOGS.append(f"[{ts}] {line}")


def run_cmd(cmd: list[str], timeout: float = 2.0) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", f"Timeout sau {timeout}s: {' '.join(cmd)}"
    except OSError as exc:
        return 127, "", str(exc)


def is_container_running(name: str) -> bool:
    rc, out, _ = run_cmd(["docker", "inspect", "-f", "{{.State.Running}}", name], timeout=2.0)
    return rc == 0 and out.strip() == "true"


def inspect_node(cfg: dict[str, object]) -> dict[str, object]:
    name = str(cfg["name"])
    running = is_container_running(name)
    base = {
        "key": cfg["key"],
        "name": name,
        "ip": cfg["ip"],
        "configured_role": cfg["configured_role"],
        "priority": cfg["priority"],
        "running": running,
        "has_vip": False,
        "role": "OFFLINE",
        "nfs_healthy": False,
        "threads": 0,
        "port_2049": False,
        "lease_time": None,
        "grace_time": None,
    }
    if not running:
        return base

    probe_sh = (
        f"vip=0; ip -4 addr show dev eth0 2>/dev/null | grep -qF 'inet {VIP_ADDR}/' && vip=1; "
        "chk=0; /usr/local/bin/check_nfs.sh >/dev/null 2>&1 && chk=1; "
        "thr=$(tr -d '[:space:]' < /proc/fs/nfsd/threads 2>/dev/null || echo 0); "
        "p2049=0; ss -ltn 2>/dev/null | grep -qE '[:.]2049([[:space:]]|$)' && p2049=1; "
        "lt=$(tr -d '[:space:]' < /proc/fs/nfsd/nfsv4leasetime 2>/dev/null || echo ''); "
        "gt=$(tr -d '[:space:]' < /proc/fs/nfsd/nfsv4gracetime 2>/dev/null || echo ''); "
        "printf '%s|%s|%s|%s|%s|%s\\n' \"$vip\" \"$chk\" \"${thr:-0}\" \"$p2049\" \"$lt\" \"$gt\""
    )
    rc, out, _ = run_cmd(["docker", "exec", name, "sh", "-c", probe_sh], timeout=2.0)
    if rc != 0 or "|" not in out:
        return base

    parts = out.splitlines()[-1].split("|")
    if len(parts) < 6:
        return base

    has_vip = parts[0] == "1"
    nfs_healthy = parts[1] == "1"
    threads = int(parts[2]) if parts[2].isdigit() else 0
    port_2049 = parts[3] == "1"
    lease_time = int(parts[4]) if parts[4].isdigit() else None
    grace_time = int(parts[5]) if parts[5].isdigit() else None

    if has_vip:
        role = "MASTER"
    elif nfs_healthy:
        role = "BACKUP"
    else:
        role = "FAULT"

    base.update(
        {
            "has_vip": has_vip,
            "role": role,
            "nfs_healthy": nfs_healthy,
            "threads": threads,
            "port_2049": port_2049,
            "lease_time": lease_time,
            "grace_time": grace_time,
        }
    )
    return base


def inspect_client(cfg: dict[str, object]) -> dict[str, object]:
    name = str(cfg["name"])
    running = is_container_running(name)
    base = {
        "key": cfg["key"],
        "name": name,
        "ip": cfg["ip"],
        "expected_mode": cfg["expected_mode"],
        "running": running,
        "mounted": False,
        "mount_source": None,
        "mount_mode": "none",
    }
    if not running:
        return base

    rc, out, _ = run_cmd(
        ["docker", "exec", name, "sh", "-c", "grep ' /mnt/nfs/share ' /proc/mounts | tail -n 1"],
        timeout=2.0,
    )
    if rc != 0 or not out:
        return base

    tokens = out.split()
    if len(tokens) < 4:
        return base

    mount_source = tokens[0]
    opts = tokens[3].split(",")
    mount_mode = "rw" if "rw" in opts else ("ro" if "ro" in opts else "unknown")
    base.update(
        {
            "mounted": True,
            "mount_source": mount_source,
            "mount_mode": mount_mode,
        }
    )
    return base


def get_file_sha256(path: Path, size: int, mtime_ns: int) -> str:
    """Return cached SHA-256 hex digest when (size, mtime_ns) is unchanged."""
    key = path.name
    with _SHA256_CACHE_LOCK:
        cached = _SHA256_CACHE.get(key)
        if cached and cached[0] == size and cached[1] == mtime_ns:
            return cached[2]

    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while chunk := fh.read(65536):
            digest.update(chunk)
    hex_digest = digest.hexdigest()

    with _SHA256_CACHE_LOCK:
        _SHA256_CACHE[key] = (size, mtime_ns, hex_digest)
    return hex_digest


def list_shared_files() -> list[dict[str, object]]:
    if not PUBLIC_DIR.is_dir():
        return []
    entries: list[tuple[float, dict[str, object]]] = []
    seen_names: set[str] = set()
    try:
        for path in PUBLIC_DIR.iterdir():
            if path.name == ".gitkeep" or not path.is_file() or path.is_symlink():
                continue
            try:
                stat = path.stat()
                seen_names.add(path.name)
                sha256_hex = get_file_sha256(path, stat.st_size, stat.st_mtime_ns)
                entries.append(
                    (
                        stat.st_mtime,
                        {
                            "name": path.name,
                            "size_bytes": stat.st_size,
                            "sha256": sha256_hex,
                            "mtime": datetime.fromtimestamp(stat.st_mtime).strftime("%H:%M:%S %d/%m"),
                        },
                    )
                )
            except OSError:
                continue
    except OSError:
        return []
    with _SHA256_CACHE_LOCK:
        stale = [k for k in _SHA256_CACHE if k not in seen_names]
        for k in stale:
            del _SHA256_CACHE[k]
    entries.sort(key=lambda item: item[0], reverse=True)
    return [item[1] for item in entries[:20]]


def collect_status() -> dict[str, object]:
    nodes = [inspect_node(cfg) for cfg in NODES]
    clients = [inspect_client(cfg) for cfg in CLIENTS]

    vip_holders = [str(n["name"]) for n in nodes if n["has_vip"]]
    vip_holder = vip_holders[0] if len(vip_holders) == 1 else (",".join(vip_holders) if vip_holders else None)

    n1, n2 = nodes[0], nodes[1]
    if len(vip_holders) == 1 and n1["has_vip"] and n1["nfs_healthy"] and n2["running"] and n2["nfs_healthy"]:
        cluster_status = "HEALTHY"
    elif len(vip_holders) == 1 and n2["has_vip"] and n2["nfs_healthy"]:
        cluster_status = "FAILOVER_ACTIVE"
    else:
        cluster_status = "DEGRADED"

    with TASK_LOCK:
        task_snapshot = {
            "running": bool(TASK_STATE["running"]),
            "action": TASK_STATE["action"],
            "last_exit_code": TASK_STATE["last_exit_code"],
            "logs": list(TASK_LOGS),
        }

    return {
        "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "cluster": {
            "vip": VIP_ADDR,
            "vip_holder": vip_holder,
            "status": cluster_status,
        },
        "nodes": {str(n["key"]): n for n in nodes},
        "clients": {str(c["key"]): c for c in clients},
        "shared_files": list_shared_files(),
        "task": task_snapshot,
    }


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def run_async_script(action: str, cmd: list[str]) -> None:
    def worker() -> None:
        rc = 1
        try:
            append_log(f"--- Bat dau tac vu '{action}': {' '.join(cmd)} ---")
            proc = subprocess.Popen(
                cmd,
                cwd=str(REPO_ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                cleaned = strip_ansi(line.rstrip("\r\n"))
                if cleaned:
                    append_log(cleaned)
            rc = proc.wait()
            append_log(f"--- Ket thuc '{action}' (exit={rc}) ---")
        except Exception as exc:  # noqa: BLE001
            append_log(f"[ERROR] Loi khi chay '{action}': {exc}")
        finally:
            with TASK_LOCK:
                TASK_STATE["running"] = False
                TASK_STATE["last_exit_code"] = rc

    threading.Thread(target=worker, daemon=True).start()


def execute_sync_action(action: str) -> tuple[bool, str]:
    if action == "mount_clients":
        for cfg in CLIENTS:
            cname = str(cfg["name"])
            mode = str(cfg["expected_mode"])
            if not is_container_running(cname):
                return False, f"Container {cname} chua chay"
            cmd = [
                "docker",
                "exec",
                cname,
                "sh",
                "-c",
                (
                    "umount -lf /mnt/nfs/share 2>/dev/null || true; "
                    "mkdir -p /mnt/nfs/share; "
                    f"mount -t nfs4 -o {MOUNT_OPTS},{mode} {VIP_ADDR}:/share /mnt/nfs/share"
                ),
            ]
            rc, _, err = run_cmd(cmd, timeout=8.0)
            if rc != 0:
                return False, f"Mount tren {cname} that bai: {err}"
        return True, f"Da mount {VIP_ADDR}:/share tren nfs-client-1 va nfs-client-2"

    if action == "kill_nfs_node1":
        if not is_container_running("nfs-ubuntu-node1"):
            return False, "nfs-ubuntu-node1 dang tat"
        rc, _, err = run_cmd(
            [
                "docker",
                "exec",
                "nfs-ubuntu-node1",
                "sh",
                "-c",
                "touch /run/nfs_fault_inject && rpc.nfsd 0 && exportfs -ua",
            ],
            timeout=5.0,
        )
        return (rc == 0), ("Da ngat dich vu NFS tren nfs-ubuntu-node1 (Service Failure)" if rc == 0 else err)

    if action == "restore_nfs_node1":
        if not is_container_running("nfs-ubuntu-node1"):
            return False, "nfs-ubuntu-node1 dang tat, hay bam Start Container Node 1"
        rc, _, err = run_cmd(
            [
                "docker",
                "exec",
                "nfs-ubuntu-node1",
                "sh",
                "-c",
                "rm -f /run/nfs_fault_inject && exportfs -rv && rpc.nfsd -V 4 -N 3 8",
            ],
            timeout=5.0,
        )
        return (rc == 0), ("Da khoi phuc dich vu NFS tren nfs-ubuntu-node1" if rc == 0 else err)

    if action == "stop_node1":
        rc, _, err = run_cmd(["docker", "stop", "-t", "5", "nfs-ubuntu-node1"], timeout=12.0)
        return (rc == 0), ("Da dung dot ngot container nfs-ubuntu-node1 (Hard Failure)" if rc == 0 else err)

    if action == "start_node1":
        rc, _, err = run_cmd(["docker", "start", "nfs-ubuntu-node1"], timeout=10.0)
        return (rc == 0), ("Da khoi dong lai container nfs-ubuntu-node1 (Failback)" if rc == 0 else err)

    return False, f"Action khong ho tro: {action}"


ASYNC_SCRIPTS = {
    "setup_storage": ["bash", str(SETUP_SCRIPT)],
    "test_service": ["bash", str(FAILOVER_SCRIPT), "--mode", "service"],
    "test_hard": ["bash", str(FAILOVER_SCRIPT), "--mode", "hard"],
}
SYNC_ACTIONS = {"mount_clients", "kill_nfs_node1", "restore_nfs_node1", "stop_node1", "start_node1"}


class DashboardHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        return

    def send_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/" or self.path.startswith("/?"):
            try:
                content = INDEX_PATH.read_bytes()
            except OSError as exc:
                self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(exc)})
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(content)
            return

        if self.path == "/api/status":
            self.send_json(HTTPStatus.OK, collect_status())
            return

        self.send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint khong ton tai"})

    def do_POST(self) -> None:
        if self.path != "/api/action":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "Endpoint khong ton tai"})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "Content-Length khong hop le"})
            return

        if length <= 0 or length > 16384:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "Payload rong hoac qua lon"})
            return

        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "JSON khong hop le"})
            return

        action = data.get("action") if isinstance(data, dict) else None
        if not isinstance(action, str) or (action not in ASYNC_SCRIPTS and action not in SYNC_ACTIONS):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": f"Action khong hop le: {action}"})
            return

        busy_action = None
        with TASK_LOCK:
            if TASK_STATE["running"]:
                busy_action = TASK_STATE["action"]
            else:
                TASK_STATE["running"] = True
                TASK_STATE["action"] = action
                TASK_STATE["last_exit_code"] = None

        if busy_action is not None:
            self.send_json(
                HTTPStatus.CONFLICT,
                {"error": f"Dang co tac vu '{busy_action}' dang chay, vui long doi hoan tat."},
            )
            return

        if action in ASYNC_SCRIPTS:
            run_async_script(action, ASYNC_SCRIPTS[action])
            self.send_json(HTTPStatus.ACCEPTED, {"ok": True, "action": action, "message": f"Da kich hoat '{action}'"})
            return

        ok = False
        msg = ""
        try:
            ok, msg = execute_sync_action(action)
            append_log(f"[ACTION:{action}] {msg}")
        finally:
            with TASK_LOCK:
                TASK_STATE["running"] = False
                TASK_STATE["last_exit_code"] = 0 if ok else 1

        status_code = HTTPStatus.OK if ok else HTTPStatus.BAD_REQUEST
        self.send_json(status_code, {"ok": ok, "action": action, "message": msg})


def main() -> None:
    parser = argparse.ArgumentParser(description="NFSv4 HA Cluster Web Control Center")
    parser.add_argument("--host", default="0.0.0.0", help="Dia chi lang nghe (mac dinh: 0.0.0.0)")
    parser.add_argument("--port", type=int, default=8080, help="Cong HTTP (mac dinh: 8080)")
    args = parser.parse_args()

    append_log(f"Khoi dong Web Control Center tai http://localhost:{args.port}")
    server = ThreadingHTTPServer((args.host, args.port), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDang tat Web Control Center...")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
