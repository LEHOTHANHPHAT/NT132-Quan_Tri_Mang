# So sánh các phiên bản NFS và Kiến trúc

Tài liệu tóm tắt lý thuyết NFS và liên hệ với lab của nhóm. Các nhận định
được đối chiếu với RFC và Linux man pages liệt kê cuối bài.

## 1. Các phiên bản NFS (v2, v3, v4, v4.1)

| Phiên bản | Đặc điểm chính | Truyền tải và dịch vụ |
|---|---|---|
| **NFSv2** | Phiên bản cũ; kích thước file và offset bị giới hạn bởi trường 32 bit. NFS cốt lõi là stateless. | Thường gặp qua UDP; không coi UDP là lựa chọn duy nhất của mọi triển khai. Mount và khóa dùng giao thức phụ. |
| **NFSv3** | Hỗ trợ file và offset 64 bit, ghi chưa ổn định và COMMIT. NFS cốt lõi vẫn stateless. | Có thể dùng TCP hoặc UDP tùy triển khai; thường dùng dịch vụ RPC phụ cho mount và khóa. |
| **NFSv4.0** | Tích hợp mở file và khóa; hỗ trợ xác thực mạnh như Kerberos qua RPCSEC_GSS. | Thường dùng TCP cổng 2049; không dùng giao thức MOUNT riêng như v2/v3. |
| **NFSv4.1** | Bổ sung session và giới thiệu pNFS. | Hỗ trợ TCP; pNFS là tính năng tùy chọn, cần hỗ trợ và cấu hình tương ứng. |

NFSv3 có thể xác nhận một lần ghi chưa được lưu ổn định; client dùng
COMMIT khi cần hoàn tất việc ghi ổn định. Không đồng nhất cơ chế này với
tùy chọn export `async` của Linux: đó là hai khái niệm khác nhau.

Trong lab, nhóm dùng NFSv4 qua **TCP cổng 2049**. Đây là cấu hình của
lab; cổng và cách truyền tải còn tùy phiên bản, triển khai và cấu hình.
NFSv4 tích hợp mount và khóa vào giao thức chính, giảm phụ thuộc vào
giao thức phụ của v2/v3; daemon Linux vẫn có thể hỗ trợ quản lý quyền.

### pNFS trong NFSv4.1

Parallel NFS (pNFS), được giới thiệu trong NFSv4.1, là khả năng tùy chọn.
Client nhận thông tin bố trí dữ liệu (*layout*) từ metadata server rồi
có thể truy cập trực tiếp dữ liệu trên các thiết bị lưu trữ phù hợp.
Truy cập song song có thể cải thiện băng thông khi dữ liệu được phân bố
thích hợp. Không phải mọi lần mount NFSv4.1 đều dùng pNFS; lab của nhóm
chưa chứng minh đã triển khai pNFS.

## 2. Stateless vs Stateful & Khóa file (Locking)

### NFSv2/v3: stateless ở giao thức cốt lõi

*Stateless* nghĩa là server không cần giữ trạng thái mở file riêng của
client từ các yêu cầu trước để xử lý một yêu cầu NFS cốt lõi. Client gửi
thông tin cần thiết như file handle và offset trong yêu cầu đọc/ghi. Sau
khi server khởi động lại, client thường có thể thử lại khi server sẵn
sàng. Điều này không có nghĩa server không lưu dữ liệu, không có cache
hoặc mọi thao tác đều có thể lặp lại an toàn.

Khóa file là điểm cần phân biệt: NFSv2/v3 dùng **Network Lock Manager
(NLM)** bên ngoài giao thức NFS cốt lõi. NLM vẫn phải theo dõi trạng thái
khóa và cần cơ chế phục hồi khi một máy khởi động lại.

### Các dịch vụ RPC trong triển khai Linux

- **`rpcbind`:** ánh xạ số chương trình và phiên bản RPC sang địa chỉ/cổng
  dịch vụ. Client thường hỏi `rpcbind` của server tại cổng 111 để tìm
  dịch vụ phụ; cổng của từng dịch vụ có thể thay đổi theo cấu hình.
- **`rpc.mountd`:** xử lý yêu cầu MOUNT ban đầu của NFSv2/v3, kiểm tra
  đường dẫn export và quyền client, rồi trả file handle gốc nếu được phép.
  Trên Linux, `mountd` còn hỗ trợ nhân server lấy thông tin xác thực và
  quyền export, kể cả khi phục vụ NFSv4.
- **`lockd`:** xử lý khóa file qua giao thức NLM, phối hợp giữa client
  và server để cấp hoặc giải phóng khóa.
- **`rpc.statd`:** tham gia Network Status Monitor (NSM), nhận và gửi
  thông báo khởi động lại để các bên phát hiện trạng thái khóa bị mất và
  hỗ trợ phục hồi. `statd` không cấp khóa thay cho `lockd`.

Luồng mount điển hình của NFSv2/v3:

1. Client hỏi `rpcbind` trên server để tìm địa chỉ các dịch vụ RPC cần
   thiết, đặc biệt là `mountd` khi dùng giao thức MOUNT.
2. Client gửi yêu cầu MOUNT chứa đường dẫn export; `mountd` kiểm tra
   client và đường dẫn được chia sẻ.
3. Nếu được phép, `mountd` trả **file handle** ban đầu: mã tham chiếu
   tới thư mục export trên server.
4. Client dùng handle này và các handle nhận thêm khi tra cứu để gửi
   LOOKUP, READ hoặc WRITE tới dịch vụ NFS. Khi ứng dụng cần khóa, client
   phối hợp với NLM/`lockd` riêng.

Đây là luồng điển hình; việc tìm cổng còn tùy cấu hình. NFSv4 không dùng
giao thức MOUNT riêng để lấy handle gốc theo cách của v2/v3.

### NFSv4/v4.1: stateful, lease và phục hồi

NFSv4 là *stateful* vì server duy trì trạng thái liên quan đến client,
ví dụ file đã mở và khóa đang được giữ. Thao tác mở/đóng và khóa tích hợp
trong giao thức NFSv4 thay vì dựa vào NLM riêng.

**Lease** là khoảng thời gian server bảo đảm duy trì trạng thái của client
nếu client gia hạn đúng hạn. Sau khi server khởi động lại, **grace
period** là khoảng thời gian ưu tiên cho client phục hồi trạng thái cũ;
yêu cầu mới có thể bị trì hoãn để tránh xung đột. **Reclaim** là yêu cầu
client gửi để khôi phục trạng thái mở hoặc khóa đã có trước sự cố.

Ví dụ: client A đang giữ khóa thì server khởi động lại. Khi server trở
lại, A phát hiện sự cố và gửi yêu cầu reclaim khóa trong grace period.
Server kiểm tra yêu cầu trước khi cấp lại; các yêu cầu khóa mới có thể
phải chờ. Nếu client không phục hồi đúng hạn hoặc thiếu trạng thái cần
thiết, ứng dụng có thể gặp lỗi hoặc mất khóa. Các cơ chế này cần client,
server và lưu trữ trạng thái phối hợp đúng; chuyển VIP đơn thuần không
chứng minh khóa đã được phục hồi.

## 3. Pseudo-filesystem

NFSv4 trình bày các export trong một cây namespace cho client. Trên Linux,
export với `fsid=0` thường được dùng làm gốc giả (*pseudo-root*).
Client duyệt đường dẫn từ gốc NFS thay vì nhất thiết dùng đường dẫn vật
lý trên server. Namespace giúp tổ chức export; quyền truy cập vẫn cần
được cấu hình và kiểm tra, không chỉ dựa vào việc ẩn đường dẫn.

Trong `docker-nfs/ubuntu-server/exports` của lab:

```text
/exports        192.168.10.0/24(ro,sync,fsid=0,crossmnt,no_subtree_check)
/exports/share  192.168.10.101(rw,sync,fsid=1,no_subtree_check,root_squash) 192.168.10.0/24(ro,sync,fsid=1,no_subtree_check,root_squash)
```

`/exports` là gốc NFSv4 nhờ `fsid=0`. Vì `share` nằm dưới gốc này,
client mount `192.168.10.11:/share` (lab `docker-nfs/`) hoặc qua VIP
`192.168.10.100:/share` của cụm HA `ha-cluster/`, thay vì đường dẫn
vật lý `:/exports/share`.
Export cấp `rw` cho client `192.168.10.101` và `ro` cho subnet;
quyền filesystem và ánh xạ UID/GID vẫn ảnh hưởng đến truy cập thực tế.

### Liên hệ bài failover của nhóm

Theo `docker-nfs/minhchung_tuan7_phanquyen_vip.md`, sau khi dừng node1,
node2 tiếp quản VIP `192.168.10.100`. Client 1 vẫn tạo được file; client
2 đọc được nhưng bị chặn ghi. SHA-256 của file thử trước failover trùng
với giá trị sau failover.

Phép thử thực hiện trên **hai container cùng Docker host**. Minh chứng
không kiểm tra reclaim khóa đang được giữ và không đo thời gian gián đoạn
dịch vụ; vì vậy không thể kết luận hai nội dung đó đã được kiểm chứng.

*Cập nhật:* Keepalived/VIP đã được tách khỏi `docker-nfs/` sang cụm HA
`ha-cluster/` (GlusterFS `replica 2` + NFS-Ganesha). Thời gian chuyển VIP
được đo bằng `ha-cluster/scripts/failover-test.sh`, xem
[04-ha-design.md](04-ha-design.md). Cụm này cấu hình `Graceless = true`
nên vẫn chưa kiểm chứng reclaim khóa.

## Tài liệu tham khảo

1. [RFC 1094 — NFS Protocol Specification (NFSv2)](https://www.rfc-editor.org/rfc/rfc1094.html).
2. [RFC 1813 — NFS Version 3 Protocol Specification](https://www.rfc-editor.org/rfc/rfc1813.html).
3. [RFC 7530 — NFS Version 4 Protocol](https://www.rfc-editor.org/rfc/rfc7530.html), phần khóa và phục hồi.
4. [RFC 8881 — NFS Version 4 Minor Version 1 Protocol](https://www.rfc-editor.org/rfc/rfc8881.html), phần session và pNFS.
5. [Linux man page: rpcbind(8)](https://man7.org/linux/man-pages/man8/rpcbind.8.html).
6. [Linux man page: rpc.mountd(8)](https://man7.org/linux/man-pages/man8/rpc.mountd.8.html).
7. [Linux man page: rpc.statd(8)](https://man7.org/linux/man-pages/man8/rpc.statd.8.html).
8. [Linux man page: exports(5)](https://man7.org/linux/man-pages/man5/exports.5.html).
