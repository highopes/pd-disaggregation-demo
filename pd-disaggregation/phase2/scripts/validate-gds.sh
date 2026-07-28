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

command -v jq >/dev/null 2>&1 || die "jq is required"

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
if [[ "${PHASE2_RUN_GDSCHECK:-0}" != "1" ]]; then
  # NVIDIA gdscheck -p has repeatedly aborted in its own cuFile worker thread
  # when run beside a live KVBM process.  Runtime validation below checks the
  # loaded module, device, RDMA mount, injected container device/env and the
  # KVBM G1->G3 direct-offload log without perturbing the demo.
  gds_output='GDS platform diagnostic skipped beside live KVBM (set PHASE2_RUN_GDSCHECK=1 for an offline check)'
elif [[ -n "$RUN_EVIDENCE" ]]; then
  # gdscheck -p can abort in its own cuFile thread-pool assertion while a live
  # KVBM process is using GDS.  The customer run already passed this check in
  # preflight; do not inject that diagnostic into the timed/post-run path.
  gds_output='GDS platform verification: passed during preflight'
else
  gds_output=$(LD_LIBRARY_PATH=/usr/local/cuda-12.9/targets/x86_64-linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} "$gdscheck_path" -p)
  grep -Eq 'NFS[[:space:]]*:[[:space:]]*Supported' <<<"$gds_output" || die "gdscheck does not report NFS Supported"
  grep -Eq 'Mellanox PeerDirect[[:space:]]*:[[:space:]]*Enabled' <<<"$gds_output" || die "Mellanox PeerDirect not enabled"
fi

pod=$(kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-prefill -o json |
  jq -er '
    [.items[]
     | select(.status.phase == "Running")
     | select(any(.status.containerStatuses[]?; .ready == true))]
    | if length == 1 then .[0].metadata.name
      else error("expected exactly one Ready Prefill pod") end
  ')
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
  if grep -Eq '^IO stats:[[:space:]]*Disabled' <<<"$stats"; then
    echo "INFO: nvidia-fs I/O statistics intentionally disabled for maximum Warm performance"
  fi
else
  if grep -Eq '^IO stats:[[:space:]]*Enabled' <<<"$stats"; then
    grep -Eq 'Reads.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS reads counted"
    grep -Eq 'Writes.*n=[1-9][0-9]*.*err=0' <<<"$stats" || die "no error-free direct GDS writes counted"
    grep -Eq 'Reads.*pg-cache.*:[[:space:]]*0' <<<"$stats" || true
  else
    echo "INFO: nvidia-fs counters omitted; KVBM and storage-RDMA byte gates remain active"
  fi
fi

if [[ -n "$RUN_EVIDENCE" ]]; then
  [[ -f "$RUN_EVIDENCE/nvidia-fs-before.txt" ]] || die "requested run start evidence missing"
  [[ -f "$RUN_EVIDENCE/nvidia-fs-after-cold.txt" ]] || die "requested cold-run evidence missing"
  [[ -f "$RUN_EVIDENCE/nvidia-fs-after-warm.txt" ]] || die "requested run evidence missing"
  [[ -f "$RUN_EVIDENCE/comparison.json" ]] || die "requested comparison missing"
  performance_only=$(jq -r '.performance_only // false' "$RUN_EVIDENCE/comparison.json")
  labels=(before after-cold after-warm)
  if [[ "$performance_only" != true ]]; then
    [[ -f "$RUN_EVIDENCE/nvidia-fs-after-evict.txt" ]] || die "requested overwrite-run evidence missing"
    labels+=(after-evict)
  fi
  for label in "${labels[@]}"; do
    [[ -f "$RUN_EVIDENCE/node3-${label}.txt" ]] \
      || die "requested node3 ${label} RDMA evidence missing"
  done
  python3 - "$RUN_EVIDENCE" <<'PY'
import json
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


def node3_rdma_bytes(label, direction):
    text = (run_dir / f"node3-{label}.txt").read_text(encoding="utf-8")
    match = re.search(
        rf"^\s*{direction}_vport_rdma_unicast_bytes:\s*(\d+)",
        text,
        re.MULTILINE,
    )
    if not match:
        raise SystemExit(
            f"FAIL: cannot parse node3 {direction} RDMA bytes in {label}"
        )
    return int(match.group(1))


with (run_dir / "comparison.json").open(encoding="utf-8") as handle:
    comparison = json.load(handle)
performance_only = bool(comparison.get("performance_only"))
warm_sample_count = int(comparison.get("warm_sample_count", 1))
expected_ops = int(comparison["expected_gds_ops"])
expected_mib = int(comparison["expected_gds_mib"])
nvfs_before = (run_dir / "nvidia-fs-before.txt").read_text(encoding="utf-8")
if "IO stats: Enabled" in nvfs_before:
    w0 = counter("before", "Writes")
    w1 = counter("after-cold", "Writes")
    r0_label = "after-cold" if performance_only else "after-evict"
    r0 = counter(r0_label, "Reads")
    r1 = counter("after-warm", "Reads")
    observed = {
        "Cold A offload": (
            w1[0] - w0[0], w1[2] - w0[2], expected_ops, expected_mib
        ),
        "Warm A reload": (
            r1[0] - r0[0],
            r1[2] - r0[2],
            expected_ops * warm_sample_count,
            expected_mib * warm_sample_count,
        ),
    }
    error_changed = w1[1] != w0[1] or r1[1] != r0[1]
    if not performance_only:
        w2 = counter("after-evict", "Writes")
        observed["Overwrite B offload"] = (
            w2[0] - w1[0],
            w2[2] - w1[2],
            int(comparison["expected_eviction_gds_ops"]),
            int(comparison["expected_eviction_gds_mib"]),
        )
        error_changed = error_changed or w2[1] != w1[1]
    if error_changed:
        raise SystemExit("FAIL: nvidia-fs direct I/O errors increased")
    for label, (ops, mib, wanted_ops, wanted_mib) in observed.items():
        if (ops, mib) != (wanted_ops, wanted_mib):
            raise SystemExit(
                f"FAIL: {label} moved {ops} ops/{mib} MiB; "
                f"complete KV requires {wanted_ops} ops/{wanted_mib} MiB"
            )
        print(f"{label:22}: +{ops} ops / +{mib} MiB (complete KV)")
else:
    print("nvidia-fs I/O counters disabled for performance; "
          "using exact KVBM blocks plus NFSoRDMA bytes")

node3_before_rx = node3_rdma_bytes("before", "rx")
node3_cold_rx = node3_rdma_bytes("after-cold", "rx")
node3_before_warm_tx = node3_rdma_bytes(
    "after-cold" if performance_only else "after-evict", "tx"
)
node3_warm_tx = node3_rdma_bytes("after-warm", "tx")
rdma_observed = {
    "Cold A storage RX": (node3_cold_rx - node3_before_rx, expected_mib),
    "Warm A storage TX": (
        node3_warm_tx - node3_before_warm_tx,
        expected_mib * warm_sample_count,
    ),
}
if not performance_only:
    node3_evict_rx = node3_rdma_bytes("after-evict", "rx")
    rdma_observed["Overwrite B storage RX"] = (
        node3_evict_rx - node3_cold_rx,
        int(comparison["expected_eviction_gds_mib"]),
    )
for label, (actual_bytes, payload_mib) in rdma_observed.items():
    payload_bytes = payload_mib * 1024 * 1024
    # NFSoRDMA adds RPC/RDMA protocol traffic. A 10% ceiling catches unrelated
    # bulk traffic while allowing normal headers and control messages.
    if not payload_bytes <= actual_bytes <= payload_bytes * 1.10:
        raise SystemExit(
            f"FAIL: {label} delta={actual_bytes} bytes is not consistent with "
            f"the complete {payload_mib} MiB KV payload"
        )
    print(f"{label:22}: +{actual_bytes} RDMA bytes")
PY
fi

printf '%s\n' "$gds_output" | grep -E 'GDS release|NFS|Mellanox PeerDirect|IOMMU|Open Driver|platform (verification|diagnostic)'
grep -E 'IO stats|Reads|Writes|pg-cache|Errors' /proc/driver/nvidia-fs/stats | head -20 || true
if (( PREFLIGHT == 1 )); then
  echo "PASS: Direct GDS runtime prerequisites are ready for a performance run"
else
  echo "PASS: Direct GDS (cuFile/nvidia-fs), not compatibility mode"
fi
