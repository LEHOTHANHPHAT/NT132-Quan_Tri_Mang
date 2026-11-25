#!/bin/bash
###############################################################################
# ganesha-ctl.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Điều khiển vòng đời tiến trình NFS-Ganesha
###############################################################################
set -euo pipefail

GANESHA_CONF="/etc/ganesha/ganesha.conf"
GANESHA_LOG="/var/log/ganesha/ganesha.log"
GANESHA_STDOUT="/var/log/ganesha/ganesha-stdout.log"
GANESHA_PID_FILE="/run/ganesha/ganesha.pid"

is_running() {
    pgrep -x ganesha.nfsd >/dev/null 2>&1
}

is_port_2049_listening() {
    ss -ltn 2>/dev/null | grep -qE '[:.]2049([[:space:]]|$)'
}

print_logs_tail() {
    echo "--- /var/log/ganesha/ganesha.log (tail) ---" >&2
    tail -n 30 "${GANESHA_LOG}" 2>/dev/null >&2 || true
    echo "--- /var/log/ganesha/ganesha-stdout.log (tail) ---" >&2
    tail -n 20 "${GANESHA_STDOUT}" 2>/dev/null >&2 || true
}

start_ganesha() {
    mkdir -p /run/ganesha /var/log/ganesha /var/lib/nfs/ganesha
    if is_running && is_port_2049_listening; then
        echo "ganesha.nfsd da hoat dong tren cong 2049."
        return 0
    fi

    if is_running; then
        pkill -TERM -x ganesha.nfsd 2>/dev/null || true
        sleep 0.5
    fi

    rm -f "${GANESHA_PID_FILE}"
    ganesha.nfsd -F -f "${GANESHA_CONF}" -L "${GANESHA_LOG}" -p "${GANESHA_PID_FILE}" -N NIV_EVENT \
        </dev/null >"${GANESHA_STDOUT}" 2>&1 &

    local i=0
    while [ "$i" -lt 75 ]; do
        if is_running && is_port_2049_listening; then
            echo "ganesha.nfsd da san sang tren cong TCP 2049."
            return 0
        fi
        if ! is_running && [ "$i" -ge 5 ]; then
            echo "[FAIL] ganesha.nfsd thoat som bat thuong khi khoi dong." >&2
            print_logs_tail
            return 1
        fi
        sleep 0.2
        i=$((i + 1))
    done

    echo "[FAIL] Timeout 15s cho ganesha.nfsd mo cong TCP 2049." >&2
    print_logs_tail
    return 1
}

stop_ganesha() {
    if ! is_running; then
        rm -f "${GANESHA_PID_FILE}"
        return 0
    fi

    pkill -TERM -x ganesha.nfsd 2>/dev/null || true
    local i=0
    while [ "$i" -lt 5 ]; do
        if ! is_running; then
            rm -f "${GANESHA_PID_FILE}"
            echo "ganesha.nfsd da dung."
            return 0
        fi
        sleep 0.2
        i=$((i + 1))
    done

    pkill -KILL -x ganesha.nfsd 2>/dev/null || true
    rm -f "${GANESHA_PID_FILE}"
    echo "ganesha.nfsd da bi ep dung (SIGKILL)."
}

status_ganesha() {
    if is_running && is_port_2049_listening; then
        echo "ganesha.nfsd RUNNING (TCP 2049 LISTEN)"
        return 0
    fi
    echo "ganesha.nfsd STOPPED"
    return 1
}

case "${1:-}" in
    start)
        start_ganesha
        ;;
    stop)
        stop_ganesha
        ;;
    status)
        status_ganesha
        ;;
    *)
        echo "Su dung: $0 {start|stop|status}" >&2
        exit 2
        ;;
esac
