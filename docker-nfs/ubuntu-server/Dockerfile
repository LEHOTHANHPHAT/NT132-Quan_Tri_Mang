FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Cài đặt NFS Server và công cụ mạng
RUN apt-get update && \
    apt-get install -y nfs-kernel-server rpcbind net-tools iproute2 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Tạo thư mục /exports/share khớp với sơ đồ (192.168.10.100:/share)
# và /exports/no_squash để phục vụ kịch bản demo bảo mật
RUN mkdir -p /exports/share \
             /exports/no_squash \
             /var/lib/nfs/rpc_pipefs \
             /var/lib/nfs/v4recovery

RUN chmod -R 777 /exports/share /exports/no_squash

COPY exports /etc/exports
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 2049/tcp 2049/udp 111/tcp 111/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]