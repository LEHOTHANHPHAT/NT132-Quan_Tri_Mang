#!/bin/bash
set -e

echo "=== [1/5] Khoi tao thu muc runtime & xu ly overlayfs cho /exports ==="
mkdir -p /run/sendsigs.omit.d /run/rpcbind /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery

# Neu /exports nam tren overlayfs, chuyen gốc /exports sang tmpfs va giữ nguyen cac bind-mount con
if ! grep -qs "/exports " /proc/mounts; then
    mkdir -p /tmp/share_bak /tmp/no_squash_bak
    mount --bind /exports/share /tmp/share_bak
    mount --bind /exports/no_squash /tmp/no_squash_bak
    mount -t tmpfs tmpfs /exports
    mkdir -p /exports/share /exports/no_squash
    mount --bind /tmp/share_bak /exports/share
    mount --bind /tmp/no_squash_bak /exports/no_squash
fi

chmod 777 /exports/share /exports/no_squash

echo "=== [2/5] Mount he thong file nhan nfsd & rpc_pipefs ==="
mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
mount -t rpc_pipefs rpc_pipefs /var/lib/nfs/rpc_pipefs 2>/dev/null || true

echo "=== [3/5] Khoi chay rpcbind & rpc.statd ==="
rpcbind -w
rpc.statd

echo "=== [4/5] Nap danh sach chia se tu /etc/exports ==="
exportfs -rv

echo "=== [5/5] Khoi chay 8 luong NFSv4 Server (Port 2049) ==="
# Bo co -N 2 vi Ubuntu 22.04 không con hỗ trợ cờ NFSv2
rpc.nfsd -V 4 -N 3 8

echo ">>> NFS Server Ubuntu da san sang tren cong 2049! <<<"
exec rpc.mountd --foreground --no-nfs-version 3
