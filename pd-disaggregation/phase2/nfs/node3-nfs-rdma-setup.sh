#!/usr/bin/env bash
set -euo pipefail

EXPORT_PATH="${EXPORT_PATH:-/srv/dynamo-g4}"
CLIENT_IP="${CLIENT_IP:-172.31.230.111}"
SERVER_IP="${SERVER_IP:-172.31.230.113}"
RDMA_PORT="${RDMA_PORT:-20049}"
EXPORT_FILE="${EXPORT_FILE:-/etc/exports.d/dynamo-phase2.exports}"
STATE_FILE="${STATE_FILE:-/var/lib/dynamo-phase2/nfs.env}"
INSTALL_PACKAGE="${INSTALL_PACKAGE:-0}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$EXPORT_PATH" == "/srv/dynamo-g4" ]] || die "refusing unexpected export path"
[[ "$EXPORT_FILE" == "/etc/exports.d/dynamo-phase2.exports" ]] || die "refusing unexpected export file"
[[ "$CLIENT_IP" == "172.31.230.111" ]] || die "refusing unexpected client address"
[[ "$SERVER_IP" == "172.31.230.113" ]] || die "refusing unexpected server address"
[[ "$RDMA_PORT" == "20049" ]] || die "refusing unexpected RDMA port"
ip -4 addr show | grep -Fq "$SERVER_IP/" || die "$SERVER_IP is not configured on this host"
[[ -f "$EXPORT_PATH/.dynamo-phase2-ram-storage" ]] || die "RAM storage marker is absent"

if [[ -r "$STATE_FILE" ]]; then
  # Preserve the original pre-Phase-2 state during an idempotent service start.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  package_installed_before="${PACKAGE_INSTALLED_BEFORE:-1}"
  service_was_active="${SERVICE_WAS_ACTIVE:-0}"
else
  package_installed_before="${PACKAGE_INSTALLED_BEFORE_OVERRIDE:-1}"
  service_was_active="${SERVICE_WAS_ACTIVE_OVERRIDE:-0}"
  if [[ -z "${PACKAGE_INSTALLED_BEFORE_OVERRIDE+x}" ]]; then
    dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -Fq 'install ok installed' \
      || package_installed_before=0
  fi
  if [[ -z "${SERVICE_WAS_ACTIVE_OVERRIDE+x}" ]]; then
    if systemctl list-unit-files nfs-server.service --no-legend 2>/dev/null | grep -q '^nfs-server.service'; then
      systemctl is-active --quiet nfs-server && service_was_active=1
    fi
  fi
fi

if [[ "$package_installed_before" == "0" ]] \
  && ! dpkg-query -W -f='${Status}' nfs-kernel-server 2>/dev/null | grep -Fq 'install ok installed'; then
  [[ "$INSTALL_PACKAGE" == "1" ]] || die "nfs-kernel-server is missing; rerun with INSTALL_PACKAGE=1 after reviewing apt-get -s"
  simulation=$(apt-get -s install nfs-kernel-server)
  printf '%s\n' "$simulation"
  unexpected=$(printf '%s\n' "$simulation" | awk '/^Inst / {print $2}' | grep -v '^nfs-kernel-server$' || true)
  [[ -z "$unexpected" ]] || die "dry-run would install or replace unexpected packages: $unexpected"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nfs-kernel-server
fi

install -d -m 0755 /etc/exports.d
if [[ -e "$EXPORT_FILE" ]]; then
  expected="$EXPORT_PATH $CLIENT_IP(rw,async,insecure,no_root_squash,no_subtree_check)"
  [[ "$(tr -d '\r' < "$EXPORT_FILE")" == "$expected" ]] || die "$EXPORT_FILE already exists with unexpected content"
else
  printf '%s %s(rw,async,insecure,no_root_squash,no_subtree_check)\n' "$EXPORT_PATH" "$CLIENT_IP" > "$EXPORT_FILE"
fi

modprobe rpcrdma
systemctl start nfs-server
exportfs -ra

if ! grep -Eq "(^|[[:space:]])rdma[[:space:]]+$RDMA_PORT($|[[:space:]])" /proc/fs/nfsd/portlist; then
  printf 'rdma %s\n' "$RDMA_PORT" > /proc/fs/nfsd/portlist
fi

umask 077
install -d -m 0700 "${STATE_FILE%/*}"
{
  printf 'PACKAGE_INSTALLED_BEFORE=%q\n' "$package_installed_before"
  printf 'SERVICE_WAS_ACTIVE=%q\n' "$service_was_active"
} > "$STATE_FILE"

exportfs -v
cat /proc/fs/nfsd/portlist
ss -lntup | grep -E "(:2049|:$RDMA_PORT)" || true
