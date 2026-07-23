#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
selector='nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd'

for role in prefill decode; do
  pod=$(kubectl get pod -n "$namespace" -l "$selector,dynamo-role=$role" -o jsonpath='{.items[0].metadata.name}')
  echo "=== $role / $pod ==="
  kubectl exec -n "$namespace" "$pod" -- sh -c '
    if command -v ip >/dev/null 2>&1; then ip -brief address show; else echo "ip: not present in runtime image"; fi
    if command -v rdma >/dev/null 2>&1; then rdma link show; else echo "rdma: not present in runtime image"; fi
    ibv_devinfo -d mlx5_0
    ls -l /dev/infiniband
    env | grep "^UCX_" | sort
  '
done

kubectl get pod -n "$namespace" -l "$selector" -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,HOST_NETWORK:.spec.hostNetwork,IP:.status.podIP'
