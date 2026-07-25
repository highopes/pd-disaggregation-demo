#!/usr/bin/env bash
set -euo pipefail

MODULE_VERSION="${MODULE_VERSION:-3.4}"
DKMS_SOURCE="/usr/src/mlnx-nfsrdma-$MODULE_VERSION"
MARKER_FILE="$DKMS_SOURCE/.dynamo-phase2-mlnx-nfsrdma"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$MODULE_VERSION" == "3.4" ]] || die "unexpected mlnx-nfsrdma version"

if grep -q '^rpcrdma ' /proc/modules; then
  use_count=$(awk '$1 == "rpcrdma" {print $3}' /proc/modules)
  [[ "$use_count" == "0" ]] || die "rpcrdma is still in use"
  modprobe -r xprtrdma 2>/dev/null || true
  modprobe -r svcrdma 2>/dev/null || true
  modprobe -r rpcrdma
fi

if dkms status -m mlnx-nfsrdma -v "$MODULE_VERSION" 2>/dev/null | grep -q .; then
  dkms remove -m mlnx-nfsrdma -v "$MODULE_VERSION" --all
fi

if [[ -e "$DKMS_SOURCE" ]]; then
  [[ -f "$MARKER_FILE" ]] || die "$DKMS_SOURCE lacks the Phase 2 marker"
  rm -rf --one-file-system "$DKMS_SOURCE"
fi

depmod -a
echo "Phase 2 MLNX_OFED NFS/RDMA DKMS module removed"
