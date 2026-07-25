# Phase 2 final validation

Validation date: 2026-07-25, Asia/Shanghai. Evidence run root: [`runs/20260725-135015`](runs/20260725-135015/).

## 1. 最终结论

`PHASE 2 PASS – DIRECT GDS`

HTTP 200 不是本结论的依据。结论同时满足 NFS/RDMA mount、cuFile/nvidia-fs Direct I/O、KVBM offload/onboard/match、三节点 CX-7/Nexus counter、相同 near-40K payload 冷/热正确答案和 P→D NIXL 证据。

## 2. Git / live state

Discovery 起点为 branch `main`、HEAD `ad8366dc2dbe858336e063f4de821f64df00b02d`，起始 worktree clean。Phase 2 文件是本次未提交新增/更新。实时 DGD 位于 `ai-serving`，而任务书部分示例使用 `dynamo` namespace；以 live `ai-serving/qwen3-14b-pd` 为准。repo baseline 是 `v1alpha1`，operator live object 已转换为 `v1beta1`；本次 Phase 2 使用并通过 server dry-run 的 `v1beta1` manifest。

## 3. 最终 topology

Frontend=node3，Prefill=node1，Decode=node2；node3 同时提供独立的 volatile RAM-backed NFS/RDMA Storage Emulator。完整图见根文档的[整体架构](../../../README.md#architecture)。最终 DGD Ready=True，三个 Pod Running/Ready/0 restart。

## 4. Three-endpoint Nexus mapping

| Node | CX-7 backend | Nexus |
|---|---|---|
| node1 / Prefill | `ens65np0`, `mlx5_0:1`, `172.31.230.111` | Eth1/1/1 |
| node2 / Decode | `ens65np1`, `mlx5_0:1`, `172.31.230.112` | Eth1/1/2 |
| node3 / Storage | `ens65np0`, `mlx5_0:1`, `172.31.230.113` | Eth1/2/1 |

三个端口均 200G、VLAN 2310、MTU 9216、PFC on、同一 QoS classification。node2 live netdev 是 `ens65np1`，修正了早期验证脚本曾假设 `ens65np0` 的文档/探测偏差。

## 5. Current 40,960 / FP8 KV args

Prefill/Decode 均保持 `--gpu-memory-utilization 0.90 --max-model-len 40960 --max-num-seqs 1 --kv-cache-dtype fp8 --calculate-kv-scales --no-enable-prefix-caching --block-size 128`。每张 L4 实测 GPU KV pool 54,016 tokens / 4.12 GiB。

## 6. RAM filesystem / KVBM sizing

node3 `/dev/ram0` 为 8 GiB，ext4 label `DYNAMO_G4_RAM`，挂载 `/srv/dynamo-g4`；KVBM disk cache 6 GB，实际 zero-fill 5,997,854,720 bytes。最终 ext4 6.0G used / 1.5G available，能完整容纳实际 39,994-token Prefix。详见 [`ram-storage-sizing.md`](ram-storage-sizing.md)。

## 7. node3 memory before / after

`MemTotal=49,331,120 kB`。RAM block 建立后的早期 `MemAvailable=28,868,960 kB`；最终 KVBM cache 持有时 `MemAvailable=21,032,412 kB`，Kubernetes `MemoryPressure=False`。这是实际 RAM 消耗，不把文件系统显示容量与剩余 host RAM 混为一谈。

## 8. Nexus before / change / after / startup

[`../nexus/before.txt`](../nexus/before.txt) 和 [`../nexus/after.txt`](../nexus/after.txt) 记录三端口 read-back。现有 DSCP26→qos-group3、PFC3 和 MTU 已满足，Phase 2 没有 Nexus write，所以 [`../nexus/desired.cfg`](../nexus/desired.cfg) 与 rollback 均明确为 no-op；不需要 copy running-config。最终三端口 FCS/Xmit/Rcv/Symbol error、In/Out discard 均为 0。

## 9. NFSoRDMA mount

node1 `/mnt/dynamo-g4` source=`172.31.230.113:/srv/dynamo-g4`、NFSv3、`proto=rdma`、`port=20049`，route source=`172.31.230.111`。node3 `/proc/fs/nfsd/portlist` 有 RDMA 20049，export 仅允许 `172.31.230.111`。mount option 中 `mountproto=tcp` 只用于 mountd control plane，不是 NFS data fallback。

## 10. ToS / DSCP / PFC

node1 rule 为 `src_ip=172.31.230.111,dst_ip=172.31.230.113/32,tclass=106`，node3 为反向 rule；ToS 106 对应 DSCP 26 + ECN bits。恢复后 A/B 的 storage bytes 与 P→D bytes 同时出现在 host `prio3_bytes` 和 Nexus qos-group3。规则仅匹配 storage endpoints，不覆盖全部 RDMA QP。

## 11. Direct GDS judgement

GDS 1.14.1.1：NFS Supported、Mellanox PeerDirect Enabled、L4 supported、IOMMU disabled、NVIDIA open driver supported。Prefill 有 `NVIDIA_GDS=enabled`、`NVIDIA_DRIVER_CAPABILITIES=all` 和 `/dev/nvidia-fs*`。恢复后 A/B 的 `nvidia-fs` direct read/write 各增加 1,560 MiB，page-cache=0、error=0，并与 NFSoRDMA counter 同向。因此是 Direct GDS，不是 compatibility mode。

`/proc/driver/nvidia-fs/stats` 的 legacy `Mellanox PeerDirect Supported: False` 与 matching CUDA 12.9 `gdscheck`/实际 Direct counters 不一致；本判定以 matching userspace capability、device injection、cuFile I/O 和同次硬件 counter 组成的强证据链为准，保留该差异而不掩盖。

## 12. Synthetic GDS

在集成 KVBM 前，node1 对 NFS/RDMA 文件执行 256 MiB `gdsio` GPU_DIRECT write/read。`nvidia-fs` direct stats、BAR1 map、node1/node3 RDMA bytes 和 Nexus qos-group3 按方向增长，errors/page-cache 均为 0。另一个带 `NVIDIA_GDS=enabled` 的 runtime probe 对 64 MiB write/read 也各产生 Direct stats；不带该环境/设备注入的 probe counters 不增长，明确证明 compatibility 与 Direct 的边界。

## 13. KVBM / PdConnector config

Prefill `PdConnector` 串接 `DynamoConnector`/KVBM 与 `NixlConnector`；Decode 保持 `NixlConnector`。CPU cache 未配置，未禁用 O_DIRECT，disk dir=`/mnt/dynamo-g4/kvbm`、cache=`6` GB。日志明确：`G1->G3 direct offload enabled ... bypassing Host memory (CPU cache disabled)`，NIXL 加载 `GDS_MT`。

## 14. Request A payload / answer / time

Post-persistence run ID `0725173741-6d792a`；SHA-256 `a4e86577fe41acc9f421ff312cb945aa1753090a78c767edc830659f5ba68904`；真实 tokenizer input 39,994 tokens，completion 25，未超过 40,960。Cold HTTP 200，答案 `PHASE2_0725173741-6d792a_5693` 正确，TTFT 32.575 s，total 34.788 s，cached tokens 0。

## 15. Request A cold Prefill

Cold 的 request-level cached tokens=0，KVBM before counters 全为 0；Frontend、Prefill、Decode logs 以 request IDs 关联。随后 P→D NIXL 传 3,130 MiB，证明不是单体或跳过 Prefill 的响应。

## 16. Request A offload

Cold 后 `kvbm_offload_blocks_d2d +312`；`nvidia-fs writes +24,960 ops / +1,560 MiB`；node3 RX RDMA +1,666,729,518 bytes、RX prio3 +1,668,526,586；Nexus node3 port Out +1,668,528,349、qos-group3 Tx +1,668,526,330。

## 17. Request B payload / answer / time

Warm 使用逐字节相同 payload hash，input 39,994，HTTP 200，答案相同且正确。TTFT 6.657 s，total 8.868 s，request-level cached tokens 39,936。

## 18. Request B match / onboard / GDS read

Warm `kvbm_onboard_blocks_d2d +312`、disk hit rate=0.5；`nvidia-fs reads +24,960 ops / +1,560 MiB`；node3 TX RDMA +1,667,328,928、TX prio3 +1,669,126,080；Nexus node3 In +1,669,126,329、node1 qos-group3 Tx +1,673,047,402。raw `kvbm_matched_tokens` delta=79,872 是 runtime 内部累计/双计数；请求 usage 的 39,936 是实际 match。

## 19. Same-run timing / speedup

TTFT saved 25.918 s，speedup 4.893×；total saved 25.920 s，speedup 3.923×。恢复前的独立 run 也得到 31.133→10.597 s / 2.938×，但最终展示采用持久化与 worker recovery 后的新 run。

## 20. Prefill compute / GDS reload durations

客户端 TTFT/total 是可靠同次测量；runtime 没有提供可把“纯 Prefill compute”和“纯 GDS reload”从调度、routing、onboard 中严格分离的单一 duration，故不伪造该数字。P→D NIXL 是独立计量：Cold 511.846 ms、Warm 527.194 ms；它不等于用户 TTFT。

## 21. node1 / node2 / node3 CX-7 counters

Cold：node1 TX RDMA +4,995,650,690，node2 RX +3,328,926,368，node3 RX +1,666,729,518。Warm：node3 TX +1,667,328,928、node1 RX +1,673,163,124，之后 node1 TX +3,339,404,010、node2 RX +3,328,919,346。对应 prio3 bytes 同向；PHY error/discard=0。精确差分见 [`runs/20260725-135015/near40-ab-post-persistence/counter-deltas.md`](runs/20260725-135015/near40-ab-post-persistence/counter-deltas.md)。

## 22. Nexus counters

Cold 时 node3 port/qos-group3 switch→host bytes 增长，Warm 时 node3 host→switch 与 node1 switch→host bytes 增长；两次 node2 switch→host 各约 3.332 GB，对应 P→D。所有端口 error/discard=0。

## 23. P→D NIXL

新 Prefill 首次连接现有 Decode 时 `NIXL compatibility check passed`。Cold 3,130 MiB / 511.846 ms / 6,115.121 MB/s；Warm 3,130 MiB / 527.194 ms / 5,937.093 MB/s。node2 live `ens65np1` RX/prio3 与 Nexus Eth1/1/2 同次增长。

## 24. API / Cilium / Hubble regression

Cold/Warm Qwen API 均 HTTP 200 且正确回答；DGD Ready。CEE Hubble `v1.18.7-cee.1` health OK，并捕获 `192.168.160.111 -> Frontend:8000 GET /v1/models FORWARDED`。无需凭据的 Foundation internal `/v1/models` HTTP 200。按明确边界没有执行 ComfyUI readiness、API 或 auth gateway 测试，也没有读取相关凭据。

## 25. Grafana

`OPTIONAL SKIPPED`。现有 Prometheus Operator 双控制器 ownership/thrash 是已知环境问题；不为可选 dashboard 冒险改变当前已通过的数据面。原始 KVBM、nvidia-fs、NIC、Nexus、NIXL 和 Hubble evidence 已归档。

## 26. Known limitations

- node3 是单机、易失 RAM NFS server，无持久性/HA/scale-out；reboot 会清空 cache。
- NFSv3 不支持此处 fallocate，KVBM 使用 4096-byte aligned O_DIRECT zero-fill fallback；初始化成功。
- Dynamo 1.2.1/vLLM 的 `get_kv_cache_group_metadata` 缺失会记录 AttributeError 后回退到 `cache_config.block_size`；worker Ready 且实际 A/B 正常。
- local prefix caching 按 baseline 要求禁用，因此 KV event consolidator warning 是预期；KVBM remote cache 仍工作。
- node1/node3 时钟存在约两分钟偏差；同 host 客户端计时和 counter direction 不受影响。
- systemd `daemon-reload` 首次使旧 Prefill 新 NVML 失败；只重建受影响 Pod 后，新 NVML/CUDA 和新 A/B 全部 PASS。CDI 是后续长期修复，不在本任务中覆盖现有 runtime。

## 27. Rollback result

[`../scripts/rollback-phase2.sh`](../scripts/rollback-phase2.sh) `--dry-run` PASS，40K/FP8 baseline 和 Phase 2 manifest 均通过 Kubernetes server-side dry-run。组件脚本有 device/path/IP/marker/open-user gates；Nexus rollback 是 no-op；不碰 Phase 1 QoS。没有执行 destructive rollback，以保留用户要求的最终 Direct GDS Demo 状态。详见根文档的[回滚](../../../README.md#rollback)。

## 28. 与真实 VAST G4 的差异

本环境使用 RAM-backed Linux NFS/RDMA server 模拟第三方 G4-like remote storage，以验证 Dynamo KVBM、NIXL、NFSoRDMA 和 GPUDirect Storage 数据路径。该实现不代表 VAST DASE、VAST G4 产品功能、持久性、HA、scale-out 或真实性能。

RAM tier 的 TTFT、吞吐或单次 speedup 不可外推为 VAST benchmark；上线真实 VAST 前必须按其支持矩阵重新验证 client/plugin、mount/export、GDS、multipath/failover、HA、capacity、QoS 和生产负载。
