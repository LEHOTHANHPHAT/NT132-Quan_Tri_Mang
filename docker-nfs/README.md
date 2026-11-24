# Hướng dẫn triển khai và kiểm tra NFS Server

**Phụ trách:** Lê Hồ Thành Phát (TV2)  
**Môi trường đã thử:** Ubuntu/WSL, Docker Desktop, Docker Compose

## 1. Mô hình lab

| Thành phần | Địa chỉ | Vai trò |
|---|---|---|
| `nfs-ubuntu-node1` | `192.168.10.11` | NFS Server chính |
| `nfs-ubuntu-node2` | `192.168.10.12` | NFS Server dự phòng |
| `nfs-client-1` | `192.168.10.101` | Đọc và ghi trên `/share` |
| `nfs-client-2` | `192.168.10.102` | Chỉ đọc trên `/share` |
| VIP | `192.168.10.100` | Địa chỉ truy cập chung khi thử failover |

Hai NFS Server chạy trên cùng Docker host và dùng chung thư mục
lưu trữ. Mount vào `.12:/share` để kiểm tra trực tiếp Node 2.
Mount vào `.100:/share` để kiểm tra khả năng chuyển đổi dự phòng.

## 2. Khởi động và kiểm tra lab

Chạy từ thư mục gốc `nfs-ha-project`:

```bash
docker version
docker compose version
docker compose -f docker-nfs/docker-compose.yml up -d --build
docker compose -f docker-nfs/docker-compose.yml ps
```

Kiểm tra cả hai server và hai client đều đang chạy. Nếu Node 2
không khởi động được, xem log:

```bash
docker compose -f docker-nfs/docker-compose.yml logs --tail=80 nfs-node2
```

## 3. Hiểu cấu hình Export

Cấu hình nguồn nằm trong `docker-nfs/ubuntu-server/exports`.
Dockerfile đưa cấu hình này vào `/etc/exports` trong container.

| Đường dẫn trên server | Client được cấp quyền | Ý nghĩa |
|---|---|---|
| `/exports` | `192.168.10.0/24` | Gốc NFSv4 (`fsid=0`), chỉ đọc |
| `/exports/share` | `192.168.10.101` | Client 1 có quyền đọc/ghi (`rw`) |
| `/exports/share` | `192.168.10.0/24` | Các client còn lại trong subnet, gồm Client 2, có quyền chỉ đọc (`ro`) |
| `/exports/no_squash` | `192.168.10.0/24` | Export riêng phục vụ thực nghiệm `no_root_squash` trong lab |

Client 1 khớp với dòng cấp quyền cho IP cụ thể `.101`. Client 2
khớp với dòng cấp quyền cho subnet `/24`. Cả hai dùng `/share`
khi mount vì NFSv4 trình bày `/exports` là gốc của cây thư mục
được chia sẻ.

Trên `/share`, `root_squash` ánh xạ yêu cầu từ UID 0 phía client
về danh tính ẩn danh. Tùy chọn `sync` yêu cầu máy chủ ghi dữ liệu
xuống bộ lưu trữ ổn định trước khi xác nhận yêu cầu ghi.

Xem quyền đang được áp dụng trên Node 2:

```bash
docker exec nfs-ubuntu-node2 exportfs -v
```

## 4. Kiểm tra RW/RO trực tiếp trên Node 2

Dùng một điểm mount riêng. Nếu đã chạy bài này trước đó, lệnh sẽ
giữ điểm mount hiện có và kiểm tra nguồn của nó.

```bash
for client in nfs-client-1 nfs-client-2; do
  echo "=== $client ==="
  docker exec "$client" sh -ec '
    mkdir -p /mnt/nfs-handover-test
    if ! mountpoint -q /mnt/nfs-handover-test; then
      mount -t nfs -o vers=4,rw \
        192.168.10.12:/share /mnt/nfs-handover-test
    fi
    findmnt -n -o SOURCE,TARGET --mountpoint /mnt/nfs-handover-test
  ' || break
done
```

Chỉ chạy bước tiếp theo khi cả hai client đều hiện nguồn
`192.168.10.12:/share`. Cả hai yêu cầu mount `rw` để bài thử
kiểm tra quyền ghi mà máy chủ thực sự cấp cho từng client.

```bash
TEST_FILE="tv2-handover-$(date +%s).txt"

docker exec nfs-client-1 sh -ec \
  'printf "File do Client 1 tao\n" > "/mnt/nfs-handover-test/$1"' \
  sh "$TEST_FILE" &&
docker exec nfs-client-2 cat "/mnt/nfs-handover-test/$TEST_FILE" &&
docker exec nfs-client-2 sh -c \
  'printf "Thu ghi tu Client 2\n" > "/mnt/nfs-handover-test/ro-$1"' \
  sh "$TEST_FILE"
```

**Kết quả đạt:** Client 1 tạo được file, Client 2 đọc được nội dung
`File do Client 1 tao`, và thao tác ghi của Client 2 báo
`Read-only file system`.

Nếu kết quả khác dự kiến, kiểm tra `findmnt` trên hai client
để xác nhận địa chỉ mount, rồi kiểm tra `exportfs -v` trên Node 2
để xác nhận các dòng phân quyền cho `.101` và subnet `/24`.

## 5. Minh chứng đã thực hiện

- [Tuần 4–5 — Node 2 và phân quyền RW/RO](minhchung_tuan4_5.md)
- [Tuần 6 — Đo sync/async và kiểm tra all_squash](minhchung_tuan6_sync_async.md)
- [Tuần 7 — Phân quyền qua VIP trước và sau failover](minhchung_tuan7_phanquyen_vip.md)
- [Lý thuyết về các phiên bản NFS](../docs/02-nfs-versions-comparison.md)

Bài failover xác nhận Node 2 tiếp quản VIP, file kiểm thử giữ nguyên
SHA-256 và quyền RW/RO vẫn được duy trì. Phép thử diễn ra giữa hai
container trên cùng Docker host và chưa đo thời gian gián đoạn.
