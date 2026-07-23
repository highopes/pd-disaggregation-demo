# RoCE backend baseline acceptance

时间：2026-07-23（Asia/Shanghai）。测试路径为 `csco-k8s-01/ens65np0/mlx5_0:1` 到 `csco-k8s-02/ens65np1/mlx5_0:1`，backend IPv4 分别为 `172.31.230.111` 与 `172.31.230.112`。

## L2/L3 与 MTU

- 双向普通 ICMP：各 3/3 成功，0% loss，平均 RTT 约 0.27–0.37 ms。
- 双向 `8972` byte、DF ICMP：各 3/3 成功，0% loss。
- 两端 netdev MTU 9000；Nexus 物理端口与 no-drop queue MTU 9216。
- IPv4 RoCEv2 GID 位于 `mlx5_0` port 1、GID index 3。

## RDMA write bandwidth

命令等价于：

```text
ib_write_bw -d mlx5_0 -i 1 -x 3 -F --report_gbits -n 50000 --tclass=106
```

`tclass=106` 对应 DSCP 26，并保留 ECN 位。结果：

```text
Transport: RC
Link type: Ethernet/RoCE
RDMA MTU: 4096
GID index: 3
Local/remote: 172.31.230.111 / 172.31.230.112
Average bandwidth: 109.85 Gbit/s
```

另一次未指定 traffic class 的基准为 115.54 Gbit/s；它只证明 RoCE 路径，不用于证明 priority 3 分类。

## DSCP/PFC priority mapping evidence

带 `--tclass=106` 测试后：

- node01 `tx_vport_rdma_bytes`: 3,988,800,000；`tx_prio3_bytes`: 3,327,200,000。
- node01 `tx_vport_rdma_packets`: 960,000；`tx_prio3_packets`: 800,000。
- node02 收到对应的 priority 3/RDMA 数据；反向控制方向计数也对应增长。
- 两端 priority 3 discard、pause storm、CRC、RDMA error/discard 均为 0。

这证明 DSCP 26 流量被 CX-7 分类到 priority 3；无拥塞时 PFC pause 计数为 0 是预期结果，不能据此声称曾触发 pause。

## Nexus interface evidence

测试后端口状态：

- node01: `Ethernet1/1/1`, access VLAN 2310, MTU 9216, 200G up。
- node02: `Ethernet1/1/2`, access VLAN 2310, MTU 9216, 200G up。
- 两端 interface input/output error、CRC、discard 为 0。
- 两端 `priority-flow-control` 的 configured/operational mode 均为 On，VL bitmap `(8)`（priority 3）；无拥塞基准下 RxPPP/TxPPP 均为 0。
- 测试对应 jumbo/RDMA 主机计数增长；交换机绝对 byte 计数含改造前历史流量，后续 P/D 长 prompt 验收使用严格 before/after delta。

## 判定

Backend Fabric 与 CPU-memory RoCE benchmark：PASS。GPU CUDA memory registration、NIXL/UCX 与真实 KV transfer 尚需在 Dynamo runtime 中单独证明，不能由本测试推断。
