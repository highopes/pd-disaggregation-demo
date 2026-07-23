# Phase 1 final validation

时间：2026-07-23（Asia/Shanghai）。以下均为当前实际环境的实测结果；未记录任何 Nexus 凭据、registry token 或 API Secret 值。

## 结论

Dynamo P/D + NIXL/UCX/RoCEv2 + GPUDirect RDMA 的 Phase 1 验收为 **PASS**。互联网反向代理的端到端 Token 测试按任务澄清允许跳过；对应 CNP Secret 引用与强制匹配规则仍存在。

## 最终 workload 与角色

| 组件 | 节点 | 最终状态 |
|---|---|---|
| Dynamo Frontend | csco-k8s-03 | DGD Ready=True，Pod 1/1 Running |
| VllmPrefillWorker | csco-k8s-01 | Pod 1/1 Running，0 restart，1 × L4，`rdma/ib=1` |
| VllmDecodeWorker | csco-k8s-02 | Pod 1/1 Running，0 restart，1 × L4，`rdma/ib=1` |
| foundation-instruct-vllm | csco-k8s-04 | Pod 1/1 Running，0 restart；API HTTP 200 |
| ComfyUI | csco-k8s-03 | 主 Pod 2/2 Running，0 restart |
| ComfyUI auth gateway | csco-k8s-04 | Pod 1/1 Running |

ComfyUI 必须经认证网关访问。本次最终回归只确认 workload、Pod 与容器 Ready，没有绕过认证网关执行直连 HTTP。

旧 `qwen-vllm` 与 `dare-foundation-vllm` 专属 workload 已拆除；共享 Service、PVC、Secret 与保留 workload 未删除。

运行时实测版本：Dynamo `1.2.1`、vLLM `0.20.1+cu129`、NIXL `0.10.1`（git `d5c127e5`）、UCX `1.20.1`。Prefill/Decode 都运行 `Qwen/Qwen3-14B-FP8`，均配置 `NixlConnector`、`kv_role=kv_both`。

## GPUDirect RDMA 与 UCX

- P/D 节点均加载 `nvidia_peermem`，worker 可见 NVIDIA L4 与 `/dev/infiniband`。
- `ucx_info -d` 的 `mlx5_0` memory domain 显示 CUDA registration/cache，并同时提供 `rc_mlx5`/`rc_verbs`、`cuda_copy`、`cuda_ipc`。
- CUDA-memory `ucx_perftest` 使用 64 MiB、100 iterations；UCX 明确选择 `tag(rc_mlx5/mlx5_0:1)`，结果为 `4663.53 MB/s`。
- worker 使用 `UCX_TLS=rc_x,rc,cuda_copy,cuda_ipc`；transport list 不含 `tcp`，NIXL 加载 UCX backend。

## 真实 P/D 与 KV transfer

小请求 `0d878785-29ca-4bad-9a55-0d275ba63df1` 同时出现在 Frontend、node1 Prefill 和 node2 Decode。Frontend 成功完成请求；Decode 报告 NIXL compatibility check passed，20 MiB KV transfer 为 26.414 ms、757.174 MB/s。

长请求 `997c523a-f2c9-4804-9ade-802c017c894c` 包含 4522 个输入 token、8 个输出 token，HTTP 200，总耗时约 3.05 秒。Decode NIXL metrics：

```text
Num successful transfers=1
Avg MB per transfer=720.0
Avg xfer time=240.698 ms
Throughput=2991.3 MB/s
```

手工删除两个 worker Pod 后，Grove 在原固定节点用本地镜像/模型缓存重建成功。重建后的请求 `cf114b70-ed27-4ac1-b674-922c9c91d04a` 再次同时出现在 Frontend、Prefill 和 Decode；NIXL compatibility passed，20 MiB KV transfer 为 48.683 ms、410.821 MB/s，Frontend HTTP 200。随后从 `192.168.160.183` 发起的无 Token 聊天请求也返回 HTTP 200。

## 长 Prompt 的 RoCE/PFC 计数器增量

请求前后严格取 delta：

| 位置 | 关键增量 |
|---|---|
| node1 CX-7 | `tx_vport_rdma_unicast_bytes +765,667,142`；`tx_prio3_bytes +766,404,474`；RDMA/prio packets `+184,333` |
| node2 CX-7 | `rx_vport_rdma_unicast_bytes +765,668,302`；`rx_prio3_bytes +766,404,474`；prio packets `+184,333` |
| Nexus Eth1/1/1 | input bytes `+766,405,221`；jumbo packets `+184,320` |
| Nexus Eth1/1/2 | output bytes `+766,408,579`；jumbo packets `+184,320` |
| PFC | Eth1/1/1 TxPPP `+3898`；Eth1/1/2 RxPPP `+1620` |

CRC、discard、priority-3 discard、buffer/congestion error 与 pause-storm error 的 delta 均为 0。上述方向、字节量和 PFC 计数与 node1 Prefill 向 node2 Decode 传输约 720 MiB KV 一致。

## API 与 Cilium

- `qwen-openai` NodePort 为 `192.168.160.113:30080`，`externalTrafficPolicy: Local` 保存源地址。
- 集群内不带 Token 的 `/v1/models`：HTTP 200。
- 直连数据中心客户端 `192.168.160.183` 不带 Token 的 `/v1/models`：HTTP 200。
- 同一客户端不带 Token 的 `/v1/chat/completions`：HTTP 200，实际模型完成推理。
- 互联网反向代理 `192.168.200.8/32` 的 `/v1/*` 仍由 CNP `dynamo-qwen-frontend-api` 引用 `vllm-api-token` 执行 header match；未读取 Secret 值。
- CNP 状态 Valid=True。CEE Hubble 捕获到 `.183 (world) -> Frontend:8000 GET /v1/models FORWARDED`。

## RoCE 与持久化

- VLAN 2310；Linux MTU 9000；Nexus/no-drop queue MTU 9216；DSCP 26 → qos-group/priority 3；PFC cos 3。
- jumbo DF ping（payload 8972）双向成功；`ib_write_bw` traffic class 106 实测 `109.85 Gbit/s`。
- 四节点 `dynamo-roce-qos.service` 均 enabled/active；Netplan、QoS 脚本和 systemd unit 均落盘。
- P/D 节点 `nvidia_peermem` 已加载；四节点均发布 `rdma/ib=1` 与 `nvidia.com/gpu=1`。
- Nexus startup-config 已保存四端口的 VLAN 2310、MTU 9216、PFC、QOS_CLASSIFICATION，以及 network-qos 中 cos 3 PFC/no-drop 与 MTU 9216。

## 企业版可观测性与已知环境问题

只使用现有 CEE agent 内置 `hubble v1.18.7-cee.1`、Hubble UI Enterprise、Timescape Enterprise 与现有 Prometheus/Grafana；没有安装任何社区版 Cilium/Hubble/Tetragon 工具。Hubble health 为 OK，UI NodePort 返回 HTTP 200，四个 hubble-enterprise agent 和 Timescape 均 Running。

当前集群的 Prometheus v0.55.1 与 v0.82.2 两套 operator 同时跨命名空间 reconcile，造成部分第二副本反复重建；`prometheus-k8s-0` 仍为 2/2 Running 并抓取 Frontend `/metrics`。本任务未修改这些 operator/CR；后续应通过限定 watch scope 单独治理，不能直接归因于本次 `ai-serving` CNP。
