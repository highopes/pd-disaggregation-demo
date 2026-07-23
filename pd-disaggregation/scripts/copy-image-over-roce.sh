#!/usr/bin/env bash
set -euo pipefail

# Run as root on csco-k8s-01 after the image is fully present in the k8s.io
# containerd namespace. The OCI archive is streamed directly over the CX-7
# backend; no large intermediate tar file is created.
image=${1:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1}
destination=${2:-root@172.31.230.112}
source_device=${ROCE_SOURCE_DEVICE:-ens65np0}
destination_ip=${destination##*@}
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

if [[ $(id -u) -ne 0 ]]; then
  echo 'Run this script as root so it can access the containerd socket.' >&2
  exit 1
fi

route=$(ip route get "$destination_ip")
if [[ $route != *" dev $source_device "* ]]; then
  echo "Refusing transfer: route to $destination_ip does not use $source_device: $route" >&2
  exit 1
fi

ready=$(ctr --namespace k8s.io images check --quiet "name==$image")
if [[ $ready != *"$image"* ]]; then
  echo "Source image is not fully downloaded and unpacked: $image" >&2
  exit 1
fi
ssh "${ssh_options[@]}" "$destination" ctr --namespace k8s.io images list >/dev/null

echo "Streaming $image to $destination over $source_device ($route)"
ctr --namespace k8s.io images export --platform linux/amd64 - "$image" |
  ssh "${ssh_options[@]}" "$destination" \
    ctr --namespace k8s.io images import --platform linux/amd64 -

ready=$(ssh "${ssh_options[@]}" "$destination" \
  ctr --namespace k8s.io images check --quiet "name==$image")
if [[ $ready != *"$image"* ]]; then
  echo "Destination image verification failed: $image" >&2
  exit 1
fi
echo "Destination image is ready: $image"
