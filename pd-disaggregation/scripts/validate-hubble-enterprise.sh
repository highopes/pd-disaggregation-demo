#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
selector='nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,app=dynamo-qwen-frontend'

frontend=$(kubectl get pod -n "$namespace" -l "$selector" -o jsonpath='{.items[0].metadata.name}')
node=$(kubectl get pod -n "$namespace" "$frontend" -o jsonpath='{.spec.nodeName}')
agent=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector "spec.nodeName=$node" -o jsonpath='{.items[0].metadata.name}')

echo "Frontend=$namespace/$frontend node=$node CiliumAgent=kube-system/$agent"
kubectl exec -n kube-system "$agent" -c cilium-agent -- hubble version
kubectl exec -n kube-system "$agent" -c cilium-agent -- \
  hubble status --server unix:///var/run/cilium/hubble.sock
kubectl exec -n kube-system "$agent" -c cilium-agent -- \
  hubble observe --server unix:///var/run/cilium/hubble.sock \
  --since 10m --to-pod "$namespace/$frontend" --protocol http \
  --last 100 --print-node-name --print-policy-names

