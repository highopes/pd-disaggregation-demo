#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-serving}"
RUN_EVIDENCE="${RUN_EVIDENCE:-}"
PREFLIGHT=0

die() { echo "FAIL: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 [--preflight]"
}

while (( $# > 0 )); do
  case "$1" in
    --preflight) PREFLIGHT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if (( PREFLIGHT == 1 )) && [[ -n "$RUN_EVIDENCE" ]]; then
  die "--preflight cannot be combined with RUN_EVIDENCE"
fi

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
if (( PREFLIGHT == 1 )); then
  grep -Eq '^IO stats:[[:space:]]*Enabled' <<<"$stats" \
    || die "nvidia-fs I/O statistics are disabled; enable rw_stats before starting A/B"
else
  grep -Eq 'Reads.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS reads counted"
  grep -Eq 'Writes.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS writes counted"
  grep -Eq 'Reads.*pg-cache.*:[[:space:]]*0' <<<"$stats" || true
fi

if [[ -n "$RUN_EVIDENCE" ]]; then
  [[ -f "$RUN_EVIDENCE/nvidia-fs-before.txt" ]] || die "requested run start evidence missing"
  [[ -f "$RUN_EVIDENCE/nvidia-fs-after-cold.txt" ]] || die "requested cold-run evidence missing"
  [[ -f "$RUN_EVIDENCE/nvidia-fs-after-warm.txt" ]] || die "requested run evidence missing"
  [[ -f "$RUN_EVIDENCE/comparison.json" ]] || die "requested A/B comparison missing"
  python3 - "$RUN_EVIDENCE" <<'PY'
import re
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])


def counter(label, kind):
    text = (run_dir / f"nvidia-fs-{label}.txt").read_text(encoding="utf-8")
    match = re.search(
        rf"^{kind}\s*: n=(\d+) ok=\d+ err=(\d+).*?{kind.lower()[:-1]}MiB=(\d+)",
        text,
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(f"FAIL: cannot parse {kind} in nvidia-fs-{label}.txt")
    return tuple(map(int, match.groups()))


w0 = counter("before", "Writes")
w1 = counter("after-cold", "Writes")
r0 = counter("after-cold", "Reads")
r1 = counter("after-warm", "Reads")
write_ops, write_mib = w1[0] - w0[0], w1[2] - w0[2]
read_ops, read_mib = r1[0] - r0[0], r1[2] - r0[2]
if min(write_ops, write_mib, read_ops, read_mib) <= 0:
    raise SystemExit("FAIL: requested A/B lacks positive Direct GDS write/read deltas")
if w1[1] != w0[1] or r1[1] != r0[1]:
    raise SystemExit("FAIL: nvidia-fs direct I/O errors increased during requested A/B")
print(f"A/B Direct GDS write delta: +{write_ops} ops / +{write_mib} MiB")
print(f"A/B Direct GDS read delta : +{read_ops} ops / +{read_mib} MiB")
PY
fi

printf '%s\n' "$gds_output" | grep -E 'GDS release|NFS|Mellanox PeerDirect|IOMMU|Open Driver|platform verification'
grep -E 'Reads|Writes|pg-cache|Errors' /proc/driver/nvidia-fs/stats | head -20
if (( PREFLIGHT == 1 )); then
  echo "PASS: Direct GDS prerequisites and evidence counters are ready for a new A/B"
else
  echo "PASS: Direct GDS (cuFile/nvidia-fs), not compatibility mode"
fi
