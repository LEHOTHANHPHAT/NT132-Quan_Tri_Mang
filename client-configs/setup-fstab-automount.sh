#!/bin/bash
###############################################################################
# setup-fstab-automount.sh
# Cau hinh mount tu dong qua /etc/fstab (cach 1 trong 2 cach automount)
#
# Luu y quan trong voi fstab + NFS:
#   - "_netdev"  : bao he thong doi mang san sang roi moi mount (quan trong
#                  tren may vat ly/VM boot that; trong container lab co the
#                  bo qua nhung van nen giu de dung thuc te doanh nghiep)
#   - "hard,intr": neu server rot mang, tien trinh client se cho thay vi loi
#                  ngay (an toan du lieu hon "soft")
#   - "x-systemd.automount, x-systemd.mount-timeout=10, noauto"
#                : ket hop fstab voi systemd automount (mount khi co truy cap
#                  thuc te, khong lam cham qua trinh boot neu server down)
###############################################################################
set -euo pipefail

NFS_SERVER="192.168.10.11"
# "/exports" tren server la pseudo-root (fsid=0) -> client phai dung
# duong dan tuong doi "/share", KHONG dung "/exports/share".
NFS_EXPORT="/share"
MOUNT_POINT="/mnt/nfs/share"
MODE="${1:-rw}"   # rw | ro, tuy client-rw hay client-ro

mkdir -p "${MOUNT_POINT}"

FSTAB_LINE="${NFS_SERVER}:${NFS_EXPORT}  ${MOUNT_POINT}  nfs4  ${MODE},vers=4.2,sec=sys,hard,intr,_netdev,x-systemd.automount,x-systemd.mount-timeout=10,noauto  0  0"

if grep -qs "${MOUNT_POINT}" /etc/fstab; then
    echo "Da ton tai entry cho ${MOUNT_POINT} trong /etc/fstab, bo qua ghi them."
else
    cp /etc/fstab /etc/fstab.bak.$(date +%s)
    echo "${FSTAB_LINE}" >> /etc/fstab
    echo "Da them dong sau vao /etc/fstab:"
    echo "  ${FSTAB_LINE}"
fi

echo
echo "=== Nap lai systemd va kich hoat mount ==="
systemctl daemon-reload
# Vi dung "noauto" + x-systemd.automount, mountpoint se duoc quan ly
# boi don vi *.automount tu dong sinh tu fstab (xem: systemctl list-units '*.automount')
systemctl start "$(systemd-escape -p --suffix=automount "${MOUNT_POINT}")" || true

echo
echo "Kiem tra:"
echo "  systemctl status $(systemd-escape -p --suffix=automount "${MOUNT_POINT}")"
echo "  ls ${MOUNT_POINT}   # truy cap se kich hoat mount thuc su (on-demand)"
echo "  mount | grep nfs4"