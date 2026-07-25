#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${SERVER_IP:-172.31.230.113}"
EXPORT_PATH="${EXPORT_PATH:-/srv/dynamo-g4}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/dynamo-g4}"
RDMA_PORT="${RDMA_PORT:-20049}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$SERVER_IP" == "172.31.230.113" ]] || die "refusing unexpected server address"
[[ "$EXPORT_PATH" == "/srv/dynamo-g4" ]] || die "refusing unexpected export path"
[[ "$MOUNT_POINT" == "/mnt/dynamo-g4" ]] || die "refusing unexpected mount point"
[[ "$RDMA_PORT" == "20049" ]] || die "refusing unexpected RDMA port"

if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  source_name=$(findmnt -rn -o SOURCE "$MOUNT_POINT")
  options=$(findmnt -rn -o OPTIONS "$MOUNT_POINT")
  [[ "$source_name" == "$SERVER_IP:$EXPORT_PATH" ]] || die "mount uses unexpected source $source_name"
  grep -qw 'proto=rdma' <<<"${options//,/ }" || die "existing mount is not RDMA"
  grep -Eq '(^|,)vers=3(,|$)' <<<"$options" || die "existing mount is not NFSv3"
  echo "NFS/RDMA mount already active"
  exit 0
fi

modprobe rpcrdma
install -d -m 0755 "$MOUNT_POINT"
mount -v -t nfs -o vers=3,proto=rdma,port="$RDMA_PORT",hard,timeo=600,retrans=2 \
  "$SERVER_IP:$EXPORT_PATH" "$MOUNT_POINT"

options=$(findmnt -rn -o OPTIONS "$MOUNT_POINT")
grep -qw 'proto=rdma' <<<"${options//,/ }" || die "mounted transport is not RDMA"
grep -Eq '(^|,)vers=3(,|$)' <<<"$options" || die "mounted protocol is not NFSv3"
[[ -f "$MOUNT_POINT/.dynamo-phase2-ram-storage" ]] || die "remote RAM storage marker is absent"

findmnt -T "$MOUNT_POINT" -o TARGET,SOURCE,FSTYPE,OPTIONS
nfsstat -m "$MOUNT_POINT" 2>/dev/null || nfsstat -m
ip route get "$SERVER_IP"
