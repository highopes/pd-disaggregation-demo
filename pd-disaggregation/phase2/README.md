# Dynamo Phase 2: NFSoRDMA + Direct GDS + KVBM

最终状态：`PHASE 2 PASS – DIRECT GDS`。

本目录是可重建的 Phase 2 实施包。它在不改变 40,960 context、FP8 KV 和现有 Prefill→Decode GPUDirect RDMA 的前提下，把 node3 的 8 GiB RAM-backed ext4 作为远端 KV storage emulator，经 NFSv3/RDMA 和 NVIDIA GPUDirect Storage 连接到 node1 Prefill KVBM。

## 实测结果

- DGD `ai-serving/qwen3-14b-pd` Ready；Frontend=node3、Prefill=node1、Decode=node2，均 Running/Ready/0 restart。
- node1 `/mnt/dynamo-g4` 是 `172.31.230.113:/srv/dynamo-g4`、NFSv3、`proto=rdma`、port 20049。
- GDS 1.14.1.1 报告 NFS Supported、Mellanox PeerDirect Enabled、IOMMU Disabled；实际 `nvidia-fs` Direct I/O 和 CX-7/Nexus counter 同向增长，非 compatibility mode。
- 恢复/持久化后的 near-40K run `0725173741-6d792a`：39,994 input tokens，冷/热答案均正确，热请求命中 39,936 tokens；TTFT `32.575 s → 6.657 s`，节省 25.918 s，4.893×。
- Cold offload / Warm onboard 各 312 blocks；Direct GDS 写/读各 +24,960 ops / +1,560 MiB；P→D NIXL 两次均传 3,130 MiB。
- 新 NVML 和新 PyTorch CUDA context 在 Prefill/Decode 均 PASS；Foundation HTTP 200；CEE Hubble health OK 且捕获 Qwen `/v1/models` FORWARDED flow。按任务边界没有测试 ComfyUI readiness/API/auth gateway。

## 使用

只读预检与当前链路验证：

```bash
pd-disaggregation/phase2/scripts/preflight-phase2.sh
pd-disaggregation/phase2/scripts/validate-nfs-rdma.sh
pd-disaggregation/phase2/scripts/validate-gds.sh
pd-disaggregation/phase2/scripts/validate-kvbm.sh
```

安全现场 Demo 默认复放已验证 run 的结果，同时实时检查 DGD/NFSoRDMA/GDS/KVBM：

```bash
pd-disaggregation/phase2/scripts/demo-phase2.sh
```

要产生新的正式 near-40K A/B，显式给一个不存在的目录：

```bash
pd-disaggregation/phase2/scripts/demo-phase2.sh \
  --run-ab pd-disaggregation/phase2/evidence/runs/$(date +%Y%m%d-%H%M%S)-ab
```

Demo 不安装 package、不删除 Pod、不 reload driver、不改 Nexus、不重建/mkfs RAM disk，也不做 full-bandwidth benchmark。payload token 数由运行中模型的真实 tokenizer 计算；冷/热使用完全相同 payload hash。

## 配置与持久化

- [`dynamo/qwen3-14b-pd-kvbm-gds.yaml`](dynamo/qwen3-14b-pd-kvbm-gds.yaml)：Phase 2 DGD。
- [`storage/`](storage/)：带设备/内存/marker gate 的 RAM block 生命周期。
- [`nfs/`](nfs/)：MLNX_OFED NFS/RDMA build patch、server/client 和 rollback。
- [`systemd/`](systemd/)：node1/node3 的有限超时、非 boot-critical units。
- [`nexus/`](nexus/)：before/after；desired/rollback 明确记录“无交换机变更”。
- [`evidence/phase2-final-validation.md`](evidence/phase2-final-validation.md)：最终 28 项证据索引。

Nexus 只读脚本使用 shell 环境中的 `NEXUS_USERNAME`/`NEXUS_PASSWORD`，凭据不得打印或持久化。`nvidia-fs`/NFSoRDMA DKMS 与 systemd 安装是维护操作；不要在 GPU Pod 运行时重复无条件执行 `daemon-reload`。

## 回滚

先做无变更校验：

```bash
pd-disaggregation/phase2/scripts/rollback-phase2.sh --dry-run
```

执行顺序、停机影响和保留 package 的原因见 [`ROLLBACK.md`](ROLLBACK.md)。

## 边界

本环境使用 RAM-backed Linux NFS/RDMA server 模拟第三方 G4-like remote storage，以验证 Dynamo KVBM、NIXL、NFSoRDMA 和 GPUDirect Storage 数据路径。该实现不代表 VAST DASE、VAST G4 产品功能、持久性、HA、scale-out 或真实性能。
