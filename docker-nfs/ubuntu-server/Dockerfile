FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Cài đặt NFS Server, Keepalived và các công cụ mạng/giám sát
RUN apt-get update && \
    apt-get install -y \
        nfs-kernel-server \
        rpcbind \
        net-tools \
        iproute2 \
        keepalived \
        psmisc \
        iputils-ping \
        arping \
        procps \
        curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Tạo thư mục export và thư mục runtime cho NFSv4 + Keepalived
RUN mkdir -p /exports/share \
             /exports/no_squash \
             /var/lib/nfs/rpc_pipefs \
             /var/lib/nfs/v4recovery \
             /etc/keepalived

RUN chmod -R 777 /exports/share /exports/no_squash

COPY exports /etc/exports
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 2049/tcp 2049/udp 111/tcp 111/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
