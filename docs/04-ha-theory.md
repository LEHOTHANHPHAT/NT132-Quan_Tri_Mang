# Lý thuyết High Availability (HA) và Khôi phục lỗi cho Hệ thống NFS

- **Môn học / Lớp:** `NT132.R12.ANTT` — Quản trị mạng
- **Đề tài:** Tìm hiểu và Triển khai Hệ thống Network File System (NFS) & High Availability
- **Tài liệu thiết kế kiến trúc đi kèm:** [04-ha-design.md](./04-ha-design.md)
- **Nhánh Git thực hiện:** `feat/nfs-ha-cluster`

---

## 1. Tổng quan Lý thuyết High Availability (HA) cho Hệ thống File Server

### 1.1. Bài toán Single Point of Failure (SPOF) trên NFS truyền thống

Trong mô hình triển khai NFS truyền thống (một NFS Server đơn lẻ phục vụ đồng thời nhiều NFS Client), toàn bộ luồng đọc/ghi dữ liệu, cấp phát File Handle và quản lý khóa tệp tin đều tập trung vào một máy chủ vật lý hoặc container duy nhất. Máy chủ này trở thành **điểm lỗi đơn (Single Point of Failure — SPOF)**. Khi NFS Server đơn lẻ gặp sự cố (hỏng phần cứng, đứt kết nối mạng, treo nhân hệ điều hành, hoặc tiến trình `rpc.nfsd` bị dừng đột ngột):

- Mọi phiên làm việc từ các NFS Client đang mount đều bị ngắt quãng.
- Với tùy chọn mount `hard` (mặc định trên Linux), các tiến trình đọc/ghi trên Client bị treo ở trạng thái chờ (`D state` / uninterruptible sleep) cho tới khi Server hoạt động trở lại, làm đóng băng ứng dụng phụ thuộc.
- Với tùy chọn mount `soft`, sau khi hết số lần thử lại (`retrans`), nhân Client trả về lỗi `EIO` (Input/Output Error), dẫn đến nguy cơ hỏng dữ liệu hoặc ghi thiếu bản ghi đang xử lý dở.
- Các khóa tệp tin (file locking) đang được giữ trên Server bị gián đoạn cho đến khi Server khởi động lại hoàn toàn.

Do đó, hệ thống lưu trữ dùng chung cần áp dụng kiến trúc **High Availability (HA — Tính sẵn sàng cao)** để loại bỏ SPOF, đảm bảo dịch vụ chia sẻ file có thể tự động chuyển sang máy chủ dự phòng với thời gian gián đoạn tối thiểu và không làm mất dữ liệu.

### 1.2. Các chỉ số đánh giá độ sẵn sàng cao

Hiệu quả của một cụm HA File Server được đo lường và kiểm chứng thông qua ba chỉ số kỹ thuật chuẩn mực:

| Chỉ số | Tên đầy đủ | Ý nghĩa kỹ thuật |
| :--- | :--- | :--- |
| **Uptime / SLA** | Service Level Agreement | Tỷ lệ phần trăm thời gian hệ thống cung cấp dịch vụ bình thường trên tổng thời gian vận hành trong năm (ví dụ: `99.9%` tương ứng thời gian gián đoạn tối đa ~8.76 giờ/năm; `99.99%` tương ứng ~52.6 phút/năm). |
| **RTO** | Recovery Time Objective | Thời gian tối đa kể từ thời điểm Node chính gặp sự cố cho tới khi hệ thống hoàn tất chuyển mạch dịch vụ (gắn Virtual IP sang Node dự phòng và khôi phục luồng I/O cho Client). |
| **RPO** | Recovery Point Objective | Lượng dữ liệu tối đa có thể bị mất khi xảy ra sự cố đột ngột, tính theo khoảng dữ liệu mới ghi chưa kịp đồng bộ sang Node dự phòng (`RPO = 0` nghĩa là không mất bất kỳ dữ liệu nào đã xác nhận ghi thành công). |

### 1.3. Phân loại mô hình HA cho File Server: Active-Passive và Active-Active

| Tiêu chí | Active-Passive (Failover / Hot-Standby) | Active-Active (Clustering / Parallel) |
| :--- | :--- | :--- |
| **Nguyên lý vận hành** | Chỉ có **1 Node (Active/Master)** nắm giữ Virtual IP (VIP) và trực tiếp phục vụ mọi yêu cầu đọc/ghi từ Client. **Node còn lại (Passive/Backup)** ở trạng thái dự phòng nóng (Hot-Standby), liên tục nhận đồng bộ dữ liệu và theo dõi Heartbeat để tiếp quản khi Active lỗi. | **Cả 2 hoặc nhiều Node** cùng lúc ở trạng thái Active, cùng tiếp nhận và xử lý I/O từ Client qua cơ chế cân bằng tải (Load Balancer, DNS Round-Robin) hoặc pNFS. |
| **Quản lý khóa file & nhất quán dữ liệu** | An toàn và đơn giản: tại một thời điểm chỉ có duy nhất một nhân NFS Server ghi xuống vùng lưu trữ, loại bỏ nguy cơ xung đột ghi chéo metadata. | Rất phức tạp: bắt buộc phải có hệ thống file phân cụm (Clustered Filesystem như CephFS, GFS2, OCFS2) hoặc user-space NFS server hỗ trợ **Distributed Lock Manager (DLM)** như NFS-Ganesha kết hợp GlusterFS. |
| **Hiệu năng & tận dụng tài nguyên** | Tối đa bằng năng lực của 1 Node Active tại một thời điểm (Node Passive chủ yếu xử lý đồng bộ lưu trữ). | Tận dụng được băng thông mạng và CPU của toàn bộ các Node cùng lúc. |
| **Nguy cơ Split-Brain** | Thấp nếu kiểm soát tốt quyền giữ VIP và trạng thái dịch vụ; dễ cô lập nút lỗi. | Cao hơn nếu mất kết nối Heartbeat giữa các Node mà cả hai vẫn tiếp tục ghi đồng thời vào cùng một dữ liệu. |
| **Độ phức tạp triển khai** | Thấp đến trung bình; tương thích trực tiếp với `nfs-kernel-server` sẵn có trong nhân Linux. | Cao; đòi hỏi hạ tầng DLM, cơ chế STONITH/Fencing phần cứng và cấu hình phức tạp. |

### 1.4. Bài toán Split-Brain và Nguyên lý Phòng tránh trong Cụm HA

**Split-Brain (Tách não)** là sự cố nghiêm trọng nhất trong cụm HA xảy ra khi đường truyền Heartbeat giữa hai Node bị đứt (ví dụ lỗi mạng nội bộ) trong khi cả hai Node thực tế vẫn đang chạy:

- Node 2 không nhận được gói tin Heartbeat từ Node 1 nên cho rằng Node 1 đã chết và tự nâng cấp lên làm `MASTER`, đồng thời chiếm lấy Virtual IP.
- Kết quả là cả Node 1 và Node 2 đều giữ cùng một địa chỉ VIP trên mạng và cùng ghi xuống dữ liệu lưu trữ, gây xung đột ARP, ngắt kết nối Client chập chờn và có thể phá hỏng hệ thống tệp tin.

Các cơ chế phòng tránh Split-Brain trong lý thuyết cụm HA gồm:

1. **Quorum (Đa số phiếu):** Yêu cầu số nút tối thiểu (thường là $N/2 + 1$, ví dụ cụm 3 Node hoặc dùng Node trọng tài / Witness) mới được phép giữ tài nguyên Active.
2. **Fencing / STONITH (Shoot The Other Node In The Head):** Trước khi Node 2 tiếp quản tài nguyên, nó gửi lệnh cô lập hoàn toàn Node 1 (tắt nguồn qua IPMI/PDU hoặc thu hồi quyền truy cập SAN/Storage) để chắc chắn Node 1 không thể tiếp tục ghi dữ liệu.
3. **Healthcheck đa tầng & Hạ quyền tự động:** Kiểm tra đồng thời cả kết nối mạng lẫn sức khỏe dịch vụ NFS; nếu dịch vụ trên Node lỗi, Node tự hạ độ ưu tiên hoặc tự dừng tiến trình để nhường VIP sạch sẽ.

---

## 2. Lý thuyết Stack Công nghệ trong Cụm NFS HA

Một hệ thống NFS HA hoàn chỉnh được cấu thành từ hai tầng công nghệ độc lập nhưng bổ trợ cho nhau: **(1) Tầng Quản lý Cụm & Điều phối Virtual IP** và **(2) Tầng Đồng bộ Dữ liệu (Storage Replication / Shared Storage)**.

### 2.1. Tầng Quản lý Cụm & Virtual IP

#### So sánh Keepalived (VRRP) và Pacemaker + Corosync

| Tiêu chí | Keepalived (VRRP) | Pacemaker + Corosync |
| :--- | :--- | :--- |
| **Cơ chế cốt lõi** | Triển khai giao thức **VRRP (Virtual Router Redundancy Protocol)** để quản lý địa chỉ Virtual IP (VIP) và theo dõi sức khỏe dịch vụ thông qua các script kiểm tra định kỳ (`vrrp_script`). | Bộ quản trị cụm đầy đủ (**CRM — Cluster Resource Manager**): Corosync đảm nhiệm lớp truyền thông nhóm/Quorum/Heartbeat, còn Pacemaker điều phối vòng đời tài nguyên (VIP, mount đĩa, DRBD, NFS daemon) theo thứ tự phụ thuộc nghiêm ngặt. |
| **Tài nguyên & độ phức tạp** | Gọn nhẹ, chỉ gồm một tiến trình chính và một tệp cấu hình `/etc/keepalived/keepalived.conf`. | Phức tạp hơn, cần định nghĩa nhiều OCF Resource Agents (`IPaddr2`, `Filesystem`, `exportfs`, `nfsserver`) và cấu hình chính sách ràng buộc (`colocation`, `order`). |
| **Khả năng vận hành trên Container** | Hoạt động nhẹ nhàng và ổn định bên trong Linux Container (Docker) chỉ cần quyền mạng phù hợp (`NET_ADMIN`). | Yêu cầu môi trường gần giống máy ảo/máy thật với `systemd` đầy đủ và IPC nhân phức tạp, khó vận hành gọn trong container thông thường. |
| **Tốc độ chuyển mạch VIP** | Rất nhanh (~1–3 giây tùy `advert_int`). | Nhanh (~2–5 giây), nhưng tốn thêm thời gian khởi chạy/stop tuần tự từng resource agent khi failover. |

#### Nguyên lý Giao thức VRRP (RFC 5798) và Keepalived

**VRRP (Virtual Router Redundancy Protocol)** là giao thức mạng hoạt động ở tầng IP (**IP Protocol số `112`**) cho phép nhiều máy chủ chia sẻ một địa chỉ IP ảo gọi là **Virtual IP (VIP)** dưới một nhóm định danh chung là **Virtual Router ID (`VRID`)**:

1. **Bầu chọn vai trò `MASTER` và `BACKUP`:**
   - Mỗi Node tham gia VRRP được gán một giá trị ưu tiên (`priority` từ `1` đến `254`). Node có `priority` cao nhất được bầu làm `MASTER`, chịu trách nhiệm gắn VIP lên giao diện mạng và nhận toàn bộ lưu lượng gửi đến VIP. Các Node còn lại ở trạng thái `BACKUP`.
2. **Cơ chế Heartbeat (VRRP Advertisement):**
   - Node `MASTER` định kỳ phát bản tin **VRRP Advertisement** theo chu kỳ `advert_int` (thường là `1` giây) tới địa chỉ multicast `224.0.0.18` (hoặc gửi trực tiếp dạng unicast `unicast_peer` trong các mạng ảo hóa/cloud không hỗ trợ multicast).
   - Node `BACKUP` duy trì bộ đếm thời gian `Master_Down_Interval` (mặc định xấp xỉ `3 * advert_int + skew_time`). Nếu quá khoảng thời gian này không nhận được bản tin Advertisement, `BACKUP` kết luận `MASTER` đã sự cố và lập tức chuyển sang trạng thái `MASTER`.
3. **Giám sát tầng ứng dụng (`vrrp_script` Healthcheck):**
   - Giao thức VRRP thuần túy chỉ phát hiện được lỗi mất mạng hoặc tắt máy (Node chết hẳn). Nếu máy chủ vẫn sống nhưng **dịch vụ NFS bên trong bị treo hoặc crash**, VRRP vẫn tiếp tục gửi Heartbeat bình thường dẫn tới Client không truy cập được dữ liệu.
   - Keepalived khắc phục bằng cơ chế `vrrp_script`: chạy định kỳ một script kiểm tra sức khỏe ứng dụng. Khi script báo lỗi liên tiếp đủ ngưỡng `fall`, Keepalived tự động trừ điểm `priority` (`weight` âm) hoặc đưa phiên VRRP sang trạng thái `FAULT`, buộc Node `BACKUP` có `priority` cao hơn tiếp quản VIP ngay lập tức.
4. **Cơ chế Gratuitous ARP (GARP):**
   - Khi một Node chuyển lên làm `MASTER` và gắn VIP lên card mạng, các thiết bị Switch/Bridge và NFS Client trong cùng mạng LAN vẫn đang lưu ánh xạ `VIP -> địa chỉ MAC cũ của Node 1` trong bảng ARP cache (thường tồn tại hàng chục giây đến vài phút).
   - Keepalived giải quyết bằng cách phát ra loạt gói tin **Gratuitous ARP (GARP)** — bản tin ARP quảng bá không cần có gói ARP Request trước đó — thông báo địa chỉ VIP nay thuộc về **địa chỉ MAC mới của Node 2**. Switch L2 và các Client cập nhật ngay bảng MAC/ARP để chuyển hướng gói tin sang Node 2 chỉ trong vài mili-giây.

### 2.2. Tầng Đồng bộ Dữ liệu (Storage Replication / Shared Storage)

Tầng quản lý VIP chỉ giải quyết việc điều hướng lưu lượng mạng; để dịch vụ NFS tiếp tục phục vụ không mất dữ liệu (`RPO = 0`), hai Node bắt buộc phải truy cập vào **cùng một tập dữ liệu đồng nhất**. Có 3 mô hình lưu trữ phổ biến cho cụm NFS HA:

#### 1. DRBD (Distributed Replicated Block Device) — Đồng bộ mức Block

DRBD hoạt động như một lớp RAID-1 qua mạng TCP/IP ngay bên dưới hệ thống tập tin (`ext4`/`xfs`) tại thiết bị khối ảo `/dev/drbdX`. DRBD cung cấp 3 chế độ giao thức đồng bộ quyết định sự đánh đổi giữa hiệu năng và độ an toàn dữ liệu:

- **Protocol A (Asynchronous — Bất đồng bộ):** Ghi xong vào đĩa cục bộ trên Node Primary và đẩy vào bộ đệm TCP gửi đi là báo hoàn tất cho ứng dụng. Tốc độ cao, phù hợp khoảng cách địa lý xa nhưng có nguy cơ mất dữ liệu mới nhất nếu Node Primary chết đột ngột (`RPO > 0`).
- **Protocol B (Memory Synchronous — Bán đồng bộ):** Báo hoàn tất khi dữ liệu đã ghi xong trên đĩa Primary và đã tới bộ nhớ đệm (RAM) của Node Secondary.
- **Protocol C (Synchronous — Đồng bộ hoàn toàn):** Chỉ trả về xác nhận ghi hoàn tất cho hệ thống tập tin khi **cả Node Primary và Node Secondary đều đã ghi dữ liệu xuống đĩa vật lý thành công**. Đây là giao thức tiêu chuẩn cho cụm HA tại chỗ vì đảm bảo **RPO = 0**.

Trong cấu hình DRBD truyền thống (`Primary/Secondary`), tại một thời điểm chỉ Node `Primary` được phép mount `/dev/drbd0` để export NFS; khi failover, cụm phải chuyển Node 2 từ `Secondary` lên `Primary` rồi mới thực hiện `mount` trước khi mở dịch vụ NFS.

#### 2. GlusterFS (Replicated Volume) — Đồng bộ mức File phân tán

GlusterFS là hệ thống file phân tán trên không gian người dùng (user-space), kết hợp các thư mục lưu trữ cục bộ (**Bricks**) trên từng máy chủ thành một không gian tên thống nhất qua mô-đun **AFR (Automatic File Replication)** với cấu hình `replica 2` (hoặc `replica 3` để tránh split-brain bằng arbiter):

- **Ghi đồng bộ ở mức tệp:** Khi một tệp được tạo hoặc chỉnh sửa qua điểm mount GlusterFS, cơ chế AFR nhân bản đồng thời dữ liệu xuống tất cả các brick trong tập replica.
- **Cơ chế Self-Heal:** Nếu một Node ngoại tuyến trong lúc Node kia đang ghi, khi Node lỗi khởi động lại, tiến trình Self-Heal Daemon (`glustershd`) tự động đối chiếu thuộc tính mở rộng (`trusted.afr.*`) và đồng bộ bù các tệp bị sai lệch.
- **Ưu điểm cho Failover:** Cả hai Node có thể gắn sẵn (mount) volume GlusterFS vào cây thư mục export mà không phải chờ thao tác mount thiết bị block lúc xảy ra sự cố, giúp giảm đáng kể thời gian chuyển mạch.

#### 3. Shared Storage (SAN / NAS / Shared Volume) + Đồng bộ Metadata

Trong các hệ thống doanh nghiệp dùng thiết bị lưu trữ tập trung (SAN/NAS) hoặc trong môi trường Docker Lab mô phỏng vùng lưu trữ dùng chung, cả hai Node máy chủ cùng ánh xạ trực tiếp tới một không gian lưu trữ vật lý chung:

- Hai Node nhìn thấy tức thời cùng một cây thư mục dữ liệu và cùng một bảng **inode** (không có độ trễ sao chép mạng giữa hai Node).
- Tuy nhiên, để chạy được mô hình **Active-Passive**, vẫn phải đảm bảo **tại một thời điểm chỉ có Node giữ VIP tiếp nhận I/O từ NFS Client**, đồng thời đồng bộ cấu hình `/etc/exports` và vùng siêu dữ liệu trạng thái `/var/lib/nfs`.

#### Bảng so sánh 3 giải pháp tầng lưu trữ cho NFS HA

| Tiêu chí | DRBD (Protocol C) | GlusterFS (`replica 2`) | Shared Storage / Shared Volume |
| :--- | :--- | :--- | :--- |
| **Đơn vị đồng bộ** | Khối dữ liệu (Block device) | Tệp tin (Distributed filesystem) | Lưu trữ dùng chung trực tiếp |
| **Đảm bảo RPO = 0** | Có (với Protocol C) | Có (với AFR synchronous write) | Có (dữ liệu ghi trực tiếp xuống kho chung) |
| **Thao tác khi Failover** | Cần promote Secondary $\rightarrow$ Primary và mount filesystem | Volume đã mount sẵn, phục vụ ngay | Thư mục đã mount sẵn, phục vụ ngay |
| **Độ trễ mạng khi ghi** | Có (chờ ACK TCP từ Node 2) | Có (chờ ghi đủ replica bricks) | Không tốn băng thông nhân bản giữa 2 Node |
| **Yêu cầu hạ tầng** | Kernel module `drbd` + block disk riêng trên từng node | Cụm `glusterd` + brick độc lập | Vùng lưu trữ chung gắn vào cả 2 Node |

---

## 3. Lý thuyết Giữ Trạng thái (State Recovery & Grace Period) trên NFSv4 khi Failover

### 3.1. Khác biệt bản chất khi Failover giữa NFSv3 và NFSv4

Khác với các giao thức phi trạng thái như HTTP, việc chuyển đổi dự phòng trên NFS chịu ảnh hưởng trực tiếp từ mô hình quản lý trạng thái của từng phiên bản giao thức:

| Khía cạnh | NFSv3 (Stateless) | NFSv4 / NFSv4.1 (Stateful) |
| :--- | :--- | :--- |
| **Trạng thái phiên trong nhân** | Server **không lưu** thông tin Client nào đang mở file nào. Mỗi yêu cầu RPC độc lập chứa đầy đủ File Handle và offset. | Server **lưu giữ toàn bộ trạng thái** (`ClientID`, `Open StateID`, `Lock StateID`, `Delegation`) thông qua cơ chế hợp đồng thuê (**Lease-based locking**). |
| **Dịch vụ khóa file** | Dựa vào daemon phụ bên ngoài: `rpc.lockd` (NLM) và `rpc.statd` (NSM) chạy qua `rpcbind` (port 111 + các port động). | Tích hợp trực tiếp thao tác `OPEN`, `LOCK`, `RENEW` vào bên trong giao thức NFSv4 trên **một cổng duy nhất `TCP 2049`**. |
| **Cơ chế phục hồi sau sập Node** | Server mới dùng `rpc.statd` đọc `/var/lib/nfs/statd` và gửi gói `SM_NOTIFY` báo các Client tự xin cấp lại khóa NLM (dễ bị kẹt khi qua firewall hoặc container). | Server mới mở **Grace Period** và đọc danh sách Client cũ từ `/var/lib/nfs/v4recovery` để cho phép Client chủ động gửi lệnh **Reclaim** khôi phục toàn bộ khóa một cách có kiểm soát. |

### 3.2. Cơ chế Lease Time, Grace Period và Quy trình State Reclaim

Trên nhân Linux (`nfsd`), vòng đời quản lý trạng thái và khôi phục lỗi của NFSv4 vận hành theo 3 thành phần cốt lõi:

1. **Lease Time (`/proc/fs/nfsd/nfsv4leasetime`):**
   - Quy định thời hạn hiệu lực tối đa của một "hợp đồng thuê" trạng thái (mặc định trên Linux là **90 giây**).
   - Client phải định kỳ gửi thông điệp gia hạn (`RENEW` trong NFSv4.0 hoặc `SEQUENCE` trong NFSv4.1) trước khi hết Lease Time. Nếu quá thời hạn này mà Client không liên lạc, Server coi như Client đã chết và thu hồi toàn bộ khóa file để giải phóng tài nguyên.
2. **Grace Period (`/proc/fs/nfsd/nfsv4gracetime`):**
   - Ngay khi NFSv4 Server khởi động hoặc Node dự phòng tiếp quản VIP sau Failover, Server bước vào **thời kỳ ân hạn (Grace Period)** (mặc định cũng bằng **90 giây**).
   - Trong khoảng thời gian Grace Period, Server áp dụng hai quy tắc nghiêm ngặt:
     - **Chặn yêu cầu mới:** Mọi yêu cầu mở file mới (`OPEN`) hoặc xin cấp khóa mới (`LOCK`) từ các Client thông thường bị từ chối tạm thời với mã lỗi `NFS4ERR_GRACE`. Điều này ngăn chặn một Client mới vào chiếm mất khóa file của các Client đang kết nối trước sự cố nhưng chưa kịp chuyển sang Node 2.
     - **Ưu tiên khôi phục trạng thái cũ (State Reclaim):** Server chỉ chấp nhận các yêu cầu khôi phục trạng thái (`CLAIM_PREVIOUS` / `RECLAIM`) từ các Client hợp lệ đã làm việc trước khi chuyển mạch. Khi Client hoàn tất việc lấy lại toàn bộ khóa, nó gửi lệnh `RECLAIM_COMPLETE` (NFSv4.1+).
3. **Thư mục lưu vết `/var/lib/nfs/v4recovery`:**
   - Mỗi khi Client xác lập danh tính với NFSv4 Server (`SETCLIENTID` / `EXCHANGE_ID`), Server ghi nhận định danh Client vào thư mục `/var/lib/nfs/v4recovery` (hoặc cơ sở dữ liệu `nfsdcld`).
   - Nếu hai Node trong cụm HA đồng bộ thư mục `/var/lib/nfs/v4recovery`, khi `nfs-node2` lên thay `nfs-node1`, nó sở hữu đầy đủ danh sách Client trước đó nên xác thực và chấp nhận yêu cầu Reclaim từ Client mà không từ chối quyền đòi lại khóa.

### 3.3. File Handle, Tham số `fsid` và Bài toán Lỗi `Stale File Handle (ESTALE)`

Trong giao thức NFS, Client không truy cập tệp tin bằng đường dẫn chuỗi (như `/exports/share/test.txt`) trong từng gói tin đọc/ghi, mà truy cập thông qua một định danh nhị phân cố định gọi là **NFS File Handle**. File Handle được Server tạo ra từ hai thành phần chính:

- **Filesystem Identifier (`fsid`):** Định danh của vùng export (mặc định nếu không khai báo, Linux có thể tính từ major/minor device number hoặc UUID của phân vùng đĩa).
- **Inode & Generation Number:** Số thứ tự định danh tệp tin trên hệ thống tệp.

**Nguyên nhân gây lỗi `ESTALE (Stale File Handle)` khi Failover:**
Nếu Node 1 và Node 2 gán `fsid` khác nhau cho cùng một thư mục export (do cấu hình `/etc/exports` lệch nhau hoặc số thiết bị block `/dev/sdX` trên hai máy khác nhau), thì cùng một tệp tin nhưng **File Handle trả về từ Node 2 sẽ khác Node 1**. Khi Client tiếp tục gửi gói tin mang File Handle cũ sang Node 2 sau failover, Node 2 không nhận diện được và lập tức trả về lỗi `Stale file handle`, làm gãy phiên làm việc đang chạy.

**Giải pháp chuẩn hóa trong lý thuyết NFS HA:**
- Bắt buộc khai báo tường minh cùng một giá trị **`fsid=<số>`** cho mọi thư mục trong `/etc/exports` trên tất cả các Node trong cụm (ví dụ `fsid=0` cho pseudo-root NFSv4, `fsid=1`, `fsid=2` cho từng thư mục chia sẻ).
- Đảm bảo vùng lưu trữ bên dưới giữ nguyên **inode number** nhất quán giữa các Node.

### 3.4. Tác động của Mount Option phía Client tới Khả năng Chịu lỗi

Khả năng phục hồi mượt mà không chỉ phụ thuộc vào cụm Server mà còn chịu ảnh hưởng trực tiếp từ các tùy chọn mount trên NFS Client:

| Tùy chọn Client | Vai trò trong kịch bản Failover |
| :--- | :--- |
| **`hard` vs `soft`** | Bắt buộc dùng **`hard`** cho cụm HA có ghi dữ liệu: khi Server chuyển mạch mất vài giây, tiến trình trên Client tạm dừng chờ Server trả lời rồi tiếp tục ghi nguyên vẹn; nếu dùng `soft`, tiến trình có thể bị lỗi `EIO` ngay giữa lúc chuyển VIP. |
| **`intr` (trên kernel cũ) / Ctrl+C** | Trên nhân Linux hiện đại, `hard` mặc định cho phép ngắt bằng tín hiệu `SIGKILL` (`kill -9`) nếu cần thiết; vẫn giữ an toàn dữ liệu khi failover ngắn hạn. |
| **`timeo=<n>` & `retrans=<k>`** | `timeo` tính theo đơn vị $1/10$ giây (mặc định `600` tức 60 giây trên NFSv4/TCP). Việc rút ngắn hợp lý `timeo` (ví dụ `timeo=50` tương ứng 5 giây) và `retrans=2` giúp Client phát hiện kết nối tới Node cũ bị ngắt và thử thiết lập lại phiên TCP tới VIP nhanh hơn. |
| **`proto=tcp` & `vers=4`** | Sử dụng TCP làm lớp vận chuyển tin cậy và chuẩn giao thức NFSv4 trên cổng `2049`, giúp đi xuyên tường lửa dễ dàng và hỗ trợ cơ chế State Reclaim hoàn chỉnh. |

---

## 4. Kiến trúc User-Space NFS-Ganesha (`FSAL_GLUSTER`) và Quản trị Quorum GlusterFS

### 4.1. So sánh Kernel `nfs-kernel-server` trên FUSE với User-Space NFS-Ganesha (`FSAL_GLUSTER`)

Trong thực tế triển khai NFS HA trên GlusterFS, việc gắn volume GlusterFS qua lớp **FUSE** (`/mnt/gluster`) rồi dùng `nfs-kernel-server` export lại dễ phát sinh nút cổ chai và lỗi kỹ thuật:

- **Chi phí chuyển ngữ cảnh (Context Switch):** Mỗi lời gọi I/O phải đi qua $Client \rightarrow Kernel\ nfsd \rightarrow VFS \rightarrow FUSE\ Daemon \rightarrow Gluster\ Client \rightarrow Mạng$, vừa tốn CPU vừa có nguy cơ treo khóa VFS trong môi trường container Docker.
- **Xung đột định danh `fsid` & FUSE Re-export:** FUSE không sinh định danh block device ổn định giữa các máy khác nhau, dễ trả về `ESTALE` khi failover sang Node dự phòng.

**NFS-Ganesha** giải quyết triệt để vấn đề này bằng mô hình **user-space NFS Server** tích hợp trực tiếp mô-đun **`FSAL_GLUSTER`** thông qua thư viện **`libgfapi`**:

- Mọi thao tác đọc/ghi từ NFSv4 được Ganesha chuyển thẳng qua `libgfapi` (trong cùng không gian người dùng) tới các Brick GlusterFS qua TCP, loại bỏ hoàn toàn tầng trung gian FUSE.
- **File Handle đồng nhất nhờ GlusterFS GFID:** Thay vì dựa vào cặp `(st_dev, inode ext4)` vốn khác nhau giữa ổ đĩa cục bộ của Node 1 và Node 2, `FSAL_GLUSTER` mã hóa NFS File Handle từ **GFID (UUID 128-bit toàn cụm)** được GlusterFS gán đồng bộ trong thuộc tính mở rộng `trusted.gfid` của mọi tệp trên cả hai Brick. Nhờ đó, khi VIP chuyển sang Node 2, Client giữ nguyên File Handle cũ mà không gặp lỗi `ESTALE (Stale file handle)`.

### 4.2. Bài toán Quorum và Split-Brain trong GlusterFS 2-Node so với Production Arbiter

Trong mô hình nhân bản **GlusterFS `replica 2`**, hai Node lưu trữ hai bản sao ngang hàng hoàn toàn qua mạng:

- **Chế độ Lab 2-Node (`cluster.quorum-type none`):** Nếu bật kiểm tra đa số mặc định khi chỉ có đúng 2 Node, khi Node 1 tắt nguồn, Node 2 còn lại chỉ chiếm $1/2 = 50\%$ ($\le 50\%$) nên sẽ tự chuyển volume về chỉ đọc để tránh Split-Brain. Trong kịch bản HA Failover 2-Node chủ động qua **một Virtual IP duy nhất** (Active-Passive Keepalived), việc cấu hình `cluster.quorum-type none` kết hợp `network.ping-timeout 5` cho phép Node 2 tiếp tục phục vụ đọc/ghi bình thường (`RPO = 0`), ghi nhật ký sai lệch `trusted.afr.*` và tự động vá bù (**Self-Heal**) ngay khi Node 1 trực tuyến trở lại.
- **Khuyến nghị Production (`replica 3 arbiter 1`):** Trên hệ thống thực tế cần khả năng tự cô lập Split-Brain ngay ở tầng lưu trữ nếu đứt mạng giữa các Node nhưng cả hai vẫn chạy, quản trị viên bổ sung thêm một Node thứ 3 gọn nhẹ làm **Arbiter** (chỉ lưu metadata/xattr và kích thước tệp $0$ byte) để đạt quy tắc đa số $2/3$ phiếu bầu.
