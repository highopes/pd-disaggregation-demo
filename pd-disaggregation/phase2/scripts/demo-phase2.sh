#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE2_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_RUN="$PHASE2_DIR/evidence/runs/20260725-135015/near40-ab-post-persistence"
RUN_DIR="$DEFAULT_RUN"
RUN_NEW=0

usage() {
  echo "usage: $0 [--evidence RUN_DIR] [--run-ab OUTPUT_DIR]"
}

while (( $# > 0 )); do
  case "$1" in
    --evidence) RUN_DIR=${2:?missing evidence directory}; shift 2 ;;
    --run-ab) RUN_DIR=${2:?missing output directory}; RUN_NEW=1; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

echo '=== Phase 2 final status ==='
kubectl -n ai-serving get dynamographdeployment qwen3-14b-pd -o wide
kubectl -n ai-serving get pods -l 'app in (dynamo-qwen-frontend,dynamo-qwen-prefill,dynamo-qwen-decode)' -o wide

"$SCRIPT_DIR/validate-nfs-rdma.sh"
RUN_EVIDENCE="$RUN_DIR" "$SCRIPT_DIR/validate-gds.sh"
"$SCRIPT_DIR/validate-kvbm.sh"

if (( RUN_NEW == 1 )); then
  [[ ! -e "$RUN_DIR" ]] || { echo "FAIL: output directory already exists: $RUN_DIR" >&2; exit 1; }
  "$SCRIPT_DIR/demo-kv-offload-reload.sh" "$RUN_DIR"
fi

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
if not (data.get("cold_answer_correct") and data.get("warm_answer_correct")):
    raise SystemExit("FAIL: A/B answer gate failed")
print("\nRemote KV Storage ->(NFS/RDMA + GDS)-> Prefill GPU ->(NIXL/UCX/RoCE)-> Decode GPU\n")
print(f"Cold GPU Prefill TTFT : {data['cold_ttft_seconds']:.3f} s")
print(f"Warm GDS Reload TTFT  : {data['warm_gds_ttft_seconds']:.3f} s")
print(f"TTFT Saved            : {data['ttft_saved_seconds']:.3f} s")
print(f"TTFT Speedup          : {data['ttft_speedup']:.3f} x")
print(f"Payload SHA-256       : {data['payload_sha256']}")
print(f"Matched tokens        : {data['warm_cached_tokens']}")
print(f"Device->Disk blocks   : {data['cold_offload_blocks_d2d_delta']:.0f}")
print(f"Disk->Device blocks   : {data['warm_onboard_blocks_d2d_delta']:.0f}")

def nvfs_counter(label, kind):
    text = (run_dir / f"nvidia-fs-{label}.txt").read_text(encoding="utf-8")
    match = re.search(rf"^{kind}\s*: n=(\d+) ok=\d+ err=(\d+).*?{kind.lower()[:-1]}MiB=(\d+)", text, re.MULTILINE)
    if not match:
        raise SystemExit(f"FAIL: cannot parse nvidia-fs {kind} counter")
    return tuple(map(int, match.groups()))

w0 = nvfs_counter("before", "Writes")
w1 = nvfs_counter("after-cold", "Writes")
r0 = nvfs_counter("after-cold", "Reads")
r1 = nvfs_counter("after-warm", "Reads")
if w1[1] or r1[1]:
    raise SystemExit("FAIL: nvidia-fs direct I/O error counter is non-zero")
print(f"Direct GDS write      : +{w1[0] - w0[0]} ops / +{w1[2] - w0[2]} MiB")
print(f"Direct GDS read       : +{r1[0] - r0[0]} ops / +{r1[2] - r0[2]} MiB")

decode_log = (run_dir / "decode.log").read_text(encoding="utf-8", errors="replace")
nixl = [line for line in decode_log.splitlines() if "Avg MB per transfer=3130.0" in line]
for label, line in zip(("Cold", "Warm"), nixl[-2:]):
    detail = line.split("KV Transfer metrics:", 1)[-1].strip()
    print(f"P->D NIXL {label:<4}      : {detail}")
print(f"Evidence directory     : {run_dir}")
print("\nPHASE 2 PASS – DIRECT GDS")
PY
