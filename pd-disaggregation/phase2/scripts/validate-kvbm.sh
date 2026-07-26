#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-serving}"
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

ready=$(kubectl -n "$NAMESPACE" get dynamographdeployment qwen3-14b-pd \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$ready" == True ]] || die "DGD Ready=$ready"

pod=$(kubectl -n "$NAMESPACE" get pod -l app=dynamo-qwen-prefill -o jsonpath='{.items[0].metadata.name}')
spec=$(kubectl -n "$NAMESPACE" get pod "$pod" -o json)
for required in \
  'PdConnector' 'DynamoConnector' 'NixlConnector' \
  '--max-model-len 40960' '--kv-cache-dtype fp8' '--no-enable-prefix-caching' \
  'DYN_KVBM_DISK_CACHE_GB' 'NVIDIA_GDS'; do
  grep -Fq -- "$required" <<<"$spec" || die "Prefill spec lacks $required"
done

metrics=$(kubectl -n "$NAMESPACE" exec "$pod" -- curl -fsS http://127.0.0.1:6880/metrics)
for metric in kvbm_offload_blocks_d2d kvbm_onboard_blocks_d2d kvbm_matched_tokens; do
  value=$(awk -v metric="$metric" '$1 == metric {print $2}' <<<"$metrics")
  [[ -n "$value" ]] || die "$metric is absent"
  if (( PREFLIGHT == 0 )); then
    awk -v value="$value" 'BEGIN {exit !(value > 0)}' || die "$metric did not increase"
  fi
  printf '%s=%s\n' "$metric" "$value"
done
hit=$(awk '$1 == "kvbm_disk_cache_hit_rate" {print $2}' <<<"$metrics")
printf 'kvbm_disk_cache_hit_rate=%s\n' "$hit"

pod_logs=$(kubectl -n "$NAMESPACE" logs "$pod")
grep -F 'G1->G3 direct offload enabled' <<<"$pod_logs" | tail -1
if (( PREFLIGHT == 1 )); then
  echo "PASS: Prefill PdConnector(KVBM+NIXL) is ready for a new cold/warm A/B"
else
  echo "PASS: Prefill PdConnector(KVBM+NIXL), Device-to-Disk offload, Disk-to-Device onboard and matched tokens"
fi
