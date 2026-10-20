#!/bin/bash
# Kiểm tra tiến trình nfsd có đang chạy và cổng 2049 có đang mở không
if ! pgrep -x "nfsd" > /dev/null; then
    exit 1
fi

if ! ss -tulpn | grep -q ":2049 "; then
    exit 1
fi

exit 0