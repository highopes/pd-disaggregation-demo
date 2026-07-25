# Dynamo P/D + Remote KV Direct GDS Demo

本仓库记录一套已经端到端验证的两阶段 AI 推理 Demo：Phase 1 将 Qwen3-14B-FP8 的 Prefill 与 Decode 拆分到两张 NVIDIA L4，并通过 NIXL/UCX/RoCEv2 传输 KV Cache；Phase 2 在不破坏该路径的前提下，用 node3 的 RAM-backed NFS/RDMA 模拟远端存储，并由 node1 Prefill 通过 NVIDIA Direct GDS 与 Dynamo KVBM 完成 KV offload/reload。

最终状态：**Phase 1 PASS；Phase 2 PASS – DIRECT GDS**。

> 本环境使用 RAM-backed Linux NFS/RDMA server 模拟第三方 G4-like remote storage，以验证 Dynamo KVBM、NIXL、NFSoRDMA 和 GPUDirect Storage 数据路径。该实现不代表 VAST DASE、VAST G4 产品功能、持久性、HA、scale-out 或真实性能。

<a id="toc"></a>

## 目录

- [目标、边界与最终结果](#scope)
- [整体架构](#architecture)
- [节点与 GPU 角色](#node-roles)
- [软硬件版本](#versions)
- [仓库结构与证据规则](#repository)
- [完整安装指南](#installation)
  - [起始状态、Discovery 与 Backup](#discovery-backup)
  - [Phase 1：P/D、RoCE 与 GPUDirect RDMA](#install-phase1)
  - [Phase 2：RAM、NFSoRDMA、Direct GDS 与 KVBM](#install-phase2)
  - [持久化与最终交接](#persistence)
- [技术演示与工程验收](#engineering-demo)
- [CxO 演示](#cxo-demo)
- [日常运维](#operations)
- [已知问题与未来规划](#problems-roadmap)
- [回滚](#rollback)
- [证据索引](#evidence)

<a id="scope"></a>

## 目标、边界与最终结果

这套 Demo 证明的是两条可同时工作的 GPU 数据路径：

1. **Phase 1，计算节点之间：** Prefill GPU → NIXL/UCX → RoCEv2 → Decode GPU，使用 GPUDirect RDMA，不把大块 KV 绕行管理网络。
2. **Phase 2，远端存储与计算之间：** node3 RAM storage → NFSv3/RDMA → cuFile/`nvidia-fs` → node1 Prefill GPU，使用 Direct GDS；命中后再沿 Phase 1 路径把 KV 交给 Decode。

最终正式 A/B 使用相同的 39,994-token payload，冷、热回答都正确；热请求命中 39,936 tokens。TTFT 从 `32.575 s` 降至 `6.657 s`，节省 `25.918 s`，为该次请求的 `4.893×`。Cold offload 与 Warm onboard 各 312 blocks，Direct GDS 写、读各增加 24,960 ops / 1,560 MiB；两次 P→D NIXL 都传输 3,130 MiB。

这些数字是本环境的功能与演示证据，不是容量测试，也不得外推成真实 VAST G4 或其他存储产品的性能基准。Phase 2 没有修改 Nexus；已有 Phase 1 VLAN/QoS/PFC 已覆盖 node1、node2、node3。

任务边界还包括：

- 保留现有 Foundation、ComfyUI、F5、CEE Hubble、Grafana 和来源型 Cilium 策略；不读取或记录其 Secret 值。
- Nexus 工具只从当前 shell 读取 `NEXUS_USERNAME`、`NEXUS_PASSWORD`，不得打印、保存或写入命令行参数。
- 不为了 GDS 重装或 reload 正在工作的 NVIDIA driver，不用 GPU Operator 覆盖既有 driver/toolkit/device-plugin 生命周期。
- Phase 2 的 RAM disk 是易失介质，重启后由受控 systemd unit 重建；它不提供持久性、HA 或 scale-out。

[返回目录](#toc)

<a id="architecture"></a>

## 整体架构

```text
External client 192.168.160.183
       │ OpenAI-compatible API
       │ NodePort 192.168.160.113:30080
       ▼
qwen-openai Service ─ Cilium CNP/L7 ─ Dynamo Frontend
                                            node3 / CPU Pod
                                            │ NATS + ETCD control/discovery
                      ┌─────────────────────┴─────────────────────┐
                      ▼                                           ▼
              Prefill worker                               Decode worker
              node1 / NVIDIA L4                            node2 / NVIDIA L4
              hostNetwork                                  hostNetwork
                      └──── NIXL → UCX → RoCEv2/GDR ─────────────┘
                              CX-7 backend VLAN 2310
                              172.31.230.0/24

node3 Storage Emulator
  /dev/ram0 (8 GiB) → ext4 /srv/dynamo-g4
       │ NFSv3, proto=rdma, port=20049, ToS 106
       ▼
  node1 /mnt/dynamo-g4
       │ cuFile + nvidia-fs Direct GDS
       ▼
  Prefill KVBM GPU cache
       │ cache hit 后仍经 Phase 1 NIXL/UCX/RoCE 路径
       ▼
  Decode GPU
```

控制面、API 面和两条数据面彼此分工：

| 平面 | 路径 | 用途 | 验证依据 |
|---|---|---|---|
| API/可观测性 | client → Cilium → Frontend | OpenAI API、策略、Hubble L7 | HTTP、CNP、Hubble `FORWARDED` |
| Dynamo 控制面 | Frontend/P/D ↔ NATS/ETCD | 服务发现、请求编排 | DGD Ready、Frontend/P/D 日志 |
| P→D KV 数据面 | node1 GPU → CX-7 → node2 GPU | Phase 1 KV 传输 | NIXL UUID/metrics、UCX CUDA、NIC/Nexus counters |
| Storage KV 数据面 | node3 RAM → NFS/RDMA → node1 GPU | Phase 2 offload/onboard | mount、cuFile、`nvidia-fs`、KVBM、NIC/Nexus counters |

Kubernetes Primary Network 仍为 ISOVALENT Cilium。Frontend 不使用 `hostNetwork`，便于 Service、CNP、Hubble 和 Prometheus 观察 API；P/D worker 使用 `hostNetwork`，并把 UCX 限定在 CX-7 `mlx5_0:1`。NFS/RDMA 是 node1 与 node3 间的独立连接，不取代 node1 与 node2 间的 P→D 链路。

[返回目录](#toc)

<a id="node-roles"></a>

## 节点与 GPU 角色

| 节点 | Management IP | GPU / Demo 角色 | CX-7 netdev / RDMA / backend IP | Nexus 端口 |
|---|---|---|---|---|
| `csco-k8s-01` | `192.168.160.111` | 1 × L4；Dynamo Prefill；KVBM；GDS client | `ens65np0` / `mlx5_0:1` / `172.31.230.111` | `Eth1/1/1` |
| `csco-k8s-02` | `192.168.160.112` | 1 × L4；Dynamo Decode | `ens65np1` / `mlx5_0:1` / `172.31.230.112` | `Eth1/1/2` |
| `csco-k8s-03` | `192.168.160.113` | Frontend CPU Pod；8 GiB RAM/NFS-RDMA Storage Emulator；保留 ComfyUI | `ens65np0` / `mlx5_0:1` / `172.31.230.113` | `Eth1/2/1` |
| `csco-k8s-04` | `192.168.160.114` | 1 × L4；保留 `foundation-instruct-vllm` | `ens65np1` / `mlx5_0:1` / `172.31.230.114` | `Eth1/2/2`，任务前已 no-carrier |

`node4` 的 CX-7 no-carrier 是既有物理问题。当前 P/D 与 GDS 路径均不依赖它；在修复光模块、线缆或交换机链路前，不应把 node4 纳入 RDMA/GDS 数据面。

[返回目录](#toc)

<a id="versions"></a>

## 软硬件版本

下表是最终实测环境。复制到类似系统时，必须重新做支持矩阵与 Capability Gate；版本相近不等于可跳过验证。

| 类别 | 组件 | 实测版本 / 配置 | 备注 |
|---|---|---|---|
| OS | Ubuntu | 24.04.2 LTS | 四节点 |
| Kernel | Linux | `6.11.0-26-generic` | Phase 2 NFSoRDMA patch 只审核了该 kernel |
| Kubernetes | kubelet/API | `v1.31.9` | 四节点集群 |
| GPU | NVIDIA L4 | 23,034 MiB；每节点 1 张 | node1 Prefill、node2 Decode、node4 Foundation |
| GPU driver | NVIDIA Open Kernel Module | `575.51.03` | CUDA driver compatibility 12.9；IOMMU disabled |
| GPU runtime | NVIDIA device plugin | `0.17.2` | 既有 legacy runtime；CDI 尚未迁移 |
| Dynamo | platform/chart/runtime | `1.2.1` | chart SHA-256 见 [chart-source.md](pd-disaggregation/dynamo/chart-source.md) |
| 推理 | vLLM | `0.20.1+cu129` | 运行容器内实测 |
| 模型 | Qwen | `Qwen/Qwen3-14B-FP8` | 原生 max context 40,960 |
| KV 配置 | vLLM/KVBM | FP8 KV；block 128；54,016-token GPU KV pool / 4.12 GiB | `max-num-seqs=1`，偏重单请求长上下文 |
| KV transport | NIXL | `0.10.1`, git `d5c127e5` | P→D |
| Transport | UCX | `1.20.1` | CUDA、verbs、gdrcopy；不启用 TCP fallback |
| RDMA plugin | Mellanox shared device plugin | `v1.5.3` | 资源名 `rdma/ib` |
| NIC | NVIDIA/Mellanox ConnectX-7 MT2910 | firmware `28.43.2566`，200G | node1/2 GPU 与 NIC 同 NUMA，拓扑 PHB |
| OFED | MLNX_OFED | `24.10.OFED.24.10.2.1.8.1` | Phase 2 build source 与 symvers 来源 |
| NFSoRDMA | `mlnx-nfsrdma` DKMS | `3.4` | node1/node3；含仓库 Linux 6.11 compatibility patch |
| GDS userspace | `gds-tools-12-9` / `libcufile-12-9` | `1.14.1.1-1` | node1；matching `/usr/local/cuda-12.9` 工具 |
| GDS kernel | `nvidia-fs-dkms` | `2.26.6-1` | exact-kernel DKMS module；不 reload NVIDIA driver |
| Remote FS | Linux NFS | NFSv3 / `proto=rdma` / port `20049` | node3 server → node1 client |
| Remote media | Linux `brd` + ext4 | `/dev/ram0`, 8 GiB, label `DYNAMO_G4_RAM` | KVBM disk cache 6 GB；易失 |
| CNI/可观测性 | ISOVALENT Cilium CEE | `1.18.7-cee.1` | 保留企业版安装 |
| Hubble | Enterprise | `1.13.4`；UI `1.3.12` | Timescape `1.8.4` 保持部署但不是本文入口 |
| Security | Tetragon | `1.18.0` | 既有环境 |
| Switch | Nexus `N9K-C9332D-GX2B` | NX-OS `10.4(3)` | VLAN 2310、DSCP 26、priority/qos-group 3 |

运行时组件的最终裁决以容器、宿主机和交换机实时输出为准。仓库中的版本表是已验证基线，不应替代重建时的实时 discovery。

[返回目录](#toc)

<a id="repository"></a>

## 仓库结构与证据规则

| 路径 | 用途 |
|---|---|
| `pd-disaggregation/discovery/` | Phase 0 环境、拓扑与共享资源发现 |
| `pd-disaggregation/backup/` | Phase 1 前非敏感 Kubernetes/配置备份 |
| `pd-disaggregation/nexus/` | Phase 1 Nexus before/desired/final/rollback 与端口映射 |
| `pd-disaggregation/rdma/` | Netplan、主机 QoS/PFC、`nvidia_peermem`、RDMA device plugin |
| `pd-disaggregation/dynamo/` | Dynamo chart、values、RuntimeClass 与 Phase 1 DGD |
| `pd-disaggregation/cilium/` | Qwen Service 与来源型 CNP |
| `pd-disaggregation/scripts/` | Phase 1 preflight、安装辅助和验证脚本 |
| `pd-disaggregation/evidence/` | Phase 1 最终验证与历史原始证据 |
| `pd-disaggregation/phase2/backup/` | Phase 2 前 live state、runtime source 与回滚基线；不是安装入口 |
| `pd-disaggregation/phase2/storage/` | RAM block device 的安全创建/释放 |
| `pd-disaggregation/phase2/nfs/` | NFSoRDMA build、server/client 与组件回滚 |
| `pd-disaggregation/phase2/dynamo/` | GDS runtime probe 与最终 KVBM DGD |
| `pd-disaggregation/phase2/systemd/` | node1/node3 有界持久化 unit |
| `pd-disaggregation/phase2/scripts/` | Phase 2 preflight、验证、Demo 和回滚编排 |
| `pd-disaggregation/phase2/evidence/` | Phase 2 28 项最终报告、容量依据与原始 run |

证据目录只保存非敏感输出。禁止保存 Kubernetes Secret YAML、Nexus/API/F5/Grafana 凭据、Authorization header 或 registry token。Pod 后缀和 Endpoint IP 会变化，所以新证据必须同时记录时间、namespace、角色和节点。

本文是唯一的安装、演示和回滚入口。保留的 discovery、backup、evidence 和源码说明是事实依据，不与本文竞争操作入口。

[返回目录](#toc)

<a id="installation"></a>

## 完整安装指南

以下步骤从本项目 Phase 1 之前的真实状态开始：四节点 Kubernetes、NVIDIA driver/container runtime/device plugin、共享模型 PVC、Foundation、ComfyUI、CEE/Hubble/Grafana 已存在；CX-7 和 Nexus 尚未形成 Dynamo 专用 lossless backend，Dynamo P/D 与 Phase 2 storage/GDS 尚未部署。本文不把“从裸机安装 Kubernetes、Cilium、GPU driver”虚构成已经验证过的范围。

在其他类似系统上复刻时，应先准备等价的 Kubernetes/GPU/CNI 基础环境，再从本节执行。所有宿主机和交换机变更都安排维护窗口；每个 Gate 失败时停止，不跨越 Gate 继续安装。

Phase 1 前的基础平台准备清单：

| 基础能力 | 最低要求 | 本指南如何处理 |
|---|---|---|
| Kubernetes | 四个可调度 Linux 节点；版本与所选 Dynamo 支持矩阵匹配 | 不负责从裸机安装；Discovery 重新验证 Ready、资源与 owner |
| GPU stack | NVIDIA L4 或等价受支持 GPU；Open driver、container toolkit/runtime、device plugin 可工作 | 保留既有生命周期；不叠加 GPU Operator；宿主与容器新 CUDA context 都要通过 |
| RDMA stack | CX-7 或等价 RoCE NIC；MLNX_OFED、RDMA core、`rdma`/`ibv_*`/`mlnx_qos`/`ethtool` 工具 | Phase 1 配置 backend/QoS；Phase 2 只为 exact kernel 构建 NFS/RDMA 模块 |
| Network/CNI | 可工作的 Kubernetes CNI；Nexus 端口映射和变更权限 | 本环境保留 Cilium CEE，新增来源型策略与专用 VLAN 2310 |
| Shared model cache | P/D 都可读取模型的 `ai-serving/hf-cache-pvc` 或等价存储 | 复用，不在回滚中删除；模型访问许可/凭据由管理员预先配置 |
| 运维工具 | `kubectl`、Helm、SSH、`jq`、`curl`、Python 3、DKMS、matching kernel headers、compiler toolchain | 每个阶段在使用前做 availability/version Gate |
| 证据与安全 | 私有 evidence 目录、维护窗口、回滚权限 | `umask 077`；不导出 Secret；Nexus 凭据仅用环境变量 |

<a id="discovery-backup"></a>

### 起始状态、Discovery 与 Backup

在 node1 仓库根目录建立新的私有证据目录，不覆盖仓库内历史基线：

```bash
cd /root/ns_ai-serving
umask 077
run_id=$(date +%Y%m%d-%H%M%S)
evidence_dir="pd-disaggregation/evidence/runs/$run_id"
mkdir -p "$evidence_dir"
date --iso-8601=seconds > "$evidence_dir/started-at.txt"
```

先阅读已知基线：

```bash
sed -n '1,240p' pd-disaggregation/discovery/phase0-summary.md
sed -n '1,240p' pd-disaggregation/backup/shared-resources.md
sed -n '1,240p' pd-disaggregation/nexus/cx7-port-mapping.md
pd-disaggregation/scripts/preflight.sh |& tee "$evidence_dir/preflight-before.txt"
```

然后重新采集实时状态。至少记录：

```bash
kubectl get nodes -o wide | tee "$evidence_dir/nodes-before.txt"
kubectl get pods -A -o wide | tee "$evidence_dir/pods-before.txt"
kubectl get dgd -A -o yaml | tee "$evidence_dir/dgd-before.yaml"
kubectl get svc,endpoints -n ai-serving -o yaml \
  | tee "$evidence_dir/ai-serving-network-before.yaml"
kubectl get runtimeclass -o yaml | tee "$evidence_dir/runtimeclass-before.yaml"
kubectl get ds -A | tee "$evidence_dir/daemonsets-before.txt"
```

不要导出 Secret。对四节点分别记录 `uname -r`、`nvidia-smi`、`lspci`、`ip -br link/address`、`rdma link`、`ibv_devinfo`、`ethtool -i/-k/-S`、`dkms status`、`mount` 和内存状态。确认 GPU workload、NIC 名、PCI 地址、GID index、NUMA 和 Nexus 端口映射与本文一致；不一致时以实时环境为准，先修订配置再实施。

Nexus 凭据只放环境变量：

```bash
export NEXUS_USERNAME='当前用户名'
read -rsp 'Nexus password: ' NEXUS_PASSWORD; export NEXUS_PASSWORD
python3 pd-disaggregation/scripts/nexus_read.py \
  'show version' \
  'show interface status' \
  'show policy-map system type network-qos' \
  |& tee "$evidence_dir/nexus-before.txt"
```

脚本不会打印凭据。结束 Nexus 操作后执行 `unset NEXUS_PASSWORD`。如果实时接口映射、VLAN、QoS、PFC 或共享 workload 与仓库基线不一致，必须记录差异和影响；不要把旧配置盲目套到新系统。

#### Discovery Gate

只有同时满足以下条件才进入 Phase 1：

- 四节点 Kubernetes Ready，既有 Foundation/ComfyUI/CEE 资源及所有者已识别。
- node1、node2 各有一张可调度 L4，宿主 `nvidia-smi` 和新 CUDA context 正常。
- node1、node2 CX-7 link active，netdev/RDMA/GID/PCI/Nexus 映射明确；GPU/NIC 拓扑适合 GDR。
- 现有配置与回滚备份完整，Secret 未被读取或导出。
- node4 no-carrier 被记录为非阻塞既有问题，而不是误判为本次变更故障。

<a id="install-phase1"></a>

### Phase 1：P/D、RoCE 与 GPUDirect RDMA

#### 1. 配置 Nexus lossless backend

先审查配置差异：

```bash
diff -u pd-disaggregation/nexus/before-relevant.cfg \
  pd-disaggregation/nexus/desired.cfg || true
```

在当前 shell 设置凭据后执行：

```bash
python3 pd-disaggregation/scripts/nexus_apply.py \
  pd-disaggregation/nexus/desired.cfg

python3 pd-disaggregation/scripts/nexus_read.py \
  'show running-config interface vlan 2310' \
  'show policy-map system type network-qos' \
  'show interface priority-flow-control' \
  'show startup-config interface vlan 2310'
```

期望：VLAN 2310 `DYNAMO_ROCE_BACKEND` 存在；DSCP 26 映射 priority/qos-group 3；PFC 仅对 priority 3；no-drop class MTU 4200；default class 和物理端口 MTU 9216；running/startup-config 一致。不要为了追求 pause counter 非零制造拥塞，无拥塞时 pause=0 是正常结果。

#### 2. 配置四节点 CX-7、MTU、DSCP/PFC

每个节点安装与主机名对应的 Netplan 和 QoS 文件。下面以 node1 为例；node2–4 使用各自 YAML：

```bash
install -m 0600 pd-disaggregation/rdma/netplan/csco-k8s-01.yaml \
  /etc/netplan/95-roce-backend.yaml
install -m 0755 pd-disaggregation/rdma/dynamo-roce-qos.sh \
  /usr/local/sbin/dynamo-roce-qos.sh
install -m 0644 pd-disaggregation/rdma/dynamo-roce-qos.service \
  /etc/systemd/system/dynamo-roce-qos.service
netplan generate
netplan apply
systemctl daemon-reload
systemctl enable --now dynamo-roce-qos.service
```

如果仓库只在 node1，先把对应文件安全复制到远端临时目录，再在远端执行 `install`。不要让四台主机共用错误的 netdev 或 backend IP。

`systemctl daemon-reload` 在 systemd cgroup 与 NVIDIA legacy runtime hook 组合中可能使正在运行的 GPU 容器失去设备访问。首次安装应先完成 host/systemd 配置，再部署 P/D。若已有 GPU workload，必须使用维护窗口，并在 reload 后同时检查宿主机与 Pod 内的新 NVML/CUDA 进程；HTTP 200 不能替代该 canary。

仅在 node1、node2 安装 Peer Memory 模块启动配置：

```bash
install -m 0644 pd-disaggregation/rdma/nvidia-peermem.conf \
  /etc/modules-load.d/nvidia-peermem.conf
modprobe nvidia_peermem
```

主机网络 Gate：

```bash
ping -I 172.31.230.111 -M do -s 4172 -c 3 -W 2 172.31.230.112
rdma link
ibv_devinfo -d mlx5_0
systemctl is-active dynamo-roce-qos.service
```

期望：DF ping 3/3，Ethernet MTU 4200，RDMA active MTU 4096，`mlx5_0` ACTIVE，DSCP trust/PFC priority 3 生效。

#### 3. 安装 Kubernetes RDMA 资源与 Dynamo platform

本环境已有工作的 driver、container toolkit、containerd runtime 和 GPU device plugin；不要安装 GPU Operator 覆盖它们。

```bash
kubectl apply -f pd-disaggregation/rdma/rdma-shared-device-plugin.yaml
kubectl apply -f pd-disaggregation/dynamo/nvidia-runtimeclass.yaml

helm upgrade --install dynamo-platform \
  pd-disaggregation/dynamo/dynamo-platform-1.2.1.tgz \
  -n dynamo-system --create-namespace \
  -f pd-disaggregation/dynamo/platform-values.yaml

kubectl get pods -n dynamo-system -o wide
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,RDMA:.status.allocatable.rdma/ib'
```

期望：Dynamo operator、Grove、KAI、NATS、ETCD Ready；四节点发布 GPU/RDMA 资源；`RuntimeClass/nvidia` 存在；共享 `ai-serving/hf-cache-pvc` 仍 Bound。

若 Helm upgrade 后 KAI scheduler 报 `Unauthorized`，先确认 ServiceAccount 被重建而旧 Pod 仍持有旧 UID token，只滚动 `deployment/kai-scheduler-default`，不要扩大 RBAC。

#### 4. 准备 Dynamo 镜像

NVCR 大层续传曾因认证 realm 切换返回 401，并让普通 containerd pull 丢弃 partial。网络正常时可直接预拉；慢速链路使用仓库的可恢复脚本：

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

下载器仅通过 stdin 向 `curl` 传递短期 registry token，不打印或持久化；partial 位于 `/tmp/dynamo-nvcr-resume/`。复制脚本先验证路由走 CX-7，再以 OCI tar stream 导入远端 containerd。

#### 5. 部署 Phase 1 DGD、Service 与 CNP

```bash
kubectl apply --dry-run=client -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl apply --dry-run=server -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl apply -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml

kubectl apply --dry-run=server \
  -f pd-disaggregation/cilium/frontend-service-policy.yaml
kubectl apply -f pd-disaggregation/cilium/frontend-service-policy.yaml

kubectl wait -n ai-serving --for=condition=Ready \
  dynamographdeployment/qwen3-14b-pd --timeout=20m
```

Phase 1 关键参数不得在 P/D 两端漂移：同一模型、dtype、TP、block size、40,960 max model length、FP8 KV、`NixlConnector/kv_both`；`gpu-memory-utilization=0.90`、`max-num-seqs=1`、`--no-enable-prefix-caching`。UCX 固定 `rc_x,rc,cuda_copy,cuda_ipc`、`mlx5_0:1`、GID 3、traffic class 106，transport list 不含 `tcp`。

Frontend 固定 node3，Prefill 固定 node1，Decode 固定 node2。`qwen-openai` 使用 `externalTrafficPolicy: Local`，因此 F5/客户端只应访问实际承载 Frontend 的 `192.168.160.113:30080`。互联网反向代理来源必须匹配既有 Secret 引用的 Authorization header；数据中心直连 `.183` 按设计无需 token。不要读取 Secret 来做本文测试。

#### 6. Phase 1 Capability Gate

```bash
pd-disaggregation/scripts/preflight.sh
pd-disaggregation/scripts/validate-roce.sh
pd-disaggregation/scripts/validate-gdr.sh
pd-disaggregation/scripts/validate-dynamo.sh
pd-disaggregation/scripts/validate-api.sh
EXTERNAL_CLIENT_SSH=root@192.168.160.183 \
  pd-disaggregation/scripts/validate-api.sh
pd-disaggregation/scripts/validate-hubble-enterprise.sh
```

必须同时满足：DGD Ready；三角色节点正确；P/D Pod 中 `mlx5_0`、RDMA device、CUDA registration 可见；UCX 不含 TCP fallback；新 `nvidia-smi` 和新 PyTorch CUDA context 正常；内部和 `.183` API HTTP 200；Hubble health OK。真正的 GDR 强证据还需在维护窗口执行本文[技术演示](#engineering-demo)中的 CUDA-memory `ucx_perftest`，并用同一请求 UUID、NIXL metrics 和 NIC/Nexus counters 交叉证明真实 P→D。

<a id="install-phase2"></a>

### Phase 2：RAM、NFSoRDMA、Direct GDS 与 KVBM

Phase 2 只在 Phase 1 全部 Gate 通过后开始。任何步骤若会 reload/reinstall NVIDIA driver、改变 node1↔node2 P/D QoS、强制卸载被使用的文件系统，或无法证明 exact kernel/module 匹配，应停止而不是强行继续。

#### 1. Phase 2 Discovery、Backup 与容量 Gate

```bash
pd-disaggregation/phase2/scripts/preflight-phase2.sh
sed -n '1,220p' pd-disaggregation/phase2/evidence/ram-storage-sizing.md
```

对 node1 记录 GDS package candidate、kernel/header、driver DKMS、IOMMU、Secure Boot、`/proc/driver/nvidia-fs` 和当前 P/D；对 node3 记录内存、`brd` 使用情况、NFS packages/exports、OFED source/config/symvers 和 `rpcrdma` 状态。使用新的私有目录保存非敏感输出；仓库的 `phase2/backup/` 是本次历史回滚基线，不应被另一套系统盲目复用。

RAM sizing Gate：node3 必须有足够可用内存；脚本要求 8 GiB RAM device 不超过物理内存 25%，创建后仍保留至少 35%/16 GiB 可用内存；`/dev/ram0`、`/srv/dynamo-g4` 不得已有未知 owner、mount、export 或 open user。本环境 8 GiB ext4 配 6 GB KVBM cache，实际容纳完整 near-40K prefix 后仍无 Kubernetes MemoryPressure。

#### 2. 在 node1 安装 matching CUDA 12.9 GDS

先做 package simulation 并审查依赖，不允许 apt 顺带替换 driver：

```bash
apt-cache policy nvidia-fs-dkms gds-tools-12-9 libcufile-12-9
apt-get -s install \
  nvidia-fs-dkms=2.26.6-1 \
  gds-tools-12-9=1.14.1.1-1 \
  libcufile-12-9=1.14.1.1-1
```

只有 simulation 显示不会移除或升级当前 NVIDIA/OFED 栈，且 kernel/header/driver exact match 时才安装：

```bash
apt-get install \
  nvidia-fs-dkms=2.26.6-1 \
  gds-tools-12-9=1.14.1.1-1 \
  libcufile-12-9=1.14.1.1-1
```

本环境的 package helper 最初不能从压缩的 NVIDIA `.ko.zst` 正确生成 symbol versions。安全处置是复用同一 NVIDIA driver、同一 kernel 已成功构建的 DKMS `Module.symvers`，只重建 `nvidia-fs`，不卸载或 reload driver：

```bash
test -r /var/lib/dkms/nvidia/575.51.03/6.11.0-26-generic/x86_64/module/Module.symvers
NVIDIA_SYMVERS=/var/lib/dkms/nvidia/575.51.03/6.11.0-26-generic/x86_64/module/Module.symvers \
  dkms build -m nvidia-fs -v 2.26.6 -k 6.11.0-26-generic --force
dkms install -m nvidia-fs -v 2.26.6 -k 6.11.0-26-generic --force
depmod -a 6.11.0-26-generic
modprobe nvidia-fs
```

该 workaround 只适用于版本和路径完全一致的环境；若 driver/kernel 不同，必须重新获得 matching symvers，不可复制本环境文件。验收：

```bash
dkms status -m nvidia-fs -v 2.26.6
modinfo nvidia-fs | grep -E '^(filename|version|vermagic):'
/usr/local/cuda-12.9/gds/tools/gdscheck -p
nvidia-smi
```

期望 module 位于 `updates/dkms`，vermagic 与运行 kernel 一致，matching CUDA 12.9 `gdscheck` 能识别 L4、Open driver、IOMMU disabled。此时 NFS 尚未挂载，`NFS: Unsupported` 不应提前被记为 GDS 失败；最终判定在 mount 和实际 Direct I/O 后完成。

#### 3. 在 node1、node3 构建 MLNX NFS/RDMA 3.4

仓库 patch 只支持 `6.11.0-26-generic`、MLNX_OFED `24.10.OFED.24.10.2.1.8.1`。脚本会检查 OFED source、`Module.symvers`、`configure.mk.kernel` 中的 `CONFIG_GPU_DIRECT_STORAGE=y`、module vermagic 和 `nvfs_*` hook。先 isolated build：

```bash
PATCH_FILE=/root/ns_ai-serving/pd-disaggregation/phase2/nfs/mlnx-nfsrdma-3.4-linux-6.11.patch \
BUILD_ONLY=1 \
  bash pd-disaggregation/phase2/nfs/build-install-mlnx-nfsrdma.sh
```

node1、node3 都通过后，再分别安装：

```bash
PATCH_FILE=/root/ns_ai-serving/pd-disaggregation/phase2/nfs/mlnx-nfsrdma-3.4-linux-6.11.patch \
  bash pd-disaggregation/phase2/nfs/build-install-mlnx-nfsrdma.sh
```

期望 `rpcrdma.ko`、`svcrdma.ko`、`xprtrdma.ko` 来自 `/lib/modules/6.11.0-26-generic/updates/dkms/`，vermagic 正确，`dkms status -m mlnx-nfsrdma -v 3.4` 为 installed。若系统已有非本阶段 `rpcrdma` 被加载，脚本会拒绝覆盖；先调查 owner，不要强制替换。

#### 4. 在 node3 创建受控 RAM storage

```bash
sudo pd-disaggregation/phase2/storage/start-ram-storage.sh
findmnt /srv/dynamo-g4
df -h /srv/dynamo-g4
test -f /srv/dynamo-g4/.dynamo-phase2-ram-storage
```

期望 `/dev/ram0`、ext4 label `DYNAMO_G4_RAM`、挂载点 `/srv/dynamo-g4`、8 GiB 容量和 owner marker 全部匹配。脚本只接受 `/dev/ramN` 与固定 mount path，并在内存、已有设备、owner 和 mount 不明确时停止。

#### 5. 启动 node3 NFS/RDMA 并挂载 node1

先在 node3 模拟 NFS package 变更；只有不会破坏既有服务时才允许脚本安装缺少的 package：

```bash
apt-get -s install nfs-kernel-server
sudo INSTALL_PACKAGE=1 \
  pd-disaggregation/phase2/nfs/node3-nfs-rdma-setup.sh
```

若 package 已存在，直接省略 `INSTALL_PACKAGE=1`。脚本导出 `/srv/dynamo-g4` 给唯一 client `172.31.230.111`，并在 port 20049 启动 RDMA listener。然后在 node1：

```bash
sudo pd-disaggregation/phase2/nfs/node1-nfs-rdma-mount.sh
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/dynamo-g4
nfsstat -m
```

期望 source 为 `172.31.230.113:/srv/dynamo-g4`，filesystem 为 NFSv3，options 明确包含 `proto=rdma,port=20049`。`mount` 成功但显示 TCP 不算通过。

#### 6. 固定 NFS/RDMA 的 ToS 106

在 node1、node3 使用仓库脚本设置 endpoint-specific RDMA-CM ToS：

```bash
sudo pd-disaggregation/phase2/systemd/rdma-cm-tos106.sh start
```

先后执行一次 Direct write/read，再通过 host priority counters、packet capture 或 Nexus qos-group 3 counters 证明 ToS 106/DSCP 26 分类。Phase 2 `nexus/desired.cfg` 与 `rollback.cfg` 都是 no-op 记录，因为 Phase 1 配置已经覆盖 node3；不得为 Phase 2 重写共享 Nexus QoS。

#### 7. 先做 synthetic Direct GDS Gate

先启用可恢复的统计开关并记录 before：

```bash
cat /proc/driver/nvidia-fs/stats
/usr/local/cuda-12.9/gds/tools/gdscheck -p
```

用 `gdsio` 对 `/mnt/dynamo-g4` 上的测试文件执行对齐的 GPU_DIRECT write/read，并同时采集 node1/node3 CX-7 与 Nexus counter。也可临时应用受限 probe：

```bash
kubectl apply -f pd-disaggregation/phase2/dynamo/gds-runtime-probe.yaml
kubectl get pod -n ai-serving phase2-gds-runtime-probe -w
```

完成后删除 probe。只有同时满足下列条件才判定 Direct GDS PASS：

- matching CUDA 12.9 `gdscheck` 在 NFS/RDMA mount 存在时报告 NFS Supported、Mellanox PeerDirect Enabled、L4 supports GDS、IOMMU disabled。
- Pod 获得 `NVIDIA_GDS=enabled`、`NVIDIA_DRIVER_CAPABILITIES=all`、`/dev/nvidia-fs*` 和 matching cuFile library。
- `nvidia-fs` direct read/write、BAR1 map 和 RDMA/Nexus counters 在同一次 I/O 中同向增加。
- page-cache、DMA/BAR1、I/O state error 均为 0；不带 GDS device/env 的对照 probe 不产生 direct counters。

只看到 HTTP 200、文件内容正确、`gdscheck` 一行或 NFS mount 都不足以证明 Direct GDS。`/proc/driver/nvidia-fs/stats` 的 legacy `Mellanox PeerDirect Supported: False` 与 matching CUDA 12.9 `gdscheck` 和实际 direct counters 存在已记录差异，必须保留该差异并使用完整证据链判定。

#### 8. 应用 KVBM + GDS DGD

先做双重 dry-run：

```bash
kubectl apply --dry-run=client \
  -f pd-disaggregation/phase2/dynamo/qwen3-14b-pd-kvbm-gds.yaml
kubectl apply --dry-run=server \
  -f pd-disaggregation/phase2/dynamo/qwen3-14b-pd-kvbm-gds.yaml
```

确认 Phase 1 的模型、40,960 context、FP8 KV、P/D placement 与 UCX 参数未被回退；只有 Prefill 新增 PdConnector 的 DynamoConnector+NixlConnector、6 GB disk cache、GDS env/device 与 `/mnt/dynamo-g4` hostPath。然后：

```bash
kubectl apply \
  -f pd-disaggregation/phase2/dynamo/qwen3-14b-pd-kvbm-gds.yaml
kubectl wait -n ai-serving --for=condition=Ready \
  dynamographdeployment/qwen3-14b-pd --timeout=20m

pd-disaggregation/phase2/scripts/validate-nfs-rdma.sh
pd-disaggregation/phase2/scripts/validate-gds.sh
pd-disaggregation/phase2/scripts/validate-kvbm.sh
```

KVBM 在 NFSv3 上不能使用 `fallocate`，本环境启用了对齐 O_DIRECT zero-fill fallback，最终创建 5,997,854,720-byte cache 文件。这是已知兼容措施，不代表 NFS 提供 `fallocate`。

#### 9. 正式 cold/warm A/B Gate

默认 Demo 只复放已归档结果；新安装必须显式创建一个不存在的新目录运行 A/B：

```bash
new_run="pd-disaggregation/phase2/evidence/runs/$(date +%Y%m%d-%H%M%S)-ab"
pd-disaggregation/phase2/scripts/demo-phase2.sh --run-ab "$new_run"
```

A/B 必须满足：冷、热 payload hash 相同；使用运行中模型的真实 tokenizer；答案正确且一致；cold 出现 offload/direct writes；warm 出现 cached tokens/onboard/direct reads；P→D NIXL 两次都存在；node1/node2/node3 与 Nexus counters 方向一致且 errors/discards 为 0。不要只凭 TTFT 更快宣告通过。

<a id="persistence"></a>

### 持久化与最终交接

核心 Phase 2 已通过后，才在 node1、node3 安装有限的持久化 units：

```bash
sudo pd-disaggregation/phase2/systemd/install-persistence.sh
systemctl list-unit-files 'dynamo-phase2-*'
systemctl --no-pager --full status 'dynamo-phase2-*'
```

node1 持久化 ToS 和 NFS/RDMA client；node3 持久化 ToS、RAM storage 和 NFS/RDMA server。unit 不是 boot-critical，带超时和依赖；root-only 状态存放在 `/var/lib/dynamo-phase2`。

安装脚本仅在 unit 内容改变时执行 `daemon-reload`，但本环境首次 reload 后旧 Prefill Pod 出现 NVML Unknown Error。每次 host/systemd/package 维护后都必须启动**新进程**做 canary：

```bash
prefill=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=prefill' \
  -o jsonpath='{.items[0].metadata.name}')
decode=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=decode' \
  -o jsonpath='{.items[0].metadata.name}')

for pod in "$prefill" "$decode"; do
  kubectl exec -n ai-serving "$pod" -- nvidia-smi
  kubectl exec -n ai-serving "$pod" -- python3 -c \
    'import torch; print(torch.cuda.is_available(), torch.cuda.device_count())'
done
```

若宿主 GPU 正常而单个旧 Pod 失败，只在维护窗口重建受影响的 PodClique worker；不得 reload driver。恢复后重新执行 Phase 1 GDR/RoCE、Phase 2 三个 validator 和新的 near-40K A/B，才能交接。

最终交接检查：

```bash
pd-disaggregation/scripts/preflight.sh
pd-disaggregation/scripts/validate-dynamo.sh
pd-disaggregation/scripts/validate-gdr.sh
pd-disaggregation/scripts/validate-roce.sh
pd-disaggregation/phase2/scripts/preflight-phase2.sh
pd-disaggregation/phase2/scripts/validate-nfs-rdma.sh
pd-disaggregation/phase2/scripts/validate-gds.sh
pd-disaggregation/phase2/scripts/validate-kvbm.sh
pd-disaggregation/phase2/scripts/rollback-phase2.sh --dry-run
```

[返回目录](#toc)

<a id="engineering-demo"></a>

## 技术演示与工程验收

本节面向专业工程师。建议准备两个终端：node1 负责只读状态、日志和 counters，`.183` 负责 API 请求。主动 GPU/RDMA 测试和新 near-40K A/B 只在维护窗口执行。

### 1. 建立验收记录

```bash
cd /root/ns_ai-serving
umask 077
run_id=$(date +%Y%m%d-%H%M%S)
evidence_dir="pd-disaggregation/evidence/runs/$run_id"
mkdir -p "$evidence_dir"
printf 'run_id=%s\nstarted_at=%s\n' "$run_id" "$(date --iso-8601=seconds)" \
  | tee "$evidence_dir/run-info.txt"
```

### 2. 证明角色、资源与 API 没有漂移

```bash
pd-disaggregation/scripts/preflight.sh |& tee "$evidence_dir/01-preflight.txt"
pd-disaggregation/scripts/validate-dynamo.sh |& tee "$evidence_dir/02-dynamo.txt"
pd-disaggregation/scripts/validate-api.sh |& tee "$evidence_dir/03-api-internal.txt"
EXTERNAL_CLIENT_SSH=root@192.168.160.183 \
  pd-disaggregation/scripts/validate-api.sh \
  |& tee "$evidence_dir/04-api-external.txt"
```

期望：platform/DGD Ready；Frontend/node3、Prefill/node1、Decode/node2；三 Pod Ready/0 restart；GPU/RDMA allocatable 正确；内部和 `.183` 无 token 均 HTTP 200。`.183` 是数据中心直连来源；这不绕过互联网反向代理的 token 策略。

### 3. 证明 Phase 1 RoCE 与 GDR 能力

```bash
pd-disaggregation/scripts/validate-roce.sh |& tee "$evidence_dir/05-roce.txt"
pd-disaggregation/scripts/validate-gdr.sh |& tee "$evidence_dir/06-gdr.txt"
```

期望：`mlx5_0:1`、Ethernet、active MTU 4096、GID 3、traffic class 106；UCX `rc_x,rc,cuda_copy,cuda_ipc` 且无 TCP；mlx5 memory domain 支持 CUDA registration/cache；Pod 内新 NVML/CUDA 成功。

主动 CUDA-memory UCX 测试会占用两张 GPU。终端 A：

```bash
prefill=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=prefill' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ai-serving -it "$prefill" -- \
  sh -lc 'ucx_perftest -p 13337'
```

终端 B：

```bash
decode=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=decode' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n ai-serving "$decode" -- \
  sh -lc 'UCX_LOG_LEVEL=info ucx_perftest 172.31.230.111 -p 13337 -t tag_bw -m cuda -s 67108864 -n 100'
```

期望日志明确选择 `tag(rc_mlx5/mlx5_0:1)`、memory type CUDA、无 TCP。初始实测为 4,663.53 MB/s；NVML 恢复后复测为 4,748.39 MB/s。带宽数字会波动，transport 和 memory type 才是首要 Gate。测试后在 server 终端 Ctrl-C。

### 4. 证明真实 Phase 1 P→D 请求

发送 near-40K 或仓库验证请求前后，分别采集 P/D NIC、Nexus priority 3 counters 和三角色日志。按 request UUID 关联 Frontend、Prefill、Decode，并检查 Decode 的 `KV Transfer metrics`：

```bash
kubectl logs -n ai-serving "$decode" --since=20m \
  | grep 'KV Transfer metrics' | tail -5
```

Phase 1 最终 40K 验收为：40,637 input、7 output、40,644 total，答案 `54088`；P→D NIXL 传输 3,180 MiB / 507.228 ms / 6,269.37 MB/s。历史合成 `ib_write_bw` 为 109.85 Gbit/s。两者分别是实际 KV transfer 与链路 microbenchmark，不可混为一个性能数字。

### 5. 证明 Phase 2 NFSoRDMA 与 Direct GDS

```bash
pd-disaggregation/phase2/scripts/preflight-phase2.sh \
  |& tee "$evidence_dir/07-phase2-preflight.txt"
pd-disaggregation/phase2/scripts/validate-nfs-rdma.sh \
  |& tee "$evidence_dir/08-nfs-rdma.txt"
pd-disaggregation/phase2/scripts/validate-gds.sh \
  |& tee "$evidence_dir/09-gds.txt"
pd-disaggregation/phase2/scripts/validate-kvbm.sh \
  |& tee "$evidence_dir/10-kvbm.txt"
```

期望：node1 mount 是 NFSv3 `proto=rdma` port 20049；node3 RAM marker、export/listener 和内存 Gate 正常；matching GDS 1.14.1.1 报告 NFS/PeerDirect enabled；Prefill 注入 GDS device/env；KVBM metrics、6 GB cache 和 PdConnector 配置正确；`nvidia-fs` direct I/O error/page-cache 为 0。

### 6. 演示 cold offload 与 warm reload

安全现场 Demo 默认实时检查当前链路，并复放已经归档的正式 A/B，不安装 package、不改 Nexus、不重建 RAM disk、不删除 Pod，也不跑 full-bandwidth benchmark：

```bash
pd-disaggregation/phase2/scripts/demo-phase2.sh
```

期望屏幕摘要：

```text
Cold GPU Prefill TTFT : 32.575 s
Warm GDS Reload TTFT  :  6.657 s
TTFT Saved            : 25.918 s
TTFT Speedup          :  4.893 x
```

若需要新的正式 A/B，显式指定一个不存在的目录：

```bash
new_run="pd-disaggregation/phase2/evidence/runs/$(date +%Y%m%d-%H%M%S)-ab"
pd-disaggregation/phase2/scripts/demo-phase2.sh --run-ab "$new_run"
```

工程师必须检查同一 payload SHA-256、冷/热正确答案、39,936 cached tokens、312 block offload/onboard、1,560 MiB Direct GDS write/read、两次 P→D NIXL 以及三端/Nexus counter，而不是只展示 4.893×。

### 7. API 安全与企业可观测性回归

```bash
pd-disaggregation/scripts/validate-hubble-enterprise.sh \
  |& tee "$evidence_dir/11-hubble.txt"
```

期望 CEE CLI 版本匹配、Healthcheck Ok，并捕获 Qwen `/v1/models` 或 `/v1/chat/completions` 的 L7 `FORWARDED` flow。本文不安装社区版 Cilium/Hubble/Tetragon，也不修改现有 F5 或 UI 入口。Phase 2 的可选 Grafana dashboard 因 Prometheus Operator 双控制器 ownership/thrash 未部署；原始 KVBM、GDS、NIC、Nexus、NIXL 和 Hubble 证据足以完成数据面验收。

[返回目录](#toc)

<a id="cxo-demo"></a>

## CxO 演示

建议时长 12–15 分钟。核心叙事是：“同一个兼容 API 背后，Prompt 计算、Token 生成和可复用 KV 存储被解耦；GPU 间与存储到 GPU 的大数据都走专用 RDMA，平台还能同时给出策略、可观测性和回滚证据。”

### 演示前准备

- 先执行 Phase 1/2 validators 和 `demo-phase2.sh` 默认复放；任何 Gate 失败时取消现场性能演示。
- 浏览器打开既有 F5 发布的 Hubble UI Enterprise 与 fsomonitor Grafana，不新增入口或更改认证。
- Grafana 设 Last 15 minutes、5–10 秒 refresh；Hubble 预设 namespace `ai-serving`。
- 准备 `.183` API 终端与 node1 只读运维终端；先做一次短 warm-up。
- 不在管理层现场做 Pod 删除、driver/module reload、Nexus write、RAM disk 重建或新 near-40K 压测。

### 1. 一张图说明两阶段价值（2 分钟）

展示本文[整体架构](#architecture)：

- Phase 1：Prefill 和 Decode 独立扩展，3,130–3,180 MiB 级 KV 经 CX-7/RoCE/GDR 传递。
- Phase 2：相同 prefix 可从远端 KV storage 直接回到 Prefill GPU，减少重复 Prefill 计算；命中后仍走已经工作的 P→D 数据面。
- 客户端仍访问 `qwen-openai`，无需理解后端拆分。

### 2. 现场发送一个真实请求（2 分钟）

在 `.183` 执行：

```bash
curl --connect-timeout 10 --max-time 60 -sS \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-14B-FP8","messages":[{"role":"user","content":"/no_think\n请用三点说明企业为什么需要可观测的分布式 AI 推理平台。"}],"max_tokens":128,"temperature":0.2}' \
  http://192.168.160.113:30080/v1/chat/completions \
  | jq -r '.choices[0].message.content'
```

说明 `.183` 是允许无 token 的数据中心直连来源；互联网反向代理仍由 CNP 的 Secret header match 保护。

### 3. 展示 Phase 1 P/D 与专用数据面（2 分钟）

```bash
kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd' \
  -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.dynamo-role,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready'

decode=$(kubectl get pod -n ai-serving \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,dynamo-role=decode' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n ai-serving "$decode" --since=15m \
  | grep 'KV Transfer metrics' | tail -1
```

解释实际 KV transfer 与合成链路带宽的区别。强调独立扩展与管理网络隔离，不承诺尚未测试的并发容量。

### 4. 展示 Phase 2 “以存代算”（3 分钟）

```bash
pd-disaggregation/phase2/scripts/demo-phase2.sh
```

展示归档 run 的相同 payload、正确答案、39,936-token cache hit、Cold offload/Warm onboard、Direct GDS counters，以及 `32.575 s → 6.657 s` TTFT。用一句话解释：热请求不是“模型算得更快”，而是此前计算得到的 prefix KV 从远端 storage 通过 Direct GDS 回到 GPU，避免重复执行绝大部分 Prefill。

必须同时显示 Direct GDS 与 P→D NIXL 证据，避免把普通 NFS cache 或 compatibility mode 误说成 GDS。

### 5. 展示安全与可观测性（3 分钟）

在 Hubble UI Enterprise 过滤：namespace=`ai-serving`、destination=Frontend、L7/HTTP、path=`/v1/chat/completions`、verdict=`FORWARDED`。在 Grafana 展示 External Source IP、L7 by Workload 与 Network Overview。

管理层信息：请求来源、API path、策略 verdict、成功率和时延在同一时间轴上可查；Hubble 证明 API flow 和 policy，GDS/RDMA 则由另一组硬件与 runtime counters 证明，二者职责不同。

### 6. 用边界与恢复能力收尾（2 分钟）

- Phase 2 可一键 dry-run 和有序回退到 latest Phase 1 40K/FP8 baseline，不删除共享 Nexus QoS。
- worker 曾在 maintenance 后按实际故障范围重建，并完成新 NVML/CUDA、GDR、Direct GDS 与 near-40K A/B 复验。
- 当前 storage emulator 是 8 GiB 易失 RAM，不声称具备真实存储产品的持久性、HA、scale-out 或真实性能；生产路线需接入受支持的持久化平台并重新验收。

[返回目录](#toc)

<a id="operations"></a>

## 日常运维

### 启动与健康顺序

重启后应依次确认：node3 CX-7/ToS → RAM device/ext4 → NFS/RDMA server → node1 CX-7/ToS → NFS/RDMA client → `nvidia-fs`/GDS → Prefill/Decode/DGD。不要只看 systemd active；必须检查真实 mount、module、Pod 内 CUDA 和一次受控 I/O。

### 变更纪律

- 先 dry-run、备份和明确 owner，再做 package/systemd/Kubernetes/Nexus 变更。
- GPU 节点的 `daemon-reload`、container runtime、device plugin、driver/module 或 cgroup 变更都进入维护窗口。
- 每次维护后同时执行宿主 `nvidia-smi` 与 Pod 内新 `nvidia-smi`/PyTorch CUDA canary。
- NFS client 尚在使用时禁止强制 unmount；Prefill 仍持有 hostPath 时禁止拆 storage server；RAM device marker 不匹配时脚本必须停止。
- `nvidia-fs` statistics 开关用于证据采集后应恢复到 discovery 前状态；长期监控另行设计。

### 安全

- Nexus 仅使用环境中的 `NEXUS_USERNAME`/`NEXUS_PASSWORD`，使用后 unset；不写文件、不打印。
- 不读取 Kubernetes Secret 值；验证现有引用和 policy 行为即可。
- 证据目录使用 `umask 077`，提交前搜索 token、password、Authorization 和私钥特征。
- Demo 脚本默认复放历史 A/B，避免现场制造长时高负载或不可逆状态。

[返回目录](#toc)

<a id="problems-roadmap"></a>

## 已知问题与未来规划

| 问题 | 现象 | 原因 / 判断 | 当前措施 | 未来规划 |
|---|---|---|---|---|
| `daemon-reload` 后 GPU Pod 丢失访问 | 宿主 `nvidia-smi` 正常；旧 Prefill Pod 新进程报 `Failed to initialize NVML: Unknown Error`，旧 vLLM 可能仍能回答 | systemd cgroup 与 NVIDIA legacy runtime hook 的高概率交互；缺少完整审计时间线，因此不写成唯一法证结论 | 维护窗口；host/Pod 对照；只重建实际失败的 PodClique worker；不 reload driver；随后复验 CUDA/GDR/GDS/A/B | 独立评估 CDI，增加维护后新进程 canary 与告警，设计 P/D 冗余 |
| legacy PeerDirect 字段冲突 | `/proc/driver/nvidia-fs/stats` 显示 `Mellanox PeerDirect Supported: False`；matching CUDA 12.9 `gdscheck` 显示 Enabled | legacy stats 的检测路径与当前 Open driver/dmabuf 路径不一致 | 不隐藏差异；以 matching userspace、device injection、cuFile direct I/O、BAR1、RDMA/Nexus counters 组成强证据链 | 升级前按支持矩阵验证新版 `nvidia-fs`，保留 A/B 对照，不为消除一行输出破坏工作环境 |
| `nvidia-fs` DKMS 初建 symvers 失败 | package 安装成功但模块出现 NVIDIA P2P symbol version 问题 | helper 不能正确处理当前压缩 `.ko.zst`；driver DKMS 已有 matching `Module.symvers` | 用同 driver/kernel 的 DKMS symvers 只重建 `nvidia-fs`；不重装/reload driver | 评估发行版与 NVIDIA 已修复组合；升级做 isolated build、签名、vermagic 与回归 |
| MLNX NFS/RDMA 与 kernel API 不匹配 | OFED 3.4 source 在 Linux 6.11 原始构建失败 | sunrpc/xprtrdma API 变化 | 使用仓库审核 patch；脚本锁定 exact kernel/OFED、isolated build、nvfs hook 与 vermagic Gate | 迁移到厂商原生支持当前 kernel 的 OFED/NFSoRDMA 版本，减少本地 patch |
| NFSv3 不支持 `fallocate` | KVBM cache 文件预分配失败 | NFSv3/export 能力限制 | 使用对齐 O_DIRECT zero-fill，最终文件 5,997,854,720 bytes | 在真实目标存储上验证预分配、稀疏文件、O_DIRECT、崩溃恢复与容量治理 |
| RAM storage 易失且单点 | node3 reboot 后数据消失；无副本、HA、scale-out | 这是功能 Demo 的 storage emulator 设计 | 受控 systemd 重建；明确 VAST 边界；只用于功能演示 | 接入受支持的持久化远端存储，重做 GDS/NFSoRDMA、故障、扩展和 SLO 验收 |
| KVBM metadata fallback | 日志出现 `get_kv_cache_group_metadata` AttributeError，随后 fallback 到 block size | 当前 vLLM/KVBM API 版本差异 | fallback 非致命；以实际 offload/onboard/match 和正确答案验收 | 升级到接口一致的 Dynamo/vLLM/KVBM 组合并移除兼容 fallback |
| KVBM 功能边界 | CPU cache 关闭；local prefix caching 按 baseline 关闭 | 为了让 A/B 真正经过远端 KVBM 和真实 Prefill | 明确只测 Device↔Disk，使用相同 payload/hash | 增加 CPU tier、多副本共享、淘汰策略、并发和容量测试 |
| Prometheus Operator 所有权冲突 | v0.55.1 与 v0.82.2 跨 namespace reconcile，部分副本抖动 | 两套 controller watch/ownership 重叠 | 保留工作中的 Prometheus；Phase 2 dashboard 标为 optional skipped，不冒险改数据面 | 盘点 Helm/CR owner、收窄 watch scope、保证每个 CR 唯一 controller，再补正式 dashboard |
| 尚未迁移 CDI | legacy device injection 仍受 systemd/cgroup 风险影响 | 现有环境未由统一 CDI lifecycle 管理 | 不安装 GPU Operator 覆盖现有 stack；严格执行 maintenance canary | 在单节点验证 toolkit/device-plugin CDI，再分节点滚动，复测全部 GPU/RDMA workload |
| NVCR 大层 401 | 普通 pull 在认证 realm 切换后重新下载 | 慢链路与短期 registry token/partial 处理 | 使用可恢复 pull 和 CX-7 OCI stream copy | 建内部 registry/cache，纳入镜像签名、SBOM 与预热流程 |
| node4 CX-7 no-carrier | `ens65np1` 物理 link down | 任务前光模块/线缆/端口问题 | 当前 P/D/GDS 不依赖 node4 | 修复物理层后再做 MTU/PFC/RDMA/GDS 验收 |
| node3 时钟偏差 | node3 约比 node1 慢 2 分钟，跨节点日志时间线不直观 | NTP/chrony 未完全同步 | 证据同时记录 request UUID、角色和本地时间，不只靠 timestamp | 统一 chrony/NTP source 并监控 offset |
| 单次性能不可外推 | 本次 near-40K 得到 4.893×，但未做并发、长稳、故障或统计分布 | Demo 是功能 A/B，不是生产 benchmark | 所有材料明确 workload、payload、cache hit 和限制 | 设计多 prompt/并发/容量/尾时延/命中率/故障注入的正式 benchmark |

规划优先级建议：

1. CDI 与 maintenance canary，先降低 GPU 运行时运维风险。
2. Prometheus Operator 唯一所有权和 NTP 治理，提高长期可观测性与证据质量。
3. 用厂商原生支持的 kernel/OFED/GDS 组合替代本地 compatibility patch。
4. 接入真实持久化 GDS 存储，验证 HA、scale-out、重启恢复、容量与生产 SLO。
5. 在多副本 P/D、并发和真实业务数据集上完成性能/质量测试。

[返回目录](#toc)

<a id="rollback"></a>

## 回滚

回滚分两层：Phase 2 → latest Phase 1，或 Phase 1 → 项目实施前状态。两者都会影响单副本服务，必须在维护窗口执行。先做只读解析和 dry-run，不使用强制 unmount、driver reload 或未解析的通配删除。

### A. Phase 2 回退到 latest Phase 1 40K/FP8

先验证，不产生 live write：

```bash
pd-disaggregation/phase2/scripts/rollback-phase2.sh --dry-run
```

dry-run 必须确认回滚 baseline 同时包含 `--max-model-len 40960` 与 `--kv-cache-dtype fp8`，并通过 Kubernetes client/server dry-run。执行：

```bash
pd-disaggregation/phase2/scripts/rollback-phase2.sh --execute
```

脚本顺序：

1. 应用 Phase 2 discovery 时保存的 latest repo baseline DGD，等待 Prefill、Decode 与 DGD Ready。
2. 在新 worker 中执行 NVML 与新 PyTorch CUDA context canary。
3. 停 node1 NFS/RDMA client，再删除 node1↔node3 专用 ToS 和 Phase 2 units。
4. node3 停 export/listener，确认无 client/open user 后卸载 `/dev/ram0` ext4、释放 `brd`，再删除 ToS 和 units。
5. 运行 Phase 1 GDR、RoCE、Dynamo/API regression，确认 node1↔node2 P/D 不受影响。
6. 把 Phase 2 为证据采集打开的 `nvidia-fs` rw/peer statistics 恢复为 discovery 前的 0。

脚本会验证固定 IP/path/device/source/export/marker。Prefill 仍持有 hostPath 时 node1 unmount 会拒绝；client 仍在线时 node3 rollback 会拒绝。必须解决引用，不能强制卸载。

Phase 2 没有 Nexus write，因此交换机 rollback 是 no-op；不得删除共享的 Phase 1 VLAN 2310/QoS/PFC。自动 rollback 也不卸载 `nvidia-fs`、CUDA cuFile tools 或 `mlnx-nfsrdma` DKMS：DGD baseline 恢复后它们不在数据路径，保留可避免 package dependency removal 误伤 NVIDIA/RDMA stack。若合规要求移除 package，先停止所有使用者，审查 `phase2/nfs/remove-mlnx-nfsrdma.sh` 和发行版 `apt-get -s remove`，单独安排维护变更。

### B. Phase 1 回退到项目实施前状态

先确认 Phase 2 已回退且 node1/node3 不再使用 storage path。然后：

如果只回退 MTU、固定节点或 Local Service 改进，而保留其他 Phase 1 功能，先按 [phase1-improvement-before.md](pd-disaggregation/backup/phase1-improvement-before.md) 比对；不要执行完整清理。

完整回滚先删除本项目工作负载与平台。执行前确认没有其他对象使用 Dynamo CRD、KAI、Grove、NATS、ETCD、RDMA device plugin 或 RuntimeClass：

```bash
kubectl delete -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl delete -f pd-disaggregation/cilium/frontend-service-policy.yaml
helm uninstall dynamo-platform -n dynamo-system
kubectl delete -f pd-disaggregation/rdma/rdma-shared-device-plugin.yaml
kubectl delete -f pd-disaggregation/dynamo/nvidia-runtimeclass.yaml
```

默认不删除 Helm 遗留 CRD/PVC，以免影响共享对象或丢失数据。恢复项目实施前的 workload 与 Cilium policy：

```bash
kubectl apply -f pd-disaggregation/backup/qwen-vllm.yaml
kubectl apply -f pd-disaggregation/backup/dare-foundation-vllm.yaml
kubectl apply -f pd-disaggregation/backup/cilium-policies.yaml
```

等待原 Deployment Ready，并逐个验证原 Service。共享 PVC、API token Secret 和保留的 Foundation/ComfyUI 不需要恢复，也不得删除。

Nexus 回滚仍只使用环境凭据：

```bash
export NEXUS_USERNAME='当前用户名'
read -rsp 'Nexus password: ' NEXUS_PASSWORD; export NEXUS_PASSWORD
python3 pd-disaggregation/scripts/nexus_apply.py \
  pd-disaggregation/nexus/rollback.cfg
python3 pd-disaggregation/scripts/nexus_read.py \
  'show vlan brief' \
  'show running-config interface Ethernet1/1/1' \
  'show running-config interface Ethernet1/1/2' \
  'show running-config interface Ethernet1/2/1' \
  'show running-config interface Ethernet1/2/2' \
  'show policy-map system type network-qos'
unset NEXUS_PASSWORD
```

`rollback.cfg` 恢复改造前的 VLAN 2300、qos-group 3 MTU 2240、接口描述，删除 VLAN 2310，并保存 startup-config；接口原有 MTU 9216、PFC 和 service-policy 不删除。

主机回滚前保存当前 Netplan、unit 与 DCB 状态；在四节点逐一执行，并先用 `ibdev2netdev` 解析实际接口。只有路径明确属于本项目时才删除：

```bash
rdma_netdev=$(ibdev2netdev | awk '$2 == "port" && $3 == "1" {print $5; exit}')
test -n "$rdma_netdev"
mlnx_qos -i "$rdma_netdev" --pfc=0,0,0,0,0,0,0,0
mlnx_qos -i "$rdma_netdev" --dscp2prio=flush
systemctl disable --now dynamo-roce-qos.service
rm /etc/systemd/system/dynamo-roce-qos.service
rm /usr/local/sbin/dynamo-roce-qos.sh
rm /etc/netplan/95-roce-backend.yaml
netplan apply
ip link set dev "$rdma_netdev" mtu 1500
systemctl daemon-reload
```

仅在 node1/node2 确认没有 RDMA/GPU 进程使用 `nvidia_peermem` 后：

```bash
rm /etc/modules-load.d/nvidia-peermem.conf
modprobe -r nvidia_peermem
```

`systemctl daemon-reload` 仍可能影响其他运行中 GPU Pod，因此放在维护窗口并执行 NVML/CUDA canary。回滚完成后验证：原 workload/service/policy 恢复；CX-7 没有 backend IPv4、MTU 1500、trust PCP、PFC 关闭；VLAN 2310 消失；共享 GPU/Cilium/CEE/Foundation/ComfyUI 未被删除；Nexus running/startup-config 一致。node4 no-carrier 是任务前状态，不算回滚故障。

### 回滚可恢复性

配置文件删除可从 Git 和 `pd-disaggregation/backup/` 恢复；node3 RAM storage 中的数据在 stop/reboot 后不可恢复，这是设计属性。Phase 2 rollback 不删除历史非敏感 evidence。任何包级清理都不在自动回滚中，避免不可逆地破坏现有 driver/RDMA 环境。

[返回目录](#toc)

<a id="evidence"></a>

## 证据索引

| 结论 | 主要证据 |
|---|---|
| Phase 0 topology / baseline | [phase0-summary.md](pd-disaggregation/discovery/phase0-summary.md) |
| Phase 1 RoCE baseline、109.85 Gbit/s | [roce-baseline.md](pd-disaggregation/evidence/roce-baseline.md) |
| Phase 1 最终 P/D、GDR、40K、API/CNP | [phase1-final-validation.md](pd-disaggregation/evidence/phase1-final-validation.md) |
| 企业可观测性 | [enterprise-observability.md](pd-disaggregation/evidence/enterprise-observability.md) |
| NVCR 恢复下载 | [image-download-recovery.md](pd-disaggregation/evidence/image-download-recovery.md) |
| Phase 2 RAM 容量依据 | [ram-storage-sizing.md](pd-disaggregation/phase2/evidence/ram-storage-sizing.md) |
| Phase 2 28 项最终验收 | [phase2-final-validation.md](pd-disaggregation/phase2/evidence/phase2-final-validation.md) |
| 最终 post-persistence A/B | [comparison.md](pd-disaggregation/phase2/evidence/runs/20260725-135015/near40-ab-post-persistence/comparison.md) |
| 最终 KVBM/GDS counter delta | [counter-deltas.md](pd-disaggregation/phase2/evidence/runs/20260725-135015/near40-ab-post-persistence/counter-deltas.md) |
| NVML maintenance recovery | [nvml-daemon-reload-recovery.txt](pd-disaggregation/phase2/evidence/runs/20260725-135015/nvml-daemon-reload-recovery.txt) |
| Phase 2 rollback dry-run | [rollback-dry-run.txt](pd-disaggregation/phase2/evidence/runs/20260725-135015/rollback-dry-run.txt) |

最终 post-persistence run ID 为 `0725173741-6d792a`，payload SHA-256 为 `a4e86577fe41acc9f421ff312cb945aa1753090a78c767edc830659f5ba68904`。该标识用于关联归档证据，不含访问凭据。

[返回目录](#toc)
