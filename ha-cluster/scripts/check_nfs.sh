#!/bin/bash
###############################################################################
# check_nfs.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Healthcheck dịch vụ NFS cho Keepalived
#
# Kiểm tra tuần tự 5 điều kiện sức khỏe của NFSv4 Server:
#   1. Không có tệp cờ giả lập lỗi /run/nfs_fault_inject
#   2. Luồng kernel nfsd đang hoạt động (/proc/fs/nfsd/threads > 0)
#   3. Tiến trình rpc.mountd đang chạy
#   4. Cổng TCP 2049 đang ở trạng thái LISTEN
#   5. Bảng exportfs -s đang chia sẻ /exports/share
#
# Cách dùng:
#   /usr/local/bin/check_nfs.sh           # Chế độ im lặng cho Keepalived
#   /usr/local/bin/check_nfs.sh --verbose # In chi tiết từng bước kiểm tra
###############################################################################
set -u

VERBOSE=0
if [ "${1:-}" = "--verbose" ] || [ "${1:-}" = "-v" ]; then
    VERBOSE=1
fi

log_ok() {
    if [ "${VERBOSE}" -eq 1 ]; then
        printf '[OK]   %s\n' "$1"
    fi
}

log_fail() {
    if [ "${VERBOSE}" -eq 1 ]; then
        printf '[FAIL] %s\n' "$1" >&2
    fi
}

# 1. Kiểm tra cờ giả lập sự cố dịch vụ
if [ -e /run/nfs_fault_inject ]; then
    log_fail "Phat hien co gia lap loi /run/nfs_fault_inject"
    exit 1
fi
log_ok "Khong co co gia lap loi /run/nfs_fault_inject"

# 2. Kiểm tra số luồng nhân nfsd
if [ ! -r /proc/fs/nfsd/threads ]; then
    log_fail "Khong doc duoc /proc/fs/nfsd/threads (nfsd chua mount)"
    exit 1
fi
NFSD_THREADS="$(tr -d '[:space:]' < /proc/fs/nfsd/threads 2>/dev/null || echo 0)"
if ! [[ "${NFSD_THREADS}" =~ ^[0-9]+$ ]] || [ "${NFSD_THREADS}" -le 0 ]; then
    log_fail "So luong nfsd = ${NFSD_THREADS:-0} (<= 0)"
    exit 1
fi
log_ok "Luong kernel nfsd dang chay: ${NFSD_THREADS}"

# 3. Kiểm tra tiến trình rpc.mountd
if ! pgrep -x rpc.mountd >/dev/null 2>&1; then
    log_fail "Tien trinh rpc.mountd khong hoat dong"
    exit 1
fi
log_ok "Tien trinh rpc.mountd dang hoat dong"

# 4. Kiểm tra cổng TCP 2049 đang LISTEN
if ! ss -ltn 2>/dev/null | grep -qE '[:.]2049([[:space:]]|$)'; then
    log_fail "Cong TCP 2049 khong o trang thai LISTEN"
    exit 1
fi
log_ok "Cong TCP 2049 dang LISTEN"

# 5. Kiểm tra bảng exportfs
if ! exportfs -s 2>/dev/null | grep -q '/exports/share'; then
    log_fail "Khong tim thay /exports/share trong exportfs -s"
    exit 1
fi
log_ok "Bang exportfs -s co /exports/share"

exit 0
