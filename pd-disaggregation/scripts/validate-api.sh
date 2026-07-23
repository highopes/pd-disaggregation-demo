#!/usr/bin/env bash
set -euo pipefail

namespace=${DYNAMO_NAMESPACE:-ai-serving}
endpoint=${DYNAMO_ENDPOINT:-http://192.168.160.113:30080}

echo 'Cluster-internal test (no API key expected):'
frontend=$(kubectl get pod -n "$namespace" \
  -l 'nvidia.com/dynamo-graph-deployment-name=qwen3-14b-pd,nvidia.com/dynamo-component=Frontend' \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "$namespace" "$frontend" -- python3 -c \
  'import urllib.request; print("internal_http=" + str(urllib.request.urlopen("http://qwen-openai:8000/v1/models", timeout=10).status))'

if [[ -z ${EXTERNAL_CLIENT_SSH:-} ]]; then
  echo 'Set EXTERNAL_CLIENT_SSH to the SSH target for 192.168.160.183 to run the direct external no-token test.'
  exit 0
fi

# 192.168.160.183 is a direct data-center client, not the internet reverse
# proxy. Its successful no-token request is the required external acceptance
# test. Reverse-proxy token validation is intentionally out of scope here.
external_code=$(ssh "$EXTERNAL_CLIENT_SSH" curl --connect-timeout 10 --max-time 30 -sS \
  -o /dev/null -w '%{http_code}' "$endpoint/v1/models")
printf 'external_no_key_http=%s\n' "$external_code"
