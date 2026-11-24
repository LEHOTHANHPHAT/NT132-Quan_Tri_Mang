# Tuần 6 — Thực nghiệm ghi NFS với sync và async

**Sinh viên thực hiện:** Lê Hồ Thành Phát (TV2)  
**Phần phụ trách:** NFS Server, Docker và Export

## 1. Mục tiêu

So sánh tốc độ ghi file qua NFS khi thay đổi tùy chọn Export phía
máy chủ từ `sync` sang `async`.

Với `sync`, máy chủ chờ dữ liệu được ghi xuống bộ lưu trữ ổn định
trước khi xác nhận yêu cầu ghi. Với `async`, máy chủ có thể xác nhận
sớm hơn, khi dữ liệu vẫn đang chờ được ghi xuống bộ lưu trữ.

## 2. Môi trường và cách đo

- Máy chủ: Node 2 (`192.168.10.12`), chạy trong Docker trên WSL.
- Máy khách: Client 1 (`192.168.10.101`), có quyền đọc/ghi.
- Thư mục NFS: `192.168.10.12:/share`.
- Điểm mount trên client: `/mnt/nfs-node2-test`.
- Mỗi cấu hình đo 3 lượt. Mỗi lượt ghi một file thử 64 MiB.

Đầu tiên, xác nhận dòng Export của Client 1 đang dùng `sync` bằng
`exportfs -v` và chạy 3 lượt đo. Sau đó đổi tùy chọn của Client 1
sang `async`, nạp lại bằng `exportfs -ra`, kiểm tra bằng `exportfs -v`
và chạy lại cùng phép đo.

Mỗi lượt dùng lệnh `dd if=/dev/zero of="$file" bs=1M count=64 conv=fdatasync`.
Tùy chọn `conv=fdatasync` yêu cầu đồng bộ dữ liệu của file trước khi
`dd` kết thúc. File thử được xóa sau mỗi lượt.

## 3. Kết quả

| Cấu hình | Lượt | Thời gian (s) | Tốc độ (MB/s) |
|---|---:|---:|---:|
| sync  | 1 | 0.190885  | 352 |
| sync  | 2 | 0.0769941 | 872 |
| sync  | 3 | 0.0770736 | 871 |
| async | 1 | 0.332445  | 202 |
| async | 2 | 0.131649  | 510 |
| async | 3 | 0.0851689 | 788 |

| Cấu hình | Tốc độ ghi trung vị (MB/s) |
|---|---:|
| sync  | 871 |
| async | 510 |

## 4. Nhận xét

Trong phép thử ghi file 64 MiB trên lab này, `sync` đạt tốc độ
trung vị 871 MB/s và `async` đạt 510 MB/s. Trung vị của `async`
thấp hơn khoảng 41% so với `sync`.

Cả hai cấu hình đều có lượt đầu chậm nhất. Mỗi cấu hình chỉ được
đo ba lượt, theo thứ tự `sync` trước và `async` sau. Vì vậy, kết
quả chỉ đại diện cho lần thử này. Nguyên nhân chênh lệch cần thêm
phép đo để xác định.

## 5. Khôi phục cấu hình

Sau thử nghiệm, đã khôi phục `/etc/exports` trên Node 2, nạp lại
bằng `exportfs -ra` và xác nhận dòng `/exports/share` của Client 1
(`192.168.10.101`) đã trở lại `sync` bằng `exportfs -v`.
