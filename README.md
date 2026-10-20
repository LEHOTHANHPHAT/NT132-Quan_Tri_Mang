# Đồ án: Tìm hiểu và Triển khai Hệ thống Network File System (NFS) & High Availability

Repository lưu trữ mã nguồn, cấu hình Docker, script tự động hóa và tài liệu nghiên cứu cho đồ án triển khai dịch vụ chia sẻ file mạng **NFS (Network File System)** trên môi trường Linux/Docker kết hợp kiến trúc chịu lỗi **High Availability (HA)**.

---

## 1. Mục tiêu đồ án

* Nghiên cứu kiến trúc cốt lõi của NFS (VFS, RPC, XDR) và đối sánh hiệu năng thực tế với **SMB/CIFS, FTP, SSHFS**.
* Phân tích sự tiến hóa từ **NFSv2, NFSv3 (Stateless)** lên **NFSv4, NFSv4.1 (Stateful)** và các cơ chế xác thực (`AUTH_SYS`, **Kerberos**).
* Đóng gói và triển khai **NFS Server trên Docker** với cả hai nhánh hệ điều hành **Ubuntu** và **CentOS/Rocky Linux**.
* Thực nghiệm quản lý quyền truy cập theo IP/Subnet, kiểm chứng các tham số mount (`rw/ro`, `sync/async`, `root_squash`/`no_root_squash`) và tự động hóa bằng `fstab` & `systemd automount`.
* Thiết kế và triển khai cụm **NFS Server High Availability (HA)** đảm bảo tính liên tục của dịch vụ khi xảy ra sự cố phần cứng/mạng.

---

## 2. Phân công nhiệm vụ các thành viên

| Thành viên | Mảng phụ trách | Thư mục làm việc chính | Nhánh Git (Branch) |
| :--- | :--- | :--- | :--- |
| **Thành viên 1** | Kiến trúc cốt lõi, So sánh giao thức & Benchmark | `docs/`, `benchmarks/` | `feat/architecture-benchmark` |
| **Thành viên 2** | NFS Server trên Docker (Ubuntu/CentOS) & Quản lý Export | `docker-nfs/` | `feat/docker-nfs-server` |
| **Thành viên 3** | NFS Client, Tự động hóa Mount (`fstab`/`systemd`) & Bảo mật | `client-configs/` | `feat/client-automount-sec` |
| **Thành viên 4** | Hạ tầng High Availability (Keepalived + Shared Storage) | `ha-cluster/` | `feat/nfs-ha-cluster` |

---

## 3. Sơ đồ kiến trúc hệ thống Lab

```text
                    +---------------------------------------+
                    |          NFS Clients (Linux)          |
                    |  (Manual Mount / fstab / systemd)     |
                    +-------------------+-------------------+
                                        |
                                        | Kết nối qua TCP Port 2049
                                        v
                          [ Virtual IP: 192.168.56.100 ]
                                        |
              +-------------------------+-------------------------+
              | (Active - Master)                                 | (Passive - Backup)
              v                                                   v
+---------------------------+                       +---------------------------+
|     NFS Server Node 1     | <=== Keepalived ====> |     NFS Server Node 2     |
|  (Docker Ubuntu / CentOS) |      (Heartbeat)      |  (Docker Ubuntu / CentOS) |
+-------------+-------------+                       +-------------+-------------+
              |                                                   |
              +------ Đồng bộ dữ liệu (DRBD / GlusterFS) ---------+