#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR=/usr/local/libexec/dynamo-phase2

if ip -4 address show | grep -Fq '172.31.230.111/'; then
  units=(dynamo-phase2-nfs-rdma-client.service dynamo-phase2-rdma-tos.service)
  files=(dynamo-phase2-nfs-rdma-client.service dynamo-phase2-rdma-tos.service)
elif ip -4 address show | grep -Fq '172.31.230.113/'; then
  units=(dynamo-phase2-nfs-rdma-server.service dynamo-phase2-ram-storage.service dynamo-phase2-rdma-tos.service)
  files=(dynamo-phase2-nfs-rdma-server.service dynamo-phase2-ram-storage.service dynamo-phase2-rdma-tos.service)
else
  echo "FAIL: host is neither the approved node1 nor node3 storage endpoint" >&2
  exit 1
fi

for unit in "${units[@]}"; do
  systemctl disable "$unit" 2>/dev/null || true
done
for file in "${files[@]}"; do
  rm -f "/etc/systemd/system/$file"
done
rm -rf --one-file-system "$TARGET_DIR"
rmdir /var/lib/dynamo-phase2 2>/dev/null || true
systemctl daemon-reload
echo "PASS: Phase 2 persistence files removed"
