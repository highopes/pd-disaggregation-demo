# Phase 1 回滚

以下命令只在决定撤销本 Demo 时执行。备份文件不含 Secret 数据；`vllm-api-token` 与 `hf-cache-pvc` 始终复用现有集群对象。

## 1. 移除 Dynamo 工作负载与平台

```bash
kubectl delete -f pd-disaggregation/dynamo/qwen3-14b-pd.yaml
kubectl delete -f pd-disaggregation/cilium/frontend-service-policy.yaml
helm uninstall dynamo-platform -n dynamo-system
kubectl delete -f pd-disaggregation/rdma/rdma-shared-device-plugin.yaml
kubectl delete -f pd-disaggregation/dynamo/nvidia-runtimeclass.yaml
```

确认没有其他对象使用 Dynamo CRD、KAI、Grove、NATS 或 ETCD 后，才考虑删除 Helm 留下的 CRD/PVC；默认不删除，以免丢失数据。

## 2. 恢复原 Qwen 与 Dare

```bash
kubectl apply -f pd-disaggregation/backup/qwen-vllm.yaml
kubectl apply -f pd-disaggregation/backup/dare-foundation-vllm.yaml
kubectl apply -f pd-disaggregation/backup/cilium-policies.yaml
```

等待两个 Deployment Ready，并分别验证原 Service。共享 PVC、API token Secret 和保留的 Foundation/ComfyUI 不需要恢复。

## 3. 恢复 Nexus

先在当前 shell 设置 `NEXUS_USERNAME`、`NEXUS_PASSWORD`，不要写入文件或 shell history，然后执行：

```bash
python3 pd-disaggregation/scripts/nexus_apply.py pd-disaggregation/nexus/rollback.cfg
python3 pd-disaggregation/scripts/nexus_read.py \
  'show vlan brief' \
  'show running-config interface Ethernet1/1/1' \
  'show running-config interface Ethernet1/1/2' \
  'show running-config interface Ethernet1/2/1' \
  'show running-config interface Ethernet1/2/2' \
  'show policy-map system type network-qos'
```

`rollback.cfg` 恢复改造前的 VLAN 2300、qos-group 3 MTU 2240、接口描述和删除 VLAN 2310，并保存 startup-config。接口原有的 MTU 9216、PFC 和 QoS service-policy 在改造前已经存在，因此不会移除。

## 4. 恢复 Linux CX-7

在四个节点逐一执行，先用 `ibdev2netdev` 核对接口名：

```bash
rdma_netdev=$(ibdev2netdev | awk '$2 == "port" && $3 == "1" {print $5; exit}')
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

仅在 node1/node2 没有 RDMA/GPU 进程使用模块时，再撤销持久加载：

```bash
rm /etc/modules-load.d/nvidia-peermem.conf
modprobe -r nvidia_peermem
```

回滚完成后应恢复为：CX-7 无 backend IPv4、MTU 1500、trust PCP、PFC 全关闭。node4 物理链路在任务前就是 down/no-carrier，不应把它作为回滚故障处理。
