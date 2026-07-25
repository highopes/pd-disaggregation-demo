#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-apply}"
DEVICE="${RDMA_DEVICE:-mlx5_0}"
PORT="${RDMA_PORT:-1}"
RULE_FILE="/sys/class/infiniband/$DEVICE/tc/$PORT/traffic_class"

die() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -e "$RULE_FILE" ]] || die "RDMA traffic-class control is absent: $RULE_FILE"

if ip -4 address show | grep -Fq '172.31.230.111/'; then
  source_ip=172.31.230.111
  destination_ip=172.31.230.113/32
elif ip -4 address show | grep -Fq '172.31.230.113/'; then
  source_ip=172.31.230.113
  destination_ip=172.31.230.111/32
else
  die "host is neither the approved node1 nor node3 storage endpoint"
fi

case "$ACTION" in
  apply)
    expected="src_ip=$source_ip,dst_ip=$destination_ip,tclass=106"
    if ! grep -Fxq "$expected" "$RULE_FILE"; then
      printf 'src_ip=%s,dst_ip=%s,tclass=106\n' "$source_ip" "$destination_ip" > "$RULE_FILE"
    fi
    grep -Fxq "$expected" "$RULE_FILE" || die "ToS 106 rule read-back failed"
    echo "PASS: $expected"
    ;;
  remove)
    expected="src_ip=$source_ip,dst_ip=$destination_ip,tclass=106"
    if grep -Fxq "$expected" "$RULE_FILE"; then
      printf 'src_ip=%s,dst_ip=%s,tclass=-1\n' "$source_ip" "$destination_ip" > "$RULE_FILE"
    fi
    if grep -Fq "src_ip=$source_ip,dst_ip=$destination_ip" "$RULE_FILE"; then
      die "ToS rule remains after removal"
    fi
    echo "PASS: Phase 2 endpoint-specific ToS rule absent"
    ;;
  check)
    expected="src_ip=$source_ip,dst_ip=$destination_ip,tclass=106"
    grep -Fxq "$expected" "$RULE_FILE" || die "expected ToS 106 rule is absent"
    echo "PASS: $expected"
    ;;
  *)
    die "usage: $0 {apply|check|remove}"
    ;;
esac
