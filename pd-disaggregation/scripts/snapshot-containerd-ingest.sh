#!/usr/bin/env bash
set -euo pipefail

partials=${1:-/tmp/dynamo-nvcr-resume/nvidia_ai-dynamo_vllm-runtime-1.2.1-amd64/partials}
ingest_root=/var/lib/containerd/io.containerd.content.v1.content/ingest

if [[ $(id -u) -ne 0 ]]; then
  echo 'Run as root to read containerd ingest data.' >&2
  exit 1
fi
mkdir -p "$partials"

found=0
for ref_file in "$ingest_root"/*/ref; do
  [[ -f $ref_file ]] || continue
  ref=$(sed -n '1p' "$ref_file")
  [[ $ref == *layer-sha256:* ]] || continue
  digest=${ref##*layer-sha256:}
  data=${ref_file%/ref}/data
  [[ -f $data ]] || continue
  target=$partials/$digest.partial
  source_size=$(stat -c %s "$data")
  target_size=$(stat -c %s "$target" 2>/dev/null || printf '0')
  if [[ $source_size -gt $target_size ]]; then
    cp --reflink=auto "$data" "$target"
    echo "Snapshot sha256:$digest at $(stat -c %s "$target") bytes"
  else
    echo "Kept newer snapshot sha256:$digest at $target_size bytes"
  fi
  found=$((found + 1))
done

echo "Active ingest entries inspected: $found"

