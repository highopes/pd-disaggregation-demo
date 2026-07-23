# 旧服务共享资源与 ownerReference 记录

记录时间：2026-07-23（live environment）。不包含任何 Secret 数据。

- `qwen-vllm` Pod → ReplicaSet `qwen-vllm-6c878d4ccc` → Deployment `qwen-vllm`。
- `dare-foundation-vllm` Pod → ReplicaSet `dare-foundation-vllm-7dd4b75f46` → Deployment `dare-foundation-vllm`。
- 两者均挂载共享 PVC `ai-serving/hf-cache-pvc`，绑定 PV `hf-cache-pv`（NFS RWX 2Ti）。该 PVC/PV 同时被保留服务使用，不删除。
- CiliumNetworkPolicy `vllm-token-from-lb` 与 `vllm-http-visibility` 的 selector 均为 `app=vllm`，属于共享策略，不随旧服务删除。
- Secret `ai-serving/vllm-api-token`：仅记录名称；用途是 Cilium HTTP `Authorization` header match；数据键名为 `auth-header`。未导出值。
- qwen/dare 没有专属 ConfigMap，也没有专属 Secret 引用。
- `foundation-instruct-chat-template` 只属于保留服务 `foundation-instruct-vllm`，不修改、不删除。

回滚旧服务：

```bash
kubectl apply -f pd-disaggregation/backup/qwen-vllm.yaml
kubectl apply -f pd-disaggregation/backup/dare-foundation-vllm.yaml
```
