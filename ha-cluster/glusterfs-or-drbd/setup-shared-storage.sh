#!/bin/bash
###############################################################################
# setup-shared-storage.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Khởi tạo & Kiểm chuẩn GlusterFS Replica 2 + Ganesha
#
# Quy trình 6 bước idempotent:
#   1. Chuẩn bị 2 Brick độc lập trên Host (shared-data/bricks/node{1,2}) & kiểm tra cô lập
#   2. Peer 2 Node GlusterFS (192.168.10.11 <-> 192.168.10.12)
#   3. Tạo/kiểm chuẩn volume gv0 (replica 2), dọn xattr mồ côi nếu cần, tối ưu HA
#   4. Khởi tạo thư mục /share & /no_squash (chmod 0777) bên trong gv0
#   5. Đối chiếu ganesha.conf, khởi chạy ganesha.nfsd & kiểm tra check_nfs.sh trên 2 Node
#   6. Kiểm chứng đồng bộ hai chiều qua mạng (SHA-256 Brick 1 == Brick 2) & chờ VIP trên Node 1
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NODE1="nfs-ubuntu-node1"
NODE2="nfs-ubuntu-node2"
IP1="192.168.10.11"
IP2="192.168.10.12"
VIP="192.168.10.100"
VOL_NAME="gv0"
BRICK_SUBDIR="/data/brick/${VOL_NAME}"
FUSE_MNT="/mnt/gv0_init"

MNT_ACTIVE=0
ISOLATION_PROBE=""
GLUSTER_PROBE=""

pass() { printf '[PASS] %s\n' "$1"; }
info() { printf '[INFO] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

cleanup() {
    if [ -n "${ISOLATION_PROBE}" ]; then
        docker exec "${NODE1}" rm -f "${ISOLATION_PROBE}" 2>/dev/null || true
        ISOLATION_PROBE=""
    fi
    if [ -n "${GLUSTER_PROBE}" ]; then
        if [ "${MNT_ACTIVE}" -eq 1 ]; then
            docker exec "${NODE1}" rm -f "${GLUSTER_PROBE}" 2>/dev/null || true
        fi
        GLUSTER_PROBE=""
    fi
    if [ "${MNT_ACTIVE}" -eq 1 ]; then
        docker exec "${NODE1}" sh -c "umount -lf '${FUSE_MNT}' 2>/dev/null || true; rmdir '${FUSE_MNT}' 2>/dev/null || true" >/dev/null 2>&1 || true
        MNT_ACTIVE=0
    fi
}
trap cleanup EXIT

check_container_running() {
    local container="$1"
    local running
    running="$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || echo "false")"
    if [ "${running}" != "true" ]; then
        fail "Container ${container} chua chay. Hay khoi dong bang: docker compose -f ha-cluster/docker-compose.yml up -d --build"
    fi
    pass "Container ${container} dang hoat dong"
}

verify_brick_isolation() {
    local probe="/data/brick/.ha_brick_isolation_probe"
    local marker="brick-isolated-$(date +%s%N)"
    ISOLATION_PROBE="${probe}"
    docker exec "${NODE1}" sh -c "printf '%s\n' '${marker}' > '${probe}'"
    if docker exec "${NODE2}" test -e "${probe}" 2>/dev/null; then
        fail "Phat hien ${NODE1} va ${NODE2} dung chung /data/brick (vi pham co lap brick!)"
    fi
    docker exec "${NODE1}" rm -f "${probe}"
    ISOLATION_PROBE=""
    pass "Hai thu muc brick (/data/brick tren ${NODE1} & ${NODE2}) tach biet hoan toan"
}

wait_glusterd_ready() {
    local node="$1"
    local i
    for i in $(seq 1 30); do
        if docker exec "${node}" gluster peer status >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.3
    done
    fail "glusterd tren ${node} khong san sang"
}

ensure_peer_connected() {
    if ! docker exec "${NODE1}" gluster peer status 2>/dev/null | grep -q "Peer in Cluster (Connected)"; then
        info "Thuc hien peer probe ${IP2} tu ${NODE1}..."
        docker exec "${NODE1}" gluster peer probe "${IP2}" >/dev/null
    fi

    local i ok1 ok2
    for i in $(seq 1 50); do
        ok1=0
        ok2=0
        if docker exec "${NODE1}" gluster peer status 2>/dev/null | grep -q "State: Peer in Cluster (Connected)"; then
            ok1=1
        fi
        if docker exec "${NODE2}" gluster peer status 2>/dev/null | grep -q "State: Peer in Cluster (Connected)"; then
            ok2=1
        fi
        if [ "${ok1}" -eq 1 ] && [ "${ok2}" -eq 1 ]; then
            pass "GlusterFS Trusted Pool da ket noi 2 chieu (${IP1} <-> ${IP2})"
            return 0
        fi
        sleep 0.3
    done
    fail "Peer GlusterFS giua ${IP1} va ${IP2} khong dat trang thai Connected"
}

clean_orphan_brick_xattrs() {
    local node="$1"
    docker exec "${node}" bash -c "
        set -euo pipefail
        brick='${BRICK_SUBDIR}'
        if [ -d \"\${brick}\" ]; then
            rm -rf \"\${brick}/.glusterfs\" \"\${brick}/.trashcan\"
            while IFS= read -r -d '' path; do
                attrs=\$(getfattr -m '^trusted\.' \"\${path}\" 2>/dev/null | grep -E '^trusted\.' || true)
                for a in \${attrs}; do
                    setfattr -x \"\${a}\" \"\${path}\" 2>/dev/null || true
                done
            done < <(find \"\${brick}\" -print0)
        else
            mkdir -p \"\${brick}\"
        fi
    "
}

ensure_volume_option() {
    local key="$1"
    local expected="$2"
    local current
    current="$(docker exec "${NODE1}" gluster volume get "${VOL_NAME}" "${key}" 2>/dev/null | awk -v k="${key}" '$1 == k {print $2}' | tail -n 1 || true)"
    if [ "${current}" != "${expected}" ]; then
        docker exec "${NODE1}" gluster volume set "${VOL_NAME}" "${key}" "${expected}" >/dev/null
    fi
}

ensure_gluster_volume() {
    if ! docker exec "${NODE1}" gluster volume info "${VOL_NAME}" >/dev/null 2>&1; then
        info "Chua co volume ${VOL_NAME} -> don xattr mo coi (neu co) & tao replica 2..."
        clean_orphan_brick_xattrs "${NODE1}"
        clean_orphan_brick_xattrs "${NODE2}"
        docker exec "${NODE1}" gluster volume create "${VOL_NAME}" replica 2 \
            "${IP1}:${BRICK_SUBDIR}" "${IP2}:${BRICK_SUBDIR}" force >/dev/null
        pass "Da tao volume ${VOL_NAME} (replica 2)"
    else
        pass "Volume ${VOL_NAME} da ton tai (giu nguyen du lieu)"
    fi

    ensure_volume_option "nfs.disable" "on"
    ensure_volume_option "server.allow-insecure" "on"
    ensure_volume_option "cluster.quorum-type" "none"
    ensure_volume_option "network.ping-timeout" "5"
    ensure_volume_option "cluster.self-heal-daemon" "on"
    pass "Da ap dung cac tuy chon HA cho ${VOL_NAME} (quorum=none, ping-timeout=5, shd=on)"

    if ! docker exec "${NODE1}" gluster volume info "${VOL_NAME}" 2>/dev/null | grep -qE '^Status:[[:space:]]*Started$'; then
        docker exec "${NODE1}" gluster volume start "${VOL_NAME}" >/dev/null
    fi

    local i st b1 b2 shd
    for i in $(seq 1 50); do
        st="$(docker exec "${NODE1}" gluster volume status "${VOL_NAME}" 2>/dev/null || true)"
        b1="$(printf '%s\n' "${st}" | awk -v t="Brick ${IP1}:${BRICK_SUBDIR}" 'index($0,t)==1 {print $(NF-1)}')"
        b2="$(printf '%s\n' "${st}" | awk -v t="Brick ${IP2}:${BRICK_SUBDIR}" 'index($0,t)==1 {print $(NF-1)}')"
        shd="$(printf '%s\n' "${st}" | awk '/^Self-heal Daemon on localhost/ {print $(NF-1)}')"
        if [ "${b1}" = "Y" ] && [ "${b2}" = "Y" ] && [ "${shd}" = "Y" ]; then
            pass "Volume ${VOL_NAME} da Started: 2/2 Brick online & Self-heal Daemon hoat dong"
            return 0
        fi
        sleep 0.3
    done
    fail "Timeout cho 2 brick va Self-heal Daemon cua ${VOL_NAME} online"
}

mount_gv0_temp() {
    docker exec "${NODE1}" bash -c "
        set -euo pipefail
        mkdir -p '${FUSE_MNT}'
        umount -lf '${FUSE_MNT}' 2>/dev/null || true
        mount -t glusterfs '127.0.0.1:/${VOL_NAME}' '${FUSE_MNT}'
    "
    MNT_ACTIVE=1
}

umount_gv0_temp() {
    if [ "${MNT_ACTIVE}" -eq 1 ]; then
        docker exec "${NODE1}" sh -c "umount -lf '${FUSE_MNT}' 2>/dev/null || true; rmdir '${FUSE_MNT}' 2>/dev/null || true"
        MNT_ACTIVE=0
    fi
}

ensure_export_subdirs() {
    mount_gv0_temp
    docker exec "${NODE1}" bash -c "
        set -euo pipefail
        mkdir -p '${FUSE_MNT}/share' '${FUSE_MNT}/no_squash'
        chmod 0777 '${FUSE_MNT}/share' '${FUSE_MNT}/no_squash'
        find '${FUSE_MNT}' -mindepth 1 -exec stat {} + >/dev/null
    "
    umount_gv0_temp
    pass "Da tao, dong bo GFID va cap quyen 0777 cho /share & /no_squash trong ${VOL_NAME}"
}

ensure_ganesha_ready() {
    local c1 c2 node
    c1="$(docker exec "${NODE1}" sha256sum /etc/ganesha/ganesha.conf | awk '{print $1}')"
    c2="$(docker exec "${NODE2}" sha256sum /etc/ganesha/ganesha.conf | awk '{print $1}')"
    if [ "${c1}" != "${c2}" ]; then
        fail "/etc/ganesha/ganesha.conf giua ${NODE1} va ${NODE2} khong giong nhau"
    fi
    pass "Cau hinh /etc/ganesha/ganesha.conf dong nhat tren ca 2 Node (${c1})"

    for node in "${NODE1}" "${NODE2}"; do
        docker exec "${node}" /usr/local/sbin/ganesha-ctl.sh start >/dev/null
        docker exec "${node}" /usr/local/bin/check_nfs.sh --verbose
    done
    pass "NFS-Ganesha (FSAL_GLUSTER) va check_nfs.sh dat 5/5 tren ca 2 Node"
}

verify_live_replication_and_vip() {
    local marker="gluster-live-probe-$(date +%s%N)"
    local rel_file="share/.ha_gluster_probe"
    local sha1 sha2 i

    mount_gv0_temp
    GLUSTER_PROBE="${FUSE_MNT}/${rel_file}"
    docker exec "${NODE1}" sh -c "printf '%s\n' '${marker}' > '${GLUSTER_PROBE}' && sync '${GLUSTER_PROBE}'"

    sha1="$(docker exec "${NODE1}" sha256sum "${BRICK_SUBDIR}/${rel_file}" | awk '{print $1}')"
    sha2="$(docker exec "${NODE2}" sha256sum "${BRICK_SUBDIR}/${rel_file}" | awk '{print $1}')"
    if [ -z "${sha1}" ] || [ "${sha1}" != "${sha2}" ]; then
        fail "Nhan ban song GlusterFS that bai (Brick1=${sha1:-missing}, Brick2=${sha2:-missing})"
    fi

    docker exec "${NODE1}" rm -f "${GLUSTER_PROBE}"
    GLUSTER_PROBE=""
    umount_gv0_temp
    pass "Nhan ban 2 chieu qua mang thanh cong: Brick 1 == Brick 2 (${sha1})"

    for i in $(seq 1 40); do
        if docker exec "${NODE1}" ip -4 addr show dev eth0 2>/dev/null | grep -qF "inet ${VIP}/"; then
            pass "${NODE1} dang giu Virtual IP ${VIP}/24"
            return 0
        fi
        sleep 0.3
    done
    fail "${NODE1} khong nhan duoc Virtual IP ${VIP} sau khi Ganesha san sang"
}

echo "=== [1/6] Khoi tao 2 thu muc Brick doc lap & kiem tra container ==="
for dir in "${REPO_ROOT}/shared-data/bricks/node1" "${REPO_ROOT}/shared-data/bricks/node2"; do
    mkdir -p "${dir}"
    chmod 0777 "${dir}"
done
check_container_running "${NODE1}"
check_container_running "${NODE2}"
verify_brick_isolation

echo "=== [2/6] Thiet lap Trusted Storage Pool (${IP1} <-> ${IP2}) ==="
wait_glusterd_ready "${NODE1}"
wait_glusterd_ready "${NODE2}"
ensure_peer_connected

echo "=== [3/6] Khoi tao & cau hinh HA cho GlusterFS volume ${VOL_NAME} (replica 2) ==="
ensure_gluster_volume

echo "=== [4/6] Khoi tao thu muc /share & /no_squash ben trong ${VOL_NAME} ==="
ensure_export_subdirs

echo "=== [5/6] Khoi chay NFS-Ganesha (FSAL_GLUSTER) & kiem tra check_nfs.sh ==="
ensure_ganesha_ready

echo "=== [6/6] Kiem chung nhan ban song qua mang & Keepalived VIP ${VIP} ==="
verify_live_replication_and_vip

echo ">>> Hoan tat khoi tao & kiem chuan GlusterFS Replica 2 + NFS-Ganesha + Keepalived! <<<"
