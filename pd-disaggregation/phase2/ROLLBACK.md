# Phase 2 rollback

回滚会短暂中断单副本 Qwen P/D。它恢复最新 40K/FP8 baseline，不回到旧 8K 配置，不触碰 Phase 1 `dynamo-roce-qos.service`，也不修改 ComfyUI/gateway。

## 先验证

```bash
pd-disaggregation/phase2/scripts/rollback-phase2.sh --dry-run
```

dry-run 验证 baseline 同时包含 `--max-model-len 40960` 和 `--kv-cache-dtype fp8`，并打印确切顺序，不做任何 live write。

## 执行

在维护窗口从 node1 仓库根目录运行：

```bash
pd-disaggregation/phase2/scripts/rollback-phase2.sh --execute
```

脚本依次：

1. 应用 discovery 时备份的 latest repo baseline DGD，等待 Prefill/Decode/DGD Ready。
2. 在新 worker 中启动 `nvidia-smi` 和新 PyTorch CUDA context。
3. 停止 node1 NFS/RDMA client，然后删除 node1↔node3 专用 ToS rule 和 Phase 2 units。
4. node3 停 NFS export/listener，再卸载 `/dev/ram0` ext4 并释放 `brd` RAM，最后删除反向 ToS rule 和 units。
5. 运行既有 GDR、RoCE、Dynamo baseline regression，确认 node1↔node2 P/D 保持健康。
6. 把 Phase 2 为证据采集启用的 `nvidia-fs` rw/peer statistics flags 恢复为 discovery 前的 0；不卸载模块或 driver。

各组件脚本只接受固定地址/path/device，检查 marker、source、export、open user 和 block identity。若 Prefill 仍持有 hostPath，node1 unmount 会拒绝；若 NFS client 仍在线，node3 rollback 会拒绝；这两种情况都必须先解决引用，不能强制卸载。

node3 在 `/var/lib/dynamo-phase2` 以 root-only mode 保存安装前 package/service 和 `brd` ownership 状态，使 reboot 后的回滚仍能区分 Phase 2 创建的资源；成功 stop 后状态文件会删除。

## Nexus 与 package

Phase 2 没有 Nexus write，因此 switch rollback 是 no-op；不得删除共享的 Phase 1 VLAN 2310/QoS/PFC 配置。

自动 rollback 不卸载 `nvidia-fs`、CUDA 12.9 cuFile tools 或 MLNX_OFED NFS/RDMA DKMS：它们在 DGD 恢复后不处于数据路径，保留可避免 package dependency removal 误伤工作中的 NVIDIA/RDMA stack。若合规要求还原 package，先停止所有 NFS/RDMA/GDS 使用者，再分别审查 `nfs/remove-mlnx-nfsrdma.sh` 和发行版 package dry-run；不要 reload/reinstall GPU driver。

## daemon-reload canary

本次首次持久化实测触发旧 Prefill Pod 的 `NVML Unknown Error`。宿主 GPU 和 Decode 正常，只按仓库 recovery 删除该 Prefill Pod，由 PodClique 重建；新 Pod 的 NVML/CUDA、Direct GDS 与 near-40K A/B 全部复验通过。以后任何 `daemon-reload` 后都必须在 P/D Pod 启动新 NVML/CUDA 进程，失败时重建实际受影响 worker，不得把旧 vLLM 仍可回答当作通过。
