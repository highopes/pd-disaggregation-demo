#!/usr/bin/env bash
set -euo pipefail

rdma_netdev="$(ibdev2netdev | awk '$2 == "port" && $3 == "1" {print $5; exit}')"
if [[ -z "${rdma_netdev}" ]]; then
  echo "No RDMA Ethernet netdev found" >&2
  exit 1
fi

ip link set dev "${rdma_netdev}" mtu 9000
mlnx_qos -i "${rdma_netdev}" --dcbx=os
mlnx_qos -i "${rdma_netdev}" --trust=dscp
mlnx_qos -i "${rdma_netdev}" --dscp2prio=set,26,3
mlnx_qos -i "${rdma_netdev}" --prio_tc=0,1,2,3,4,5,6,7
mlnx_qos -i "${rdma_netdev}" --pfc=0,0,0,1,0,0,0,0
mlnx_qos -i "${rdma_netdev}" --cable_len=7
