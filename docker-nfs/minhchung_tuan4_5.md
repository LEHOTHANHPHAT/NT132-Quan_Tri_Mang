=== 1. CAU HINH EXPORT ===
/exports            192.168.10.0/24(ro,sync,fsid=0,crossmnt,no_subtree_check)
/exports/share      192.168.10.101(rw,sync,fsid=1,no_subtree_check,root_squash) 192.168.10.0/24(ro,sync,fsid=1,no_subtree_check,root_squash)
/exports/no_squash  192.168.10.0/24(rw,sync,fsid=2,no_subtree_check,no_root_squash)

=== 2. KET QUA EXPORTFS -V TREN NODE 1 ===
/exports/share	192.168.10.101(sync,wdelay,hide,no_subtree_check,fsid=1,sec=sys,rw,secure,root_squash,no_all_squash)
/exports      	192.168.10.0/24(sync,wdelay,hide,crossmnt,no_subtree_check,fsid=0,sec=sys,ro,secure,root_squash,no_all_squash)
/exports/share	192.168.10.0/24(sync,wdelay,hide,no_subtree_check,fsid=1,sec=sys,ro,secure,root_squash,no_all_squash)
/exports/no_squash
		192.168.10.0/24(sync,wdelay,hide,no_subtree_check,fsid=2,sec=sys,rw,secure,no_root_squash,no_all_squash)

=== 3. TEST CLIENT 1 (192.168.10.101 - RW) ===
-rw-r--r-- 1 nobody nogroup 29 Nov  8 10:23 /mnt/nfs_share/minhchung.txt

=== 4. TEST CLIENT 2 (192.168.10.102 - RO) ===
Thanh Phat xac nhan ghi file
--> Thu xoa file tren Client 2:
rm: cannot remove '/mnt/nfs_share/minhchung.txt': Read-only file system

=== 5. MINH CHUNG NODE 2 HOAT DONG (.12) ===
/exports/share  192.168.10.101(sync,wdelay,hide,no_subtree_check,fsid=1,sec=sys,rw,secure,root_squash,no_all_squash)
/exports        192.168.10.0/24(sync,wdelay,hide,crossmnt,no_subtree_check,fsid=0,sec=sys,ro,secure,root_squash,no_all_squash)
/exports/share  192.168.10.0/24(sync,wdelay,hide,no_subtree_check,fsid=1,sec=sys,ro,secure,root_squash,no_all_squash)
/exports/no_squash
                192.168.10.0/24(sync,wdelay,hide,no_subtree_check,fsid=2,sec=sys,rw,secure,no_root_squash,no_all_squash)
=== 6. KET QUA MOUNT SANG NODE 2 TU CLIENT 1 ===

# Client 1 tạo file
docker exec nfs-client-1 sh -c \
  'echo "Minh chung ghi file qua Node 2" > "/mnt/nfs-node2-test/$1"' \
  sh "$TEST_FILE"

# Client 2 đọc file do Client 1 tạo
docker exec nfs-client-2 cat "/mnt/nfs-node2-test/$TEST_FILE"

# Client 2 thử ghi vào một file kiểm thử riêng
docker exec nfs-client-2 sh -c \
  'echo "Thu ghi tu client RO" > "/mnt/nfs-node2-test/ro-$1"' \
  sh "$TEST_FILE"
Minh chung ghi file qua Node 2
sh: 1: cannot create /mnt/nfs-node2-test/ro-node2-test-1795498168.txt: Read-only file system

