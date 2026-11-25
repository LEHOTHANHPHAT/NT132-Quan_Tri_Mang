#!/bin/bash
###############################################################################
# setup-fstab-boot.sh
# Cau hinh mount TU DONG NGAY LUC BOOT qua /etc/fstab (khong dung automount
# on-demand). Dung rieng cho demo "mount tu dong qua fstab" trong bao cao,
# TACH BACH voi phan "systemd .mount/.automount" (on-demand, xem thu muc
# client-configs/systemd/).
###############################################################################
set -euo pipefail

NFS_SERVER="192.168.10.11"
NFS_EXPORT="/share"
MOUNT_POINT="/mnt/nfs/share"
MODE="${1:-rw}"   # rw | ro

mkdir -p "${MOUNT_POINT}"

# Khong co "noauto"/"x-systemd.automount": mount se duoc thuc hien NGAY
# luc he thong boot, khong can truy cap truoc.
FSTAB_LINE="${NFS_SERVER}:${NFS_EXPORT}  ${MOUNT_POINT}  nfs4  ${MODE},vers=4.2,sec=sys,hard,intr,_netdev  0  0"

if grep -qs "${MOUNT_POINT}" /etc/fstab; then
    echo "Da ton tai entry cho ${MOUNT_POINT} trong /etc/fstab, bo qua ghi them."
else
    cp /etc/fstab /etc/fstab.bak.$(date +%s)
    echo "${FSTAB_LINE}" >> /etc/fstab
    echo "Da them dong sau vao /etc/fstab:"
    echo "  ${FSTAB_LINE}"
fi

echo
echo "=== Mount ngay (mo phong 'mount -a' luc boot) ==="
mount -a -t nfs4

echo
echo "Kiem tra:"
echo "  mount | grep nfs4"