#!/bin/bash
set -euo pipefail

KEEPALIVED_PID=""
CHECK_SCRIPT="/usr/local/bin/check_nfs.sh"
GLUSTERD_VOL="/etc/glusterfs/glusterd.vol"

cleanup() {
    echo ">>> Nhan tin hieu dung container, thu hoi Keepalived, Ganesha & GlusterFS... <<<"
    if [ -n "${KEEPALIVED_PID}" ] && kill -0 "${KEEPALIVED_PID}" 2>/dev/null; then
        kill -TERM "${KEEPALIVED_PID}" 2>/dev/null || true
    fi
    pkill -TERM -x ganesha.nfsd 2>/dev/null || true
    pkill -TERM -x glusterfsd 2>/dev/null || true
    pkill -TERM -x glusterfs 2>/dev/null || true
    pkill -TERM -x glusterd 2>/dev/null || true

    local i=0
    while [ "$i" -lt 40 ]; do
        if ! pgrep -x keepalived >/dev/null 2>&1 && \
           ! pgrep -x ganesha.nfsd >/dev/null 2>&1 && \
           ! pgrep -x glusterfsd >/dev/null 2>&1 && \
           ! pgrep -x glusterd >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
        i=$((i + 1))
    done
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "=== [1/5] Don dep trang thai runtime & VIP cu ==="
rm -rf /run/gluster/* /run/ganesha/* /run/dbus/* /run/rpcbind/* \
       /run/nfs_fault_inject /run/glusterd* /run/keepalived*.pid \
       /run/vrrp.pid /var/run/keepalived*.pid /run/rpcbind.lock /run/rpcbind.sock
mkdir -p /data/brick /var/lib/glusterd /var/log/glusterfs /var/log/ganesha \
         /run/ganesha /run/gluster /run/dbus /run/rpcbind /etc/keepalived /var/lib/nfs/ganesha

VIP_CIDR="${KEEPALIVED_VIP:-192.168.10.100/24}"
if [ -n "${KEEPALIVED_STATE:-}" ] || [ -n "${KEEPALIVED_VIP:-}" ]; then
    ip addr del "${VIP_CIDR}" dev "${KEEPALIVED_INTERFACE:-eth0}" 2>/dev/null || true
fi

echo "=== [2/5] Cau hinh rpc-auth-allow-insecure trong ${GLUSTERD_VOL} ==="
if [ -f "${GLUSTERD_VOL}" ] && ! grep -q "rpc-auth-allow-insecure" "${GLUSTERD_VOL}"; then
    sed -i '/^[[:space:]]*end-volume/i \    option rpc-auth-allow-insecure on' "${GLUSTERD_VOL}"
fi

echo "=== [3/5] Khoi chay D-Bus, rpcbind & glusterd ==="
dbus-uuidgen --ensure >/dev/null 2>&1 || true
dbus-daemon --system --fork
rpcbind -w
/usr/sbin/glusterd --log-level INFO

glusterd_ready=0
for _ in $(seq 1 50); do
    if gluster peer status >/dev/null 2>&1; then
        glusterd_ready=1
        break
    fi
    sleep 0.2
done
if [ "${glusterd_ready}" -ne 1 ]; then
    echo "[FAIL] glusterd khong san sang sau 10s" >&2
    exit 1
fi
echo ">>> glusterd da san sang! <<<"

if [ -n "${KEEPALIVED_STATE:-}" ]; then
    echo "=== [4/5] Cau hinh & khoi chay Keepalived (${KEEPALIVED_STATE}, priority=${KEEPALIVED_PRIORITY:-100}) ==="
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
fi

echo "=== [5/5] Kiem tra trang thai volume gv0 & auto-recovery Ganesha ==="
if gluster volume info gv0 2>/dev/null | grep -qE '^Status:[[:space:]]*Started$'; then
    echo "Phat hien gv0 da Started -> cho glusterfsd san sang, kich hoat Self-Heal & bat Ganesha..."
    for _ in $(seq 1 75); do
        if pgrep -x glusterfsd >/dev/null 2>&1 && ss -ltnp 2>/dev/null | grep -q "glusterfsd"; then
            break
        fi
        sleep 0.2
    done
    gluster volume heal gv0 >/dev/null 2>&1 &
    /usr/local/sbin/ganesha-ctl.sh start
else
    echo "Volume gv0 chua khoi tao -> cho setup-shared-storage.sh bootstrap."
fi

if [ -n "${KEEPALIVED_PID}" ]; then
    while kill -0 "${KEEPALIVED_PID}" 2>/dev/null; do
        wait "${KEEPALIVED_PID}" 2>/dev/null || break
    done
else
    while pgrep -x glusterd >/dev/null 2>&1; do
        sleep 1
    done
fi
