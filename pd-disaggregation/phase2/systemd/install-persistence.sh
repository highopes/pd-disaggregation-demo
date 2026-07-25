#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE2_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
TARGET_DIR=/usr/local/libexec/dynamo-phase2

die() {
  echo "FAIL: $*" >&2
  exit 1
}

reload_required=0
install_unit() {
  local source_file=$1
  local target_file="/etc/systemd/system/${source_file##*/}"
  if ! cmp -s "$source_file" "$target_file"; then
    install -m 0644 "$source_file" "$target_file"
    reload_required=1
  fi
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "must run as root"
install -d -m 0755 "$TARGET_DIR"

install -m 0755 "$SCRIPT_DIR/rdma-cm-tos106.sh" "$TARGET_DIR/rdma-cm-tos106.sh"
install -m 0755 "$SCRIPT_DIR/remove-persistence.sh" "$TARGET_DIR/remove-persistence.sh"
install_unit "$SCRIPT_DIR/dynamo-phase2-rdma-tos.service"

if ip -4 address show | grep -Fq '172.31.230.111/'; then
  install -m 0755 "$PHASE2_DIR/nfs/node1-nfs-rdma-mount.sh" "$TARGET_DIR/"
  install -m 0755 "$PHASE2_DIR/nfs/node1-nfs-rdma-unmount.sh" "$TARGET_DIR/"
  install_unit "$SCRIPT_DIR/dynamo-phase2-nfs-rdma-client.service"
  units=(dynamo-phase2-rdma-tos.service dynamo-phase2-nfs-rdma-client.service)
elif ip -4 address show | grep -Fq '172.31.230.113/'; then
  install -m 0755 "$PHASE2_DIR/storage/start-ram-storage.sh" "$TARGET_DIR/"
  install -m 0755 "$PHASE2_DIR/storage/stop-ram-storage.sh" "$TARGET_DIR/"
  install -m 0755 "$PHASE2_DIR/nfs/node3-nfs-rdma-setup.sh" "$TARGET_DIR/"
  install -m 0755 "$PHASE2_DIR/nfs/node3-nfs-rdma-rollback.sh" "$TARGET_DIR/"
  install_unit "$SCRIPT_DIR/dynamo-phase2-ram-storage.service"
  install_unit "$SCRIPT_DIR/dynamo-phase2-nfs-rdma-server.service"
  units=(dynamo-phase2-rdma-tos.service dynamo-phase2-ram-storage.service dynamo-phase2-nfs-rdma-server.service)
else
  die "host is neither the approved node1 nor node3 storage endpoint"
fi

if (( reload_required == 1 )); then
  systemctl daemon-reload
fi
systemctl enable "${units[@]}"
for unit in "${units[@]}"; do
  systemctl start "$unit"
  systemctl is-active --quiet "$unit" || die "$unit is not active"
done
printf 'PASS: persisted units: %s\n' "${units[*]}"
