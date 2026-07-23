#!/usr/bin/env bash
set -euo pipefail

# Resumable pull for public NVCR images on very slow links. Unlike a normal
# containerd pull, partial blobs survive anonymous-token renewal failures.
image=${1:-nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1}
work_root=${NVCR_RESUME_DIR:-/tmp/dynamo-nvcr-resume}
platform_arch=${NVCR_PLATFORM_ARCH:-amd64}

if [[ $(id -u) -ne 0 ]]; then
  echo 'Run as root so completed containerd blobs can be reused and imported.' >&2
  exit 1
fi
if [[ $image != nvcr.io/*:* ]]; then
  echo "Expected nvcr.io/repository:tag, got: $image" >&2
  exit 1
fi

name=${image%:*}
tag=${image##*:}
repository=${name#nvcr.io/}
safe_name=${repository//\//_}
work_dir=$work_root/${safe_name}-${tag}-${platform_arch}
layout=$work_dir/oci
partials=$work_dir/partials
mkdir -p "$layout/blobs/sha256" "$partials"

get_token() {
  local response token attempt=0
  while true; do
    if response=$(curl --fail --silent --show-error --location --get \
      --data-urlencode "scope=repository:${repository}:pull" \
      https://nvcr.io/proxy_auth) && \
      token=$(jq -er '.token // .access_token' <<<"$response"); then
      printf '%s' "$token"
      return
    fi
    attempt=$((attempt + 1))
    echo "NVCR anonymous token attempt $attempt failed; retrying in 20 seconds." >&2
    sleep 20
  done
}

authorized_get() {
  local output=$1
  local url=$2
  local accept=${3:-application/octet-stream}
  local token
  token=$(get_token)
  local rc
  if printf 'header = "Authorization: Bearer %s"\nheader = "Accept: %s"\n' "$token" "$accept" |
    curl --config - --fail --silent --show-error --location \
      --connect-timeout 30 --output "$output" "$url"; then
    rc=0
  else
    rc=$?
  fi
  unset token
  return "$rc"
}

fetch_manifest() {
  local reference=$1
  local output=$2
  local accept='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  local attempt=0
  until authorized_get "$output" \
    "https://nvcr.io/v2/${repository}/manifests/${reference}" "$accept"; do
    attempt=$((attempt + 1))
    echo "Manifest fetch attempt $attempt failed; retrying in 10 seconds." >&2
    sleep 10
  done
}

registry_index=$work_dir/registry-index.json
manifest_file=$work_dir/manifest.json
fetch_manifest "$tag" "$registry_index"

if jq -e '.manifests | type == "array"' "$registry_index" >/dev/null; then
  manifest_digest=$(jq -er --arg arch "$platform_arch" \
    '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $arch) | .digest' \
    "$registry_index" | sed -n '1p')
  fetch_manifest "$manifest_digest" "$manifest_file"
else
  cp "$registry_index" "$manifest_file"
  manifest_digest=sha256:$(sha256sum "$manifest_file" | awk '{print $1}')
fi

if [[ -z ${manifest_digest:-} ]] || [[ ! -s $manifest_file ]]; then
  echo "No linux/$platform_arch manifest was returned for $image" >&2
  exit 1
fi

manifest_hex=${manifest_digest#sha256:}
actual_manifest=sha256:$(sha256sum "$manifest_file" | awk '{print $1}')
if [[ $actual_manifest != "$manifest_digest" ]]; then
  echo "Manifest digest mismatch: expected $manifest_digest got $actual_manifest" >&2
  exit 1
fi
manifest_media=$(jq -r '.mediaType // "application/vnd.docker.distribution.manifest.v2+json"' "$manifest_file")
manifest_size=$(stat -c %s "$manifest_file")
cp "$manifest_file" "$layout/blobs/sha256/$manifest_hex"

download_blob() {
  local digest=$1
  local expected_size=$2
  local hex=${digest#sha256:}
  local final=$layout/blobs/sha256/$hex
  local partial=$partials/$hex.partial
  local candidate=$partials/$hex.containerd
  local ingest_ref ingest_data current_size actual attempt token

  if [[ -f $final ]] && [[ $(stat -c %s "$final") -eq $expected_size ]] && \
     [[ $(sha256sum "$final" | awk '{print $1}') == "$hex" ]]; then
    echo "Blob already complete: $digest ($expected_size bytes)"
    return
  fi

  if ctr --namespace k8s.io content get "$digest" >"$candidate" 2>/dev/null; then
    if [[ $(stat -c %s "$candidate") -eq $expected_size ]] && \
       [[ $(sha256sum "$candidate" | awk '{print $1}') == "$hex" ]]; then
      mv "$candidate" "$final"
      echo "Reused completed containerd blob: $digest"
      return
    fi
  fi
  rm -f "$candidate"

  ingest_ref=$(rg -l "$hex" /var/lib/containerd/io.containerd.content.v1.content/ingest/*/ref 2>/dev/null | sed -n '1p' || true)
  if [[ -n $ingest_ref ]]; then
    ingest_data=${ingest_ref%/ref}/data
    if [[ -f $ingest_data ]]; then
      current_size=$(stat -c %s "$partial" 2>/dev/null || printf '0')
      if [[ $(stat -c %s "$ingest_data") -gt $current_size ]]; then
        cp --reflink=auto "$ingest_data" "$partial"
        echo "Saved active containerd partial: $digest ($(stat -c %s "$partial")/$expected_size)"
      fi
    fi
  fi

  if [[ -f $partial ]] && [[ $(stat -c %s "$partial") -gt $expected_size ]]; then
    echo "Discarding oversized temporary partial for $digest" >&2
    rm -f "$partial"
  fi
  touch "$partial"

  attempt=0
  while true; do
    current_size=$(stat -c %s "$partial")
    if [[ $current_size -eq $expected_size ]]; then
      actual=$(sha256sum "$partial" | awk '{print $1}')
      if [[ $actual == "$hex" ]]; then
        mv "$partial" "$final"
        echo "Blob complete: $digest ($expected_size bytes)"
        return
      fi
      echo "Temporary blob checksum mismatch for $digest; restarting only this blob." >&2
      rm -f "$partial"
      touch "$partial"
      current_size=0
    fi

    attempt=$((attempt + 1))
    echo "Downloading $digest: $current_size/$expected_size bytes (attempt $attempt)"
    token=$(get_token)
    if printf 'header = "Authorization: Bearer %s"\n' "$token" |
      curl --config - --fail --silent --show-error --location \
        --continue-at - --output "$partial" \
        --connect-timeout 30 --retry 5 --retry-delay 5 --retry-all-errors \
        --speed-time 600 --speed-limit 1024 \
        "https://nvcr.io/v2/${repository}/blobs/${digest}"; then
      :
    else
      echo "Blob transfer interrupted at $(stat -c %s "$partial") bytes; refreshing token and resuming." >&2
      sleep 10
    fi
    unset token
  done
}

while IFS=$'\t' read -r digest size; do
  download_blob "$digest" "$size"
done < <(jq -r '[.config, .layers[]] | .[] | [.digest, (.size | tostring)] | @tsv' "$manifest_file")

printf '{"imageLayoutVersion":"1.0.0"}\n' >"$layout/oci-layout"
jq -n \
  --arg media "$manifest_media" \
  --arg digest "$manifest_digest" \
  --arg tag "$tag" \
  --argjson size "$manifest_size" \
  '{schemaVersion:2, mediaType:"application/vnd.oci.image.index.v1+json", manifests:[{mediaType:$media,digest:$digest,size:$size,annotations:{"org.opencontainers.image.ref.name":$tag}}]}' \
  >"$layout/index.json"

echo "Importing completed OCI layout into containerd: $image"
tar -C "$layout" -cf - oci-layout index.json blobs |
  ctr --namespace k8s.io images import --platform "linux/$platform_arch" \
    --base-name "$name" --index-name "$image" -

ready=$(ctr --namespace k8s.io images check --quiet "name==$image")
if [[ $ready != *"$image"* ]]; then
  echo "Imported image did not pass containerd completeness check: $image" >&2
  exit 1
fi
echo "Image ready in containerd: $image"
echo "Resume data retained at $work_dir until all destination copies are verified."
