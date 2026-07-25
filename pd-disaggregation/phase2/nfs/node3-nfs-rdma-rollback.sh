#!/usr/bin/env bash
set -euo pipefail

EXPORT_PATH="${EXPORT_PATH:-/srv/dynamo-g4}"
EXPORT_FILE="${EXPORT_FILE:-/etc/exports.d/dynamo-phase2.exports}"
STATE_FILE="${STATE_FILE:-/var/lib/dynamo-phase2/nfs.env}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$EXPORT_PATH" == "/srv/dynamo-g4" ]] || die "refusing unexpected export path"
[[ "$EXPORT_FILE" == "/etc/exports.d/dynamo-phase2.exports" ]] || die "refusing unexpected export file"

service_was_active=0
package_installed_before=1
if [[ -r "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  service_was_active="${SERVICE_WAS_ACTIVE:-0}"
  package_installed_before="${PACKAGE_INSTALLED_BEFORE:-1}"
fi

if command -v showmount >/dev/null 2>&1; then
  active_clients=$(showmount -a 127.0.0.1 2>/dev/null | awk -v path="$EXPORT_PATH" '$0 ~ path {print}' || true)
  [[ -z "$active_clients" ]] || die "NFS clients still reference $EXPORT_PATH"
fi

if [[ -e "$EXPORT_FILE" ]]; then
  grep -Fxq "$EXPORT_PATH 172.31.230.111(rw,async,insecure,no_root_squash,no_subtree_check)" "$EXPORT_FILE" \
    || die "$EXPORT_FILE has unexpected content"
  rm -f "$EXPORT_FILE"
  exportfs -ra
fi

if [[ "$service_was_active" == "0" ]]; then
  systemctl stop nfs-server
fi

rm -f "$STATE_FILE"
echo "Phase 2 NFS export and RDMA listener rolled back"
if [[ "$package_installed_before" == "0" ]]; then
  echo "nfs-kernel-server was installed by Phase 2 and intentionally left installed; remove it only after dependency review"
fi
