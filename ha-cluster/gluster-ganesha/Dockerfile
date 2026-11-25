FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Cài đặt GlusterFS, NFS-Ganesha (FSAL_GLUSTER), Keepalived và công cụ mạng/giám sát
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        glusterfs-server \
        glusterfs-client \
        glusterfs-cli \
        nfs-ganesha \
        nfs-ganesha-gluster \
        dbus \
        rpcbind \
        nfs-common \
        keepalived \
        attr \
        iproute2 \
        netbase \
        iputils-ping \
        arping \
        procps \
        psmisc \
        net-tools \
        ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /data/brick \
             /var/lib/glusterd \
             /var/log/glusterfs \
             /var/log/ganesha \
             /run/ganesha \
             /run/dbus \
             /run/rpcbind \
             /etc/keepalived \
             /etc/ganesha \
             /var/lib/nfs/ganesha

COPY ganesha.conf /etc/ganesha/ganesha.conf
COPY ganesha-ctl.sh /usr/local/sbin/ganesha-ctl.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0644 /etc/ganesha/ganesha.conf && \
    chmod 0755 /usr/local/sbin/ganesha-ctl.sh /usr/local/bin/entrypoint.sh

EXPOSE 2049/tcp 111/tcp 111/udp 24007/tcp 24008/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
