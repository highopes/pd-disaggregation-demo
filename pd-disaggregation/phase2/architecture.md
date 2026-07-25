# Phase 2 architecture

```text
                              API / Cilium / Hubble
Client ──> qwen-openai ──> Dynamo Frontend (node3)
                                   │
                                   ▼
Remote KV tier                 Prefill GPU (node1)                 Decode GPU (node2)
node3 /dev/ram0                Qwen3-14B-FP8                       Qwen3-14B-FP8
ext4 /srv/dynamo-g4            40,960 / FP8 KV                     40,960 / FP8 KV
NFSv3 RDMA port 20049  ──────> KVBM + NIXL ──────────────────────> NIXL
172.31.230.113                  /mnt/dynamo-g4
       Storage↔Prefill: NFSoRDMA + cuFile/nvidia-fs Direct GDS
       Prefill↔Decode: NIXL + UCX + GPUDirect RDMA / RoCEv2
```

| Endpoint | Backend | Nexus | Role |
|---|---|---|---|
| node1 | `ens65np0` / `mlx5_0:1` / `172.31.230.111` | Eth1/1/1 | Prefill、NFS/RDMA client、GDS initiator |
| node2 | `ens65np1` / `mlx5_0:1` / `172.31.230.112` | Eth1/1/2 | Decode、P→D NIXL target |
| node3 | `ens65np0` / `mlx5_0:1` / `172.31.230.113` | Eth1/2/1 | Frontend plus volatile Storage Emulator |

三端口均为 VLAN 2310、200G、MTU 9216，现有 DSCP 26 / ToS 106 映射到 lossless qos-group/PFC priority 3。Phase 2 没有修改 Nexus。node1/node3 只增加互为源/目的的 RDMA-CM ToS 106 规则，避免改变所有 RDMA QP。

Prefill 使用 `PdConnector`，内部串接 `DynamoConnector`（KVBM）和 `NixlConnector`；Decode 仍只使用 `NixlConnector`。`NVIDIA_GDS=enabled` 与 `NVIDIA_DRIVER_CAPABILITIES=all` 使 NVIDIA runtime 把 `/dev/nvidia-fs*` 注入 Prefill。没有该注入时同一容器测试只会走 compatibility path。

RAM/NFS tier 的启动依赖是：CX-7/RDMA → `brd` RAM device → ext4 → NFS export/listener → node1 RDMA mount → Prefill。systemd unit 只使用 `Wants/After`、有限 timeout，Storage 暂不可用不会阻止 node3 启动；Kubernetes Prefill 的 hostPath/健康检查会明确暴露依赖失败。

RAM storage 在 reboot 后清空，这是设计属性而不是故障。它只用于隔离未知虚拟盘性能并证明接口/数据路径，不代表 VAST 产品行为。
