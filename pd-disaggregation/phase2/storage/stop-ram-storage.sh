#!/usr/bin/env bash
set -euo pipefail

RAM_DEVICE="${RAM_DEVICE:-/dev/ram0}"
MOUNT_POINT="${MOUNT_POINT:-/srv/dynamo-g4}"
STATE_FILE="${STATE_FILE:-/var/lib/dynamo-phase2/ram-storage.env}"
MARKER_NAME=".dynamo-phase2-ram-storage"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$RAM_DEVICE" =~ ^/dev/ram[0-9]+$ ]] || die "RAM_DEVICE must be a brd /dev/ramN device"
[[ "$MOUNT_POINT" == "/srv/dynamo-g4" ]] || die "refusing unexpected mount point: $MOUNT_POINT"

created_module=0
if [[ -r "$STATE_FILE" ]]; then
  # The state file is root-owned, mode 0600, and contains only shell-escaped values
  # written by start-ram-storage.sh.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  created_module="${CREATED_MODULE:-0}"
fi

if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  source_device=$(findmnt -rn -o SOURCE "$MOUNT_POINT")
  [[ "$source_device" == "$RAM_DEVICE" ]] || die "$MOUNT_POINT uses unexpected source $source_device"
  [[ -f "$MOUNT_POINT/$MARKER_NAME" ]] || die "mount lacks the Phase 2 marker"
  if exportfs -v 2>/dev/null | grep -Fq "$MOUNT_POINT"; then
    die "$MOUNT_POINT is still exported; roll back NFS first"
  fi
  if fuser -m "$MOUNT_POINT" >/dev/null 2>&1; then
    die "$MOUNT_POINT still has open users"
  fi
  umount "$MOUNT_POINT"
fi

if [[ "$created_module" == "1" ]] && grep -q '^brd ' /proc/modules; then
  if lsblk -nr -o NAME,MOUNTPOINT | awk '$1 ~ /^ram/ && $2 != "" {found=1} END {exit !found}'; then
    die "another RAM block device is mounted; refusing to unload brd"
  fi
  modprobe -r brd
fi

rm -f "$STATE_FILE"
rmdir "$MOUNT_POINT" 2>/dev/null || true
echo "Phase 2 RAM storage stopped"
