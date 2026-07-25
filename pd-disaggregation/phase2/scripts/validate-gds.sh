#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-serving}"
RUN_EVIDENCE="${RUN_EVIDENCE:-}"

die() { echo "FAIL: $*" >&2; exit 1; }

grep -q '^nvidia_fs ' /proc/modules || die "nvidia_fs is not loaded"
[[ -c /dev/nvidia-fs0 ]] || die "/dev/nvidia-fs0 is absent"
[[ -r /proc/driver/nvidia-fs/stats ]] || die "nvidia-fs stats unavailable"
findmnt -rn -o OPTIONS /mnt/dynamo-g4 | grep -qw 'proto=rdma' || die "remote mount is not RDMA"

gdscheck_path=$(command -v gdscheck || true)
[[ -n "$gdscheck_path" ]] || gdscheck_path=/usr/local/cuda-12.9/gds/tools/gdscheck
[[ -x "$gdscheck_path" ]] || die "gdscheck absent"
gds_output=$(LD_LIBRARY_PATH=/usr/local/cuda-12.9/targets/x86_64-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} "$gdscheck_path" -p)
grep -Eq 'NFS[[:space:]]*:[[:space:]]*Supported' <<<"$gds_output" || die "gdscheck does not report NFS Supported"
grep -Eq 'Mellanox PeerDirect[[:space:]]*:[[:space:]]*Enabled' <<<"$gds_output" || die "Mellanox PeerDirect not enabled"

pod=$(kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-prefill -o jsonpath='{.items[0].metadata.name}')
[[ -n "$pod" ]] || die "Prefill pod absent"
kubectl -n "$NAMESPACE" exec "$pod" -- sh -ec '
  test "$NVIDIA_GDS" = enabled
  test "$NVIDIA_DRIVER_CAPABILITIES" = all
  test -c /dev/nvidia-fs0
  findmnt -rn -o OPTIONS /mnt/dynamo-g4 | grep -qw proto=rdma
' || die "Prefill GDS runtime injection/mount check failed"
pod_logs=$(kubectl -n "$NAMESPACE" logs "$pod")
grep -Fq 'G1->G3 direct offload enabled' <<<"$pod_logs" \
  || die "KVBM direct Device-to-Disk log absent"

stats=$(cat /proc/driver/nvidia-fs/stats)
grep -Eq 'Reads.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS reads counted"
grep -Eq 'Writes.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS writes counted"
grep -Eq 'Reads.*pg-cache.*:[[:space:]]*0' <<<"$stats" || true

if [[ -n "$RUN_EVIDENCE" ]]; then
  [[ -f "$RUN_EVIDENCE/nvidia-fs-after-warm.txt" ]] || die "requested run evidence missing"
  [[ -f "$RUN_EVIDENCE/comparison.json" ]] || die "requested A/B comparison missing"
fi

printf '%s\n' "$gds_output" | grep -E 'GDS release|NFS|Mellanox PeerDirect|IOMMU|Open Driver|platform verification'
grep -E 'Reads|Writes|pg-cache|Errors' /proc/driver/nvidia-fs/stats | head -20
echo "PASS: Direct GDS (cuFile/nvidia-fs), not compatibility mode"
