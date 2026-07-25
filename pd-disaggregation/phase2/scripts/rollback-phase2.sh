#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PHASE2_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
REPO_ROOT=$(cd -- "$PHASE2_DIR/../.." && pwd)
BASELINE="$PHASE2_DIR/backup/qwen3-14b-pd.repo.yaml"
MODE="${1:---dry-run}"

[[ "$MODE" == --dry-run || "$MODE" == --execute ]] || {
  echo "usage: $0 [--dry-run|--execute]" >&2
  exit 2
}
[[ -f "$BASELINE" ]] || { echo "FAIL: baseline manifest absent" >&2; exit 1; }
grep -Fq -- '--max-model-len 40960' "$BASELINE" || { echo "FAIL: baseline is not 40K" >&2; exit 1; }
grep -Fq -- '--kv-cache-dtype fp8' "$BASELINE" || { echo "FAIL: baseline is not FP8 KV" >&2; exit 1; }

if [[ "$MODE" == --dry-run ]]; then
  cat <<EOF
PASS: rollback preconditions verified
DRY-RUN order:
1. kubectl apply latest 40K/FP8 baseline: $BASELINE
2. wait DGD Ready and verify new NVML/CUDA processes
3. stop/disable node1 Phase 2 mount and endpoint-specific ToS unit
4. stop/disable node3 NFS/RDMA, RAM storage and endpoint-specific ToS units
5. verify Phase 1 node1<->node2 P/D RoCE; do not touch dynamo-roce-qos.service
6. no Nexus rollback command: Phase 2 made no switch configuration change
7. restore nvidia-fs rw/peer statistics enable flags to their pre-Phase-2 value 0
EOF
  exit 0
fi

kubectl apply -f "$BASELINE"
kubectl -n ai-serving wait --for=condition=Ready dynamographdeployment/qwen3-14b-pd --timeout=30m
kubectl -n ai-serving wait --for=condition=Ready pod -l app=dynamo-qwen-prefill --timeout=30m
kubectl -n ai-serving wait --for=condition=Ready pod -l app=dynamo-qwen-decode --timeout=30m

for role in prefill decode; do
  pod=$(kubectl -n ai-serving get pod -l "app=dynamo-qwen-$role" -o jsonpath='{.items[0].metadata.name}')
  kubectl -n ai-serving exec "$pod" -- nvidia-smi
  kubectl -n ai-serving exec "$pod" -- python3 -c 'import torch; assert torch.cuda.is_available(); print(torch.cuda.device_count())'
done

systemctl stop dynamo-phase2-nfs-rdma-client.service
systemctl stop dynamo-phase2-rdma-tos.service
bash "$PHASE2_DIR/systemd/remove-persistence.sh"

ssh -o BatchMode=yes root@192.168.160.113 \
  'systemctl stop dynamo-phase2-nfs-rdma-server.service; systemctl stop dynamo-phase2-ram-storage.service; systemctl stop dynamo-phase2-rdma-tos.service; /usr/local/libexec/dynamo-phase2/remove-persistence.sh'

bash "$REPO_ROOT/pd-disaggregation/scripts/validate-gdr.sh"
bash "$REPO_ROOT/pd-disaggregation/scripts/validate-roce.sh"
bash "$REPO_ROOT/pd-disaggregation/scripts/validate-dynamo.sh"
for parameter in rw_stats_enabled peer_stats_enabled; do
  path="/sys/module/nvidia_fs/parameters/$parameter"
  if [[ -w "$path" ]]; then
    printf '0\n' > "$path"
  fi
done
echo "PASS: Phase 2 rollback complete; installed GDS/NFSoRDMA packages remain inert for audit and require separate dependency-reviewed removal"
