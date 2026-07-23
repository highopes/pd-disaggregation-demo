#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}

kubectl version
helm status dynamo-platform -n dynamo-system
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,RDMA:.status.allocatable.rdma/ib'
kubectl get pods -n dynamo-system -o wide
kubectl get pods -n kube-system -l app.kubernetes.io/name=k8s-rdma-shared-dev-plugin -o wide
kubectl get runtimeclass nvidia
kubectl get crd | grep -E 'dynamo|grove|kai'
kubectl get pvc hf-cache-pvc -n "$namespace"

