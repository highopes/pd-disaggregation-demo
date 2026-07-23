#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
selector='nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd'

kubectl get dynamographdeployment qwen3-14b-pd -n "$namespace" -o wide
kubectl get podcliqueset,podclique,podgang -n "$namespace"
kubectl get pod -n "$namespace" -l "$selector" -o wide
kubectl get service qwen-openai qwen3-14b-pd-frontend -n "$namespace"
kubectl get endpointslice -n "$namespace" -l kubernetes.io/service-name=qwen-openai

for role in prefill decode; do
  pod=$(kubectl get pod -n "$namespace" -l "$selector,dynamo-role=$role" -o jsonpath='{.items[0].metadata.name}')
  echo "=== $role NIXL/UCX ==="
  kubectl logs -n "$namespace" "$pod" | grep -Ei 'NIXL|UCX|TCP|disaggreg|prefill|decode' | tail -200
done

frontend=$(kubectl get pod -n "$namespace" -l "$selector,app=dynamo-qwen-frontend" -o jsonpath='{.items[0].metadata.name}')
echo "=== frontend routing ==="
kubectl logs -n "$namespace" "$frontend" | grep -Ei 'prefill|decode|route|worker|request' | tail -200

