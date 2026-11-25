# Tuần 7 — Kiểm tra quyền RW/RO qua VIP khi failover

> **Ghi chú:** Phép thử này chạy trên cấu hình Keepalived cũ được
> tích hợp trong `docker-nfs/` (commit `adaf7eb`). Hiện Keepalived/VIP
> đã được tách sang cụm HA riêng `ha-cluster/`; để chạy lại kịch bản
> failover, dùng `ha-cluster/scripts/failover-test.sh` (xem
> [04-ha-design.md](../docs/04-ha-design.md)). Kết quả bên dưới giữ
> nguyên như lúc ghi nhận.

## Mục tiêu

Kiểm tra dữ liệu và quyền truy cập NFS khi VIP `192.168.10.100`
chuyển từ Node 1 sang Node 2. Cả hai client giữ nguyên điểm mount
`/mnt/nfs-vip-test`, trỏ tới `192.168.10.100:/share`.

## Kết quả

| Kiểm tra | Trước failover | Sau failover |
|---|---|---|
| Node giữ VIP | Node 1 | Node 2 (`192.168.10.12`) |
| Client 1 (`192.168.10.101`) | Tạo được file | Tạo được file mới |
| Client 2 (`192.168.10.102`) | Đọc được file, ghi bị chặn | Đọc được file mới, ghi bị chặn |

Sau khi dừng Node 1, Node 2 có hai địa chỉ trên `eth0`:
`192.168.10.12/24` và `192.168.10.100/24`.

SHA-256 của file `tv2-before-1795502402.txt` trùng nhau trước và
sau failover:

`e6fe16241c286275acad8c47e9709b92e1b1a0ad675fbd09a528d42cd663785e`

Sau failover, Client 2 đọc được nội dung `Du lieu sau failover`
từ file mới do Client 1 tạo. Khi thử ghi, Client 2 nhận lỗi
`Read-only file system`.

## Kết luận

Node 2 tiếp quản VIP. File kiểm thử cũ giữ nguyên nội dung và
quyền RW/RO vẫn được áp dụng qua cùng điểm mount. Phép thử
được thực hiện giữa hai container trên cùng Docker host và
chưa đo thời gian gián đoạn dịch vụ.
