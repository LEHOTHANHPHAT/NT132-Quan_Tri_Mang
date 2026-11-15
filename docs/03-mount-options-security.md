# Mount Options & Bảo mật NFS Client
| Client | IP | Quyền trên `/share` |
|---|---|---|
| `client-rw` | 192.168.10.101 | `rw` |
| `client-ro` | 192.168.10.102 | `ro` |
## Dựng môi trường

Trong thư mục `docker-nfs` chạy lệnh khởi động các container (nhớ mở docker lên trước):
```bash
docker compose up -d --build
```

Kiểm tra:
```bash
docker compose ps
```

## Vào trong container
Container giống như một máy riêng biệt, cần login vào để sử dụng
```bash
docker exec -it nfs-client-1 bash
hoặc
docker exec -it nfs-client-2 bash
```

## Copy file script vào container
Copy các file script trong máy thật vào container (đứng ở folder `NT132-Quan_Tri_Mang`):
```bash
docker cp client-configs/manual-mount.sh nfs-client-1:/root/
docker cp client-configs/manual-mount.sh nfs-client-2:/root/
docker cp client-configs/setup-fstab-automount.sh nfs-client-1:/root/
docker cp client-configs/security-demo/privesc-no-root-squash.sh nfs-client-1:/root/
```

# Thực hiện mount thủ công
Vào container 1 và chạy 2 lệnh:
```bash
docker exec -it nfs-client-1 bash
```
```bash
chmod +x /root/manual-mount.sh
/root/manual-mount.sh rw
```

Container 2 chạy lệnh:
```bash
docker exec -it nfs-client-2 bash
```
```bash
chmod +x /root/manual-mount.sh
/root/manual-mount.sh ro
```

Kết quả mẫu:
- Với container 1 được cấp quyền đọc ghi - rw:
```bash
root@client-1:/# chmod +x /root/manual-mount.sh
/root/manual-mount.sh rw
=== [1/5] Cai dat goi NFS client (nfs-common) ===
nfs-common da duoc cai dat, bo qua.
=== [2/5] Kiem tra RPC/portmapper toi server 192.168.10.11 ===
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100000    4   udp    111  portmapper
    100000    3   udp    111  portmapper
    100000    2   udp    111  portmapper
    100024    1   udp  33778  status
    100024    1   tcp  45653  status
    100003    4   tcp   2049  nfs
    100005    1   udp  50347  mountd
    100005    1   tcp  50733  mountd
    100005    2   udp  54094  mountd
    100005    2   tcp  37033  mountd
=== [3/5] Tao thu muc mount point ===
=== [4/5] Mount thu cong bang 'mount -t nfs4' (che do: rw) ===
=== [5/5] Kiem chung ket qua mount ===
192.168.10.11:/share on /mnt/nfs/share type nfs4 (rw,relatime,vers=4.2,rsize=524288,wsize=524288,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=192.168.10.101,local_lock=none,addr=192.168.10.11)
Filesystem           Type  Size  Used Avail Use% Mounted on
192.168.10.11:/share nfs4   78G   14G   61G  18% /mnt/nfs/share

>>> Test quyen ghi thuc te:
  -> GHI THANH CONG (dung voi client duoc cap quyen rw)

De go mount: umount /mnt/nfs/share
```

- Với container 2 chỉ cấp quyền đọc - ro:
```bash
root@client-2:/# chmod +x /root/manual-mount.sh
/root/manual-mount.sh ro
=== [1/5] Cai dat goi NFS client (nfs-common) ===
nfs-common da duoc cai dat, bo qua.
=== [2/5] Kiem tra RPC/portmapper toi server 192.168.10.11 ===
   program vers proto   port  service
    100000    4   tcp    111  portmapper
    100000    3   tcp    111  portmapper
    100000    2   tcp    111  portmapper
    100000    4   udp    111  portmapper
    100000    3   udp    111  portmapper
    100000    2   udp    111  portmapper
    100024    1   udp  33778  status
    100024    1   tcp  45653  status
    100003    4   tcp   2049  nfs
    100005    1   udp  50347  mountd
    100005    1   tcp  50733  mountd
    100005    2   udp  54094  mountd
    100005    2   tcp  37033  mountd
=== [3/5] Tao thu muc mount point ===
=== [4/5] Mount thu cong bang 'mount -t nfs4' (che do: ro) ===
=== [5/5] Kiem chung ket qua mount ===
192.168.10.11:/share on /mnt/nfs/share type nfs4 (ro,relatime,vers=4.2,rsize=524288,wsize=524288,namlen=255,hard,proto=tcp,timeo=600,retrans=2,sec=sys,clientaddr=192.168.10.102,local_lock=none,addr=192.168.10.11)
Filesystem           Type  Size  Used Avail Use% Mounted on
192.168.10.11:/share nfs4   78G   14G   61G  18% /mnt/nfs/share

>>> Test quyen ghi thuc te:
  -> KHONG THE GHI (dung voi client chi duoc cap quyen ro / root_squash)

De go mount: umount /mnt/nfs/share
```

# Dựng mount tự động - fstab

Dọn mount cũ trên mỗi container để tránh xung đột
```bash
umount /mnt/nfs/share
```

## Chạy script cấu hình fstab

```bash
chmod +x /root/setup-fstab-automount.sh
/root/setup-fstab-automount.sh rw
```
## Kiểm tra option mount
```bash
mount | grep nfs4
```
- Kiểm tra có rw/ro không.

## Kiểm tra quyền đọc ghi

- client-rw sẽ ghi thành công còn client-ro sẽ thất bại
```bash
echo "fstab-test-$(date +%s)" > /mnt/nfs/share/fstab-test.txt && echo "GHI THANH CONG" || echo "GHI THAT BAI"
```

- Tuy client-ro không ghi được file nhưng vẫn thấy file do client-rw tạo -> Cho thấy cả 2 đang dùng chung 1 folder
```bash
cat /mnt/nfs/share/fstab-test.txt
ls -la /mnt/nfs/share/
```
