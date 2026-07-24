#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
selector='nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd'
failed=0

for role in prefill decode; do
  pod=$(kubectl get pod -n "$namespace" -l "$selector,dynamo-role=$role" -o jsonpath='{.items[0].metadata.name}')
  echo "=== $role / $pod ==="
  if ! kubectl exec -n "$namespace" "$pod" -- \
    nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv,noheader; then
    echo "ERROR: $role cannot initialize NVML inside $pod." >&2
    echo "Compare host nvidia-smi with Pod NVML; a host-pass/Pod-fail result usually requires recreating the stale worker Pod." >&2
    failed=1
  fi
  if ! kubectl exec -n "$namespace" "$pod" -- \
    sh -c 'ucx_info -d | grep -E "Memory domain:|Transport:|memory types|cuda"'; then
    echo "ERROR: $role UCX capability query failed inside $pod." >&2
    failed=1
  fi
done

if (( failed != 0 )); then
  echo "GDR capability validation: FAIL. Do not record a GDR PASS until both worker Pods pass NVML and UCX checks." >&2
  exit 1
fi

echo "GDR capability validation: PASS"
