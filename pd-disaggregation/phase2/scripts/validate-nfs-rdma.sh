#!/usr/bin/env bash
set -euo pipefail

MOUNT_POINT="${MOUNT_POINT:-/mnt/dynamo-g4}"
SERVER_IP=172.31.230.113
CLIENT_IP=172.31.230.111

die() { echo "FAIL: $*" >&2; exit 1; }

source_name=$(findmnt -rn -o SOURCE "$MOUNT_POINT" 2>/dev/null || true)
options=$(findmnt -rn -o OPTIONS "$MOUNT_POINT" 2>/dev/null || true)
[[ "$source_name" == "$SERVER_IP:/srv/dynamo-g4" ]] || die "unexpected source: $source_name"
grep -Eq '(^|,)vers=3(,|$)' <<<"$options" || die "mount is not NFSv3"
grep -qw 'proto=rdma' <<<"${options//,/ }" || die "mount is not NFSoRDMA"
grep -qw 'port=20049' <<<"${options//,/ }" || die "mount does not use RDMA port 20049"
[[ -f "$MOUNT_POINT/.dynamo-phase2-ram-storage" ]] || die "remote RAM marker absent"

route=$(ip route get "$SERVER_IP")
grep -Fq "src $CLIENT_IP" <<<"$route" || die "route does not use storage source $CLIENT_IP"

ssh -o BatchMode=yes -o ConnectTimeout=10 root@192.168.160.113 \
  "grep -Eq '(^|[[:space:]])rdma[[:space:]]+20049($|[[:space:]])' /proc/fs/nfsd/portlist && exportfs -v | grep -Fq '/srv/dynamo-g4'" \
  || die "node3 RDMA listener/export read-back failed"

findmnt -T "$MOUNT_POINT" -o TARGET,SOURCE,FSTYPE,OPTIONS
nfsstat -m "$MOUNT_POINT" 2>/dev/null || nfsstat -m
echo "$route"
echo "PASS: NFSv3 source=$SERVER_IP proto=rdma port=20049 over the CX-7 path; mountproto=tcp is mountd control only"
