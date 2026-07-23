#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
selector='nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd'

for role in prefill decode; do
  pod=$(kubectl get pod -n "$namespace" -l "$selector,dynamo-role=$role" -o jsonpath='{.items[0].metadata.name}')
  echo "=== $role / $pod ==="
  kubectl exec -n "$namespace" "$pod" -- nvidia-smi --query-gpu=name,driver_version,pci.bus_id --format=csv,noheader
  kubectl exec -n "$namespace" "$pod" -- sh -c 'ucx_info -d | grep -E "Memory domain:|Transport:|memory types|cuda"'
done

