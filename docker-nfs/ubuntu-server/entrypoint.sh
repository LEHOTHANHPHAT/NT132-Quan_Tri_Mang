#!/bin/bash
set -e

KEEPALIVED_PID=""
MOUNTD_PID=""
CHECK_SCRIPT="/usr/local/bin/check_nfs.sh"

cleanup() {
    echo ">>> Nhan tin hieu dung container, thu hoi Keepalived & NFS... <<<"
    if [ -n "${KEEPALIVED_PID}" ] && kill -0 "${KEEPALIVED_PID}" 2>/dev/null; then
        kill -TERM "${KEEPALIVED_PID}" 2>/dev/null || true
    fi
    if [ -n "${MOUNTD_PID}" ] && kill -0 "${MOUNTD_PID}" 2>/dev/null; then
        kill -TERM "${MOUNTD_PID}" 2>/dev/null || true
    fi
    rpc.nfsd 0 2>/dev/null || true
    if [ -n "${KEEPALIVED_PID}" ]; then
        wait "${KEEPALIVED_PID}" 2>/dev/null || true
    fi
    if [ -n "${MOUNTD_PID}" ]; then
        wait "${MOUNTD_PID}" 2>/dev/null || true
    fi
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "=== [1/6] Khoi tao thu muc runtime & xu ly overlayfs cho /exports ==="
mkdir -p /run/sendsigs.omit.d /run/rpcbind /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery /etc/keepalived
rm -f /run/nfs_fault_inject /run/keepalived.pid /run/vrrp.pid /var/run/keepalived.pid

# Neu /exports nam tren overlayfs, chuyen goc /exports sang tmpfs va giu nguyen cac bind-mount con
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

VIP_CIDR="${KEEPALIVED_VIP:-192.168.10.100/24}"
if [ -n "${KEEPALIVED_STATE:-}" ] || [ -n "${KEEPALIVED_VIP:-}" ]; then
    ip addr del "${VIP_CIDR}" dev "${KEEPALIVED_INTERFACE:-eth0}" 2>/dev/null || true
fi

echo "=== [2/6] Mount he thong file nhan nfsd & rpc_pipefs ==="
modprobe nfsd 2>/dev/null || true
mount -t nfsd nfsd /proc/fs/nfsd 2>/dev/null || true
mount -t rpc_pipefs rpc_pipefs /var/lib/nfs/rpc_pipefs 2>/dev/null || true

# Tinh chinh NFSv4 lease/grace time truoc khi khoi chay luong nfsd
LEASE_TIME="${NFS_LEASE_TIME:-10}"
if [ -w /proc/fs/nfsd/nfsv4leasetime ]; then
    echo "${LEASE_TIME}" > /proc/fs/nfsd/nfsv4leasetime
fi
if [ -w /proc/fs/nfsd/nfsv4gracetime ]; then
    echo "${LEASE_TIME}" > /proc/fs/nfsd/nfsv4gracetime
fi

echo "=== [3/6] Khoi chay rpcbind & rpc.statd ==="
rpcbind -w
rpc.statd

echo "=== [4/6] Nap danh sach chia se tu /etc/exports ==="
exportfs -rv

echo "=== [5/6] Khoi chay 8 luong NFSv4 Server (Port 2049) ==="
# Bo co -N 2 vi Ubuntu 22.04 khong con ho tro co NFSv2
rpc.nfsd -V 4 -N 3 8
rpc.mountd --foreground --no-nfs-version 3 &
MOUNTD_PID=$!

echo ">>> NFS Server Ubuntu da san sang tren cong 2049 (Lease/Grace=${LEASE_TIME}s)! <<<"

if [ -n "${KEEPALIVED_STATE:-}" ]; then
    echo "=== [6/6] Cau hinh & khoi chay Keepalived (${KEEPALIVED_STATE}, priority=${KEEPALIVED_PRIORITY:-100}) ==="
    if [ -f "${CHECK_SCRIPT}" ]; then
        cp "${CHECK_SCRIPT}" /usr/local/sbin/check_nfs_runtime.sh
        chown root:root /usr/local/sbin/check_nfs_runtime.sh
        chmod 0755 /usr/local/sbin/check_nfs_runtime.sh
        KA_SCRIPT="/usr/local/sbin/check_nfs_runtime.sh"
    else
        KA_SCRIPT="${CHECK_SCRIPT}"
    fi

    cat > /etc/keepalived/keepalived.conf <<EOF
global_defs {
    router_id ${HOSTNAME:-nfs-node}
    script_user root
    enable_script_security
}

vrrp_script chk_nfs {
    script "${KA_SCRIPT}"
    interval 1
    timeout 1
    fall 2
    rise 2
}

vrrp_instance VI_NFS {
    state ${KEEPALIVED_STATE}
    interface ${KEEPALIVED_INTERFACE:-eth0}
    virtual_router_id ${KEEPALIVED_VRID:-51}
    priority ${KEEPALIVED_PRIORITY:-100}
    advert_int 1
    garp_master_delay 1
    garp_master_repeat 3
    garp_master_refresh 5

    unicast_src_ip ${KEEPALIVED_UNICAST_SRC}
    unicast_peer {
        ${KEEPALIVED_UNICAST_PEER}
    }

    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_PASS:-nt132ha}
    }

    virtual_ipaddress {
        ${VIP_CIDR}
    }

    track_script {
        chk_nfs
    }
}
EOF

    keepalived --dont-fork --log-console --log-detail &
    KEEPALIVED_PID=$!
    echo ">>> Keepalived da khoi chay (VIP=${VIP_CIDR})! <<<"
    while kill -0 "${KEEPALIVED_PID}" 2>/dev/null; do
        wait "${KEEPALIVED_PID}" 2>/dev/null || break
    done
else
    wait "${MOUNTD_PID}"
fi
