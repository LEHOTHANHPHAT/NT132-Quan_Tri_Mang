#!/usr/bin/env python3
"""Web Control Center cho cụm NFSv4 HA (GlusterFS Replica 2 + NFS-Ganesha + Keepalived) — Quốc - NT132.R12.ANTT."""

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
BRICK1_SHARE_DIR = REPO_ROOT / "shared-data" / "bricks" / "node1" / "gv0" / "share"
BRICK2_SHARE_DIR = REPO_ROOT / "shared-data" / "bricks" / "node2" / "gv0" / "share"
SETUP_SCRIPT = REPO_ROOT / "ha-cluster" / "glusterfs-or-drbd" / "setup-shared-storage.sh"
FAILOVER_SCRIPT = REPO_ROOT / "ha-cluster" / "scripts" / "failover-test.sh"

VIP_ADDR = "192.168.10.100"
VOL_NAME = "gv0"
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
    base: dict[str, object] = {
        "key": cfg["key"],
        "name": name,
        "ip": cfg["ip"],
        "configured_role": cfg["configured_role"],
        "priority": cfg["priority"],
        "running": running,
        "has_vip": False,
        "role": "OFFLINE",
        "nfs_healthy": False,
        "ganesha_running": False,
        "glusterd_running": False,
        "glusterfsd_running": False,
        "port_2049": False,
        "lease_time": 10,
        "grace_time": 10,
        "graceless": True,
    }
    if not running:
        return base

    probe_sh = (
        f"vip=0; ip -4 addr show dev eth0 2>/dev/null | grep -qF 'inet {VIP_ADDR}/' && vip=1; "
        "chk=0; /usr/local/bin/check_nfs.sh >/dev/null 2>&1 && chk=1; "
        "gan=0; pgrep -x ganesha.nfsd >/dev/null 2>&1 && gan=1; "
        "gd=0; pgrep -x glusterd >/dev/null 2>&1 && gd=1; "
        "gfsd=0; pgrep -x glusterfsd >/dev/null 2>&1 && gfsd=1; "
        "p2049=0; ss -ltn 2>/dev/null | grep -qE '[:.]2049([[:space:]]|$)' && p2049=1; "
        "printf '%s|%s|%s|%s|%s|%s\\n' \"$vip\" \"$chk\" \"$gan\" \"$gd\" \"$gfsd\" \"$p2049\""
    )
    rc, out, _ = run_cmd(["docker", "exec", name, "sh", "-c", probe_sh], timeout=2.0)
    if rc != 0 or "|" not in out:
        return base

    parts = out.splitlines()[-1].split("|")
    if len(parts) < 6:
        return base

    has_vip = parts[0] == "1"
    nfs_healthy = parts[1] == "1"
    ganesha_running = parts[2] == "1"
    glusterd_running = parts[3] == "1"
    glusterfsd_running = parts[4] == "1"
    port_2049 = parts[5] == "1"

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
            "ganesha_running": ganesha_running,
            "glusterd_running": glusterd_running,
            "glusterfsd_running": glusterfsd_running,
            "port_2049": port_2049,
        }
    )
    return base


def inspect_gluster(nodes: list[dict[str, object]]) -> dict[str, object]:
    summary: dict[str, object] = {
        "volume": VOL_NAME,
        "status": "OFFLINE",
        "online_bricks": 0,
        "total_bricks": 2,
        "peer_connected": False,
        "pending_heal": None,
    }
    target_node = next((str(n["name"]) for n in nodes if n["running"] and n["glusterd_running"]), None)
    if not target_node:
        return summary

    probe_sh = (
        f"gluster volume status {VOL_NAME} 2>/dev/null || echo '__VOL_ERR__'; "
        "echo '__PEER_SEP__'; "
        "gluster peer status 2>/dev/null || true"
    )
    rc, out, _ = run_cmd(["docker", "exec", target_node, "sh", "-c", probe_sh], timeout=3.0)
    if rc != 0 or "__PEER_SEP__" not in out:
        return summary

    vol_out, peer_out = out.split("__PEER_SEP__", 1)
    online_bricks = 0
    total_bricks = 0
    if "__VOL_ERR__" not in vol_out:
        for line in vol_out.splitlines():
            if line.startswith("Brick "):
                total_bricks += 1
                tokens = line.split()
                if len(tokens) >= 2 and tokens[-2] == "Y":
                    online_bricks += 1

    peer_connected = "State: Peer in Cluster (Connected)" in peer_out
    if total_bricks == 0:
        vol_status = "NOT_CREATED"
    elif online_bricks >= 2 and peer_connected:
        vol_status = "HEALTHY"
    elif online_bricks >= 1:
        vol_status = "DEGRADED"
    else:
        vol_status = "OFFLINE"

    pending_heal: int | None = None
    if online_bricks >= 2 and peer_connected:
        rc_h, heal_out, _ = run_cmd(
            ["docker", "exec", target_node, "gluster", "volume", "heal", VOL_NAME, "info"],
            timeout=3.0,
        )
        if rc_h == 0 and heal_out:
            connected_bricks = len(re.findall(r"^Status:\s*Connected$", heal_out, re.MULTILINE))
            counts = [int(m.group(1)) for m in re.finditer(r"^Number of entries:\s*(\d+)", heal_out, re.MULTILINE)]
            if connected_bricks >= 2 and counts:
                pending_heal = sum(counts)

    summary.update(
        {
            "status": vol_status,
            "online_bricks": online_bricks,
            "total_bricks": max(total_bricks, 2),
            "peer_connected": peer_connected,
            "pending_heal": pending_heal,
        }
    )
    return summary


def inspect_client(cfg: dict[str, object]) -> dict[str, object]:
    name = str(cfg["name"])
    running = is_container_running(name)
    base: dict[str, object] = {
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
    """Return cached SHA-256 hex digest keyed by full path when (size, mtime_ns) is unchanged."""
    key = str(path)
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


def _scan_brick_dir(brick_dir: Path, live_paths: set[str]) -> dict[str, tuple[float, int, str]]:
    found: dict[str, tuple[float, int, str]] = {}
    if not brick_dir.is_dir():
        return found
    try:
        for path in brick_dir.iterdir():
            if path.name.startswith(".") or not path.is_file() or path.is_symlink():
                continue
            try:
                stat = path.stat()
                live_paths.add(str(path))
                sha_hex = get_file_sha256(path, stat.st_size, stat.st_mtime_ns)
                found[path.name] = (stat.st_mtime, stat.st_size, sha_hex)
            except OSError:
                continue
    except OSError:
        return {}
    return found


def list_brick_comparison() -> list[dict[str, object]]:
    live_paths: set[str] = set()
    b1_map = _scan_brick_dir(BRICK1_SHARE_DIR, live_paths)
    b2_map = _scan_brick_dir(BRICK2_SHARE_DIR, live_paths)

    with _SHA256_CACHE_LOCK:
        stale = [k for k in _SHA256_CACHE if k not in live_paths]
        for k in stale:
            del _SHA256_CACHE[k]

    rows: list[tuple[float, dict[str, object]]] = []
    for fname in set(b1_map) | set(b2_map):
        b1 = b1_map.get(fname)
        b2 = b2_map.get(fname)
        if b1 and b2:
            sync_state = "SYNCED" if b1[2] == b2[2] else "MISMATCH"
        elif b2:
            sync_state = "BRICK2_ONLY"
        else:
            sync_state = "BRICK1_ONLY"

        mtime_val = max(b1[0] if b1 else 0.0, b2[0] if b2 else 0.0)
        size_val = b2[1] if b2 else (b1[1] if b1 else 0)
        rows.append(
            (
                mtime_val,
                {
                    "name": fname,
                    "size_bytes": size_val,
                    "mtime": datetime.fromtimestamp(mtime_val).strftime("%H:%M:%S %d/%m"),
                    "brick1": {
                        "exists": b1 is not None,
                        "size_bytes": b1[1] if b1 else None,
                        "sha256": b1[2] if b1 else None,
                    },
                    "brick2": {
                        "exists": b2 is not None,
                        "size_bytes": b2[1] if b2 else None,
                        "sha256": b2[2] if b2 else None,
                    },
                    "sync_state": sync_state,
                },
            )
        )

    rows.sort(key=lambda item: item[0], reverse=True)
    return [item[1] for item in rows[:20]]


def collect_status() -> dict[str, object]:
    nodes = [inspect_node(cfg) for cfg in NODES]
    clients = [inspect_client(cfg) for cfg in CLIENTS]
    gluster = inspect_gluster(nodes)

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
        "gluster": gluster,
        "nodes": {str(n["key"]): n for n in nodes},
        "clients": {str(c["key"]): c for c in clients},
        "brick_files": list_brick_comparison(),
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
                "touch /run/nfs_fault_inject && /usr/local/sbin/ganesha-ctl.sh stop",
            ],
            timeout=6.0,
        )
        return (rc == 0), ("Da ngat dich vu NFS-Ganesha tren nfs-ubuntu-node1 (Service Failure)" if rc == 0 else err)

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
                "rm -f /run/nfs_fault_inject && /usr/local/sbin/ganesha-ctl.sh start",
            ],
            timeout=20.0,
        )
        return (rc == 0), ("Da khoi phuc dich vu NFS-Ganesha tren nfs-ubuntu-node1" if rc == 0 else err)

    if action == "stop_node1":
        rc, _, err = run_cmd(["docker", "stop", "-t", "5", "nfs-ubuntu-node1"], timeout=12.0)
        return (rc == 0), ("Da dung dot ngot container nfs-ubuntu-node1 (Hard Failure)" if rc == 0 else err)

    if action == "start_node1":
        rc, _, err = run_cmd(["docker", "start", "nfs-ubuntu-node1"], timeout=15.0)
        return (rc == 0), ("Da khoi dong lai container nfs-ubuntu-node1 (Failback + Self-Heal)" if rc == 0 else err)

    if action == "trigger_heal":
        target = next((str(c["name"]) for c in NODES if is_container_running(str(c["name"]))), None)
        if not target:
            return False, "Ca 2 Node GlusterFS dang tat"
        rc, out, err = run_cmd(["docker", "exec", target, "gluster", "volume", "heal", VOL_NAME], timeout=8.0)
        msg = out or err or "Da kich hoat Self-Heal"
        return (rc == 0), (f"[{target}] {msg}" if rc == 0 else f"[{target}] {msg}")

    return False, f"Action khong ho tro: {action}"


ASYNC_SCRIPTS = {
    "setup_storage": ["bash", str(SETUP_SCRIPT)],
    "test_service": ["bash", str(FAILOVER_SCRIPT), "--mode", "service"],
    "test_hard": ["bash", str(FAILOVER_SCRIPT), "--mode", "hard"],
}
SYNC_ACTIONS = {
    "mount_clients",
    "kill_nfs_node1",
    "restore_nfs_node1",
    "stop_node1",
    "start_node1",
    "trigger_heal",
}


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
