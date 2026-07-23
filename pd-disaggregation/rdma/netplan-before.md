# CX-7 Netplan 修改前状态

四节点均由 Netplan + NetworkManager 管理；既有 YAML 只配置管理口 `ens33`。CX-7 没有 IPv4、没有默认路由，也没有专属 Netplan 文件。

| Node | Management | CX-7 netdev | CX-7 MAC | Link |
|---|---|---|---|---|
| csco-k8s-01 | 192.168.160.111/24 | ens65np0 | a0:88:c2:34:e8:e6 | up / 200G |
| csco-k8s-02 | 192.168.160.112/24 | ens65np1 | a0:88:c2:34:e8:e7 | up / 200G |
| csco-k8s-03 | 192.168.160.113/24 | ens65np0 | a0:88:c2:34:e7:f6 | up / 200G |
| csco-k8s-04 | 192.168.160.114/24 | ens65np1 | a0:88:c2:34:e7:f7 | down / no carrier |

回滚时删除本任务新增的 `/etc/netplan/95-roce-backend.yaml` 并执行 `netplan apply`；不要改动既有 `01-*`、`50-*`、`90-*` 文件。
