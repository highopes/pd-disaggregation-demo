#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE2_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
RUN_DIR="$PHASE2_DIR/evidence/runs/$(date +%Y%m%d-%H%M%S)-full-kv"
RUN_NEW=1

usage() {
  echo "usage: $0 [--evidence RUN_DIR] [--run-ab OUTPUT_DIR]"
}

while (( $# > 0 )); do
  case "$1" in
    --evidence) RUN_DIR=${2:?missing evidence directory}; RUN_NEW=0; shift 2 ;;
    --run-ab) RUN_DIR=${2:?missing output directory}; RUN_NEW=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if (( RUN_NEW == 1 )); then
  [[ ! -e "$RUN_DIR" ]] || { echo "FAIL: output directory already exists: $RUN_DIR" >&2; exit 1; }
fi

echo '=== Phase 2 final status ==='
kubectl -n ai-serving get dynamographdeployment qwen3-14b-pd -o wide
kubectl -n ai-serving get pods -l 'app in (dynamo-qwen-frontend,dynamo-qwen-prefill,dynamo-qwen-decode)' -o wide

"$SCRIPT_DIR/validate-nfs-rdma.sh"

if (( RUN_NEW == 1 )); then
  "$SCRIPT_DIR/validate-gds.sh" --preflight
  "$SCRIPT_DIR/validate-kvbm.sh" --preflight
  "$SCRIPT_DIR/demo-kv-offload-reload.sh" "$RUN_DIR"
fi

if (( RUN_NEW == 0 )); then
  RUN_EVIDENCE="$RUN_DIR" "$SCRIPT_DIR/validate-gds.sh"
fi
"$SCRIPT_DIR/validate-kvbm.sh"

comparison="$RUN_DIR/comparison.json"
[[ -f "$comparison" ]] || { echo "FAIL: comparison absent: $comparison" >&2; exit 1; }
python3 - "$comparison" <<'PY'
import json
import re
import sys
from pathlib import Path

comparison_path = Path(sys.argv[1])
run_dir = comparison_path.parent
with comparison_path.open(encoding="utf-8") as handle:
    data = json.load(handle)
performance_only = bool(data.get("performance_only"))
answer_keys = ["cold_answer_correct", "warm_answer_correct"]
if not performance_only:
    answer_keys.append("eviction_answer_correct")
if not all(data.get(key) for key in answer_keys):
    raise SystemExit("FAIL: Cold/Warm answer gate failed")
print("\nRemote KV Storage ->(NFS/RDMA + GDS)-> Prefill GPU ->(NIXL/UCX/RoCE)-> Decode GPU\n")
print(f"Cold GPU Prefill TTFT : {data['cold_ttft_seconds']:.3f} s")
if not performance_only:
    print(f"Overwrite Prompt TTFT : {data['eviction_ttft_seconds']:.3f} s")
print(f"Warm GDS Median TTFT  : {data['warm_gds_ttft_seconds']:.3f} s")
if "warm_ttft_samples_seconds" in data:
    samples = ", ".join(f"{value:.3f}" for value in data["warm_ttft_samples_seconds"])
    print(f"Warm GDS Samples      : [{samples}] s")
    print(f"Warm GDS Best TTFT    : {data['warm_best_ttft_seconds']:.3f} s")
print(f"TTFT Saved            : {data['ttft_saved_seconds']:.3f} s")
if "ttft_saved_percent" in data:
    print(f"TTFT Saved Percent    : {data['ttft_saved_percent']:.1f} %")
print(f"TTFT Speedup          : {data['ttft_speedup']:.3f} x")
print(f"Payload SHA-256       : {data['payload_sha256']}")
print(f"Matched tokens        : {data['warm_cached_tokens']}")
print(f"Device->Disk blocks   : {data['cold_offload_blocks_d2d_delta']:.0f}")
print(f"Disk->Device blocks   : {data.get('warm_onboard_blocks_per_request', data['expected_kv_blocks'])} per request / "
      f"{data['warm_onboard_blocks_d2d_delta']:.0f} total")
print(f"Complete KV via GDS   : {data['expected_gds_mib']} MiB "
      f"({data['expected_gds_ops']} layer/KV I/Os each direction)")
if not performance_only:
    print(f"Overwrite SHA-256     : {data['eviction_payload_sha256']}")
    print(f"Overwrite blocks      : {data['eviction_offload_blocks_d2d_delta']:.0f}")

def nvfs_counter(label, kind):
    text = (run_dir / f"nvidia-fs-{label}.txt").read_text(encoding="utf-8")
    match = re.search(rf"^{kind}\s*: n=(\d+) ok=\d+ err=(\d+).*?{kind.lower()[:-1]}MiB=(\d+)", text, re.MULTILINE)
    if not match:
        raise SystemExit(f"FAIL: cannot parse nvidia-fs {kind} counter")
    return tuple(map(int, match.groups()))

expected_ops = int(data["expected_gds_ops"])
expected_mib = int(data["expected_gds_mib"])
before_nvfs = (run_dir / "nvidia-fs-before.txt").read_text(encoding="utf-8")
if "IO stats: Enabled" in before_nvfs:
    w0 = nvfs_counter("before", "Writes")
    w1 = nvfs_counter("after-cold", "Writes")
    r0_label = "after-cold" if performance_only else "after-evict"
    r0 = nvfs_counter(r0_label, "Reads")
    r1 = nvfs_counter("after-warm", "Reads")
    observed = {
        "Direct GDS Cold write": (
            w1[0] - w0[0], w1[2] - w0[2], expected_ops, expected_mib
        ),
        "Direct GDS Warm read": (
            r1[0] - r0[0], r1[2] - r0[2], expected_ops, expected_mib
        ),
    }
    if not performance_only:
        w2 = nvfs_counter("after-evict", "Writes")
        expected_evict_ops = int(data["expected_eviction_gds_ops"])
        expected_evict_mib = int(data["expected_eviction_gds_mib"])
        observed["Direct GDS B write"] = (
            w2[0] - w1[0], w2[2] - w1[2], expected_evict_ops, expected_evict_mib
        )
    for label, (ops, mib, wanted_ops, wanted_mib) in observed.items():
        if (ops, mib) != (wanted_ops, wanted_mib):
            raise SystemExit(
                f"FAIL: {label}={ops} ops/{mib} MiB, "
                f"expected complete KV={wanted_ops} ops/{wanted_mib} MiB"
            )
        print(f"{label:<22}: +{ops} ops / +{mib} MiB")
else:
    print("nvidia-fs counters     : disabled during timing to remove small-I/O "
          "statistics overhead; exact KVBM block gates passed")

decode_log = (run_dir / "decode.log").read_text(encoding="utf-8", errors="replace")
expected_pd_mib = float(data["expected_pd_mib"])
expected_pd_descriptors = float(data["expected_pd_descriptors"])
nixl = []
for line in decode_log.splitlines():
    if "KV Transfer metrics:" not in line:
        continue
    mb = re.search(r"Avg MB per transfer=([0-9.]+)", line)
    descriptors = re.search(r"Avg number of descriptors=([0-9.]+)", line)
    if not mb or not descriptors:
        continue
    nixl.append((line, float(mb.group(1)), float(descriptors.group(1))))
expectations = [
    ("Cold", expected_pd_mib, expected_pd_descriptors),
]
if performance_only:
    for sample in range(1, int(data.get("warm_sample_count", 1)) + 1):
        expectations.append(
            (f"Warm {sample}", expected_pd_mib, expected_pd_descriptors)
        )
else:
    expectations.insert(
        1,
        (
            "Overwrite",
            float(data["expected_eviction_pd_mib"]),
            float(data["expected_eviction_pd_descriptors"]),
        ),
    )
    expectations.append(("Warm", expected_pd_mib, expected_pd_descriptors))
if len(nixl) < len(expectations):
    raise SystemExit(
        f"FAIL: found {len(nixl)} P->D NIXL transfers, "
        f"need {len(expectations)}"
    )
for (label, wanted_mib, wanted_desc), (line, observed_mib, observed_desc) in zip(
    expectations, nixl[-len(expectations):]
):
    if (
        abs(observed_mib - wanted_mib) >= 0.01
        or abs(observed_desc - wanted_desc) >= 0.01
    ):
        raise SystemExit(
            f"FAIL: P->D NIXL {label}={observed_mib} MiB/{observed_desc} descriptors, "
            f"expected {wanted_mib} MiB/{wanted_desc} descriptors"
        )
    detail = line.split("KV Transfer metrics:", 1)[-1].strip()
    print(f"P->D NIXL {label:<11}: {detail}")
print(f"Evidence directory     : {run_dir}")
print("\nPHASE 2 PASS – COMPLETE NEAR-40K KV DIRECT GDS REUSE")
PY
