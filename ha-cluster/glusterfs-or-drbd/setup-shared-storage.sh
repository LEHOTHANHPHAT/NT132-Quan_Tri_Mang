#!/bin/bash
###############################################################################
# setup-shared-storage.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Chuẩn bị & Kiểm chứng Shared Storage + NFSv4 State
#
# Chức năng:
#   1. Khởi tạo và cấp quyền cho shared-data/{public,restricted,v4recovery}
#   2. Kiểm tra trạng thái chạy của nfs-ubuntu-node1 và nfs-ubuntu-node2
#   3. Kiểm chứng đồng bộ dữ liệu & inode tức thời trên /exports/share
#   4. Đối chiếu cấu hình /etc/exports (fsid=0,1,2) đồng nhất giữa 2 Node
#   5. Kiểm tra nfsv4leasetime=10, nfsv4gracetime=10 và đồng bộ /var/lib/nfs/v4recovery
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NODE1="nfs-ubuntu-node1"
NODE2="nfs-ubuntu-node2"
EXPECTED_LEASE_TIME="${NFS_LEASE_TIME:-10}"
ACTIVE_PROBE_PATH=""

cleanup_probe() {
    if [ -n "${ACTIVE_PROBE_PATH}" ]; then
        docker exec "${NODE1}" rm -f "${ACTIVE_PROBE_PATH}" 2>/dev/null || true
        ACTIVE_PROBE_PATH=""
    fi
}
trap cleanup_probe EXIT

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

check_container_running() {
    local container="$1"
    local running
    running="$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || echo "false")"
    if [ "${running}" != "true" ]; then
        fail "Container ${container} chua chay. Hay khoi dong bang: docker compose -f docker-nfs/docker-compose.yml up -d --build"
    fi
    pass "Container ${container} dang hoat dong"
}

verify_shared_inode() {
    local container_dir="$1"
    local probe_name="$2"
    local probe_path="${container_dir}/${probe_name}"
    local marker="ha-probe-$(date +%s%N)"

    ACTIVE_PROBE_PATH="${probe_path}"
    docker exec "${NODE1}" sh -c "printf '%s\n' '${marker}' > '${probe_path}'"

    local content_n2 inode_n1 inode_n2
    content_n2="$(docker exec "${NODE2}" cat "${probe_path}" 2>/dev/null || true)"
    inode_n1="$(docker exec "${NODE1}" stat -c '%i' "${probe_path}" 2>/dev/null || echo "0")"
    inode_n2="$(docker exec "${NODE2}" stat -c '%i' "${probe_path}" 2>/dev/null || echo "1")"

    if [ "${content_n2}" != "${marker}" ]; then
        fail "Noi dung probe tai ${probe_path} khong dong bo giua ${NODE1} va ${NODE2}"
    fi
    if [ "${inode_n1}" != "${inode_n2}" ] || [ "${inode_n1}" = "0" ]; then
        fail "Inode tai ${probe_path} khong khop (${NODE1}=${inode_n1}, ${NODE2}=${inode_n2})"
    fi

    docker exec "${NODE1}" rm -f "${probe_path}"
    ACTIVE_PROBE_PATH=""
    pass "Dong bo ${container_dir} giua 2 Node thanh cong (inode=${inode_n1})"
}

verify_exports_fsid() {
    local exp1 exp2
    exp1="$(docker exec "${NODE1}" cat /etc/exports | tr -d '\r')"
    exp2="$(docker exec "${NODE2}" cat /etc/exports | tr -d '\r')"
    if [ "${exp1}" != "${exp2}" ]; then
        fail "/etc/exports giua ${NODE1} va ${NODE2} khong giong nhau"
    fi
    for fsid in "fsid=0" "fsid=1" "fsid=2"; do
        if ! printf '%s\n' "${exp1}" | grep -q "${fsid}"; then
            fail "Thieu ${fsid} trong /etc/exports"
        fi
    done
    pass "Cau hinh /etc/exports dong nhat voi fsid=0, fsid=1, fsid=2 tren ca 2 Node"
}

verify_nfsv4_timers() {
    local node param val
    for node in "${NODE1}" "${NODE2}"; do
        for param in nfsv4leasetime nfsv4gracetime; do
            val="$(docker exec "${node}" cat "/proc/fs/nfsd/${param}" 2>/dev/null | tr -d '[:space:]' || echo "")"
            if [ "${val}" != "${EXPECTED_LEASE_TIME}" ]; then
                fail "${node} /proc/fs/nfsd/${param}=${val:-unset} (ky vong ${EXPECTED_LEASE_TIME})"
            fi
        done
    done
    pass "Tham so nfsv4leasetime=${EXPECTED_LEASE_TIME} va nfsv4gracetime=${EXPECTED_LEASE_TIME} tren ca 2 Node"
}

echo "=== [1/5] Khoi tao thu muc Shared Storage tren Host ==="
for dir in "${REPO_ROOT}/shared-data/public" "${REPO_ROOT}/shared-data/restricted" "${REPO_ROOT}/shared-data/v4recovery"; do
    mkdir -p "${dir}"
    chmod 777 "${dir}"
done
pass "Da chuan bi thu muc shared-data/{public,restricted,v4recovery}"

echo "=== [2/5] Kiem tra trang thai 2 NFS Server container ==="
check_container_running "${NODE1}"
check_container_running "${NODE2}"

echo "=== [3/5] Kiem chung dong bo du lieu & inode tren /exports/share ==="
verify_shared_inode "/exports/share" ".ha_storage_sync_probe"

echo "=== [4/5] Doi chieu fsid trong /etc/exports giua 2 Node ==="
verify_exports_fsid

echo "=== [5/5] Kiem tra Lease/Grace time va dong bo /var/lib/nfs/v4recovery ==="
verify_nfsv4_timers
verify_shared_inode "/var/lib/nfs/v4recovery" ".ha_v4recovery_probe"

echo ">>> Tat ca kiem tra Shared Storage & State Recovery da dat! <<<"
