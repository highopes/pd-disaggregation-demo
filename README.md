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

Kubernetes Primary Network 仍是 Cilium/ISOVALENT；仅 worker 的 KV 数据面绑定 CX-7。Frontend 不使用 `hostNetwork`，因此 Service、CNP、Hubble UI Enterprise 和 Prometheus/Grafana 仍可观察 API 流量。Timescape 组件保持部署，但本指南不使用 Timescape UI。

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

本任务不安装社区版 Cilium/Hubble/Tetragon 工具。`validate-hubble-enterprise.sh` 只调用现有 CEE agent 镜像内置的同版本 `hubble v1.18.7-cee.1`。Hubble UI Enterprise 的后端是现有 NodePort 31235，但人员访问应继续使用当前已经工作正常的 F5 反向代理地址；不要为演示新增或修改 NodePort、Ingress、F5、Cilium 或其他网络配置。Grafana 使用现有 fsomonitor Grafana。

## 验证与证据

本节面向实际执行验收的工程师。目标不是单纯取得 HTTP 200，而是分别证明：资源与调度正确、P/D 确实发生、KV 使用 NIXL/UCX、数据面是 RoCE 而非 TCP、CUDA memory 能被 UCX/RDMA 注册、API/CNP 边界正确，以及企业版 Hubble/Prometheus 能观察业务。

除特别标记为“主动压力测试”的命令外，现有脚本都是只读检查：它们执行 `kubectl get`、`kubectl logs`、`kubectl exec` 内的查询命令，或发起一个只读 `/v1/models` 请求，不会修改 Kubernetes、Nexus、F5 或主机网络。

### 验证脚本速查

| 脚本 | 实际执行的功能 | 成功时应关注什么 | 不能单独证明什么 |
|---|---|---|---|
| `preflight.sh` | 检查 Kubernetes/Helm、四节点 GPU 与 `rdma/ib`、Dynamo platform、RDMA plugin、RuntimeClass、CRD 和共享 PVC | Helm deployed；四节点各有 GPU/RDMA；platform Pod Ready；PVC Bound | 不发推理请求，不检查 KV 传输 |
| `validate-roce.sh` | 在 P/D worker 内查看 IP、RDMA link、`ibv_devinfo`、`/dev/infiniband` 和 `UCX_*` 环境变量 | `mlx5_0`、Ethernet、active MTU 4096、RDMA device 可见；`UCX_TLS` 不含 `tcp` | 名称虽叫 RoCE validation，但不会主动跑 ping 或带宽测试 |
| `validate-gdr.sh` | 查看 worker 的 L4/driver/PCI 信息与 `ucx_info -d` memory domain/transport | mlx5 memory domain 包含 CUDA registration/cache；可见 `rc_mlx5`/`rc_verbs` 与 CUDA transport | 证明的是 GDR 能力前提；不等同于实际 CUDA buffer 已跨机传输 |
| `validate-dynamo.sh` | 查看 DGD/Grove、Pod、两个 Qwen Service/Endpoint，以及 Frontend/P/D 的 NIXL、UCX、routing、request 日志 | DGD Ready；Frontend/node3、Prefill/node1、Decode/node2；NIXL 加载 UCX；同一 request UUID 可跨三端关联 | 日志中的 Dynamo TCP request/control plane 不等于 KV data plane TCP fallback |
| `validate-api.sh` | 集群内访问 `/v1/models`；设置 `EXTERNAL_CLIENT_SSH` 后，从 `.183` 不带 Token 访问 NodePort | `internal_http=200`、`external_no_key_http=200` | 按任务范围不测试无法控制的互联网反向代理服务器 |
| `validate-hubble-enterprise.sh` | 在 Frontend 所在节点调用 CEE agent 内置 Hubble CLI，检查版本、健康和最近 10 分钟 HTTP flow | `v1.18.7-cee.1`、Healthcheck Ok、目标 Frontend flow 为 FORWARDED | 不安装外部 CLI；Hubble API flow 本身不能证明 KV 走 RDMA |

### 0. 建立一次验收记录目录

在 `csco-k8s-01`、仓库根目录执行：

```bash
cd /root/ns_ai-serving
umask 077
run_id=$(date +%Y%m%d-%H%M%S)
evidence_dir="pd-disaggregation/evidence/runs/$run_id"
mkdir -p "$evidence_dir"
printf 'run_id=%s\nstarted_at=%s\n' "$run_id" "$(date --iso-8601=seconds)" \
  | tee "$evidence_dir/run-info.txt"
```

不要把 `NEXUS_PASSWORD`、API Token、Grafana/F5 登录信息、Secret YAML 或 curl Authorization header 保存进证据目录。Pod 名和 Endpoint IP 会在重建后变化，因此证据应同时记录时间、namespace、role 和 node，不能只记录 Pod 名。

### 1. 前置资源与调度检查

```bash
pd-disaggregation/scripts/preflight.sh \
  |& tee "$evidence_dir/01-preflight.txt"

pd-disaggregation/scripts/validate-dynamo.sh \
  |& tee "$evidence_dir/02-dynamo-state-and-logs.txt"
```

`preflight.sh` 从 Kubernetes allocatable resource 和实际 platform Pod 两侧交叉确认“资源已注册且控制面已运行”。期望结果：

- `dynamo-platform` Helm release 为 deployed；operator、Grove、KAI、NATS、ETCD 都 Ready。
- `csco-k8s-01` 至 `04` 均发布 `nvidia.com/gpu=1`、`rdma/ib=1`。
- RDMA shared device plugin 四节点 Ready；`RuntimeClass/nvidia` 存在。
- `ai-serving/hf-cache-pvc` 为 Bound。
- DGD `qwen3-14b-pd` Ready；Frontend 固定 node3、Prefill 固定 node1、Decode 固定 node2。

此前实测 DGD 为 Ready=True，三个 Dynamo Pod 均为 1/1 Running；重建后的 P/D Pod 为 0 restart。`qwen-openai` 和 `qwen3-14b-pd-frontend` 虽然 selector 不同，但 Endpoint 相同。

### 2. RoCE 设备、MTU 与 UCX 约束

先运行低风险的容器内检查：

```bash
pd-disaggregation/scripts/validate-roce.sh \
  |& tee "$evidence_dir/03-roce-worker-state.txt"
```

预期能看到：Prefill 位于 node1、Decode 位于 node2；`mlx5_0` port 1 为 Ethernet、active MTU 4096；`/dev/infiniband` 存在；`UCX_NET_DEVICES=mlx5_0:1`、GID index 3、traffic class 106；`UCX_TLS=rc_x,rc,cuda_copy,cuda_ipc`，其中没有 `tcp`。

脚本不主动产生 RoCE 流量。MTU 连通性需人工验证，4200 Ethernet MTU 对应 IPv4 DF ping payload 4172：

```bash
ssh root@192.168.160.111 \
  'ping -I 172.31.230.111 -M do -s 4172 -c 3 -W 2 172.31.230.112'

ssh root@192.168.160.112 \
  'ping -I 172.31.230.112 -M do -s 4172 -c 3 -W 2 172.31.230.111'
```

期望两边均显示 `3 packets transmitted, 3 received, 0% packet loss`。此前 node1→node2 实测 3/3、0% loss，RDMA active MTU 为 4096。

交换机只读检查需要在当前 shell 设置 `NEXUS_USERNAME`、`NEXUS_PASSWORD`，脚本不会打印或保存它们：

```bash
python3 pd-disaggregation/scripts/nexus_read.py \
  'show policy-map system type network-qos' \
  'show running-config interface Ethernet1/1/1' \
  'show running-config interface Ethernet1/1/2' \
  |& tee "$evidence_dir/04-nexus-roce-state.txt"
```

预期 RoCE no-drop `qos-group 3` 为 MTU 4200、PFC cos 3；default class 与物理端口为 9216。此前 running/startup-config 均已得到这一结果。

### 3. GPUDirect RDMA 能力与主动 CUDA-memory 测试

先执行无压力的能力检查：

```bash
pd-disaggregation/scripts/validate-gdr.sh \
  |& tee "$evidence_dir/05-gdr-capability.txt"
```

成功输出应包含 NVIDIA L4、driver 575.51.03，以及 mlx5 memory domain 对 CUDA memory 的 registration/cache 支持。`cuda_copy` 只能说明 CUDA memory transport 可用；真正的 GDR 强证据还需要 CUDA-memory `ucx_perftest`。

以下测试会实际占用两张 L4 和 RoCE 链路，只在无业务或演示维护窗口执行。打开两个终端。

终端 A（Prefill/server）：

```bash
prefill=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=prefill' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ai-serving -it "$prefill" -- \
  sh -lc 'ucx_perftest -p 13337'
```

终端 B（Decode/client）：

```bash
decode=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=decode' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ai-serving "$decode" -- \
  sh -lc 'UCX_LOG_LEVEL=info ucx_perftest 172.31.230.111 -p 13337 -t tag_bw -m cuda -s 67108864 -n 100'
```

验证重点不是只看一个带宽数字，而是日志必须明确选择 `tag(rc_mlx5/mlx5_0:1)`，memory type 为 CUDA，并且没有 TCP transport。此前使用 64 MiB、100 iterations 的实测结果为 `4663.53 MB/s`。测试结束后在终端 A 按 Ctrl-C。

### 4. API 边界与实际推理请求

先跑轻量 API 检查：

```bash
pd-disaggregation/scripts/validate-api.sh \
  |& tee "$evidence_dir/06-api-internal.txt"

EXTERNAL_CLIENT_SSH=root@192.168.160.183 \
DYNAMO_ENDPOINT=http://192.168.160.113:30080 \
  pd-disaggregation/scripts/validate-api.sh \
  |& tee "$evidence_dir/07-api-external-183.txt"
```

预期输出：

```text
internal_http=200
external_no_key_http=200
```

这是正确的访问模型：`.183` 是不经过互联网反向代理的直连数据中心客户端，因此无需 Token。互联网反向代理来源仍由 CNP 的 Secret header match 强制认证；由于本环境不能控制互联网服务器，其端到端测试不在本验收范围。

为了验证真实推理而不仅是 `/v1/models`，可从 node1 生成长 prompt，并让 curl 实际在 `.183` 上执行：

```bash
request_tag="pd-evidence-$(date +%s)"
long_prompt=$(printf '分布式推理需要高带宽、低延迟、可观测和可恢复。%.0s' {1..600})

jq -n --arg prompt "$long_prompt" \
  '{model:"Qwen/Qwen3-14B-FP8",messages:[{role:"user",content:$prompt}],max_tokens:8,temperature:0}' \
  | ssh root@192.168.160.183 \
      "curl --connect-timeout 10 --max-time 120 -sS \
       -H 'Content-Type: application/json' \
       -H 'X-Request-ID: $request_tag' \
       --data-binary @- \
       -w '\nhttp=%{http_code} total=%{time_total}s\n' \
       http://192.168.160.113:30080/v1/chat/completions" \
  | tee "$evidence_dir/08-long-prompt-response.txt"
```

期望得到 OpenAI-compatible JSON、`http=200`、模型名和 token usage。此前长请求包含 4522 个输入 token、8 个输出 token，HTTP 200，总时间约 3.05 秒。

### 5. 证明 Prefill 与 Decode 真正分离

在长请求后立即运行：

```bash
pd-disaggregation/scripts/validate-dynamo.sh \
  |& tee "$evidence_dir/09-post-request-dynamo-logs.txt"
```

人工关联方法：

1. 在 Frontend 最近日志中找到刚才的 `X-Request-ID`。
2. 从同一条或相邻日志复制 Dynamo 内部 `request_id` UUID。
3. 在 Prefill 和 Decode 最近 15 分钟日志中搜索同一 UUID。
4. 确认 Prefill Pod 在 node1、Decode Pod 在 node2，并在 Decode 看到 NIXL compatibility/transfer metrics。

```bash
frontend=$(kubectl get pod -n ai-serving -l 'app=dynamo-qwen-frontend' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n ai-serving "$frontend" --since=15m | grep "$request_tag"

# 从上一条输出复制实际 UUID 后替换占位符。
request_uuid='<DYNAMO_REQUEST_UUID>'
for role in prefill decode; do
  pod=$(kubectl get pod -n ai-serving \
    -l "nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=$role" \
    -o jsonpath='{.items[0].metadata.name}')
  kubectl logs -n ai-serving "$pod" --since=15m | grep "$request_uuid"
done
```

节点时钟曾存在约百秒偏差，因此 UUID 比时间戳更可靠。此前结果可供对照：

- 小请求 UUID `0d878785-29ca-4bad-9a55-0d275ba63df1` 同时出现在三端；20 MiB KV 为 26.414 ms、757.174 MB/s。
- 长请求 UUID `997c523a-f2c9-4804-9ade-802c017c894c` 同时出现在三端；720 MiB KV 为 240.698 ms、2991.3 MB/s。
- worker 重建后的 UUID `cf114b70-ed27-4ac1-b674-922c9c91d04a` 再次贯穿三端，证明重建后 P/D 仍有效。

注意：Dynamo 用 TCP 承载 request/control plane 是正常设计。`TCP fallback` 的否定结论只针对 NIXL KV data plane，判断依据是 UCX transport、NIXL transfer 和 CX-7 counters，而不是日志中完全不能出现单词 TCP。

### 6. 用计数器证明 KV 经过 CX-7/RoCE

这是强证据测试，应在业务安静窗口完成“before → 单个长请求 → after”。`validate-roce.sh` 不会自动收集这些 delta。

请求前分别保存 P/D 主机计数器：

```bash
ssh root@192.168.160.111 \
  "ethtool -S ens65np0 | egrep 'vport_rdma|prio3|discard|crc|pause'; rdma statistic show link mlx5_0/1" \
  | tee "$evidence_dir/10-node1-counters-before.txt"

ssh root@192.168.160.112 \
  "ethtool -S ens65np1 | egrep 'vport_rdma|prio3|discard|crc|pause'; rdma statistic show link mlx5_0/1" \
  | tee "$evidence_dir/11-node2-counters-before.txt"

python3 pd-disaggregation/scripts/nexus_read.py \
  'show interface Ethernet1/1/1 counters' \
  'show interface Ethernet1/1/2 counters' \
  'show interface priority-flow-control' \
  |& tee "$evidence_dir/12-nexus-counters-before.txt"
```

发送第 4 步的单个长 prompt，然后以相同命令保存 `after` 文件。计算 delta 时重点看：

- node1 `tx_vport_rdma_unicast_bytes`、`tx_prio3_bytes` 增加。
- node2 `rx_vport_rdma_unicast_bytes`、`rx_prio3_bytes` 增加相近字节量。
- Nexus Eth1/1/1 input 与 Eth1/1/2 output 增加相近字节量。
- priority 3 discard、CRC、RDMA error、pause storm 等错误 delta 为 0。
- 有拥塞时 PFC pause 增加是有效 lossless 证据；没有拥塞时 pause=0 也不代表失败。

此前 720 MiB KV 请求的对照值：node1 RDMA TX `+765,667,142` bytes，node2 RDMA RX `+765,668,302` bytes；两侧 priority-3 与 Nexus 对应方向约增加 766.4 MB；Nexus jumbo packets `+184,320`，所有关键 error/discard delta 为 0。

### 7. 企业版 Hubble flow 证据

先从 `.183` 发一个 `/v1/models` 或 chat 请求，随后立即运行：

```bash
pd-disaggregation/scripts/validate-hubble-enterprise.sh \
  |& tee "$evidence_dir/13-hubble-enterprise.txt"
```

原理是直接复用 Frontend 所在 node3 的 CEE agent 内置 Hubble CLI，不引入任何社区版二进制。预期输出包括：

```text
hubble v1.18.7-cee.1
Healthcheck ... Ok
Current/Max Flows: 4095/4095
192.168.160.183 (world) -> Frontend:8000 ... FORWARDED
```

此前实测捕获到 `.183 (world) -> ai-serving Frontend:8000 GET /v1/models FORWARDED`，并观察到 Prometheus 对 `/metrics` 的 FORWARDED 流量。

图形化检查使用当前经 F5 发布、已经工作正常的 Hubble UI Enterprise URL。不要为验证改动 F5、NodePort 31235 或任何网络策略。在 UI 中选择最近 5–15 分钟，并逐步过滤：

- Namespace：`ai-serving`。
- Destination：当前 Dynamo Frontend Pod/workload。
- Protocol/L7：HTTP。
- Path：`/v1/models` 或 `/v1/chat/completions`。
- Verdict：`FORWARDED`。
- Source：`.183`/external/world（以 UI 实际显示字段为准）。

Hubble UI Enterprise 证明 API 流量、来源、L7 method/path、策略 verdict 和服务依赖关系；它不负责证明 hostNetwork worker 间 KV 使用 RDMA，后者必须使用第 5、6 步的 NIXL 与硬件计数器证据。

### 8. Prometheus/Grafana 证据

两个模型 ServiceMonitor 的抓取周期为 30 秒。可用 Kubernetes service proxy 检查 target，无需暴露新端口：

```bash
kubectl get --raw \
  '/api/v1/namespaces/fsomonitor/services/http:fsomonitor-kube-prometheus-prometheus:9090/proxy/api/v1/targets' \
  | jq -r '.data.activeTargets[]
    | select((.labels.namespace//"")=="ai-serving")
    | [.health,.labels.job,.labels.service,.scrapeUrl,.lastError]
    | @tsv' \
  | tee "$evidence_dir/14-prometheus-targets.txt"
```

此前实测 `qwen-openai` 与 `foundation-instruct-openai` target 均为 `up`。若刚产生流量但 Grafana 尚无变化，等待至少一个 30 秒 scrape interval，并把 Dashboard 时间范围设为 Last 15 minutes、刷新间隔设为 5–10 秒。

fsomonitor Grafana 当前已有以下适合本项目的 Dashboard，可按标题搜索，也可用 UID 定位：

| Dashboard | UID | 建议用途 |
|---|---|---|
| Hubble L7 HTTP Metrics by External Source IP | `hubble-l7-external-source-ip` | 按 `.183` 展示外部请求量、成功率、响应码和平均时延 |
| Hubble L7 HTTP Metrics by Workload | `3g264CZVz` | 按 `ai-serving`/Frontend workload 展示流量、p50/p95/p99、source/destination |
| Hubble / Network Overview (Namespace) | `nlsO8tYVz` | 展示 namespace flow、verdict、drop、top source/destination |
| Hubble Metrics and Monitoring | `5HftnJAWz` | 展示 HTTP、DNS、forward/drop 和 Hubble processing 状态 |
| Cilium Metrics | `vtuWtdumz` | 展示 endpoint、policy、forward/drop、BPF 与 Cilium 健康 |

Grafana 使用现有访问地址和现有登录凭据，不要把凭据写进 README 或证据文件。优先设置：destination namespace=`ai-serving`、destination workload=Frontend 下拉框的实际值、source IP=`192.168.160.183`、reporter=`destination`（如该变量存在）。

### 9. 验收结论与证据包

一次完整验收至少应留下：

1. preflight/DGD/Pod/Service/Endpoint 文本输出。
2. RoCE/UCX/GDR capability 与可选 CUDA-memory perftest 输出。
3. 一个实际 chat completion 响应及 HTTP code/耗时。
4. 同一 Dynamo request UUID 在 Frontend、Prefill、Decode 的日志片段。
5. 长请求前后的 CX-7/RDMA/Nexus counters 与人工计算 delta。
6. CEE Hubble CLI 的 FORWARDED flow。
7. Hubble UI Enterprise 和 Grafana 的截图，截图中包含时间范围与过滤条件。
8. 明确的 PASS/PARTIAL PASS/FAIL 和未完成项，不能用截图代替结论。

此前完整结果见 [phase1-final-validation.md](pd-disaggregation/evidence/phase1-final-validation.md)：Phase 1 为 PASS；CUDA-memory UCX 为 4663.53 MB/s，RoCE `ib_write_bw` 历史基准为 109.85 Gbit/s，真实 720 MiB KV transfer 为 2991.3 MB/s。合成 RDMA 带宽、CUDA-memory 带宽和真实 KV 吞吐是不同指标，不应在报告中混为同一个性能数字。

保留服务回归中，Foundation API 返回 HTTP 200。ComfyUI 必须通过认证网关访问，因此只检查其 workload、Pod 和容器 Ready；不要绕过认证网关做 ComfyUI 直连测试。

## CxO 演示

本节用于 10–15 分钟管理层演示。重点是展示“一套稳定 API 如何由两台 GPU 节点分工完成推理，并且流量、性能和策略都可观察”，不在现场讲解每条 UCX 参数，也不在现场进行破坏性 Pod 删除、交换机修改或满带宽 benchmark。

### 演示前准备

- 浏览器打开当前经 F5 反向代理发布的 Hubble UI Enterprise 地址。沿用现有地址和认证方式，不修改 F5、NodePort 或网络策略。
- 浏览器打开现有 fsomonitor Grafana；预先收藏 External Source IP、L7 by Workload 和 Network Overview Dashboard。
- Grafana 时间范围设为 Last 15 minutes，auto refresh 设为 5–10 秒。
- 准备两个终端：一个在 `.183` 发请求，一个在 node1 执行只读 `kubectl`/logs。
- 先发一个短请求完成模型 warm-up，并确认 Qwen API HTTP 200；不要把模型首次加载时间放进业务时延演示。
- 演示前清空 Hubble UI 过滤条件，再设置 namespace=`ai-serving`，确保稍后能看到新请求。

### 1. 用一张图讲清架构（1 分钟）

向观众说明：客户端仍然只看到旧兼容服务 `qwen-openai`，无需知道后端已拆成三部分。

```text
Client / existing ecosystem
        |
qwen-openai (stable OpenAI-compatible API)
        |
Frontend on node3
        |
        +--> Prefill on node1: 阅读和编码长 Prompt
        |
        +== NIXL/UCX/RoCE ==> Decode on node2: 逐 token 生成结果
```

管理层信息：API 与既有系统兼容，计算职责可独立扩展；大块 KV 不绕管理网络，而是在专用 CX-7 lossless fabric 上传输。

### 2. 现场完成一次真实推理（2 分钟）

在 `.183` 执行，不带 Token：

```bash
curl --connect-timeout 10 --max-time 60 -sS \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-14B-FP8","messages":[{"role":"user","content":"/no_think\n请用三点说明企业为什么需要可观测的分布式 AI 推理平台。"}],"max_tokens":128,"temperature":0.2}' \
  http://192.168.160.113:30080/v1/chat/completions \
  | jq -r '.choices[0].message.content'
```

展示模型真实回答，然后说明 `.183` 是数据中心直连客户端，不经过互联网反向代理，所以无 Token 成功符合设计；互联网反向代理来源仍由 Cilium policy 强制 Token。

### 3. 在 Hubble UI Enterprise 中看见这次请求（2–3 分钟）

切换到已经通过 F5 打开的 Hubble UI Enterprise，时间范围选择刚才请求所在的最近窗口，过滤：

- namespace=`ai-serving`；
- destination=Frontend；
- L7/HTTP；
- path=`/v1/chat/completions`；
- verdict=`FORWARDED`；
- source 选择 `.183`/external/world 对应项。

展示 source → Frontend 的 flow、POST/path、状态码和策略 verdict。讲解重点：平台不仅知道“端口有流量”，还知道是哪个来源、哪个 API path、被哪条策略允许，便于审计与故障定位。

这里使用的是 **Hubble UI Enterprise**，不是 Timescape UI；不要为演示切换产品、修改现有 UI 发布路径或新增网络入口。

### 4. 在 Grafana 中展示业务结果（3 分钟）

为了让 rate 面板有明显变化，可在 `.183` 安全地顺序发送 5 个短请求：

```bash
for i in $(seq 1 5); do
  curl --connect-timeout 10 --max-time 60 -sS -o /dev/null \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"Qwen/Qwen3-14B-FP8\",\"messages\":[{\"role\":\"user\",\"content\":\"/no_think 第 $i 个演示请求，请回复 OK。\"}],\"max_tokens\":16,\"temperature\":0}" \
    http://192.168.160.113:30080/v1/chat/completions
done
```

等待 30–60 秒，让 Prometheus 完成一次 scrape，然后依次展示：

1. **Hubble L7 HTTP Metrics by External Source IP**：source IP 选 `.183`，展示请求量、非 5xx 成功率、响应码、平均时延。
2. **Hubble L7 HTTP Metrics by Workload**：namespace 选 `ai-serving`，workload 从下拉框选择当前 Frontend，展示 p50/p95/p99 和请求来源。
3. **Hubble / Network Overview (Namespace)**：展示 forwarded flow 与 policy drop；正常演示应看到业务请求被 forward，而不是大量异常 drop。

管理层信息：应用、网络和安全使用同一时间轴，不需要故障发生后再人工拼接多套日志。

### 5. 展示 P/D 和 RDMA 的差异化价值（2–3 分钟）

先用一条只读命令展示角色固定在不同节点：

```bash
kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd' \
  -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dynamo-role,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready'
```

然后展示最近一次 NIXL transfer metric：

```bash
decode=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=decode' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n ai-serving "$decode" --since=15m \
  | grep 'KV Transfer metrics' | tail -1
```

如果短请求只产生较小 KV，可以展示已保存的长 Prompt 验收证据：4522 输入 tokens 对应 720 MiB KV，NIXL 实测约 2991.3 MB/s；同时 CX-7/Nexus 两端约增加 766 MB 且错误 delta 为 0。

管理层信息：Prefill 与 Decode 可以按业务瓶颈分别扩展；专用 RoCE 数据面减少大 KV 移动对普通业务网络的影响。109.85 Gbit/s 是合成 RoCE 链路基准，2991.3 MB/s 是一次真实 KV transfer，两者含义不同。

### 6. 用安全与可恢复性收尾（1–2 分钟）

- Hubble UI Enterprise 展示来源、path 和 FORWARDED verdict，Grafana 展示持续成功率与时延。
- Cilium 保留“互联网反向代理要求 Token、数据中心直连 `.183` 无需 Token”的来源边界。
- `qwen-openai` 保持旧服务兼容性；Frontend 固定 node3，F5 pool 不因 Pod 重建漂移。
- Prefill/Decode 曾人工删除并由 Grove 在固定节点重建，重建后同一 P/D/NIXL 验收再次成功。
- Foundation 与 ComfyUI 保持运行；ComfyUI 仍必须通过其认证网关。

不建议在正式 CxO 演示中现场删除 worker Pod：模型恢复需要时间，且这不会比展示已保存的重建证据增加业务价值。若必须演示自愈，应在独立彩排窗口完成并预留模型加载时间。

### 演示时避免过度声明

- Hubble UI Enterprise 证明 API flow、L7 与 policy，不单独证明 KV 使用 RoCE。
- Grafana 的 HTTP 时延是端到端观察，不等于纯 GPU kernel 时间。
- 一次请求不是容量 benchmark；讨论容量需单独设计并发、SLO 和统计周期。
- 不把合成 `ib_write_bw`、CUDA-memory UCX 和真实 KV throughput 混成一个数字。
- 不展示或朗读 Nexus、API、F5、Grafana 的任何凭据。

## Troubleshooting

- `RuntimeClass "nvidia" not found`：containerd 已有 nvidia handler，但 KAI 会注入 RuntimeClass；应用 `nvidia-runtimeclass.yaml`。
- KAI scheduler 报 `Unauthorized`：Helm upgrade 可能重建 ServiceAccount，而旧 scheduler Pod 仍持有绑定旧 UID 的 token；只滚动 `deployment/kai-scheduler-default`，不要改 RBAC。
- NVCR 长层在 401 后从 0 开始：使用 `resumable-nvcr-pull.sh`；根因和 challenge 见 [image-download-recovery.md](pd-disaggregation/evidence/image-download-recovery.md)。
- node4 backend down：先修物理链路；不要把任务前 no-carrier 当作软件回归。
- Local NodePort 返回无后端：F5 必须访问实际承载 Pod 的固定节点；Qwen 使用 node3:30080，Foundation 使用 node4:30083，不要把所有节点都无差别加入这两个 Local Service 的 pool。
- PFC pause counter 为 0：无拥塞时是正常现象；仍需确认 PFC operational bitmap、priority mapping、error/discard 为 0。
- Hubble：只使用 CEE agent 内置 CLI、经现有 F5 发布的 Hubble UI Enterprise 和现有 Grafana；Timescape 组件保持不变，但不把 Timescape UI 当作本指南入口，也不向企业版集群安装社区 chart/CLI。
- 当前集群有两套 Prometheus Operator（v0.55.1 与 v0.82.2）跨命名空间 reconcile，造成部分第二副本反复重建；现有 `prometheus-k8s-0` 仍为 `2/2 Running`。本任务未改动这些 operator/CR，修复时应先划分各 operator 的 watch scope，不能在本 Demo 中直接删除其中一套。

## 回滚

完整顺序和命令见 [ROLLBACK.md](pd-disaggregation/ROLLBACK.md)。备份位于 `pd-disaggregation/backup/`，包括旧 Qwen、旧 Dare、共享资源记录和改造前 CNP；Secret 值未导出。

## Phase 范围

Phase 1 包含 Dynamo P/D、NIXL/UCX/RoCEv2、CX-7/Nexus lossless fabric、GPUDirect RDMA、按来源区分的 Cilium API 访问控制、Hubble UI Enterprise/Prometheus/Grafana 可观测性、Pod 重建与保留服务回归。Timescape 组件保持现状，但不是本文演示使用的 UI。

Phase 2 尚未实施：VAST G4 KV Cache Storage、KV offload/reload 和 GPUDirect Storage 均不在本阶段范围内。
