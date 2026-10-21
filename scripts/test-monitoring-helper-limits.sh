#!/usr/bin/env bash
# Validate monitoring helper services have bounded resources and rotated logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/../testnet/docker-compose.testnet.yml"

service_block() {
  local service="$1"
  awk -v service="$service" '
    $0 == "  " service ":" { in_service=1; print; next }
    in_service && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
    in_service { print }
  ' "$COMPOSE_FILE"
}

assert_contains() {
  local service="$1"
  local expected="$2"
  local block="$3"
  if ! grep -Fq "$expected" <<< "$block"; then
    echo "FAIL: ${service} missing ${expected}"
    return 1
  fi
}

check_service() {
  local service="$1"
  local memory="$2"
  local cpus="$3"
  local block
  block="$(service_block "$service")"

  assert_contains "$service" "memory: ${memory}" "$block"
  assert_contains "$service" "cpus: '${cpus}'" "$block"
  assert_contains "$service" "logging:" "$block"
  assert_contains "$service" "driver: json-file" "$block"
  assert_contains "$service" 'max-size: "50m"' "$block"
  assert_contains "$service" 'max-file: "3"' "$block"
}

check_service alertmanager 128M 0.5
check_service cadvisor 256M 0.5
check_service postgres-exporter 64M 0.25
check_service blackbox-exporter 64M 0.25

echo "PASS: monitoring helper resource and logging limits validate"
