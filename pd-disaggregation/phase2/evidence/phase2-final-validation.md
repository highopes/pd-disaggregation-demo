# Phase 2 final validation

Final validation: 2026-07-28, Asia/Shanghai. Evidence: [`runs/20260728-final-nfsd64-samples3`](runs/20260728-final-nfsd64-samples3/).

## 当前最终结论

`PHASE 2 PASS – COMPLETE NEAR-40K KV DIRECT GDS REUSE`。

- 模型权重仍为 `Qwen/Qwen3-14B-FP8`（GPU load 15.33 GiB），不是 24 GB L4 无法承载的 FP16 权重版本。
- KV cache=BF16、Triton attention、max context=39,168、block=256；KVBM 记录 `num_device_blocks=153,page_size=256,dtype_width_bytes=2,inner_dim=1024`。
- 请求 input=38,874，完整命中=38,656 tokens；每次 KV 为 151 blocks × 40 MiB = 6,040 MiB，12,080 个 layer/K/V I/O。
- Cold TTFT=50.392 s；三个完整 Warm TTFT=5.865/5.929/6.439 s，中位=5.929 s，speedup=8.499×，节省=88.2%。
- Cold offload=151 blocks；三个 Warm onboard=151/151/151 blocks。node3 Cold storage RX=6,428,393,308 bytes；三个 Warm storage TX=19,289,974,248 bytes。
- P→D NIXL 每次=6,080 MiB/12,160 descriptors，约 0.93–0.97 s；因此 200G RoCE P→D 不是 Warm TTFT 的主瓶颈。
- KVBM concurrency=4/batch=40；NFS server 持久化 `nfsd=64`。`nvidia-fs` rw/peer stats 保持关闭，避免小 I/O 统计开销。
- 三次 Warm 的 SHA-256、checkpoint 答案、usage cached tokens、KVBM block delta、NFSoRDMA bytes 和 NIXL descriptors 全部通过严格 Gate。

## 历史 2026-07-25 结果（仅用于根因追溯）

历史 evidence root: [`runs/20260725-135015`](runs/20260725-135015/)。其 1,560 MiB raw write/read 是实际传输量，不是显示层少算；旧 128/64 logical/physical mismatch 只能证明 GDS 路径 active，不能证明完整 KV。下列章节保留旧值，不得替代上面的 2026-07-28 最终证据。

Historical result: `DIRECT GDS PATH ACTIVE; COMPLETE 40K KV REUSE NOT VALIDATED`.

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

历史 Prefill/Decode 使用 `--block-size 128`，但 FlashInfer 启动日志明确选择物理 block 64；KVBM 随后记录 `page_size=128, inner_dim=512`。这正是半量传输的触发条件。后续 64-token/FP8 中间配置修复了完整性；当前最终配置见文首的 BF16/256-token Gate。

## 6. RAM filesystem / KVBM sizing

历史 node3 `/dev/ram0` 为 8 GiB，KVBM disk cache 6 GB、zero-fill 5,997,854,720 bytes。该文件能容纳当时实际传输的半量 KV，但旧 run 不能证明完整 Prefix 容量。当前 7 GB cache 保存一份 6,040 MiB near-40K BF16 KV；详见 [`ram-storage-sizing.md`](ram-storage-sizing.md)。

## 7. node3 memory before / after

`MemTotal=49,331,120 kB`。RAM block 建立后的早期 `MemAvailable=28,868,960 kB`；最终 KVBM cache 持有时 `MemAvailable=21,032,412 kB`，Kubernetes `MemoryPressure=False`。这是实际 RAM 消耗，不把文件系统显示容量与剩余 host RAM 混为一谈。

## 8. Nexus before / change / after / startup

[`../nexus/before.txt`](../nexus/before.txt) 和 [`../nexus/after.txt`](../nexus/after.txt) 记录三端口 read-back。现有 DSCP26→qos-group3、PFC3 和 MTU 已满足，Phase 2 没有 Nexus write，所以 [`../nexus/desired.cfg`](../nexus/desired.cfg) 与 rollback 均明确为 no-op；不需要 copy running-config。最终三端口 FCS/Xmit/Rcv/Symbol error、In/Out discard 均为 0。

## 9. NFSoRDMA mount

node1 `/mnt/dynamo-g4` source=`172.31.230.113:/srv/dynamo-g4`、NFSv3、`proto=rdma`、`port=20049`，route source=`172.31.230.111`。node3 `/proc/fs/nfsd/portlist` 有 RDMA 20049，export 仅允许 `172.31.230.111`。mount option 中 `mountproto=tcp` 只用于 mountd control plane，不是 NFS data fallback。

## 10. ToS / DSCP / PFC

node1 rule 为 `src_ip=172.31.230.111,dst_ip=172.31.230.113/32,tclass=106`，node3 为反向 rule；ToS 106 对应 DSCP 26 + ECN bits。恢复后 A/B 的 storage bytes 与 P→D bytes 同时出现在 host `prio3_bytes` 和 Nexus qos-group3。规则仅匹配 storage endpoints，不覆盖全部 RDMA QP。

## 11. Direct GDS judgement

GDS 1.14.1.1：NFS Supported、Mellanox PeerDirect Enabled、L4 supported、IOMMU disabled、NVIDIA open driver supported。Prefill 有 `NVIDIA_GDS=enabled`、`NVIDIA_DRIVER_CAPABILITIES=all` 和 `/dev/nvidia-fs*`。历史 A/B 的 raw direct read/write 各增加 1,560 MiB、page-cache=0、error=0，并与 NFSoRDMA counter 同向；因此可以判定 Direct GDS 路径工作，但只能判定半量 KV 经过该路径。

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

Cold 后 `kvbm_offload_blocks_d2d +312`；`nvidia-fs writes +24,960 ops / +1,560 MiB raw`。后者与 node3 RX RDMA +1,666,729,518 bytes 相互印证，说明实际只 Offload 了完整 KV 的一半，而不是 counter 少显示一半。

## 17. Request B payload / answer / time

Warm 使用逐字节相同 payload hash，input 39,994，HTTP 200，答案相同且正确。TTFT 6.657 s，total 8.868 s，request-level cached tokens 39,936。

## 18. Request B match / onboard / GDS read

Warm `kvbm_onboard_blocks_d2d +312`、`nvidia-fs reads +24,960 ops / +1,560 MiB raw`；node3 TX RDMA +1,667,328,928 bytes 与之吻合。request usage 虽报告 39,936 cached tokens，但实际仅 Reload 半量 KV，所以该命中值表示调度/索引判定，不是数据完整性证明。

## 19. Same-run timing / speedup

历史客户端记录 TTFT saved 25.918 s、speedup 4.893×。由于该 run 只 Reload 半量 KV 且可能利用 GPU 残留，这些 timing 仅作为故障分析记录，不能作为改进后 Demo 的性能结论。

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
- Dynamo 1.2.1/vLLM 的 `get_kv_cache_group_metadata` 缺失会记录 AttributeError 后回退到 `cache_config.block_size`；worker 虽然 Ready，但在 128/64 mismatch 下 A/B 数据不完整。
- local prefix caching 按 baseline 要求禁用，因此 KV event consolidator warning 是预期；KVBM remote cache 仍工作。
- node1/node3 时钟存在约两分钟偏差；同 host 客户端计时和 counter direction 不受影响。
- systemd `daemon-reload` 首次使旧 Prefill 新 NVML 失败；重建受影响 Pod 后 NVML/CUDA 恢复，但当时的新 A/B 仍受本文记录的半量 KV 问题影响。CDI 是后续长期修复，不在本任务中覆盖现有 runtime。

## 27. Rollback result

[`../scripts/rollback-phase2.sh`](../scripts/rollback-phase2.sh) 的历史 `--dry-run` PASS；Nexus rollback 是 no-op，不碰 Phase 1 QoS。当前 BF16/256-token manifest 已通过 server dry-run、在线 rollout、完整 Cold+3 Warm Gate 和只读 evidence replay。详见根文档的[回滚](../../../README.md#rollback)。

## 28. 与真实 VAST G4 的差异

本环境使用 RAM-backed Linux NFS/RDMA server 模拟第三方 G4-like remote storage，以验证 Dynamo KVBM、NIXL、NFSoRDMA 和 GPUDirect Storage 数据路径。该实现不代表 VAST DASE、VAST G4 产品功能、持久性、HA、scale-out 或真实性能。

RAM tier 的 TTFT、吞吐或单次 speedup 不可外推为 VAST benchmark；上线真实 VAST 前必须按其支持矩阵重新验证 client/plugin、mount/export、GDS、multipath/failover、HA、capacity、QoS 和生产负载。
