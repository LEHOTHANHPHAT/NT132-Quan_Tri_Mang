# Mount Options & Bảo mật NFS Client
Phần này không thể thực hiện trên Container Client được nên sẽ triển khai trên 2 máy ảo Ubuntu

| Client | IP | Quyền trên `/share` |
|---|---|---|
| `client-rw` | 192.168.10.101 | `rw` |
| `client-ro` | 192.168.10.102 | `ro` |

## Chạy NFS Server
Trong thư mục `docker-nfs` của máy server chạy lệnh 
```bash
sudo docker compose up -d --build nfs-node1
```

Kiểm tra:
```bash
sudo docker compose ps -a
```
Chỉ có 1 node đang chạy (STATUS Up) trên 1 máy, nếu sai chạy lệnh sau để xóa container và chạy lại
```bash
sudo docker compose down
```

## Cài đặt Client trên 2 máy Ubuntu
Cài đặt NFS Client
```bash
sudo apt install -y nfs-common
```

- Clone folder đồ án
```bash
git clone https://github.com/LEHOTHANHPHAT/NT132-Quan_Tri_Mang
```

- Vào thư mục `client-configs` cấp quyền thực thi
```bash
find . -name "*.sh" -exec sed -i 's/\r$//' {} \;
chmod +x manual-mount.sh setup-fstab-automount.sh security-demo/privesc-no-root-squash.sh
```

## Thực hiện mount thủ công
Trên nfs-client1 (.101 — được cấp quyền rw):
```bash
sudo ./manual-mount.sh rw
```

Trên nfs-client2 (.102 — chỉ được quyền ro):
```bash
sudo ./manual-mount.sh ro
```

Kết quả:
- client1 - rw: GHI THANH CONG
- client2 - ro: KHONG THE GHI

## Mount tự động qua fstab
Trước tiên cần gỡ các mount cũ trước khi thực hiện
```bash
sudo umount /mnt/nfs/share 2>/dev/null
```

Trên nfs-client1 (.101 — được cấp quyền rw):
```bash
sudo ./setup-fstab-automount.sh rw
```

Trên nfs-client2 (.102 — chỉ được quyền ro):
```bash
sudo ./setup-fstab-automount.sh ro
```

## Kiểm tra
Test quyền write/read
```bash
echo "Hello World!" > /mnt/nfs/share/test.txt
```

Hoặc mở trực tiếp folder bằng cách mở ứng dụng quản lý files bấm tổ hợp `Ctrl + L` để mở thanh nhập đường dẫn, nhập `/mnt/nfs/share`

## Kiểm tra chi tiết kết quả mount tự động (fstab)

Xem lại dòng vừa được thêm vào `/etc/fstab`:
```bash
cat /etc/fstab | tail -1
```
Kết quả:
```
192.168.10.11:/share  /mnt/nfs/share  nfs4  rw,vers=4.2,sec=sys,hard,intr,_netdev,x-systemd.automount,x-systemd.mount-timeout=10,noauto  0  0
```

Nạp lại và kiểm tra unit automount do systemd tự sinh từ dòng fstab trên:
```bash
sudo systemctl daemon-reload
systemctl list-units --type=automount
```

Vì entry fstab có `noauto` + `x-systemd.automount`, mount **sẽ không xuất hiện ngay lúc boot**, chỉ kích hoạt khi có truy cập thực tế (cơ chế on-demand):
```bash
ls /mnt/nfs/share        # hành động truy cập này kích hoạt mount thật sự
mount | grep nfs4         # kiểm tra lại, giờ phải thấy dòng mount
```

### Biến thể: mount tự động ngay lúc boot (không chờ truy cập)

Nếu muốn mount xuất hiện ngay khi VM khởi động (không cần `ls` trước), bỏ 2 option `noauto` và `x-systemd.automount`:
```bash
sudo sed -i 's/,noauto,x-systemd.automount,x-systemd.mount-timeout=10//' /etc/fstab
cat /etc/fstab | tail -1
```
Test bằng cách khởi động lại máy:
```bash
sudo reboot
```
Sau khi SSH lại, kiểm tra ngay (không cần `ls` trước):
```bash
mount | grep nfs4
```

## Mount tự động bằng systemd `.mount` & `.automount` units

Cách này tách biệt hoàn toàn khỏi `/etc/fstab`, khai báo trực tiếp bằng 2 file unit — cách làm chuẩn hơn trong triển khai thực tế.

Dọn mount/entry fstab cũ trước khi chuyển sang cách này, tránh xung đột cùng 1 mount point:
```bash
sudo umount /mnt/nfs/share 2>/dev/null
sudo sed -i '/192.168.10.11:\/share/d' /etc/fstab
sudo systemctl daemon-reload
```

Copy 2 file unit có sẵn trong project vào thư mục hệ thống:
```bash
sudo cp ~/NT132-Quan_Tri_Mang/client-configs/systemd/mnt-nfs-share.mount /etc/systemd/system/
sudo cp ~/NT132-Quan_Tri_Mang/client-configs/systemd/mnt-nfs-share.automount /etc/systemd/system/
```

Trên `nfs-client2` (.102), sửa lại quyền `ro` trong file `.mount` (client1 giữ nguyên `rw` mặc định):
```bash
sudo sed -i 's/Options=rw,/Options=ro,/' /etc/systemd/system/mnt-nfs-share.mount
```

Nạp lại và kích hoạt:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now mnt-nfs-share.automount
```

Kiểm tra:
```bash
systemctl status mnt-nfs-share.automount
systemctl status mnt-nfs-share.mount   # "inactive (dead)" là bình thường trước khi có truy cập
ls /mnt/nfs/share                       # kích hoạt mount
systemctl status mnt-nfs-share.mount   # giờ phải "active (mounted)"
mount | grep nfs4
```

Kiểm tra cơ chế tự ngắt sau thời gian không sử dụng (`TimeoutIdleSec=600`):
```bash
ls /mnt/nfs/share
sleep 610
mount | grep nfs4   # kỳ vọng: không còn mount (đã tự umount do idle)
ls /mnt/nfs/share   # truy cập lại -> tự mount lại ngay
```

## So sánh 2 cách mount tự động

| Tiêu chí | `/etc/fstab` (có `noauto`+`x-systemd.automount`) | `.mount` + `.automount` thủ công |
|---|---|---|
| Mount xuất hiện khi nào | Khi có truy cập đầu tiên | Khi có truy cập đầu tiên |
| Cách khai báo | 1 dòng trong `/etc/fstab` | 2 file unit riêng trong `/etc/systemd/system/` |
| Cơ chế vận hành | systemd tự sinh unit automount từ dòng fstab | Dùng trực tiếp unit do mình viết |
| Tự ngắt khi idle | Có (`x-systemd.mount-timeout`/mặc định) | Có (`TimeoutIdleSec`, tự khai báo) |
| Phù hợp minh hoạ cho | Cách khai báo đơn giản, quen thuộc | Cơ chế `systemd automount` hiện đại, tách biệt rõ ràng |

**Lưu ý quan trọng:** không chạy đồng thời cả 2 cách trên cùng 1 mount point — nếu đã làm cách `.mount`/`.automount`, phải xoá entry trong `/etc/fstab` trước (đã thực hiện ở bước dọn dẹp phía trên), tránh 2 cơ chế tranh nhau quản lý cùng `/mnt/nfs/share`.