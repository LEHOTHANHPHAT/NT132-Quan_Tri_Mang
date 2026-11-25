#!/bin/bash
###############################################################################
# check_nfs.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Healthcheck NFS-Ganesha + GlusterFS cho Keepalived
#
# Kiểm tra nhanh (< 50 ms, không gọi gluster CLI RPC) 5 điều kiện sức khỏe:
#   1. Không có tệp cờ giả lập lỗi /run/nfs_fault_inject
#   2. Tiến trình ganesha.nfsd đang chạy
#   3. Tiến trình glusterd đang chạy
#   4. Tiến trình brick cục bộ glusterfsd đang chạy
#   5. Cổng TCP 2049 đang ở trạng thái LISTEN
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

# 2. Kiểm tra tiến trình ganesha.nfsd
if ! pgrep -x ganesha.nfsd >/dev/null 2>&1; then
    log_fail "Tien trinh ganesha.nfsd khong hoat dong"
    exit 1
fi
log_ok "Tien trinh ganesha.nfsd dang hoat dong"

# 3. Kiểm tra tiến trình glusterd
if ! pgrep -x glusterd >/dev/null 2>&1; then
    log_fail "Tien trinh glusterd khong hoat dong"
    exit 1
fi
log_ok "Tien trinh glusterd dang hoat dong"

# 4. Kiểm tra tiến trình brick cục bộ glusterfsd
if ! pgrep -x glusterfsd >/dev/null 2>&1; then
    log_fail "Tien trinh brick glusterfsd khong hoat dong"
    exit 1
fi
log_ok "Tien trinh brick glusterfsd dang hoat dong"

# 5. Kiểm tra cổng TCP 2049 đang LISTEN
if ! ss -ltn 2>/dev/null | grep -qE '[:.]2049([[:space:]]|$)'; then
    log_fail "Cong TCP 2049 khong o trang thai LISTEN"
    exit 1
fi
log_ok "Cong TCP 2049 dang LISTEN"

exit 0
