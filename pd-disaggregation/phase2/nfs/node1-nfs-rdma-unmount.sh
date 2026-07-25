#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${SERVER_IP:-172.31.230.113}"
EXPORT_PATH="${EXPORT_PATH:-/srv/dynamo-g4}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/dynamo-g4}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$MOUNT_POINT" == "/mnt/dynamo-g4" ]] || die "refusing unexpected mount point"

if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  source_name=$(findmnt -rn -o SOURCE "$MOUNT_POINT")
  [[ "$source_name" == "$SERVER_IP:$EXPORT_PATH" ]] || die "mount uses unexpected source $source_name"
  [[ -f "$MOUNT_POINT/.dynamo-phase2-ram-storage" ]] || die "remote RAM storage marker is absent"
  if fuser -m "$MOUNT_POINT" >/dev/null 2>&1; then
    die "$MOUNT_POINT still has open users"
  fi
  umount "$MOUNT_POINT"
fi

rmdir "$MOUNT_POINT" 2>/dev/null || true
echo "Phase 2 NFS/RDMA mount removed"
