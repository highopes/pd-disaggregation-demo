#!/usr/bin/env bash
set -euo pipefail

RAM_SIZE_GIB="${RAM_SIZE_GIB:-8}"
RAM_DEVICE="${RAM_DEVICE:-/dev/ram0}"
MOUNT_POINT="${MOUNT_POINT:-/srv/dynamo-g4}"
STATE_FILE="${STATE_FILE:-/var/lib/dynamo-phase2/ram-storage.env}"
MARKER_NAME=".dynamo-phase2-ram-storage"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

case "$RAM_SIZE_GIB" in
  4|6|8) ;;
  *) die "RAM_SIZE_GIB must be one of 4, 6, or 8" ;;
esac

[[ "$RAM_DEVICE" =~ ^/dev/ram[0-9]+$ ]] || die "RAM_DEVICE must be a brd /dev/ramN device"
[[ "$MOUNT_POINT" == "/srv/dynamo-g4" ]] || die "refusing unexpected mount point: $MOUNT_POINT"

size_kib=$((RAM_SIZE_GIB * 1024 * 1024))
size_bytes=$((size_kib * 1024))

# An idempotent systemd start must adopt an already validated Phase 2 RAM disk
# without charging its allocated pages against MemAvailable a second time.
if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  source_device=$(findmnt -rn -o SOURCE "$MOUNT_POINT")
  [[ "$source_device" == "$RAM_DEVICE" ]] || die "$MOUNT_POINT is mounted from unexpected source $source_device"
  [[ -f "$MOUNT_POINT/$MARKER_NAME" ]] || die "existing mount lacks the Phase 2 marker"
  actual_bytes=$(blockdev --getsize64 "$RAM_DEVICE")
  [[ "$actual_bytes" == "$size_bytes" ]] || die "existing RAM device size does not match request"
  echo "RAM storage already active: $RAM_DEVICE -> $MOUNT_POINT"
  exit 0
fi

mem_total_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
mem_available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
max_size_kib=$((mem_total_kib / 4))
reserve_kib=$((mem_total_kib * 35 / 100))
minimum_reserve_kib=$((16 * 1024 * 1024))
if (( reserve_kib < minimum_reserve_kib )); then
  reserve_kib=$minimum_reserve_kib
fi

(( size_kib <= max_size_kib )) || die "requested RAM disk exceeds 25% of physical memory"
(( mem_available_kib - size_kib >= reserve_kib )) || die "requested RAM disk would violate the memory reserve"

created_module=0
if ! grep -q '^brd ' /proc/modules; then
  modprobe brd rd_nr=1 rd_size="$size_kib"
  created_module=1
fi

udevadm settle 2>/dev/null || true
[[ -b "$RAM_DEVICE" ]] || die "$RAM_DEVICE was not created"
[[ -e "/sys/class/block/${RAM_DEVICE##*/}" ]] || die "$RAM_DEVICE is not registered as a block device"

actual_bytes=$(blockdev --getsize64 "$RAM_DEVICE")
[[ "$actual_bytes" == "$size_bytes" ]] || die "RAM device is $actual_bytes bytes, expected $size_bytes"

if findmnt -rn -S "$RAM_DEVICE" >/dev/null 2>&1; then
  die "$RAM_DEVICE is already mounted elsewhere"
fi

existing_signature=$(wipefs -n "$RAM_DEVICE" 2>/dev/null || true)
[[ -z "$existing_signature" ]] || die "$RAM_DEVICE has an existing filesystem signature; refusing mkfs"

mkfs.ext4 -F -L DYNAMO_G4_RAM "$RAM_DEVICE"
install -d -m 0755 "$MOUNT_POINT"
mount -t ext4 -o data=ordered,nosuid,nodev "$RAM_DEVICE" "$MOUNT_POINT"
install -m 0644 /dev/null "$MOUNT_POINT/$MARKER_NAME"

umask 077
install -d -m 0700 "${STATE_FILE%/*}"
{
  printf 'RAM_DEVICE=%q\n' "$RAM_DEVICE"
  printf 'MOUNT_POINT=%q\n' "$MOUNT_POINT"
  printf 'RAM_SIZE_GIB=%q\n' "$RAM_SIZE_GIB"
  printf 'CREATED_MODULE=%q\n' "$created_module"
} > "$STATE_FILE"

findmnt -T "$MOUNT_POINT" -o TARGET,SOURCE,FSTYPE,OPTIONS
blockdev --getsize64 "$RAM_DEVICE"
df -h "$MOUNT_POINT"
awk '/^MemTotal:|^MemAvailable:/ {print}' /proc/meminfo
