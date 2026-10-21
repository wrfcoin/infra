#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKSPACE_ROOT="$(cd "${TESTNET_DIR}/../.." && pwd)"
P2P_GUARD="${TESTNET_DIR}/check-p2p-external-addr.sh"
FUNCTIONAL_PROBE="${SCRIPT_DIR}/full-profile-functional-probe.py"

COMPOSE_FILES=("${TESTNET_DIR}/docker-compose.testnet.yml")
for extra in docker-compose.override.yml docker-compose.local-paths.yml; do
  if [ -f "${TESTNET_DIR}/${extra}" ]; then
    COMPOSE_FILES+=("${TESTNET_DIR}/${extra}")
  fi
done

PASS_COUNT=0
FAIL_COUNT=0
TMP_FILES=()

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    [ -n "${file:-}" ] && [ -e "$file" ] && rm -f "$file"
  done
}
trap cleanup EXIT

have() {
  command -v "$1" >/dev/null 2>&1
}

status_line() {
  local level="$1"
  shift
  printf '%-5s %s\n' "$level" "$*"
}

mark_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  status_line PASS "$*"
}

mark_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  status_line FAIL "$*"
}

compose_runner() {
  local args=()
  local file
  for file in "${COMPOSE_FILES[@]}"; do
    args+=(-f "$file")
  done

  if have docker && docker compose version >/dev/null 2>&1; then
    (
      cd "${TESTNET_DIR}"
      COMPOSE_PROFILES=full docker compose "${args[@]}" "$@"
    )
    return
  fi

  if have docker-compose; then
    (
      cd "${TESTNET_DIR}"
      COMPOSE_PROFILES=full docker-compose "${args[@]}" "$@"
    )
    return
  fi

  return 127
}

have_testnet_images() {
  local image
  for image in \
    wrfcoin/backend:testnet-local \
    wrfcoin/frontend:testnet-local \
    wrfcoin/explorer:testnet-local \
    wrfcoin/native-chain:testnet-local
  do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

guard_external_address() {
  "${P2P_GUARD}" --env-file "${TESTNET_DIR}/.env" --require
}

service_block() {
  local service="$1"
  local file="$2"

  awk -v service="$service" '
    /^services:$/ {
      in_services = 1
      next
    }
    !in_services {
      next
    }
    $0 ~ "^  " service ":$" {
      in_block = 1
      print
      next
    }
    in_block && $0 ~ "^  [A-Za-z0-9_.-]+:$" {
      exit
    }
    in_block {
      print
    }
  ' "$file"
}

verify_service_preflight() {
  local service="$1"
  local rendered_config="$2"
  local block

  block="$(service_block "$service" "$rendered_config")"
  if [ -z "$block" ]; then
    mark_fail "${service}: missing from rendered full-profile compose config"
    return
  fi

  if printf '%s\n' "$block" | grep -Eq '^    build:$'; then
    mark_pass "${service}: local build override is active"
  else
    mark_fail "${service}: local build override missing"
  fi

  if printf '%s\n' "$block" | grep -Eq '^    image: wrfcoin/backend:testnet-local$'; then
    mark_pass "${service}: using local backend image tag"
  else
    mark_fail "${service}: expected wrfcoin/backend:testnet-local image tag"
  fi

  if printf '%s\n' "$block" | grep -Eq 'type: bind'; then
    mark_fail "${service}: bind mount detected in rendered config"
  else
    mark_pass "${service}: no bind mounts detected"
  fi
}

wait_for_health() {
  local label="$1"
  local url="$2"
  local timeout_secs="$3"
  local deadline now http_code

  if ! have curl; then
    mark_fail "LIVENESS ${label}: curl is not installed"
    return
  fi

  deadline=$(( $(date +%s) + timeout_secs ))
  while true; do
    http_code="$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || true)"
    if [ "$http_code" = "200" ]; then
      mark_pass "LIVENESS ${label}: HTTP 200"
      return
    fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      if [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
        mark_fail "LIVENESS ${label}: timed out waiting for ${url} (last HTTP ${http_code})"
      else
        mark_fail "LIVENESS ${label}: timed out waiting for ${url}"
      fi
      return
    fi

    sleep 5
  done
}

run_functional_probe() {
  local label="$1"
  local service="$2"
  local base_url="$3"
  local output

  if ! have python3; then
    mark_fail "FUNCTIONAL ${label}: python3 is not installed"
    return
  fi
  if output="$(python3 "$FUNCTIONAL_PROBE" --service "$service" --base-url "$base_url" 2>&1)"; then
    mark_pass "FUNCTIONAL ${label}: ${output}"
  else
    mark_fail "FUNCTIONAL ${label}: ${output}"
  fi
}

print_summary_and_exit() {
  status_line INFO "Summary: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

main() {
  local rendered_config

  if [ ! -f "${TESTNET_DIR}/docker-compose.testnet.yml" ]; then
    mark_fail "Base compose file missing at ${TESTNET_DIR}/docker-compose.testnet.yml"
    print_summary_and_exit
  fi

  if ! have docker && ! have docker-compose; then
    mark_fail "Neither docker compose nor docker-compose is available"
    print_summary_and_exit
  fi

  export WRFCOIN_ROOT="${WRFCOIN_ROOT:-${WORKSPACE_ROOT}}"
  export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-smoke-postgres-password}"
  export REDIS_PASSWORD="${REDIS_PASSWORD:-smoke-redis-password}"
  export JWT_SECRET="${JWT_SECRET:-smoke-jwt-secret-32-characters-min}"
  export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-smoke-grafana-password}"

  mark_pass "Using WRFCOIN_ROOT=${WRFCOIN_ROOT}"

  rendered_config="$(mktemp)"
  TMP_FILES+=("$rendered_config")
  if compose_runner config >"$rendered_config"; then
    mark_pass "Rendered full-profile compose config"
  else
    mark_fail "Unable to render full-profile compose config"
    print_summary_and_exit
  fi

  verify_service_preflight "wrfcoin-cross-chain" "$rendered_config"
  verify_service_preflight "wrfcoin-compute" "$rendered_config"
  verify_service_preflight "wrfcoin-ml" "$rendered_config"
  verify_service_preflight "wrfcoin-node-discovery" "$rendered_config"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    print_summary_and_exit
  fi

  if [ "${SMOKE_FULL_FORCE_BUILD:-0}" = "1" ] || ! have_testnet_images; then
    mark_pass "Using compose build path"
    guard_external_address
    if compose_runner up -d --build; then
      mark_pass "Started testnet stack with full profile"
    else
      mark_fail "docker compose up -d --build failed"
      print_summary_and_exit
    fi
  else
    guard_external_address
    if compose_runner up -d; then
    mark_pass "Started testnet stack with full profile"
    else
    mark_fail "docker compose up -d failed"
    print_summary_and_exit
    fi
  fi

  wait_for_health "Cross-chain" "http://127.0.0.1:3000/health" 180
  wait_for_health "Compute" "http://127.0.0.1:6000/health" 180
  wait_for_health "AI/ML" "http://127.0.0.1:6001/health" 180
  wait_for_health "Node discovery" "http://127.0.0.1:9005/health" 180

  run_functional_probe "Cross-chain" "cross-chain" "http://127.0.0.1:3000"
  run_functional_probe "Compute" "compute" "http://127.0.0.1:6000"
  run_functional_probe "AI/ML" "ml" "http://127.0.0.1:6001"
  run_functional_probe "Node discovery" "node-discovery" "http://127.0.0.1:9005"

  print_summary_and_exit
}

main "$@"
