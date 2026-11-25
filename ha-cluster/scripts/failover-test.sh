#!/bin/bash
###############################################################################
# failover-test.sh
# Thành viên 4 (Nguyễn Nhựt Quốc) - Kiểm thử Failover, Failback & GlusterFS Self-Heal
#
# Kịch bản thực nghiệm:
#   - Hỗ trợ 2 chế độ lỗi (--mode service|hard|both):
#       * service : Giả lập lỗi NFS-Ganesha (ganesha.nfsd dừng, Keepalived/Gluster còn sống)
#       * hard    : Giả lập sập node hoàn toàn (docker stop -t 5 nfs-ubuntu-node1)
#   - Chứng minh nhân bản sống 2 chiều xuống cả Brick 1 & Brick 2 trước khi đánh sập
#   - Đo thời gian chuyển mạch VIP (RTO < 5s) sang nfs-ubuntu-node2
#   - Trong chế độ hard: ghi thêm tệp chứng minh lúc Node 1 đang tắt, kiểm chứng Brick 1
#     bị thiếu/lệch SHA-256 trên ổ đĩa, bật lại Node 1 và chứng minh GlusterFS Self-Heal
#     tự động đồng bộ khớp 100% SHA-256 giữa Brick 1 và Brick 2 (RPO = 0)
#   - Kiểm chứng quyền chỉ đọc (ro) trên Client 2 và Failback sạch về Node 1.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

NODE1="nfs-ubuntu-node1"
NODE2="nfs-ubuntu-node2"
CLIENT1="nfs-client-1"
CLIENT2="nfs-client-2"
VIP="192.168.10.100"
VIP_MOUNT_OPTS="vers=4,hard,timeo=50,retrans=2,proto=tcp"
TOTAL_LINES=20

BRICK1_SHARE="${REPO_ROOT}/shared-data/bricks/node1/gv0/share"
BRICK2_SHARE="${REPO_ROOT}/shared-data/bricks/node2/gv0/share"

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

wait_for_self_heal() {
    local timeout_s="$1"
    local t_start_ms now_ms deadline_ms out connected_count pending_sum
    t_start_ms="$(date +%s%3N)"
    deadline_ms=$((t_start_ms + timeout_s * 1000))
    timeout 5 docker exec "${NODE1}" gluster volume heal gv0 >/dev/null 2>&1 || true
    while true; do
        out="$(timeout 4 docker exec "${NODE1}" gluster volume heal gv0 info 2>/dev/null || true)"
        connected_count="$(printf '%s\n' "${out}" | grep -c '^Status: Connected$' || true)"
        if [ "${connected_count}" -ge 2 ]; then
            pending_sum="$(printf '%s\n' "${out}" | awk '/^Number of entries:/ {s += $4; found = 1} END {print (found ? s : -1)}')"
            if [ "${pending_sum}" -eq 0 ]; then
                now_ms="$(date +%s%3N)"
                printf '%s\n' "$((now_ms - t_start_ms))"
                return 0
            fi
        fi
        now_ms="$(date +%s%3N)"
        if [ "${now_ms}" -ge "${deadline_ms}" ]; then
            echo "${out}" >&2
            return 1
        fi
        timeout 4 docker exec "${NODE1}" gluster volume heal gv0 >/dev/null 2>&1 || true
        sleep 0.5
    done
}

restore_node1_if_needed() {
    if ! is_running "${NODE1}"; then
        docker start "${NODE1}" >/dev/null 2>&1 || true
    else
        docker exec "${NODE1}" sh -c '
            rm -f /run/nfs_fault_inject
            if ! /usr/local/bin/check_nfs.sh >/dev/null 2>&1; then
                /usr/local/sbin/ganesha-ctl.sh start >/dev/null
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
    info "Kiem tra 4 container, trang thai GlusterFS Self-Heal & dam bao ${NODE1} giu VIP ${VIP}..."
    for c in "${NODE2}" "${CLIENT1}" "${CLIENT2}"; do
        is_running "${c}" || fail "Container ${c} chua chay"
    done
    restore_node1_if_needed
    if ! wait_for_vip "${NODE1}" 30 >/dev/null; then
        fail "Het thoi gian cho ${NODE1} nhan lai VIP ${VIP}"
    fi
    if ! wait_for_self_heal 30 >/dev/null; then
        fail "GlusterFS gv0 chua hoan tat Self-Heal (Number of entries != 0)"
    fi
    docker exec "${NODE1}" /usr/local/bin/check_nfs.sh >/dev/null 2>&1 || fail "${NODE1} chua dat check_nfs.sh"
    docker exec "${NODE2}" /usr/local/bin/check_nfs.sh >/dev/null 2>&1 || fail "${NODE2} chua dat check_nfs.sh"
    pass "${NODE1} la MASTER (VIP ${VIP}) va GlusterFS gv0 san sang (0 pending heal)"
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
        printf 'SEQ=%02d MODE=%s TOKEN=NT132.R12.ANTT-GLUSTER-GANESHA-HA-%02d\n' "${i}" "${mode}" "$((i * 7919))" >> "${out_file}"
    done
    sha256sum "${out_file}" | awk '{print $1}'
}

run_failover_scenario() {
    local mode="$1"
    local fname="ha_failover_test_${mode}.log"
    local remote_file="/mnt/nfs/share/${fname}"
    local brick1_file="${BRICK1_SHARE}/${fname}"
    local brick2_file="${BRICK2_SHARE}/${fname}"
    local offline_name="ha_selfheal_offline_proof.log"
    local offline_remote="/mnt/nfs/share/${offline_name}"
    local offline_brick1="${BRICK1_SHARE}/${offline_name}"
    local offline_brick2="${BRICK2_SHARE}/${offline_name}"

    local expected_sha actual_client_sha actual_brick1_sha actual_brick2_sha actual_ro_sha
    local offline_expected_sha offline_b1_sha offline_b2_sha offline_ro_sha
    local line_count b1_lines b2_lines vip_rto_ms t_fault_ms t_vip_ms t_done_ms io_recovery_ms failback_ms heal_ms

    echo
    echo "========================================================================"
    echo " KICH BAN FAILOVER: ${mode^^} FAILURE (GLUSTERFS REPLICA 2 + GANESHA)"
    echo "========================================================================"

    ensure_cluster_ready
    mount_client_via_vip "${CLIENT1}"
    mount_client_via_vip "${CLIENT2}"

    PAYLOAD_FILE="$(mktemp)"
    expected_sha="$(prepare_payload "${mode}" "${PAYLOAD_FILE}")"
    docker cp "${PAYLOAD_FILE}" "${CLIENT1}:/tmp/ha_payload_${mode}.txt"
    rm -f "${PAYLOAD_FILE}"
    PAYLOAD_FILE=""
    docker exec "${CLIENT1}" rm -f "${remote_file}" "${offline_remote}"

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

    # Kiem chung nhan ban song qua mang xuong ca Brick 1 va Brick 2 truoc khi danh sap
    [ -f "${brick1_file}" ] || fail "Brick 1 thieu ${brick1_file} truoc khi gay loi"
    [ -f "${brick2_file}" ] || fail "Brick 2 thieu ${brick2_file} truoc khi gay loi (GlusterFS khong nhan ban!)"
    b1_lines="$(wc -l < "${brick1_file}" | tr -d '[:space:]')"
    b2_lines="$(wc -l < "${brick2_file}" | tr -d '[:space:]')"
    if [ "${b1_lines}" -lt 5 ] || [ "${b2_lines}" -lt 5 ]; then
        fail "Nhan ban song chua du du lieu (Brick1=${b1_lines} dong, Brick2=${b2_lines} dong)"
    fi
    pass "Nhan ban song qua mang xac nhan: Brick1=${b1_lines} dong, Brick2=${b2_lines} dong. Kich hoat su co '${mode}'..."

    t_fault_ms="$(date +%s%3N)"
    if [ "${mode}" = "service" ]; then
        docker exec "${NODE1}" sh -c 'touch /run/nfs_fault_inject && /usr/local/sbin/ganesha-ctl.sh stop'
    else
        docker stop -t 5 "${NODE1}" >/dev/null
    fi

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

    actual_client_sha="$(docker exec "${CLIENT1}" sha256sum "${remote_file}" | awk '{print $1}')"
    actual_brick2_sha="$(sha256sum "${brick2_file}" | awk '{print $1}')"
    line_count="$(wc -l < "${brick2_file}" | tr -d '[:space:]')"
    if [ "${actual_client_sha}" != "${expected_sha}" ] || [ "${actual_brick2_sha}" != "${expected_sha}" ] || [ "${line_count}" != "${TOTAL_LINES}" ]; then
        fail "Sai lech du lieu tren Node 2 (expected=${expected_sha}, client=${actual_client_sha}, brick2=${actual_brick2_sha}, lines=${line_count})"
    fi
    pass "SHA-256 Client 1 == Brick 2 (${line_count}/${TOTAL_LINES} dong, RPO=0): ${expected_sha}"

    if [ "${mode}" = "service" ]; then
        actual_brick1_sha="$(sha256sum "${brick1_file}" | awk '{print $1}')"
        if [ "${actual_brick1_sha}" != "${expected_sha}" ]; then
            fail "Service mode: Brick 1 phai tiep tuc nhan ban qua glusterfsd nhung SHA-256 khong khop (brick1=${actual_brick1_sha})"
        fi
        pass "Service mode: Brick 1 van nhan ban song 100% du Ganesha Node 1 dang tat (${actual_brick1_sha})"

        docker exec "${CLIENT2}" sh -c "ls -la /mnt/nfs/share >/dev/null"
        actual_ro_sha="$(docker exec "${CLIENT2}" sha256sum "${remote_file}" | awk '{print $1}')"
        [ "${actual_ro_sha}" = "${expected_sha}" ] || fail "Client 2 doc sai SHA-256 sau failover"
        if docker exec "${CLIENT2}" sh -c "touch /mnt/nfs/share/.ro_verify_fail 2>/dev/null"; then
            docker exec "${CLIENT2}" rm -f /mnt/nfs/share/.ro_verify_fail 2>/dev/null || true
            fail "Client 2 (${CLIENT2}) ghi duoc file du dang duoc cap quyen ro!"
        fi
        pass "${CLIENT2} doc dung SHA-256 va giu nghiem ngat quyen chi doc (ro)"

        info "Thuc hien Failback khoi phuc NFS-Ganesha tren ${NODE1}..."
        docker exec "${NODE1}" sh -c 'rm -f /run/nfs_fault_inject && /usr/local/sbin/ganesha-ctl.sh start >/dev/null'
        if ! failback_ms="$(wait_for_vip "${NODE1}" 25)"; then
            fail "Failback that bai: ${NODE1} khong nhan lai VIP ${VIP} trong 25s"
        fi
        pass "Failback ve ${NODE1} thanh cong sau ${failback_ms} ms"
    else
        # Hard failure: ghi them file chung minh luc Node 1 dang tat han de chung minh Brick co lap & Self-Heal
        info "Ghi them tep ${offline_name} qua VIP (Node 2) trong luc ${NODE1} dang tat hoan toan..."
        docker exec "${CLIENT1}" sh -c "
            printf 'OFFLINE-PROOF NODE1-DOWN TOKEN=NT132.R12.ANTT-SELF-HEAL\n' > '${offline_remote}' && \
            sync '${offline_remote}'
        "
        offline_expected_sha="$(docker exec "${CLIENT1}" sha256sum "${offline_remote}" | awk '{print $1}')"

        [ -f "${offline_brick2}" ] || fail "Brick 2 thieu ${offline_name} khi ghi qua Node 2"
        if [ -f "${offline_brick1}" ]; then
            fail "Brick 1 van co ${offline_name} du Node 1 dang tat! (Nghi ngo mount cheo hoac chua co lap brick)"
        fi
        actual_brick1_sha="$(sha256sum "${brick1_file}" | awk '{print $1}')"
        if [ "${actual_brick1_sha}" = "${expected_sha}" ]; then
            fail "Brick 1 da du 20 dong du Node 1 tat giua chung (khong hop le)"
        fi
        pass "Chung minh co lap Brick khi Node 1 tat: Brick 2 co ${offline_name} & du ${TOTAL_LINES} dong; Brick 1 thieu ${offline_name} & lech SHA-256"

        info "Khoi dong lai ${NODE1} va kiem chung Failback + GlusterFS Self-Heal..."
        docker start "${NODE1}" >/dev/null
        if ! failback_ms="$(wait_for_vip "${NODE1}" 30)"; then
            fail "Failback that bai: ${NODE1} khong nhan lai VIP ${VIP} trong 30s"
        fi
        if ! heal_ms="$(wait_for_self_heal 30)"; then
            fail "GlusterFS Self-Heal khong hoi tu ve 0 pending entries trong 30s"
        fi
        pass "Failback ve ${NODE1} sau ${failback_ms} ms; Self-Heal hoi tu (0 entries) sau ${heal_ms} ms"

        actual_brick1_sha="$(sha256sum "${brick1_file}" | awk '{print $1}')"
        offline_b1_sha="$(sha256sum "${offline_brick1}" 2>/dev/null | awk '{print $1}' || true)"
        offline_b2_sha="$(sha256sum "${offline_brick2}" | awk '{print $1}')"
        if [ "${actual_brick1_sha}" != "${expected_sha}" ] || [ "${offline_b1_sha}" != "${offline_b2_sha}" ] || [ "${offline_b2_sha}" != "${offline_expected_sha}" ]; then
            fail "Self-Heal xong nhung SHA-256 van lech (hard: b1=${actual_brick1_sha} vs exp=${expected_sha}; offline: b1=${offline_b1_sha} vs b2=${offline_b2_sha})"
        fi
        pass "GlusterFS Self-Heal khop 100% SHA-256 giua Brick 1 & Brick 2 cho ca ${fname} va ${offline_name}"

        docker exec "${CLIENT2}" sh -c "ls -la /mnt/nfs/share >/dev/null"
        actual_ro_sha="$(docker exec "${CLIENT2}" sha256sum "${remote_file}" | awk '{print $1}')"
        offline_ro_sha="$(docker exec "${CLIENT2}" sha256sum "${offline_remote}" | awk '{print $1}')"
        if [ "${actual_ro_sha}" != "${expected_sha}" ] || [ "${offline_ro_sha}" != "${offline_expected_sha}" ]; then
            fail "Client 2 doc sai du lieu sau Self-Heal & Failback"
        fi
        if docker exec "${CLIENT2}" sh -c "touch /mnt/nfs/share/.ro_verify_fail 2>/dev/null"; then
            docker exec "${CLIENT2}" rm -f /mnt/nfs/share/.ro_verify_fail 2>/dev/null || true
            fail "Client 2 (${CLIENT2}) ghi duoc file du dang duoc cap quyen ro!"
        fi
        pass "${CLIENT2} doc dung ca 2 tep qua VIP va giu nghiem ngat quyen chi doc (ro)"
    fi
}

if [ "${MODE}" = "both" ]; then
    run_failover_scenario "service"
    run_failover_scenario "hard"
else
    run_failover_scenario "${MODE}"
fi

echo
echo ">>> HOAN TAT KIEM THU FAILOVER & GLUSTERFS SELF-HEAL (${MODE}) - TAT CA TIEU CHI DEU DAT! <<<"
