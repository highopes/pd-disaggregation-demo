#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE2_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$PHASE2_DIR/../.." && pwd)
COMPARE="$SCRIPT_DIR/compare-prefill-vs-gds.py"
NAMESPACE="${NAMESPACE:-ai-serving}"
OUTPUT_DIR="${1:-$PHASE2_DIR/evidence/runs/$(date +%Y%m%d-%H%M%S)-ab}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -x "$COMPARE" ]] || die "comparison script is not executable: $COMPARE"
[[ ! -e "$OUTPUT_DIR" ]] || die "refusing non-new output directory: $OUTPUT_DIR"

prefill_pod() {
  kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-prefill \
    -o jsonpath='{.items[0].metadata.name}'
}

metric_value() {
  local file=$1
  local metric=$2
  awk -v metric="$metric" '$1 == metric {print $2; found=1} END {if (!found) exit 1}' "$file"
}

live_metric_value() {
  local metric=$1
  kubectl -n "$NAMESPACE" exec "$(prefill_pod)" -- \
    curl -fsS http://127.0.0.1:6880/metrics |
    awk -v metric="$metric" '$1 == metric {print $2; found=1} END {if (!found) exit 1}'
}

wait_for_counter_increase() {
  local metric=$1
  local baseline=$2
  local timeout_seconds=$3
  local start=$SECONDS
  local current
  while (( SECONDS - start < timeout_seconds )); do
    current=$(live_metric_value "$metric")
    if awk -v current="$current" -v baseline="$baseline" 'BEGIN {exit !(current > baseline)}'; then
      printf '%s increased: baseline=%s current=%s\n' "$metric" "$baseline" "$current"
      return 0
    fi
    sleep 2
  done
  die "timed out waiting for $metric to increase above $baseline"
}

capture_host_counters() {
  local label=$1
  local node1_iface
  node1_iface=$(rdma link show | sed -n 's/.* netdev \([^ ]*\).*/\1/p' | head -1)
  [[ -n "$node1_iface" ]] || die "cannot resolve node1 RDMA netdev"
  {
    date --iso-8601=seconds
    printf 'rdma_netdev=%s\n' "$node1_iface"
    ethtool -S "$node1_iface" |
      grep -Ei 'vport_rdma|prio3_(bytes|packets|discards)|crc_errors|errors_phy|discards_phy'
    rdma statistic show link mlx5_0/1
  } > "$OUTPUT_DIR/node1-${label}.txt"
  ssh -o BatchMode=yes root@192.168.160.112 \
    "phase2_iface=\$(rdma link show | sed -n 's/.* netdev \\([^ ]*\\).*/\\1/p' | head -1); date --iso-8601=seconds; printf 'rdma_netdev=%s\\n' \"\$phase2_iface\"; ethtool -S \"\$phase2_iface\" | grep -Ei 'vport_rdma|prio3_(bytes|packets|discards)|crc_errors|errors_phy|discards_phy'; rdma statistic show link mlx5_0/1" \
    > "$OUTPUT_DIR/node2-${label}.txt"
  ssh -o BatchMode=yes root@192.168.160.113 \
    "phase2_iface=\$(rdma link show | sed -n 's/.* netdev \\([^ ]*\\).*/\\1/p' | head -1); date --iso-8601=seconds; printf 'rdma_netdev=%s\\n' \"\$phase2_iface\"; ethtool -S \"\$phase2_iface\" | grep -Ei 'vport_rdma|prio3_(bytes|packets|discards)|crc_errors|errors_phy|discards_phy'; rdma statistic show link mlx5_0/1; free -k; df -h /srv/dynamo-g4" \
    > "$OUTPUT_DIR/node3-${label}.txt"
}

capture_snapshot() {
  local label=$1
  local pod
  pod=$(prefill_pod)
  kubectl -n "$NAMESPACE" exec "$pod" -- \
    curl -fsS http://127.0.0.1:6880/metrics > "$OUTPUT_DIR/metrics-${label}.txt"
  cat /proc/driver/nvidia-fs/stats > "$OUTPUT_DIR/nvidia-fs-${label}.txt"
  capture_host_counters "$label"
  kubectl -n "$NAMESPACE" get dynamographdeployment qwen3-14b-pd -o wide \
    > "$OUTPUT_DIR/dgd-${label}.txt"
  kubectl -n "$NAMESPACE" get pods \
    -l 'app in (dynamo-qwen-frontend,dynamo-qwen-prefill,dynamo-qwen-decode)' \
    -o wide >> "$OUTPUT_DIR/dgd-${label}.txt"
  if [[ -n "${NEXUS_USERNAME:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
    python3 "$REPO_ROOT/pd-disaggregation/scripts/nexus_read.py" \
      'show interface ethernet1/1/1 counters' \
      'show interface ethernet1/1/2 counters' \
      'show interface ethernet1/2/1 counters' \
      'show queuing interface ethernet1/1/1' \
      'show queuing interface ethernet1/1/2' \
      'show queuing interface ethernet1/2/1' \
      'show interface counters errors' \
      > "$OUTPUT_DIR/nexus-${label}.txt"
  else
    printf '%s\n' 'Nexus snapshot skipped: credentials absent from environment' \
      > "$OUTPUT_DIR/nexus-${label}.txt"
  fi
}

echo "=== Preparing unique near-40K A/B payload: $OUTPUT_DIR ==="
python3 "$COMPARE" prepare --output-dir "$OUTPUT_DIR" \
  > "$OUTPUT_DIR.prepare.console.txt"

echo '=== Capturing before snapshot ==='
capture_snapshot before
cold_offload_before=$(metric_value "$OUTPUT_DIR/metrics-before.txt" kvbm_offload_blocks_d2d)

echo '=== Sending cold request and waiting for Device-to-Disk offload ==='
set +e
python3 "$COMPARE" request --output-dir "$OUTPUT_DIR" --label cold \
  > "$OUTPUT_DIR/cold.console.txt" 2>&1
cold_rc=$?
set -e
if (( cold_rc != 0 )); then
  cat "$OUTPUT_DIR/cold.console.txt" >&2
  die "cold request failed with exit code $cold_rc; partial evidence retained in $OUTPUT_DIR"
fi
wait_for_counter_increase kvbm_offload_blocks_d2d "$cold_offload_before" 300
capture_snapshot after-cold

warm_onboard_before=$(metric_value "$OUTPUT_DIR/metrics-after-cold.txt" kvbm_onboard_blocks_d2d)
warm_matched_before=$(metric_value "$OUTPUT_DIR/metrics-after-cold.txt" kvbm_matched_tokens)

echo '=== Sending byte-identical warm request and waiting for Disk-to-Device reload ==='
set +e
python3 "$COMPARE" request --output-dir "$OUTPUT_DIR" --label warm \
  > "$OUTPUT_DIR/warm.console.txt" 2>&1
warm_rc=$?
set -e
if (( warm_rc != 0 )); then
  cat "$OUTPUT_DIR/warm.console.txt" >&2
  die "warm request failed with exit code $warm_rc; partial evidence retained in $OUTPUT_DIR"
fi
wait_for_counter_increase kvbm_onboard_blocks_d2d "$warm_onboard_before" 300
wait_for_counter_increase kvbm_matched_tokens "$warm_matched_before" 300
capture_snapshot after-warm

frontend_pod=$(kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-frontend \
  -o jsonpath='{.items[0].metadata.name}')
decode_pod=$(kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-decode \
  -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NAMESPACE" logs "$frontend_pod" --since=30m > "$OUTPUT_DIR/frontend.log"
kubectl -n "$NAMESPACE" logs "$(prefill_pod)" --since=30m > "$OUTPUT_DIR/prefill.log"
kubectl -n "$NAMESPACE" logs "$decode_pod" --since=30m > "$OUTPUT_DIR/decode.log"

echo '=== Applying strict cold/warm comparison gates ==='
set +e
python3 "$COMPARE" summarize --output-dir "$OUTPUT_DIR" \
  > "$OUTPUT_DIR/summary.console.txt" 2>&1
summary_rc=$?
set -e

cat "$OUTPUT_DIR/summary.console.txt"
printf 'cold_rc=%s warm_rc=%s summary_rc=%s\n' "$cold_rc" "$warm_rc" "$summary_rc"
if (( cold_rc != 0 || warm_rc != 0 || summary_rc != 0 )); then
  echo "FAIL: near-40K KVBM/GDS A/B did not satisfy every strict gate"
  exit 2
fi
echo "PASS: near-40K Cold Prefill vs Warm Direct GDS Reload"
