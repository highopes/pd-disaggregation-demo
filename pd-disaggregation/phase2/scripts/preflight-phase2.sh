#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-ai-serving}"
failures=0

pass() { echo "PASS: $*"; }
partial() { echo "PARTIAL: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

for command in kubectl ssh rdma ethtool findmnt nfsstat; do
  command -v "$command" >/dev/null 2>&1 && pass "$command available" || fail "$command absent"
done

kubectl get dynamographdeployment qwen3-14b-pd -n "$NAMESPACE" >/dev/null 2>&1 \
  && pass "DGD ai-serving/qwen3-14b-pd exists" || fail "DGD absent"

ready=$(kubectl get dynamographdeployment qwen3-14b-pd -n "$NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
[[ "$ready" == "True" ]] && pass "DGD Ready=True" || fail "DGD Ready is $ready"

for mapping in 'frontend:csco-k8s-03' 'prefill:csco-k8s-01' 'decode:csco-k8s-02'; do
  role=${mapping%%:*}
  expected_node=${mapping##*:}
  pod=$(kubectl -n "$NAMESPACE" get pod -l "app=dynamo-qwen-$role" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  node=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
  [[ -n "$pod" && "$node" == "$expected_node" ]] && pass "$role=$pod@$node" || fail "$role mapping is $pod@$node"
done

if [[ -n "${NEXUS_USERNAME:-}" && -n "${NEXUS_PASSWORD:-}" ]]; then
  pass "Nexus credentials are available in environment (values not displayed)"
else
  partial "Nexus credentials absent; live switch read-back will be skipped"
fi

if findmnt -rn /mnt/dynamo-g4 >/dev/null 2>&1; then
  pass "node1 remote KV mount exists"
else
  fail "node1 /mnt/dynamo-g4 is not mounted"
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 root@192.168.160.113 \
  'test -f /srv/dynamo-g4/.dynamo-phase2-ram-storage && grep -Fq ACTIVE /sys/class/infiniband/mlx5_0/ports/1/state' \
  && pass "node3 RAM marker and CX-7 active" || fail "node3 storage/RDMA preflight failed"

if (( failures > 0 )); then
  echo "FAIL: Phase 2 preflight has $failures blocking finding(s)"
  exit 1
fi
echo "PASS: Phase 2 preflight"
