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
pd-disaggregation/scripts/preflight.sh \
  |& tee "$evidence_dir/preflight-before.txt" || true
```

这里的 `preflight.sh` 是**只读的 Phase 1 最终依赖检查器**，不是安装器。它按顺序读取 Kubernetes/Helm 版本、`dynamo-platform` release、各节点可分配的 `nvidia.com/gpu`/`rdma/ib`、Dynamo system Pods、RDMA device-plugin DaemonSet、`RuntimeClass/nvidia`、Dynamo/Grove/KAI CRD 和共享 `hf-cache-pvc`。脚本使用 `set -e`，任何一项不存在就立即退出；在真正的 Phase 1 前，Dynamo/RDMA 对象尚未安装，因此这里允许非零退出并把它当作“待补能力清单”。Phase 1 安装完成后的同一脚本必须不带 `|| true` 且退出 0。它不检查宿主机 driver/NIC、Nexus、实际 RoCE 流量或推理请求，这些由后续 Gate 补齐。

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

`nexus_read.py` 是只读 SSH 包装器，默认连接 `192.168.160.162`，从环境变量取凭据，通过 `pexpect` 回答密码提示，先发送 `terminal length 0` 关闭分页，再逐条执行给定的 `show` 命令并在输出前标注命令名。它不进入 configuration mode，也不写 startup-config。为避免维护 known-host 文件，脚本关闭了 host-key 持久化检查，因此操作者必须通过管理网地址和既有运维边界确认目标确实是预期 Nexus。单条命令超时会打印 `COMMAND_FAILED` 和最多 4,000 字符的 partial output 后继续，脚本可能仍以 0 退出；验收时必须同时搜索 `COMMAND_FAILED`，不能只看进程退出码。

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

`nexus_apply.py` 不是声明式事务或自动回滚工具：它读取 command file 中所有非空、非 `!` 注释行，要求第一条必须为 `configure terminal`，随后按文件顺序逐条下发；发现 NX-OS `% Invalid`、`% Incomplete`、`ERROR` 或 prompt timeout 就停止。对 `copy running-config startup-config`，它会等待明确的 `Copy complete.`，避免把进度条中的 `#` 误当成 prompt。脚本打印每条已成功执行的命令，但不打印凭据。若中途失败，前面已经接受的命令仍可能留在 running-config，所以必须立即用 `nexus_read.py` 读取实际状态，再决定重试还是使用审核过的 rollback file。

本次 `desired.cfg` 的实际写入范围是：创建 VLAN 2310 并命名为 `DYNAMO_ROCE_BACKEND`；把既有 `qos_network/c-8q-nq3` MTU 从 2240 调为 4200；将四个 CX-7 端口切到 access VLAN 2310 并写入节点描述；最后保存 startup-config。它不创建新的 PFC/DSCP policy，已有 DSCP 26→priority/qos-group 3 和 PFC priority 3 继续复用。

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

Netplan YAML 使用 NetworkManager renderer，并按每张 CX-7 的实际 MAC match 对应 netdev；关闭 DHCPv4/v6 和 IPv6 link-local，只配置对应的 `172.31.230.11X/24` 与 MTU 4200，标记为 optional，不添加 gateway、DNS 或默认路由。MAC/netdev/IP 是节点专属值，复制到其他硬件前必须按 live discovery 改写。`dynamo-roce-qos.sh` 每次启动先用 `ibdev2netdev` 解析 RDMA port 1 对应的 Linux netdev；解析不到就失败，不猜接口名。随后它执行以下有状态修改：

- 把该 netdev MTU 设为 4200，使 RoCE path MTU 可协商为 4096；
- 将 DCBX owner 设为 OS、trust mode 设为 DSCP；
- 仅增加 DSCP 26→priority 3 映射，保持 priority 0–7 到 traffic class 0–7 的一一映射；
- 只对 priority 3 开启 PFC，其他七个 priority 保持关闭；
- 写入 7 米 cable length 参数。

对应 systemd unit 是 `Type=oneshot`/`RemainAfterExit=yes`，在 `network-online.target` 后重放这些设置并随 `multi-user.target` 启动。它不会配置 backend IP（由 Netplan 完成），不会修改 Nexus，也不会验证 pause/error counters；因此必须继续执行主机和交换机 Gate。

`systemctl daemon-reload` 在 systemd cgroup 与 NVIDIA legacy runtime hook 组合中可能使正在运行的 GPU 容器失去设备访问。首次安装应先完成 host/systemd 配置，再部署 P/D。若已有 GPU workload，必须使用维护窗口，并在 reload 后同时检查宿主机与 Pod 内的新 NVML/CUDA 进程；HTTP 200 不能替代该 canary。

仅在 node1、node2 安装 Peer Memory 模块启动配置：

```bash
install -m 0644 pd-disaggregation/rdma/nvidia-peermem.conf \
  /etc/modules-load.d/nvidia-peermem.conf
modprobe nvidia_peermem
```

`nvidia-peermem.conf` 的内容只有 module 名 `nvidia_peermem`，作用是让系统启动时加载 NVIDIA peer-memory provider；当前 `modprobe` 则立即加载，使 mlx5/UCX 可以注册 GPU memory。它不配置 RoCE、不执行数据传输，也不等同于 GDR PASS；仍需确认 module 与当前 Open driver/OFED 兼容，并完成 CUDA-memory `ucx_perftest`。卸载前必须确认没有 GPU/RDMA user。

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

这三项配置分别完成：

- `rdma-shared-device-plugin.yaml` 创建 `kube-system/rdma-devices` ConfigMap 和 privileged DaemonSet。它只选择 Mellanox vendor `15b3`、device `1021`、driver `mlx5_core`、Ethernet link type，把每个匹配 HCA 以共享资源 `rdma/ib` 注册给 kubelet；它把 `/dev` 和 kubelet device-plugin socket 暴露给插件，但不配置 NIC IP、MTU 或 PFC。
- `nvidia-runtimeclass.yaml` 只创建名为 `nvidia`、handler 也为 `nvidia` 的 RuntimeClass，前提是既有 containerd 已配置该 handler；它不会安装 driver、toolkit 或 device plugin。
- Helm chart 安装 Dynamo operator、Grove、KAI scheduler、单副本 ETCD（1 GiB PVC）和 NATS JetStream（2 GiB PVC），operator discovery backend 为 ETCD。它会创建 cluster-scoped CRD/RBAC 和 namespace-scoped Pods/PVC，故卸载前必须检查是否被其他 workload 共用。

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

更具体地说，`resumable-nvcr-pull.sh` 只接受带 tag 的 `nvcr.io/...:tag` 且要求 root。它获取匿名 pull token，选择 `linux/amd64` manifest，逐个校验 manifest/blob 的期望 size 与 SHA-256；优先复用 containerd 已完成 blob，也会从 containerd ingest 保存更大的 partial，然后用 HTTP Range/`curl --continue-at -` 在 token 过期后续传。所有 blob 完成后组装 OCI layout，以 stream 方式导入 `k8s.io` containerd namespace，并用 `ctr images check` 验证完整性。它会在 `/tmp/dynamo-nvcr-resume/` 保留可恢复数据，不自动清理。

`copy-image-over-roce.sh` 同样要求 root。它先用 `ip route get` 确认目标 backend IP 实际走指定的 `ROCE_SOURCE_DEVICE`（默认 node1 的 `ens65np0`），再确认源端 image 在 `k8s.io` namespace 完整、目标 SSH/containerd 可用；然后把 `ctr images export` 的 OCI stream 直接经 SSH 送入目标 `ctr images import`，不创建大型中间 tar。最后在目标执行 `ctr images check`。它使用 batch SSH 且不持久化 host key，因此只应在已确认的专用 backend 地址上运行。

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

Phase 1 DGD 的实际效果是：复用而不创建 `hf-cache-pvc`；创建一个固定 node3 的普通 Cilium Frontend Pod，以及固定 node1/node2、各请求 1 GPU + 1 `rdma/ib`、使用 hostNetwork 的 Prefill/Decode worker。Grove/KAI 根据 DGD 创建并管理 PodClique/PodGang；启动/健康端口是 19191，最长 startup 窗口约 120 分钟，用于模型首次加载。应用同名 DGD 会触发 operator reconciliation，参数变化可能重建单副本 worker 并中断服务。

`frontend-service-policy.yaml` 创建或更新 `qwen-openai` NodePort 30080，并设置 `externalTrafficPolicy: Local`；同时创建 CiliumNetworkPolicy：cluster identity 可访问 8000 上的 `/v1/*`、metrics/health；host/remote-node 可访问 Frontend 动态控制端口；唯一的互联网反向代理 `192.168.200.8/32` 访问 `/v1/*` 时必须匹配既有 `vllm-api-token` Secret；其他数据中心来源可无 token 访问 `/v1/*`。policy 允许 Frontend 全部 egress。manifest 只引用 Secret，不读取或复制 Secret 值。

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

这些 validator 都是只读检查或轻量 API GET，不安装组件：

| 脚本 | 它具体读取什么 | 退出 0 能说明什么 | 仍不能说明什么 |
|---|---|---|---|
| `preflight.sh` | Helm release、平台/插件 Pods、node allocatable、RuntimeClass、CRD、PVC | Phase 1 Kubernetes 依赖齐全 | 不证明网络或推理数据面 |
| `validate-roce.sh` | P/D Pod 内 IP/RDMA link、`ibv_devinfo`、`/dev/infiniband`、`UCX_*`；最后列 placement/hostNetwork | 两端容器看得到预期 RDMA device 与 UCX 约束 | 不主动发流量，也不读取 Nexus counters |
| `validate-gdr.sh` | 两端 Pod 内新 `nvidia-smi` 与 `ucx_info -d` 的 CUDA/memory-domain/transport | NVML 和 UCX CUDA registration capability 同时可用 | 不是 CUDA buffer 跨机传输证明；还需 `ucx_perftest` |
| `validate-dynamo.sh` | DGD、Grove objects、Pods、Services/EndpointSlice，以及 P/D/Frontend 日志中过滤后的 NIXL/UCX/routing/request 行 | 角色、服务发现和日志中存在 P/D/NIXL 证据 | grep 日志可能含历史请求；必须用 UUID 与 counters 关联新请求 |
| `validate-api.sh` | Frontend Pod 内访问 `qwen-openai:8000/v1/models`；可选经 SSH 从 `.183` 访问 NodePort | cluster internal 和指定直连客户端分别 HTTP 200 | 未测试互联网反向代理 token；未发 chat completion |
| `validate-hubble-enterprise.sh` | Frontend 所在节点的 CEE agent 内置 Hubble version/status，以及最近 10 分钟到 Frontend 的 HTTP flows | CEE Hubble 健康且能观察 API L7/policy | 不证明 KV 走 RDMA/GDS |

`validate-dynamo.sh` 的 grep 若没有匹配会因 `set -euo pipefail` 返回非零；这通常表示没有对应日志或组件未初始化，不能简单忽略。`validate-api.sh` 未设置 `EXTERNAL_CLIENT_SSH` 时只做内部检查并以 0 退出，所以外部验收必须显式设置该变量。

必须同时满足：DGD Ready；三角色节点正确；P/D Pod 中 `mlx5_0`、RDMA device、CUDA registration 可见；UCX 不含 TCP fallback；新 `nvidia-smi` 和新 PyTorch CUDA context 正常；内部和 `.183` API HTTP 200；Hubble health OK。真正的 GDR 强证据还需在维护窗口执行本文[技术演示](#engineering-demo)中的 CUDA-memory `ucx_perftest`，并用同一请求 UUID、NIXL metrics 和 NIC/Nexus counters 交叉证明真实 P→D。

<a id="install-phase2"></a>

### Phase 2：RAM、NFSoRDMA、Direct GDS 与 KVBM

Phase 2 只在 Phase 1 全部 Gate 通过后开始。任何步骤若会 reload/reinstall NVIDIA driver、改变 node1↔node2 P/D QoS、强制卸载被使用的文件系统，或无法证明 exact kernel/module 匹配，应停止而不是强行继续。

node3 会直接运行仓库中的 `nfs/`、`storage/`、`systemd/` 脚本，因此必须具有与 node1 同一版本的文件树。若没有共享 checkout，可从 node1 只复制这三个实施目录并核对内容；不要把历史 evidence、凭据或整个工作目录无差别同步过去：

```bash
ssh root@192.168.160.113 'install -d -m 0755 /root/ns_ai-serving'
tar -C /root/ns_ai-serving -cf - \
  pd-disaggregation/phase2/nfs \
  pd-disaggregation/phase2/storage \
  pd-disaggregation/phase2/systemd \
  | ssh root@192.168.160.113 'tar -C /root/ns_ai-serving -xf -'

sha256sum \
  pd-disaggregation/phase2/nfs/build-install-mlnx-nfsrdma.sh \
  pd-disaggregation/phase2/nfs/mlnx-nfsrdma-3.4-linux-6.11.patch \
  pd-disaggregation/phase2/storage/start-ram-storage.sh \
  pd-disaggregation/phase2/systemd/install-persistence.sh \
  | ssh root@192.168.160.113 \
      'cd /root/ns_ai-serving && sha256sum -c -'
```

该复制只写 node3 的仓库副本，不安装 module、package、unit 或 service。四个代表性 SHA-256 全部 `OK` 后才能继续。

#### 1. Phase 2 Discovery、Backup 与容量 Gate

```bash
pd-disaggregation/phase2/scripts/preflight-phase2.sh || true
sed -n '1,220p' pd-disaggregation/phase2/evidence/ram-storage-sizing.md
```

`preflight-phase2.sh` 是**已建成 Phase 2 的拓扑/挂载检查器**，不是 package 安装前检查器。它验证 `kubectl`、SSH、RDMA、ethtool、findmnt、nfsstat 命令；要求 Phase 1 DGD Ready 且 Frontend/Prefill/Decode 分别位于 node3/node1/node2；只检查 Nexus 凭据变量是否存在而不读取值；要求 node1 已挂载 `/mnt/dynamo-g4`，并经 batch SSH 确认 node3 RAM marker 与 `mlx5_0` ACTIVE。干净的 Phase 2 起点还没有 mount/marker，所以这里预期非零并暂时允许 `|| true`；它的输出是待安装差距。完成 storage/NFS 后必须不带 `|| true` 重新运行并退出 0。

该脚本不检查 GDS package candidate、kernel header、OFED source/symvers、IOMMU、Secure Boot 或内存容量，因此这些不能从它的 `PASS` 推断。安装前还要分别采集：

```bash
# node1：GPU/GDS client 候选状态
uname -r
dpkg-query -W dkms linux-headers-"$(uname -r)" \
  nvidia-driver-575-open nvidia-fs-dkms gds-tools-12-9 libcufile-12-9 2>/dev/null || true
dkms status
cat /proc/cmdline
cat /proc/driver/nvidia-fs/stats 2>/dev/null || true

# node3：RAM/NFS-RDMA server 候选状态
ssh root@192.168.160.113 \
  'uname -r; free -h; lsblk; findmnt; exportfs -v 2>/dev/null || true; dkms status; grep -F CONFIG_GPU_DIRECT_STORAGE /usr/src/ofa_kernel/$(uname -m)/$(uname -r)/configure.mk.kernel 2>/dev/null || true'
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

`NVIDIA_SYMVERS` 指向当前 `nvidia/575.51.03` DKMS 已生成的 symbol CRC 表，使 `nvidia-fs` 在编译时使用与当前 `nvidia.ko` 完全一致的 `nvidia_p2p_*` 导出符号版本；随后 `dkms install` 只替换 `nvidia-fs.ko`，`depmod` 更新模块索引，`modprobe` 首次加载 GDS filesystem module。整个过程不卸载 `nvidia`、不重启 containerd、不重启宿主机。若 DKMS build/install 输出新的 NVIDIA driver package 变更、vermagic 不匹配或 module signing 失败，应停止，不得通过忽略 symbol/version error 强制加载。

该 workaround 只适用于版本和路径完全一致的环境；若 driver/kernel 不同，必须重新获得 matching symvers，不可复制本环境文件。验收：

```bash
dkms status -m nvidia-fs -v 2.26.6
modinfo nvidia-fs | grep -E '^(filename|version|vermagic):'
/usr/local/cuda-12.9/gds/tools/gdscheck -p
nvidia-smi
```

期望 module 位于 `updates/dkms`，vermagic 与运行 kernel 一致，matching CUDA 12.9 `gdscheck` 能识别 L4、Open driver、IOMMU disabled。此时 NFS 尚未挂载，`NFS: Unsupported` 不应提前被记为 GDS 失败；最终判定在 mount 和实际 Direct I/O 后完成。

#### 3. 在 node1、node3 构建 MLNX NFS/RDMA 3.4

这里解决的具体问题是：MLNX_OFED `mlnx-nfsrdma` 3.4 的 `svc_rdma.c` 仍把 sysctl callback 声明为 `struct ctl_table *table`，而 Linux 6.11 的 `proc_handler` API 已要求第一个参数为 `const struct ctl_table *table`；未经修改会在 callback type 检查处编译失败。仓库的 [Linux 6.11 compatibility patch](pd-disaggregation/phase2/nfs/mlnx-nfsrdma-3.4-linux-6.11.patch) **只把 `svcrdma_counter_handler` 的第一个参数增加 `const`**，不修改 NFS/RDMA protocol、queue、memory registration、NVFS hook 或 I/O 数据路径。它是针对这个编译 API 差异的最小补丁，不表示任意 Linux 6.11/OFED 组合都受支持。

`build-install-mlnx-nfsrdma.sh` 把可接受范围硬锁为 `6.11.0-26-generic`、MLNX_OFED `24.10.OFED.24.10.2.1.8.1` 和 module version 3.4。运行时会：

1. 检查 vendor source 位于 `/usr/src/mlnx-ofed-kernel-.../net/sunrpc/xprtrdma`，matching OFA `Module.symvers`/`configure.mk.kernel` 存在，且明确包含 `CONFIG_GPU_DIRECT_STORAGE=y`。
2. 若已加载 `rpcrdma`，只有它已经来自本 kernel 的 `updates/dkms` 才按幂等成功退出；任何其他 owner/path 都拒绝覆盖。
3. 把 vendor source 复制到 `/tmp/dynamo-phase2-mlnx-nfsrdma.*`，从 vendor `_makefile_`/`mlnx-nfsrdma_spec_` 生成 build files，以 `patch -p1 --forward` 应用上述单行 API patch，并写入 Phase 2 owner marker。
4. 先在临时目录编译 `rpcrdma.ko`、`svcrdma.ko`、`xprtrdma.ko`；逐个核对产物与 vermagic，并用 `nm` 要求 `rpcrdma.ko` 仍含 `nvfs_*` GDS hooks。
5. 非 `BUILD_ONLY` 模式才把审核过的 source 移到 `/usr/src/mlnx-nfsrdma-3.4`，执行 DKMS add/build/install、`depmod` 和 `modprobe rpcrdma`，最后确认实际加载路径是 `/lib/modules/<kernel>/updates/dkms/`。

`BUILD_ONLY=1` 只完成第 1–4 项，打印临时 build 目录、module SHA-256、depends/vermagic 后退出；不写 DKMS、`/lib/modules` 或已加载 module。临时 build 目录会保留供审计，确认后可在独立清理步骤删除。先在 node1、node3 分别做 isolated build：

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

该安装会写 `/usr/src/mlnx-nfsrdma-3.4`、`/var/lib/dkms/mlnx-nfsrdma/` 和 `/lib/modules/6.11.0-26-generic/updates/dkms/`，并加载 `rpcrdma`；它不 reload NVIDIA driver、不修改 OFED 原始 source、不启动 NFS server/client。期望三个 module 来自 `updates/dkms`，vermagic 正确，`dkms status -m mlnx-nfsrdma -v 3.4` 为 installed。若系统已有非本阶段 `rpcrdma` 被加载，脚本会拒绝覆盖；先调查 owner，不要强制替换。组件级移除脚本 `remove-mlnx-nfsrdma.sh` 只有在 `rpcrdma` use-count 为 0、source marker 正确时才卸载 modules、删除 DKMS/source；正常 Phase 2 rollback 默认保留这些 packages/modules，避免误伤工作中的 RDMA stack。

#### 4. 在 node3 创建受控 RAM storage

```bash
sudo pd-disaggregation/phase2/storage/start-ram-storage.sh
findmnt /srv/dynamo-g4
df -h /srv/dynamo-g4
test -f /srv/dynamo-g4/.dynamo-phase2-ram-storage
```

`start-ram-storage.sh` 是有破坏性写入但带严格 owner Gate 的脚本。它只接受 4/6/8 GiB、`/dev/ramN` 和固定 `/srv/dynamo-g4`；默认选择 8 GiB `/dev/ram0`。创建前它要求容量不超过物理内存 25%，扣除 RAM disk 后仍保留 `max(35% MemTotal, 16 GiB)` 的 `MemAvailable`；如果目标已经挂载，它只在 source、size、marker 全部匹配时按幂等成功返回。

首次创建时，脚本会按需 `modprobe brd rd_nr=1 rd_size=<KiB>`，核对 block device/size、确认没有其他 mount，并用 `wipefs -n` 要求目标**完全没有现有 filesystem signature**；随后才对 `/dev/ram0` 执行 `mkfs.ext4 -F -L DYNAMO_G4_RAM`，以 `data=ordered,nosuid,nodev` 挂载，创建 `.dynamo-phase2-ram-storage` owner marker，并把 device/path/size 及“是否由本脚本加载 brd”写入 root-only `/var/lib/dynamo-phase2/ram-storage.env`。因此绝不能把 `RAM_DEVICE` 指向真实磁盘；任何 signature/owner 不明确都应停止调查。

对应 `stop-ram-storage.sh` 只在 source/marker 正确、NFS export 已删除、没有 open user 时卸载；仅当 `brd` 确由本阶段加载且没有其他 RAM device mount 时才卸载 module。RAM 内容在 stop/reboot 后不可恢复。

期望 `/dev/ram0`、ext4 label `DYNAMO_G4_RAM`、挂载点 `/srv/dynamo-g4`、8 GiB 容量和 owner marker 全部匹配。

#### 5. 启动 node3 NFS/RDMA server

先在 node3 模拟 NFS package 变更；只有不会破坏既有服务时才允许脚本安装缺少的 package：

```bash
apt-get -s install nfs-kernel-server
sudo INSTALL_PACKAGE=1 \
  pd-disaggregation/phase2/nfs/node3-nfs-rdma-setup.sh
```

若 package 已存在，直接省略 `INSTALL_PACKAGE=1`。`node3-nfs-rdma-setup.sh` 把允许范围锁定为 server `172.31.230.113`、client `172.31.230.111`、export `/srv/dynamo-g4`、file `/etc/exports.d/dynamo-phase2.exports`、RDMA port 20049，并要求本机拥有 server IP 和 RAM owner marker。它先记录 `nfs-kernel-server` 是否由本阶段安装、`nfs-server` 此前是否 active；若缺 package，内部会再做一次 apt simulation，而且只允许新增 `nfs-kernel-server` 本身，出现任何未审核的额外 install/replace 就拒绝。

脚本创建的 export 内容是：

```text
/srv/dynamo-g4 172.31.230.111(rw,async,insecure,no_root_squash,no_subtree_check)
```

`async` 和 `no_root_squash` 只适合这个隔离、单 client、易失 RAM Demo；不能原样复制到多租户或持久化生产存储。若 export file 已存在但内容不同，脚本拒绝覆盖。随后它加载 `rpcrdma`、启动但不 enable 系统 `nfs-server`、执行 `exportfs -ra`，并通过 `/proc/fs/nfsd/portlist` 增加 `rdma 20049` listener；原 package/service 状态写入 root-only `/var/lib/dynamo-phase2/nfs.env`，供回滚判断哪些资源应保留。

此时先不要建立 client mount。RDMA-CM traffic-class 规则只影响随后创建的连接，应先完成下一步 ToS，再 mount。

#### 6. 先固定 NFS/RDMA ToS 106，再建立 node1 mount

在 node1、node3 各自的本地仓库执行 `apply`。`start` 不是该脚本支持的子命令：

```bash
# node1
sudo pd-disaggregation/phase2/systemd/rdma-cm-tos106.sh apply

# node3
ssh root@192.168.160.113 \
  'cd /root/ns_ai-serving && pd-disaggregation/phase2/systemd/rdma-cm-tos106.sh apply'
```

`rdma-cm-tos106.sh` 不改全局 DSCP map。它通过 backend IP 自动识别当前 host，只允许 node1 或 node3，然后向 `/sys/class/infiniband/mlx5_0/tc/1/traffic_class` 写一条 endpoint-specific rule：node1→node3 或 node3→node1，`tclass=106`。106 对应 DSCP 26 加 ECN bits，使 storage RDMA QP 命中 Phase 1 的 priority/qos-group 3；写后必须逐字 read-back。`check` 只验证规则，`remove` 用 `tclass=-1` 删除同一 endpoint rule。规则针对后续创建的 RDMA-CM QP，因此应在 NFS client mount 前应用。

现在在 node1 建立 mount：

```bash
sudo pd-disaggregation/phase2/nfs/node1-nfs-rdma-mount.sh
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/dynamo-g4
nfsstat -m
```

`node1-nfs-rdma-mount.sh` 同样锁定 server/export/mount/port，加载 `rpcrdma`，创建 `/mnt/dynamo-g4`，再用 `vers=3,proto=rdma,port=20049,hard,timeo=600,retrans=2` 挂载。`hard` 表示 server 暂时不可达时 I/O 会等待/重试而不是静默返回短数据；`timeo=600` 是 NFS decisecond 计时，即 60 秒。脚本挂载后再次检查 NFSv3、RDMA transport 和远端 owner marker，并打印 route。若已有 mount，只有 source/options 都匹配才按幂等成功；不会把 TCP mount 自动改成 RDMA。

若在 ToS rule 之前已经建立了 mount，先停止 Prefill/确认无 open user，再运行 `node1-nfs-rdma-unmount.sh`，随后重新 mount；该 unmount 脚本会核对 source/marker 并在 `fuser -m` 发现使用者时拒绝，不得强制 `umount -f`。期望 source 为 `172.31.230.113:/srv/dynamo-g4`，filesystem 为 NFSv3，options 明确包含 `proto=rdma,port=20049`。输出中的 `mountproto=tcp` 仅是 NFSv3 mountd control plane；data transport 仍必须是 `proto=rdma`。

先后执行一次 Direct write/read，再通过 host priority counters、packet capture 或 Nexus qos-group 3 counters 证明 ToS 106/DSCP 26 分类。Phase 2 `nexus/desired.cfg` 与 `rollback.cfg` 都是 no-op 记录，因为 Phase 1 配置已经覆盖 node3；不得为 Phase 2 重写共享 Nexus QoS。

#### 7. 先做 synthetic Direct GDS Gate

先记录统计开关的原值，再启用仅用于证据采集的 read/write 与 peer statistics：

```bash
rw_stats_before=$(cat /sys/module/nvidia_fs/parameters/rw_stats_enabled)
peer_stats_before=$(cat /sys/module/nvidia_fs/parameters/peer_stats_enabled)
printf 'rw_stats_before=%s\npeer_stats_before=%s\n' \
  "$rw_stats_before" "$peer_stats_before" \
  | tee "$evidence_dir/nvidia-fs-stats-before.txt"
printf '1\n' | sudo tee /sys/module/nvidia_fs/parameters/rw_stats_enabled >/dev/null
printf '1\n' | sudo tee /sys/module/nvidia_fs/parameters/peer_stats_enabled >/dev/null
cat /proc/driver/nvidia-fs/stats
/usr/local/cuda-12.9/gds/tools/gdscheck -p
```

这两个 sysfs 参数只开启计数，不切换 I/O path。变量只在当前 shell 有效；若分会话操作，应从 evidence file 恢复原值。本环境原值均为 0，其他系统必须恢复其实际原值而不是固定写 0。

在 node1 host 上对一个明确的临时文件执行 256 MiB、1 MiB 对齐的单线程 GPU_DIRECT write/read：

```bash
gdsio=/usr/local/cuda-12.9/gds/tools/gdsio
gds_test_file=/mnt/dynamo-g4/.phase2-gdsio-256m.bin

cat /proc/driver/nvidia-fs/stats \
  | tee "$evidence_dir/gdsio-nvidia-fs-before.txt"
"$gdsio" -f "$gds_test_file" -d 0 -m 0 -w 1 \
  -s 256M -o 0 -i 1M -x 0 -I 1 \
  | tee "$evidence_dir/gdsio-direct-write.txt"
"$gdsio" -f "$gds_test_file" -d 0 -m 0 -w 1 \
  -s 256M -o 0 -i 1M -x 0 -I 0 \
  | tee "$evidence_dir/gdsio-direct-read.txt"
cat /proc/driver/nvidia-fs/stats \
  | tee "$evidence_dir/gdsio-nvidia-fs-after.txt"
rm -f -- "$gds_test_file"
```

参数含义：`-d 0` 选择 L4 GPU 0，`-m 0` 使用 `cudaMalloc` device buffer，`-w 1` 单线程，`-s/-i` 分别是 dataset/I/O size，`-x 0` 明确选择 Storage↔GPU 的 `GPU_DIRECT` 路径，`-I 1/0` 分别为 write/read。不要把 `-x 1` CPU_ONLY 或 `-x 4` PAGE_CACHE 结果写成 Direct GDS。命令会在易失 RAM export 中创建并最终删除固定测试文件；若 write 失败，不执行 read/删除之前先保存错误与 counters。

在 write/read 前后还要同时采集 node1/node3 的 `ethtool -S` RDMA/prio3/error counters 和 Nexus 三个端口/qos-group 3 counters，才能区分本机 API 成功与真正的 NFSoRDMA wire traffic。

要验证 Kubernetes runtime injection，可临时应用受限 probe。该 manifest 只创建一个固定 node1、最长 sleep 1,800 秒的 Pod；它申请 `RuntimeClass/nvidia`，设置 `NVIDIA_GDS=enabled`/driver capabilities，挂载 `/mnt/dynamo-g4`、`/run/udev` 和 host `gdsio` binary，但**不会自动发 I/O**：

```bash
kubectl apply -f pd-disaggregation/phase2/dynamo/gds-runtime-probe.yaml
kubectl wait -n ai-serving --for=condition=Ready \
  pod/phase2-gds-runtime-probe --timeout=5m
kubectl exec -n ai-serving phase2-gds-runtime-probe -- \
  /opt/phase2/gdsio -f /mnt/dynamo-g4/.phase2-probe-64m.bin \
  -d 0 -m 0 -w 1 -s 64M -o 0 -i 1M -x 0 -I 1
kubectl exec -n ai-serving phase2-gds-runtime-probe -- \
  /opt/phase2/gdsio -f /mnt/dynamo-g4/.phase2-probe-64m.bin \
  -d 0 -m 0 -w 1 -s 64M -o 0 -i 1M -x 0 -I 0
kubectl exec -n ai-serving phase2-gds-runtime-probe -- \
  rm -f -- /mnt/dynamo-g4/.phase2-probe-64m.bin
kubectl delete pod -n ai-serving phase2-gds-runtime-probe
```

只有同时满足下列条件才判定 Direct GDS PASS：

- matching CUDA 12.9 `gdscheck` 在 NFS/RDMA mount 存在时报告 NFS Supported、Mellanox PeerDirect Enabled、L4 supports GDS、IOMMU disabled。
- Pod 获得 `NVIDIA_GDS=enabled`、`NVIDIA_DRIVER_CAPABILITIES=all`、`/dev/nvidia-fs*` 和 matching cuFile library。
- `nvidia-fs` direct read/write、BAR1 map 和 RDMA/Nexus counters 在同一次 I/O 中同向增加。
- page-cache、DMA/BAR1、I/O state error 均为 0；不带 GDS device/env 的对照 probe 不产生 direct counters。

只看到 HTTP 200、文件内容正确、`gdscheck` 一行或 NFS mount 都不足以证明 Direct GDS。`/proc/driver/nvidia-fs/stats` 的 legacy `Mellanox PeerDirect Supported: False` 与 matching CUDA 12.9 `gdscheck` 和实际 direct counters 存在已记录差异，必须保留该差异并使用完整证据链判定。

此处不要立即关闭 statistics；第 8–9 步还要用它记录真实 KVBM Direct GDS delta。完成正式 A/B 后再按第 9 步末尾恢复原值。

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
```

应用该 DGD 会保留 Frontend/node3 和 Decode/node2 配置；Prefill/node1 从单独 `NixlConnector` 改为 `PdConnector`，内部串联 `DynamoConnector`（KVBM）与 `NixlConnector`（P→D）。它新增 `/mnt/dynamo-g4` hostPath、只读 `/run/udev`、`NVIDIA_GDS=enabled`、6 GB disk cache、300 秒 KVBM init timeout 和 6880 metrics；Decode 仍只使用 NIXL。因为更新同名单副本 DGD 会重建 Prefill，必须等待新的 Pod Ready，并检查新 Pod 的 NVML/CUDA，而不是沿用旧 Pod 名。

三个 validator 的行为不同：

- `validate-nfs-rdma.sh` 只读核对 mount source、NFSv3、`proto=rdma`、port 20049、marker、node1 route source，并经 SSH read-back node3 listener/export。
- `validate-gds.sh` 要求 host `nvidia_fs`/device/stats 与 RDMA mount 存在，使用 matching CUDA 12.9 library 运行 `gdscheck`，核对 Prefill GDS env/device/mount 和 `G1->G3 direct offload enabled` 日志，并要求累计 direct read/write counters 已经大于 0。因此必须先完成 synthetic GDS；它本身不发 I/O，也不证明 counters 来自当前请求。
- `validate-kvbm.sh` 要求 DGD Ready、Prefill spec 含 Pd/Dynamo/NixlConnector、40K/FP8 和 GDS 配置，并要求 `kvbm_offload_blocks_d2d`、`kvbm_onboard_blocks_d2d`、`kvbm_matched_tokens` 都已经大于 0。全新 cache 在第一次 cold/warm A/B 前这些值应为 0，所以此处**暂不运行**；在下一步 A/B 后运行。

KVBM 在 NFSv3 上不能使用 `fallocate`，本环境通过 `DYN_KVBM_DISK_ZEROFILL_FALLBACK=true` 启用 4 KiB 对齐 O_DIRECT zero-fill，最终创建 5,997,854,720-byte cache 文件；`DYN_KVBM_DISABLE_DISK_OFFLOAD_FILTER=true` 允许 Demo prefix 进入 disk tier。这是已知兼容/演示设置，不代表 NFS 提供 `fallocate`，也不应未经容量与淘汰策略评估复制到生产环境。

#### 9. 正式 cold/warm A/B Gate

首次安装的 KVBM metrics 还是 0，不能直接调用 `demo-phase2.sh --run-ab`：该包装器会在新请求前先执行 `validate-kvbm.sh`，目的是保护已经建成的 Demo，而不是引导空 cache。首次 A/B 应直接调用底层采集器：

```bash
new_run="pd-disaggregation/phase2/evidence/runs/$(date +%Y%m%d-%H%M%S)-ab"
pd-disaggregation/phase2/scripts/demo-kv-offload-reload.sh "$new_run"
RUN_EVIDENCE="$new_run" pd-disaggregation/phase2/scripts/validate-gds.sh
pd-disaggregation/phase2/scripts/validate-kvbm.sh
pd-disaggregation/phase2/scripts/demo-phase2.sh --evidence "$new_run"
```

`demo-kv-offload-reload.sh` 会拒绝已存在的输出目录，随后执行以下完整流程：

1. 在唯一 Ready Prefill Pod 内使用运行模型的真实 tokenizer，二分搜索 39,500–40,000 input tokens 的 prompt；生成随机 run ID、确定性期望答案和 payload SHA-256。
2. 采集 before KVBM metrics、`nvidia-fs` stats、node1/2/3 RDMA/prio3/error counters、DGD/Pods；若 Nexus 凭据存在，再只读采集三个端口/queue counters，否则在 evidence 中明确标记 skipped。
3. 发 streaming cold request，记录 SSE、HTTP、request IDs、TTFT/total/usage/答案；最长等待 300 秒确认 `kvbm_offload_blocks_d2d` 增长，再采集 after-cold。
4. 对逐字节相同 payload 发 warm request，等待 onboard 和 matched counters 增长，再采集 after-warm 与三角色最近 30 分钟日志。
5. `compare-prefill-vs-gds.py summarize` 严格要求 cold/warm HTTP 200、答案正确、payload hash 与 token 数一致、实际 input 在目标范围、warm cached tokens>0，以及 offload/onboard/matched delta>0；生成 `comparison.json`/`.md`。它不以“warm 必须更快”作为功能 Gate，避免把噪声当正确性。

`demo-phase2.sh --evidence` 随后重新跑 NFS/GDS/KVBM validators，读取指定 evidence 的 comparison 和 `nvidia-fs` before/after，拒绝错误 counter，并打印 Direct GDS write/read、P→D NIXL 与 TTFT 摘要。至此已有非零 KVBM counters；以后要生成新 A/B，才可使用 `demo-phase2.sh --run-ab <全新目录>`，它会先确认现有链路健康再调用同一底层采集器。

A/B 必须满足：冷、热 payload hash 相同；使用运行中模型的真实 tokenizer；答案正确且一致；cold 出现 offload/direct writes；warm 出现 cached tokens/onboard/direct reads；P→D NIXL 两次都存在；node1/node2/node3 与 Nexus counters 方向一致且 errors/discards 为 0。不要只凭 TTFT 更快宣告通过。

正式 evidence 已归档后，恢复第 7 步记录的统计开关原值：

```bash
printf '%s\n' "$rw_stats_before" \
  | sudo tee /sys/module/nvidia_fs/parameters/rw_stats_enabled >/dev/null
printf '%s\n' "$peer_stats_before" \
  | sudo tee /sys/module/nvidia_fs/parameters/peer_stats_enabled >/dev/null
```

如果当前 shell 已丢失变量，从 `nvidia-fs-stats-before.txt` 人工核对后再恢复，不要猜值。本环境 discovery 前两项均为 0；其他系统以自身记录为准。

<a id="persistence"></a>

### 持久化与最终交接

核心 Phase 2 已通过后，才在 node1、node3 安装有限的持久化 units：

```bash
# node1
sudo pd-disaggregation/phase2/systemd/install-persistence.sh

# node3；要求该节点也有同一版本的 phase2/ 文件树
ssh root@192.168.160.113 \
  'cd /root/ns_ai-serving && pd-disaggregation/phase2/systemd/install-persistence.sh'

systemctl list-unit-files 'dynamo-phase2-*'
systemctl --no-pager --full status 'dynamo-phase2-*'
```

`install-persistence.sh` 要求 root，通过 backend IP 自动识别 host，拒绝在 node2/node4/未知主机运行。它把经过审核的执行脚本复制到 `/usr/local/libexec/dynamo-phase2/`，把 unit 复制到 `/etc/systemd/system/`；只在 unit 内容实际变化时设置 `reload_required` 并执行一次 `daemon-reload`。随后 enable 并按依赖顺序 start，每个 unit 都必须 `is-active`。

- node1 安装 ToS unit 和 NFS/RDMA client unit；start 时先应用 endpoint ToS，再执行受 Gate 保护的 mount，stop 时先拒绝 open user 再 unmount，并移除 ToS rule。
- node3 安装 ToS、RAM storage、NFS/RDMA server units；server unit `Requires/After` RAM storage，并在 ToS 后启动；stop 顺序由回滚编排保证先停 export，再停 RAM。
- units 都是 `Type=oneshot`/`RemainAfterExit=yes`，start timeout 为 30–120 秒、stop timeout 为 30–60 秒，挂在 `multi-user.target`；失败会留下明确 failed unit，但不是系统 boot-critical service。

node1 持久化 ToS 和 NFS/RDMA client；node3 持久化 ToS、RAM storage 和 NFS/RDMA server。owner 与原 package/service 状态保存在 root-only `/var/lib/dynamo-phase2`。`remove-persistence.sh` 只按 backend IP 删除该主机已知 unit 与 `/usr/local/libexec/dynamo-phase2`，然后执行 `daemon-reload`；它不卸载 GDS/NFSoRDMA packages。

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

最后一条 `rollback-phase2.sh --dry-run` 不改 live state：它只确认归档 baseline manifest 存在且仍含 40K context/FP8 KV，随后打印未来 `--execute` 的固定顺序。它不会主动检查当前 mount open users、node3 client、package dependency 或真正执行 server-side teardown，因此 dry-run PASS 表示“回滚输入和编排可解析”，不等于此刻已具备无阻塞拆除条件；执行回滚前仍按[回滚](#rollback)章节检查使用者与维护窗口。

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
