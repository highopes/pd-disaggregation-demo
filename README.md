# Dynamo P/D + NIXL/UCX/RoCEv2 Demo

本目录保存 Phase 1 的实际配置、备份、验证脚本和非敏感证据。目标是让 Qwen3-14B-FP8 的 Prefill 固定运行在 `csco-k8s-01`，Decode 固定运行在 `csco-k8s-02`，两者通过 ConnectX-7 backend 上的 NIXL/UCX/RoCEv2 传输 KV Cache。

## 最终架构

```text
External client 192.168.160.183
       │  NodePort 192.168.160.113:30080 / no token
       ▼
qwen-openai Service ── Cilium CNP/L7 ── Dynamo Frontend (normal Pod, node3)
                                              │ NATS/ETCD discovery/control
                         ┌────────────────────┴───────────────────┐
                         ▼                                        ▼
Prefill, node1, L4, hostNetwork                    Decode, node2, L4, hostNetwork
Qwen/Qwen3-14B-FP8                                 Qwen/Qwen3-14B-FP8
                         └── NIXL → UCX → RoCEv2 ──┘
                             172.31.230.0/24, CX-7
```

Kubernetes Primary Network 仍是 Cilium/ISOVALENT；仅 worker 的 KV 数据面绑定 CX-7。Frontend 不使用 `hostNetwork`，因此 Service、CNP、Hubble Enterprise/Timescape 和 Prometheus 仍可观察 API 流量。

## 节点与 GPU 角色

| Node | Management IP | GPU 角色 | CX-7 / backend IP | Nexus |
|---|---|---|---|---|
| csco-k8s-01 | 192.168.160.111 | Dynamo Prefill，1 × L4 | ens65np0 / mlx5_0:1 / 172.31.230.111 | Eth1/1/1 |
| csco-k8s-02 | 192.168.160.112 | Dynamo Decode，1 × L4 | ens65np1 / mlx5_0:1 / 172.31.230.112 | Eth1/1/2 |
| csco-k8s-03 | 192.168.160.113 | ComfyUI；Dynamo Frontend CPU Pod（显式固定） | ens65np0 / mlx5_0:1 / 172.31.230.113 | Eth1/2/1 |
| csco-k8s-04 | 192.168.160.114 | foundation-instruct-vllm，1 × L4（显式固定） | ens65np1 / mlx5_0:1 / 172.31.230.114 | Eth1/2/2，物理链路原本 down |

node4 的 CX-7 no-carrier 是任务前既有物理状态；Phase 1 P/D 不依赖该链路。

## 软件与硬件版本

- Kubernetes `v1.31.9`，Ubuntu 24.04.2，kernel 6.11.0-26。
- NVIDIA L4；driver `575.51.03`，CUDA compatibility 12.9；NVIDIA device plugin `0.17.2`。
- Dynamo platform/chart/runtime `1.2.1`；Helm artifact SHA-256 见 [chart-source.md](pd-disaggregation/dynamo/chart-source.md)。
- Worker 实测为 vLLM `0.20.1+cu129`、NIXL `0.10.1`（git `d5c127e5`）、UCX `1.20.1`（CUDA/verbs/gdrcopy）。
- Mellanox RDMA shared device plugin `v1.5.3`，资源名 `rdma/ib`。
- ConnectX-7 MT2910，firmware `28.43.2566`，200G；node1/node2 GPU 与 NIC 同 NUMA、拓扑为 PHB。
- ISOVALENT Cilium `1.18.7-cee.1`；Hubble Enterprise `1.13.4`、Timescape `1.8.4`、Hubble UI `1.3.12`、Tetragon `1.18.0`。
- Nexus `N9K-C9332D-GX2B`，NX-OS `10.4(3)`。

运行时中的 vLLM、NIXL、UCX 精确版本以 worker 内实际命令输出和 `pd-disaggregation/evidence/` 为准。

## RoCE 网络

Backend 是专用 L2 VLAN 2310 `DYNAMO_ROCE_BACKEND`，子网 `172.31.230.0/24`，无 gateway、DNS 或默认路由。ConnectX-7 backend netdev MTU 为 4200，对应 RDMA `active_mtu` 4096。Nexus 物理端口和普通/default traffic class 保持 9216，RoCE/PFC no-drop `qos-group 3` 为 4200，使普通 jumbo 流量与 lossless RDMA class 的最大帧边界彼此独立。

QoS 使用 DSCP 26 → priority/qos-group 3，PFC 只启用 priority 3。UCX 使用 traffic class 106（DSCP 26 加 ECN 位）。实际 IPv4 RoCEv2 GID index 为 3。

主机持久配置在：

- `pd-disaggregation/rdma/netplan/`：四节点 Netplan。
- `pd-disaggregation/rdma/dynamo-roce-qos.sh` 与 `.service`：OS-controlled DCBX、DSCP trust、PFC、MTU。
- `pd-disaggregation/rdma/nvidia-peermem.conf`：只在 P/D 节点加载。

Nexus 的实际配置、端口映射和回滚分别见 `pd-disaggregation/nexus/final-relevant.cfg`、`cx7-port-mapping.md`、`rollback.cfg`。DSCP 26 分类和 PFC cos 3 是既有策略；qos-group 3 MTU 为 4200，端口/default class 为 9216，running-config 与 startup-config 均已验证。

## 从配置目录重建

先运行：

```bash
pd-disaggregation/scripts/preflight.sh
```

### 1. Nexus

只在当前 shell 提供凭据，绝不能写入文件：

```bash
export NEXUS_USERNAME='...'
read -rsp 'Nexus password: ' NEXUS_PASSWORD; export NEXUS_PASSWORD
python3 pd-disaggregation/scripts/nexus_apply.py pd-disaggregation/nexus/desired.cfg
unset NEXUS_PASSWORD
```

脚本不打印凭据。应用前后用 `nexus_read.py` 读取状态。

### 2. 四节点 CX-7

把对应 `netplan/csco-k8s-0X.yaml` 安装为该节点的 `/etc/netplan/95-roce-backend.yaml`，把 QoS 脚本和 unit 分别安装为 `/usr/local/sbin/dynamo-roce-qos.sh` 与 `/etc/systemd/system/dynamo-roce-qos.service`，然后：

```bash
netplan generate
netplan apply
chmod 0755 /usr/local/sbin/dynamo-roce-qos.sh
systemctl daemon-reload
systemctl enable --now dynamo-roce-qos.service
```

仅 node1/node2：

```bash
install -m 0644 pd-disaggregation/rdma/nvidia-peermem.conf /etc/modules-load.d/nvidia-peermem.conf
modprobe nvidia_peermem
```

### 3. Kubernetes RDMA 与 Dynamo platform

```bash
kubectl apply -f pd-disaggregation/rdma/rdma-shared-device-plugin.yaml
kubectl apply -f pd-disaggregation/dynamo/nvidia-runtimeclass.yaml
helm upgrade --install dynamo-platform \
  pd-disaggregation/dynamo/dynamo-platform-1.2.1.tgz \
  -n dynamo-system --create-namespace \
  -f pd-disaggregation/dynamo/platform-values.yaml
```

本环境已有可工作的 NVIDIA driver、container toolkit、containerd runtime 和 GPU device plugin；不要安装 GPU Operator 覆盖它们。

### 4. 慢速互联网镜像

普通 containerd pull 在大层续开时曾因 NVCR 认证 realm 切换而 401，并丢弃 partial。使用可恢复方式：

```bash
sudo pd-disaggregation/scripts/resumable-nvcr-pull.sh \
  nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1
sudo pd-disaggregation/scripts/copy-image-over-roce.sh \
  nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1 root@172.31.230.112

sudo pd-disaggregation/scripts/resumable-nvcr-pull.sh \
  nvcr.io/nvidia/ai-dynamo/dynamo-frontend:1.2.1
sudo pd-disaggregation/scripts/copy-image-over-roce.sh \
  nvcr.io/nvidia/ai-dynamo/dynamo-frontend:1.2.1 root@172.31.230.113
```

下载器只把短期 registry token 通过 stdin 交给 curl，不打印或持久化；blob partial 位于 `/tmp/dynamo-nvcr-resume/`。复制脚本先验证路由确实走 CX-7，再以 OCI tar stream 导入远端 containerd，不产生中间大 tar。

### 5. P/D、Service 与 CNP

```bash
kubectl apply --dry-run=client -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl apply --dry-run=server -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl apply -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml

kubectl apply --dry-run=server -f pd-disaggregation/cilium/frontend-service-policy.yaml
kubectl apply -f pd-disaggregation/cilium/frontend-service-policy.yaml
```

Prefill/Decode 均请求和限制 `nvidia.com/gpu: 1`、`rdma/ib: 1`，使用 hostNetwork 和固定 nodeSelector；Frontend 是普通 Cilium Pod。两端模型、dtype、TP、block size、max model length 和 `NixlConnector/kv_both` 配置一致。worker 健康端口为 `19191`，避免与 node2 既有的 9090 监听冲突。UCX 显式设置 `UCX_TLS=rc_x,rc,cuda_copy,cuda_ipc`、`UCX_NET_DEVICES=mlx5_0:1`、GID 3、traffic class 106；没有把 `tcp` 放入 transport list。

Frontend 也显式使用 `nodeSelector` 固定在 `csco-k8s-03`。这是 `qwen-openai` 使用 `externalTrafficPolicy: Local` 的必要配套：Frontend 重建后不会漂移，F5 的 NodePort pool member 可稳定配置为 `192.168.160.113:30080`。

## API 与企业版可观测性

为兼容 Dynamo 原生服务发现和旧 Qwen3-14B 客户端，Frontend 同时由两个 Service 暴露：

- `qwen3-14b-pd-frontend`：Dynamo operator 创建的集群内 ClusterIP Service。
- `qwen-openai`：保留旧 Qwen3-14B 的服务名、ClusterIP/NodePort 30080 和 `app: qwen-openai` label，兼容既有 F5、客户端和 ServiceMonitor。

两个 Service 的 selector 不同，但最终都解析到同一个 Dynamo Frontend Pod/Endpoint；它们不是两套后端，也不会重复占用模型/GPU。

`qwen-openai` 使用 `externalTrafficPolicy: Local` 保存真实外部源地址；NodePort 应访问固定运行 Frontend 的 node3，即 `192.168.160.113:30080`。

`foundation-instruct-openai` 同样使用源地址型 CNP，因此也设置为 `externalTrafficPolicy: Local`。其 Deployment 显式固定 `csco-k8s-04`，F5 pool member 应稳定配置为 `192.168.160.114:30083`。由于 node4 只有一张被 Foundation 独占的 GPU，Deployment 使用 `Recreate` 策略，避免滚动升级时新旧 Pod 争抢唯一 GPU。

CNP 行为：

- 集群内部：无需 API key，可访问 `/v1/*`；Prometheus/健康检查可访问 `/metrics`、`/health`、`/live`。
- 互联网反向代理 `192.168.200.8/32`：访问 `/v1/*` 时必须匹配现有 Secret 引用的 `Authorization` header。
- 其他直连数据中心来源（包括 `192.168.160.183/32`）：不经过互联网反向代理，无需 Token 即可访问 `/v1/*`。
- worker 通过 host/remote-node identity 回连 Frontend 的动态 Dynamo response/control 端口；外部来源仍只允许 8000。

真实测试：

```bash
pd-disaggregation/scripts/validate-api.sh
EXTERNAL_CLIENT_SSH=root@192.168.160.183 \
  pd-disaggregation/scripts/validate-api.sh
```

脚本只验证集群内和 `192.168.160.183` 的无 Token 访问，不读取 Secret。由于本环境无法操作互联网反向代理服务器，反向代理端到端 Token 测试按任务要求跳过；CNP 中的 Secret 引用和强制匹配规则仍保留，Secret 值不读取、不输出、不落盘。

本任务不安装社区版 Cilium/Hubble/Tetragon 工具。`validate-hubble-enterprise.sh` 只调用现有 CEE agent 镜像内置的同版本 `hubble v1.18.7-cee.1`；同时可在现有 Hubble UI Enterprise NodePort 31235、Timescape 和 Prometheus/Grafana 看板观察。

## 验证与证据

```bash
pd-disaggregation/scripts/validate-roce.sh
pd-disaggregation/scripts/validate-gdr.sh
pd-disaggregation/scripts/validate-dynamo.sh
pd-disaggregation/scripts/validate-api.sh
pd-disaggregation/scripts/validate-hubble-enterprise.sh
```

### 如何证明真正 P/D

不能只看 HTTP 200。应把同一请求的 request/trace 标识与 Frontend、Prefill、Decode 日志对应，确认 Prefill 在 node1、Decode 在 node2，并出现 KV transfer/NIXL 记录。

### 如何证明 KV 经过 RoCE

对长 prompt 在请求前后分别记录 node1/node2 `ethtool -S`、`rdma statistic` 和 Nexus Eth1/1/1、Eth1/1/2 counters。CX-7 的 RDMA/priority-3 byte delta 与请求一致，management NIC 不应出现相当的数据量。

### 如何证明 NIXL 使用 UCX 而非 TCP

worker 日志应包含 NIXL UCX backend 初始化，且无 TCP fallback；`UCX_TLS` 不含 tcp。再用 `ucx_perftest` 和实际 KV transfer 验证 `mlx5_0:1`。

### 如何证明 GPUDirect RDMA

`nvidia_peermem` 只是前提。必须同时满足：worker 有 GPU 和 `/dev/infiniband`；`ucx_info -d` 的 mlx5 memory domain 显示 `cuda (access,reg,cache)`；CUDA-memory `ucx_perftest` 成功并走 RC/RoCE；真实 NIXL KV transfer 与 CX-7 counters 相关。若只看到 host memory，应判定为 host staging/PARTIAL PASS。

RoCE 基准已实测 MTU 4200 的 DF ping 0 loss；此前带 traffic class 106 的 `ib_write_bw` 为 109.85 Gbit/s，RDMA path MTU 在改进前后均为 4096。详情见 [roce-baseline.md](pd-disaggregation/evidence/roce-baseline.md)。

最终真实 P/D、CUDA-memory UCX、长 Prompt 计数器、Pod 重建、API、Hubble 与保留服务结果见 [phase1-final-validation.md](pd-disaggregation/evidence/phase1-final-validation.md)。Phase 1 验收为 PASS。

保留服务回归中，Foundation 实际 API 返回 HTTP 200。ComfyUI 必须通过认证网关访问，因此本任务只确认其 workload 存在、主 Pod `2/2 Running`、认证网关 Pod `1/1 Running`；不绕过认证网关做 ComfyUI 直连 HTTP 测试。

## Troubleshooting

- `RuntimeClass "nvidia" not found`：containerd 已有 nvidia handler，但 KAI 会注入 RuntimeClass；应用 `nvidia-runtimeclass.yaml`。
- KAI scheduler 报 `Unauthorized`：Helm upgrade 可能重建 ServiceAccount，而旧 scheduler Pod 仍持有绑定旧 UID 的 token；只滚动 `deployment/kai-scheduler-default`，不要改 RBAC。
- NVCR 长层在 401 后从 0 开始：使用 `resumable-nvcr-pull.sh`；根因和 challenge 见 [image-download-recovery.md](pd-disaggregation/evidence/image-download-recovery.md)。
- node4 backend down：先修物理链路；不要把任务前 no-carrier 当作软件回归。
- Local NodePort 返回无后端：F5 必须访问实际承载 Pod 的固定节点；Qwen 使用 node3:30080，Foundation 使用 node4:30083，不要把所有节点都无差别加入这两个 Local Service 的 pool。
- PFC pause counter 为 0：无拥塞时是正常现象；仍需确认 PFC operational bitmap、priority mapping、error/discard 为 0。
- Hubble：只使用 CEE agent 内置 CLI或现有 Enterprise UI/Timescape，不向企业版集群安装社区 chart/CLI。
- 当前集群有两套 Prometheus Operator（v0.55.1 与 v0.82.2）跨命名空间 reconcile，造成部分第二副本反复重建；现有 `prometheus-k8s-0` 仍为 `2/2 Running`。本任务未改动这些 operator/CR，修复时应先划分各 operator 的 watch scope，不能在本 Demo 中直接删除其中一套。

## 回滚

完整顺序和命令见 [ROLLBACK.md](pd-disaggregation/ROLLBACK.md)。备份位于 `pd-disaggregation/backup/`，包括旧 Qwen、旧 Dare、共享资源记录和改造前 CNP；Secret 值未导出。

## Phase 范围

Phase 1 包含 Dynamo P/D、NIXL/UCX/RoCEv2、CX-7/Nexus lossless fabric、GPUDirect RDMA、按来源区分的 Cilium API 访问控制、企业版 Hubble/Timescape 可观测性、Pod 重建与保留服务回归。

Phase 2 尚未实施：VAST G4 KV Cache Storage、KV offload/reload 和 GPUDirect Storage 均不在本阶段范围内。
