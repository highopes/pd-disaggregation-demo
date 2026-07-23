#!/usr/bin/env bash
set -euo pipefail

rdma_netdev="$(ibdev2netdev | awk '$2 == "port" && $3 == "1" {print $5; exit}')"
if [[ -z "${rdma_netdev}" ]]; then
  echo "No RDMA Ethernet netdev found" >&2
  exit 1
fi

# A 4200-byte Ethernet MTU carries the 4096-byte RoCE/RDMA path MTU while
# keeping the lossless traffic class bounded independently from ordinary
# jumbo traffic on the switch.
ip link set dev "${rdma_netdev}" mtu 4200
mlnx_qos -i "${rdma_netdev}" --dcbx=os
mlnx_qos -i "${rdma_netdev}" --trust=dscp
mlnx_qos -i "${rdma_netdev}" --dscp2prio=set,26,3
mlnx_qos -i "${rdma_netdev}" --prio_tc=0,1,2,3,4,5,6,7
mlnx_qos -i "${rdma_netdev}" --pfc=0,0,0,1,0,0,0,0
mlnx_qos -i "${rdma_netdev}" --cable_len=7
