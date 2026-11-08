# So sánh các phiên bản NFS và Kiến trúc

## 1. Các phiên bản NFS (v2, v3, v4, v4.1)
- **NFSv2:** Phiên bản cũ, chỉ chạy trên UDP, giới hạn file 2GB, hiện đã bị loại bỏ trên các OS mới.
- **NFSv3:** Hỗ trợ TCP/UDP, xử lý file lớn (64-bit), thêm tính năng ghi bất đồng bộ (async) để tăng hiệu suất.
- **NFSv4:** Bắt buộc chạy trên TCP (cổng 2049), tích hợp bảo mật (Kerberos), thân thiện với Firewall vì gom tất cả dịch vụ phụ vào một cổng duy nhất.
- **NFSv4.1:** Bổ sung pNFS (Parallel NFS) cho phép Client truy cập song song nhiều server lưu trữ cùng lúc, tăng băng thông.

## 2. Stateless vs Stateful & Khóa file (Locking)
- **Stateless (NFSv2, v3):** Máy chủ không nhớ trạng thái kết nối của Client. Nếu Client bị treo, khóa file phải nhờ một dịch vụ bên ngoài (`NLM`/`rpc.lockd`) giải quyết, dễ sinh lỗi kẹt file.
- **Stateful (NFSv4, v4.1):** Máy chủ duy trì phiên làm việc của Client bằng cơ chế cấp "hợp đồng thuê" (Lease-based locking). Khóa file được tích hợp thẳng vào giao thức NFSv4, giúp cụm máy chủ xử lý khóa an toàn khi có sự cố mạng.

## 3. Pseudo-filesystem
NFSv4 đưa ra khái niệm pseudo-filesystem (cây thư mục ảo) với gốc là `fsid=0`. Client chỉ nhìn thấy một cây thư mục duy nhất được export (ví dụ `192.168.10.11:/share`) thay vì toàn bộ cấu trúc ổ đĩa thật của Server, giúp ẩn đi kiến trúc thư mục vật lý và tăng cường bảo mật.
