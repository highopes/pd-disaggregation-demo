# CX-7 ↔ RoCE_LF2 port mapping

映射于 2026-07-23 通过逐节点短暂 flap 未承载业务的 CX-7 netdev，并同步观察 Nexus 端口状态获得。

| Kubernetes node | CX-7 netdev | RDMA device/port | MAC | Nexus port | Link |
|---|---|---|---|---|---|
| csco-k8s-01 | ens65np0 | mlx5_0/1 | a0:88:c2:34:e8:e6 | Ethernet1/1/1 | 200G up |
| csco-k8s-02 | ens65np1 | mlx5_0/1 | a0:88:c2:34:e8:e7 | Ethernet1/1/2 | 200G up |
| csco-k8s-03 | ens65np0 | mlx5_0/1 | a0:88:c2:34:e7:f6 | Ethernet1/2/1 | 200G up |
| csco-k8s-04 | ens65np1 | mlx5_0/1 | a0:88:c2:34:e7:f7 | Ethernet1/2/2 | no carrier/down |

前三项是独立 flap 实测。第四项由四根一一对应 breakout 链路中剩余唯一端口确定，且 host/switch 两侧均持续 down。
