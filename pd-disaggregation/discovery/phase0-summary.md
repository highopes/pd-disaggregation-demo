# Phase 0 live discovery

时间：2026-07-23，时区 Asia/Shanghai。文档只记录非敏感事实。

## Kubernetes / Cilium

- Kubernetes client/server 1.31.9；Ubuntu 24.04.2；kernel 6.11.0-26-generic。
- Nodes: `csco-k8s-01..04`；01 为 control-plane；四节点均无 taint。
- Pod CIDR `10.244.0.0/16`（每节点 /24）；Service CIDR `10.96.0.0/12`；management `192.168.160.0/24`。
- Cilium/Isovalent `1.18.7-cee.1`，native routing，kube-proxy replacement enabled，Hubble/L7 proxy enabled。
- Hubble relay/UI ready；当前 ai-serving CNP 为 `vllm-token-from-lb` 与 `vllm-http-visibility`。
- 当前 qwen Service `qwen-openai` 为 NodePort `30080`。集群内 HTTP 200；外部测试节点 192.168.160.183 无 Key 也是 HTTP 200。根据后续澄清，`.183` 是不经过互联网反向代理的直连来源，无 Token 成功正是预期行为；仅互联网反向代理来源需要 Token。

## GPU/runtime/workloads

- 四节点各 1 x NVIDIA L4，driver 575.51.03，CUDA compatibility 12.9。
- NVIDIA Container Toolkit 1.17.7；containerd NVIDIA runtime 为 default；NVIDIA device plugin v0.17.2 ready 4/4；未安装 GPU Operator。
- 尚无 RDMA extended resource，也无 Dynamo/NATS/RDMA device-plugin CRD/workload。
- qwen-vllm: csco-k8s-01，Qwen/Qwen3-14B-FP8，vLLM 0.9.0.1，max-model-len 24576，GPU memory utilization 0.95，NodePort 30080。
- dare-foundation-vllm: csco-k8s-02；foundation-instruct-vllm: csco-k8s-04；ComfyUI: csco-k8s-03。
- 共享 NFS PVC 上 Qwen3-14B-FP8 缓存约 16G，节点 01/02 当前挂载可见；不需要重新下载或节点间复制。

## Baseline regression

- qwen cluster-internal `/v1/models`: HTTP 200。
- foundation-instruct cluster-internal 与 NodePort `/v1/models`: HTTP 200。
- foundation-instruct 与 ComfyUI deployments 均 available 1/1。最终 ComfyUI 回归只检查 workload/Pod/containers Ready，不绕过认证网关执行直连 HTTP。

## CX-7 / RoCE candidate

- 每节点 PCI `03:01.0` ConnectX-7 MT2910，RDMA `mlx5_0`, port 1, firmware 28.43.2566；GPU/NIC topology PHB，同 NUMA 0。
- 01/03 netdev `ens65np0`；02/04 netdev `ens65np1`。01–03 200G up，04 no-carrier/down。
- 初始 MTU 1500；无 backend IPv4；GID 仅 link-local v1 index 0 / RoCEv2 index 1。
- `mlx5_core`/`mlx5_ib` loaded；`nvidia_peermem` 模块可用但未加载。
- Host DCBX 为 OS controlled、trust PCP、PFC priorities 全关闭；RDMA traffic counters 为 0。
- `ib_write_bw/read_bw/send_bw` 已安装；UCX tools 在各节点安装情况不一致，后续在固定 runtime/container 内验证。

## Nexus

- RoCE_LF2 192.168.160.162：N9K-C9332D-GX2B，NX-OS 10.4(3)。
- CX-7 breakout mapping 经逐节点受控 link flap 实测：01→Eth1/1/1，02→Eth1/1/2，03→Eth1/2/1，04→Eth1/2/2；前三条 200G up，04 两端 down。
- Existing access VLAN 2300 belongs to VRF blue/VNI 30000 and uses non-RFC1918 SVI 101.1.1.254/24；不得改作本 Demo backend。
- Existing switch QoS classifies DSCP 26 to qos-group 3 and enables PFC cos 3 on the four ports, but qos-group 3 MTU is only 2240 while port/default MTU is 9216。Jumbo RoCE 前必须修正此不一致。
- Candidate dedicated VLAN 2310 未配置；172.31.230.0/24 在 Nexus VRF 路由表、Linux routes、Pod/Service/management CIDRs 中均未发现冲突。
