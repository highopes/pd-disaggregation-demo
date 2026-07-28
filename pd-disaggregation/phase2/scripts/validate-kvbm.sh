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

command -v jq >/dev/null 2>&1 || die "jq is required"

ready=$(kubectl -n "$NAMESPACE" get dynamographdeployment qwen3-14b-pd \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$ready" == True ]] || die "DGD Ready=$ready"

pod_for_role() {
  local role=$1
  kubectl -n "$NAMESPACE" get pod -l "app=dynamo-qwen-$role" -o json |
    jq -er '
      [.items[]
       | select(.status.phase == "Running")
       | select(any(.status.containerStatuses[]?; .ready == true))]
      | if length == 1 then .[0].metadata.name
        else error("expected exactly one Ready pod") end
    '
}

frontend_pod=$(pod_for_role frontend)
pod=$(pod_for_role prefill)
decode_pod=$(pod_for_role decode)
[[ -n "$frontend_pod" && -n "$pod" && -n "$decode_pod" ]] \
  || die "Frontend/Prefill/Decode pod set is incomplete"

frontend_spec=$(kubectl -n "$NAMESPACE" get pod "$frontend_pod" -o json)
spec=$(kubectl -n "$NAMESPACE" get pod "$pod" -o json)
decode_spec=$(kubectl -n "$NAMESPACE" get pod "$decode_pod" -o json)
frontend_args=$(jq -r '.spec.containers[] | select(.name == "main") | .args[]?' <<<"$frontend_spec")
prefill_args=$(jq -r '.spec.containers[] | select(.name == "main") | .args[]?' <<<"$spec")
decode_args=$(jq -r '.spec.containers[] | select(.name == "main") | .args[]?' <<<"$decode_spec")

grep -Fq -- '--kv-cache-block-size 256' <<<"$frontend_args" \
  || die "Frontend is not using 256-token KV blocks"
grep -Fq -- '--block-size 256' <<<"$prefill_args" \
  || die "Prefill is not using 256-token KV blocks"
grep -Fq -- '--block-size 256' <<<"$decode_args" \
  || die "Decode is not using 256-token KV blocks"
jq -e '
  .spec.containers[]
  | select(.name == "main")
  | .env[]?
  | select(.name == "DYN_KVBM_DISK_CACHE_GB" and .value == "7")
' >/dev/null <<<"$spec" || die "Prefill KVBM disk cache is not 7 GB"
jq -e '
  .spec.containers[]
  | select(.name == "main")
  | .env as $env
  | any($env[]?; .name == "DYN_KVBM_MAX_CONCURRENT_TRANSFERS" and .value == "4")
    and any($env[]?; .name == "DYN_KVBM_MAX_TRANSFER_BATCH_SIZE" and .value == "40")
' >/dev/null <<<"$spec" || die "Prefill KVBM is not using tuned concurrency=4/batch=40"

for required in \
  'PdConnector' 'DynamoConnector' 'NixlConnector' \
  'Qwen/Qwen3-14B-FP8' '--max-model-len 39168' '--kv-cache-dtype auto' \
  '--attention-backend TRITON_ATTN' '--no-enable-prefix-caching' \
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
grep -Fq 'page_size=256' <<<"$pod_logs" \
  || die "KVBM did not register the physical 256-token page size"
grep -Fq 'dtype_width_bytes=2' <<<"$pod_logs" \
  || die "KVBM did not register BF16 KV elements"
grep -Fq 'inner_dim=1024' <<<"$pod_logs" \
  || die "KVBM did not register the full 8-head x 128-dimension KV width"
if grep -Fq 'does not match physical kernel block size' <<<"$pod_logs"; then
  die "vLLM still reports a logical/physical KV block-size mismatch"
fi
if (( PREFLIGHT == 1 )); then
  echo "PASS: KVBM uses physical=logical=256, BF16 KV and tuned 4x40 transfers"
else
  echo "PASS: KVBM 256-token layout, Device-to-Disk offload, Disk-to-Device onboard and matched tokens"
fi
