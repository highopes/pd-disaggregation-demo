#!/usr/bin/env bash
set -euo pipefail

OFED_VERSION="${OFED_VERSION:-24.10.OFED.24.10.2.1.8.1}"
MODULE_VERSION="${MODULE_VERSION:-3.4}"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
PATCH_FILE="${PATCH_FILE:-/tmp/mlnx-nfsrdma-3.4-linux-6.11.patch}"
BUILD_ONLY="${BUILD_ONLY:-0}"
SOURCE_ROOT="/usr/src/mlnx-ofed-kernel-$OFED_VERSION/net/sunrpc/xprtrdma"
DKMS_SOURCE="/usr/src/mlnx-nfsrdma-$MODULE_VERSION"
OFA_ROOT="/usr/src/ofa_kernel/$(uname -m)/$KERNEL_VERSION"
MARKER_FILE="$DKMS_SOURCE/.dynamo-phase2-mlnx-nfsrdma"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$KERNEL_VERSION" == "6.11.0-26-generic" ]] || die "this reviewed patch is limited to kernel 6.11.0-26-generic"
[[ "$OFED_VERSION" == "24.10.OFED.24.10.2.1.8.1" ]] || die "unexpected MLNX_OFED source version"
[[ "$MODULE_VERSION" == "3.4" ]] || die "unexpected mlnx-nfsrdma version"
[[ -d "$SOURCE_ROOT" ]] || die "MLNX_OFED NFS/RDMA source is absent"
[[ -r "$OFA_ROOT/Module.symvers" ]] || die "MLNX_OFED Module.symvers is absent"
[[ -r "$OFA_ROOT/configure.mk.kernel" ]] || die "MLNX_OFED kernel configuration is absent"
grep -Fxq 'CONFIG_GPU_DIRECT_STORAGE=y' "$OFA_ROOT/configure.mk.kernel" \
  || die "MLNX_OFED was not built with GPUDirect Storage hooks"
[[ -r "$PATCH_FILE" ]] || die "reviewed Linux 6.11 compatibility patch is absent"

if grep -q '^rpcrdma ' /proc/modules; then
  module_path=$(modinfo -F filename rpcrdma 2>/dev/null || true)
  if [[ "$module_path" == "/lib/modules/$KERNEL_VERSION/updates/dkms/rpcrdma.ko"* ]]; then
    echo "MLNX_OFED NFS/RDMA module already loaded: $module_path"
    exit 0
  fi
  die "a non-Phase-2 rpcrdma module is already loaded"
fi

if [[ ! -e "$DKMS_SOURCE" ]]; then
  stage_dir=$(mktemp -d /tmp/dynamo-phase2-mlnx-nfsrdma.XXXXXX)
  cp -a "$SOURCE_ROOT/." "$stage_dir/"
  cp "$stage_dir/_makefile_" "$stage_dir/makefile"
  cp "$stage_dir/mlnx-nfsrdma_spec_" "$stage_dir/mlnx-nfsrdma.spec"
  patch --directory="$stage_dir" -p1 --forward < "$PATCH_FILE"
  install -m 0644 /dev/null "$stage_dir/.dynamo-phase2-mlnx-nfsrdma"

  make -C "$stage_dir" clean KVER="$KERNEL_VERSION" K_BUILD="/lib/modules/$KERNEL_VERSION/build"
  make -C "$stage_dir" -j"$(nproc)" KVER="$KERNEL_VERSION" K_BUILD="/lib/modules/$KERNEL_VERSION/build"
  for module in rpcrdma.ko svcrdma.ko xprtrdma.ko; do
    [[ -r "$stage_dir/$module" ]] || die "isolated build did not produce $module"
    [[ "$(modinfo -F vermagic "$stage_dir/$module")" == "$KERNEL_VERSION "* ]] \
      || die "$module vermagic does not match $KERNEL_VERSION"
  done
  nm_output=$(nm "$stage_dir/rpcrdma.ko")
  grep -q 'nvfs_' <<<"$nm_output" || die "rpcrdma lacks GPUDirect Storage hooks"
  if [[ "$BUILD_ONLY" == "1" ]]; then
    echo "Isolated MLNX_OFED NFS/RDMA build passed: $stage_dir"
    for module in rpcrdma.ko svcrdma.ko xprtrdma.ko; do
      sha256sum "$stage_dir/$module"
      modinfo "$stage_dir/$module" | grep -E '^(description|depends|vermagic):'
    done
    exit 0
  fi
  make -C "$stage_dir" clean KVER="$KERNEL_VERSION" K_BUILD="/lib/modules/$KERNEL_VERSION/build"
  mv "$stage_dir" "$DKMS_SOURCE"
else
  [[ -f "$MARKER_FILE" ]] || die "$DKMS_SOURCE exists without the Phase 2 marker"
  grep -Fq 'const struct ctl_table *table' "$DKMS_SOURCE/svc_rdma.c" \
    || die "existing DKMS source lacks the reviewed Linux 6.11 patch"
fi

if ! dkms status -m mlnx-nfsrdma -v "$MODULE_VERSION" 2>/dev/null | grep -q .; then
  dkms add -m mlnx-nfsrdma -v "$MODULE_VERSION"
fi
dkms build -m mlnx-nfsrdma -v "$MODULE_VERSION" -k "$KERNEL_VERSION" --force
dkms install -m mlnx-nfsrdma -v "$MODULE_VERSION" -k "$KERNEL_VERSION" --force
depmod -a "$KERNEL_VERSION"
modprobe rpcrdma

module_path=$(modinfo -F filename rpcrdma)
[[ "$module_path" == "/lib/modules/$KERNEL_VERSION/updates/dkms/rpcrdma.ko"* ]] \
  || die "loaded module path is not the Phase 2 DKMS path: $module_path"

echo "MLNX_OFED NFS/RDMA installed: $module_path"
dkms status -m mlnx-nfsrdma -v "$MODULE_VERSION"
lsmod | grep '^rpcrdma'
for module in rpcrdma svcrdma xprtrdma; do
  modinfo "$module" | grep -E '^(filename|description|depends|vermagic):'
done
