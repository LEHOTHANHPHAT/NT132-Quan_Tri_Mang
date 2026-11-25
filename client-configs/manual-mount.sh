#!/bin/bash
###############################################################################
# manual-mount.sh
# Thành viên 3 - NFS Client, Mount & Bao mat
#
# Muc dich:
#   - Cai goi client NFS (nfs-common) tren cac may client khac nhau
#   - Kiem tra ket noi RPC toi NFS Server cua TV2 (docker-nfs/)
#   - Thuc nghiem mount thu cong bang `mount -t nfs4` voi nhieu option
#   - Kiem chung quyen rw/ro theo dung thiet ke trong /etc/exports cua TV2
#
# Topology (theo docker-compose.yml cua TV2):
#   nfs-node1   = 192.168.10.11   export: /exports/share (rw cho .101, ro cho subnet)
#   nfs-node2   = 192.168.10.12   (node du phong, dung lai sau khi xem HA - TV4)
#   client-rw   = 192.168.10.101  -> duoc cap quyen RW tren /share
#   client-ro   = 192.168.10.102  -> chi duoc quyen RO tren /share
#
# Chay script nay TREN TUNG CLIENT, truyen vao che do: rw | ro
#   ./manual-mount.sh rw
#   ./manual-mount.sh ro
###############################################################################
set -euo pipefail

MODE="${1:-rw}"                      # rw hoac ro
NFS_SERVER="192.168.10.11"           # nfs-node1 cua TV2
# LUU Y QUAN TRONG: /etc/exports tren server khai bao "/exports" la
# pseudo-root (fsid=0). Vi vay duong dan CLIENT phai go la "/share",
# KHONG PHAI "/exports/share" (do la duong dan that tren DIA SERVER,
# khong phai duong dan trong khong gian NFSv4 ma client nhin thay).
NFS_EXPORT="/share"
MOUNT_POINT="/mnt/nfs/share"

echo "=== [1/5] Cai dat goi NFS client (nfs-common) ==="
if ! command -v mount.nfs4 >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y nfs-common
else
    echo "nfs-common da duoc cai dat, bo qua."
fi

echo "=== [2/5] Kiem tra RPC/portmapper toi server ${NFS_SERVER} ==="
# NFSv4 chi dung 1 cong duy nhat 2049/tcp (khong can rpcbind nhu v3),
# nhung van kiem tra rpcinfo de chan doan nhanh khi loi.
rpcinfo -p "${NFS_SERVER}" || echo "Luu y: rpcinfo co the khong tra loi tren NFSv4-only server, van co the mount binh thuong."

echo "=== [3/5] Tao thu muc mount point ==="
mkdir -p "${MOUNT_POINT}"

echo "=== [4/5] Mount thu cong bang 'mount -t nfs4' (che do: ${MODE}) ==="
case "${MODE}" in
  rw)
    # client-rw (192.168.10.101) duoc exports cap quyen rw tuong minh theo IP
    mount -t nfs4 -o vers=4.2,sec=sys,rw,hard,intr \
        "${NFS_SERVER}:${NFS_EXPORT}" "${MOUNT_POINT}"
    ;;
  ro)
    # client-ro (192.168.10.102) chi nam trong dai subnet duoc cap ro
    mount -t nfs4 -o vers=4.2,sec=sys,ro,hard,intr \
        "${NFS_SERVER}:${NFS_EXPORT}" "${MOUNT_POINT}"
    ;;
  *)
    echo "Che do khong hop le. Dung: rw hoac ro" >&2
    exit 1
    ;;
esac

echo "=== [5/5] Kiem chung ket qua mount ==="
mount | grep nfs4
df -hT "${MOUNT_POINT}"

echo
echo ">>> Test quyen ghi thuc te:"
if touch "${MOUNT_POINT}/test-${MODE}-$(hostname).txt" 2>/dev/null; then
    echo "  -> GHI THANH CONG (dung voi client duoc cap quyen rw)"
else
    echo "  -> KHONG THE GHI (dung voi client chi duoc cap quyen ro / root_squash)"
fi

echo
echo "De go mount: umount ${MOUNT_POINT}"