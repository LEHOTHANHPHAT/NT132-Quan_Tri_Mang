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

=== 6. KET QUA MOUNT SANG NODE 2 TU CLIENT 1 ===

The command 'docker' could not be found in this WSL 2 distro.
We recommend to activate the WSL integration in Docker Desktop settings.

For details about using Docker Desktop with WSL 2, visit:

https://docs.docker.com/go/wsl2/

