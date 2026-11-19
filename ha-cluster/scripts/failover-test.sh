#!/bin/bash
###############################################################################
# failover-test.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Kiểm thử Failover & Failback Cụm NFS HA
#
# Kịch bản thực nghiệm:
#   - Hỗ trợ 2 chế độ lỗi:
#       * service : Giả lập lỗi dịch vụ NFS (container vẫn bật, rpc.nfsd dừng)
#       * hard    : Giả lập sập nguồn/container (docker stop nfs-ubuntu-node1)
#   - Client 1 (rw) ghi liên tục 20 dòng qua VIP 192.168.10.100:/share
#   - Đo thời gian chuyển mạch VIP (RTO < 5s) sang nfs-ubuntu-node2
#   - Kiểm chứng SHA-256 trước/sau sự cố (RPO = 0), quyền ro trên Client 2,
#     và tự động khôi phục (Failback) về nfs-ubuntu-node1.
#
# Cách dùng:
#   ./ha-cluster/scripts/failover-test.sh [--mode service|hard|both]
###############################################################################
set -euo pipefail

NODE1="nfs-ubuntu-node1"
NODE2="nfs-ubuntu-node2"
CLIENT1="nfs-client-1"
CLIENT2="nfs-client-2"
VIP="192.168.10.100"
VIP_MOUNT_OPTS="vers=4,hard,timeo=50,retrans=2,proto=tcp"
TOTAL_LINES=20

MODE="both"
PAYLOAD_FILE=""
WRITER_PID=""

usage() {
    echo "Su dung: $0 [--mode service|hard|both]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)
            [ $# -ge 2 ] || usage
            MODE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Tham so khong hop le: $1" >&2
            usage
            ;;
    esac
done

case "${MODE}" in
    service|hard|both) ;;
    *)
        echo "Che do khong hop le: ${MODE} (chi ho tro: service, hard, both)" >&2
        exit 2
        ;;
esac

info() { printf '[INFO] %s\n' "$1"; }
pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

is_running() {
    [ "$(timeout 2 docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo "false")" = "true" ]
}

has_vip() {
    local node="$1"
    is_running "${node}" || return 1
    timeout 2 docker exec "${node}" ip -4 addr show dev eth0 2>/dev/null | grep -qF "inet ${VIP}/"
}

wait_for_vip() {
    local node="$1"
    local timeout_s="$2"
    local t_start_ms now_ms deadline_ms
    t_start_ms="$(date +%s%3N)"
    deadline_ms=$((t_start_ms + timeout_s * 1000))
    while true; do
        if has_vip "${node}"; then
            now_ms="$(date +%s%3N)"
            printf '%s\n' "$((now_ms - t_start_ms))"
            return 0
        fi
        now_ms="$(date +%s%3N)"
        if [ "${now_ms}" -ge "${deadline_ms}" ]; then
            return 1
        fi
        sleep 0.15
    done
}

restore_node1_if_needed() {
    if ! is_running "${NODE1}"; then
        docker start "${NODE1}" >/dev/null 2>&1 || true
    else
        docker exec "${NODE1}" sh -c '
            rm -f /run/nfs_fault_inject
            threads=$(tr -d "[:space:]" < /proc/fs/nfsd/threads 2>/dev/null || echo 0)
            if [ "${threads:-0}" -le 0 ] || ! exportfs -s 2>/dev/null | grep -q "/exports/share"; then
                exportfs -rv >/dev/null
                rpc.nfsd -V 4 -N 3 8
            fi
        ' >/dev/null 2>&1 || true
    fi
}

cleanup_on_exit() {
    if [ -n "${WRITER_PID}" ] && kill -0 "${WRITER_PID}" 2>/dev/null; then
        kill "${WRITER_PID}" 2>/dev/null || true
        wait "${WRITER_PID}" 2>/dev/null || true
    fi
    if [ -n "${PAYLOAD_FILE}" ] && [ -f "${PAYLOAD_FILE}" ]; then
        rm -f "${PAYLOAD_FILE}"
    fi
    restore_node1_if_needed
}
trap cleanup_on_exit EXIT

ensure_cluster_ready() {
    info "Kiem tra trang thai 4 container & dam bao ${NODE1} giu VIP ${VIP}..."
    for c in "${NODE2}" "${CLIENT1}" "${CLIENT2}"; do
        is_running "${c}" || fail "Container ${c} chua chay"
    done
    restore_node1_if_needed
    if ! wait_for_vip "${NODE1}" 20 >/dev/null; then
        fail "Het thoi gian cho ${NODE1} nhan lai VIP ${VIP}"
    fi
    pass "${NODE1} dang la MASTER va giu VIP ${VIP}"
}

mount_client_via_vip() {
    local client="$1"
    docker exec "${client}" sh -c "
        umount -lf /mnt/nfs/share 2>/dev/null || true
        mkdir -p /mnt/nfs/share
        mount -t nfs4 -o ${VIP_MOUNT_OPTS} ${VIP}:/share /mnt/nfs/share
    "
    pass "Da mount ${VIP}:/share tren ${client} (${VIP_MOUNT_OPTS})"
}

prepare_payload() {
    local mode="$1"
    local out_file="$2"
    local i
    : > "${out_file}"
    for i in $(seq 1 "${TOTAL_LINES}"); do
        printf 'SEQ=%02d MODE=%s TOKEN=NT132.R12.ANTT-NFS-HA-INTEGRITY-%02d\n' "${i}" "${mode}" "$((i * 7919))" >> "${out_file}"
    done
    sha256sum "${out_file}" | awk '{print $1}'
}

run_failover_scenario() {
    local mode="$1"
    local remote_file="/mnt/nfs/share/ha_failover_test_${mode}.log"
    local server_file="/exports/share/ha_failover_test_${mode}.log"
    local expected_sha actual_client_sha actual_node2_sha actual_ro_sha
    local line_count vip_rto_ms t_fault_ms t_vip_ms t_done_ms io_recovery_ms failback_ms

    echo
    echo "========================================================================"
    echo " KICH BAN FAILOVER: ${mode^^} FAILURE"
    echo "========================================================================"

    ensure_cluster_ready
    mount_client_via_vip "${CLIENT1}"
    mount_client_via_vip "${CLIENT2}"

    PAYLOAD_FILE="$(mktemp)"
    expected_sha="$(prepare_payload "${mode}" "${PAYLOAD_FILE}")"
    docker cp "${PAYLOAD_FILE}" "${CLIENT1}:/tmp/ha_payload_${mode}.txt"
    rm -f "${PAYLOAD_FILE}"
    PAYLOAD_FILE=""
    docker exec "${CLIENT1}" rm -f "${remote_file}"

    info "Khoi chay luong ghi lien tuc ${TOTAL_LINES} dong tu ${CLIENT1} qua VIP ${VIP}..."
    docker exec "${CLIENT1}" bash -c "
        set -euo pipefail
        while IFS= read -r line; do
            printf '%s\n' \"\${line}\" >> '${remote_file}'
            sync '${remote_file}'
            sleep 0.45
        done < '/tmp/ha_payload_${mode}.txt'
        rm -f '/tmp/ha_payload_${mode}.txt'
    " &
    WRITER_PID=$!

    # Doi toi thieu 5 dong dau duoc ghi qua node1 truoc khi danh sap
    local waited=0
    while true; do
        line_count="$(docker exec "${CLIENT1}" sh -c "[ -f '${remote_file}' ] && wc -l < '${remote_file}' || echo 0" | tr -d '[:space:]')"
        if [ "${line_count}" -ge 5 ]; then
            break
        fi
        if ! kill -0 "${WRITER_PID}" 2>/dev/null; then
            fail "Luong ghi tren ${CLIENT1} ket thuc som bat thuong"
        fi
        sleep 0.2
        waited=$((waited + 1))
        if [ "${waited}" -gt 50 ]; then
            fail "Timeout khi cho ghi 5 dong dau qua ${NODE1}"
        fi
    done
    info "Da ghi ${line_count}/${TOTAL_LINES} dong qua ${NODE1}. Kich hoat su co che do '${mode}'..."

    t_fault_ms="$(date +%s%3N)"
    if [ "${mode}" = "service" ]; then
        docker exec "${NODE1}" sh -c 'touch /run/nfs_fault_inject && rpc.nfsd 0 && exportfs -ua'
    else
        docker stop -t 5 "${NODE1}" >/dev/null
    fi

    # Do thoi gian VIP chuyen sang Node 2
    local deadline_ms=$((t_fault_ms + 15000))
    while true; do
        if has_vip "${NODE2}"; then
            t_vip_ms="$(date +%s%3N)"
            break
        fi
        if [ "$(date +%s%3N)" -ge "${deadline_ms}" ]; then
            fail "VIP ${VIP} khong chuyen sang ${NODE2} trong 15 giay (mode=${mode})"
        fi
        sleep 0.15
    done
    vip_rto_ms=$((t_vip_ms - t_fault_ms))
    info "VIP ${VIP} da chuyen sang ${NODE2} sau ${vip_rto_ms} ms"
    if [ "${vip_rto_ms}" -ge 5000 ]; then
        fail "VIP Takeover RTO = ${vip_rto_ms} ms (>= 5000 ms)"
    fi
    pass "VIP Takeover RTO = ${vip_rto_ms} ms (< 5000 ms)"

    info "Cho luong ghi tren ${CLIENT1} hoan tat noi tiep sang ${NODE2}..."
    if ! wait "${WRITER_PID}"; then
        WRITER_PID=""
        fail "Luong ghi tren ${CLIENT1} bi loi trong qua trinh failover (${mode})"
    fi
    WRITER_PID=""
    t_done_ms="$(date +%s%3N)"
    io_recovery_ms=$((t_done_ms - t_fault_ms))
    pass "Client 1 ghi xong du ${TOTAL_LINES} dong khong gian doan (tong thoi gian tu luc loi den xong: ${io_recovery_ms} ms)"

    # Kiem chung toan ven SHA-256 (RPO = 0)
    actual_client_sha="$(docker exec "${CLIENT1}" sha256sum "${remote_file}" | awk '{print $1}')"
    actual_node2_sha="$(docker exec "${NODE2}" sha256sum "${server_file}" | awk '{print $1}')"
    line_count="$(docker exec "${NODE2}" sh -c "wc -l < '${server_file}'" | tr -d '[:space:]')"

    if [ "${actual_client_sha}" != "${expected_sha}" ] || [ "${actual_node2_sha}" != "${expected_sha}" ] || [ "${line_count}" != "${TOTAL_LINES}" ]; then
        fail "Sai lech du lieu (expected=${expected_sha}, client=${actual_client_sha}, node2=${actual_node2_sha}, lines=${line_count})"
    fi
    pass "SHA-256 MATCH (${line_count}/${TOTAL_LINES} dong, RPO=0): ${expected_sha}"

    # Kiem chung quyen doc/ghi tren Client 2 (ro)
    actual_ro_sha="$(docker exec "${CLIENT2}" sha256sum "${remote_file}" | awk '{print $1}')"
    if [ "${actual_ro_sha}" != "${expected_sha}" ]; then
        fail "Client 2 doc sai du lieu sau failover"
    fi
    if docker exec "${CLIENT2}" sh -c "touch /mnt/nfs/share/.ro_verify_fail 2>/dev/null"; then
        docker exec "${CLIENT2}" rm -f /mnt/nfs/share/.ro_verify_fail 2>/dev/null || true
        fail "Client 2 (${CLIENT2}) ghi duoc file du dang duoc cap quyen ro!"
    fi
    pass "${CLIENT2} doc dung SHA-256 va giu nghiem ngat quyen chi doc (ro)"

    # Failback ve Node 1
    info "Thuc hien Failback khoi phuc ${NODE1}..."
    if [ "${mode}" = "service" ]; then
        docker exec "${NODE1}" sh -c 'rm -f /run/nfs_fault_inject && exportfs -rv >/dev/null && rpc.nfsd -V 4 -N 3 8'
    else
        docker start "${NODE1}" >/dev/null
    fi

    if ! failback_ms="$(wait_for_vip "${NODE1}" 20)"; then
        fail "Failback that bai: ${NODE1} khong nhan lai VIP ${VIP} trong 20s"
    fi
    pass "Failback ve ${NODE1} thanh cong sau ${failback_ms} ms"
}

if [ "${MODE}" = "both" ]; then
    run_failover_scenario "service"
    run_failover_scenario "hard"
else
    run_failover_scenario "${MODE}"
fi

echo
echo ">>> HOAN TAT KIEM THU FAILOVER (${MODE}) - TAT CA TIEU CHI DEU DAT! <<<"
