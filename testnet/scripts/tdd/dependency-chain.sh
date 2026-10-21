#!/usr/bin/env bash
# =============================================================================
# Testnet Service Dependency Chain Test
#
# Verifies that the full service dependency chain is healthy:
#   postgres → redis → node → backend → frontend
#
# This test would have caught issues like frontend failing because backend
# was unhealthy, or backend being unhealthy because postgres couldn't auth.
#
# Usage:
#   bash testnet/scripts/tdd/dependency-chain.sh
#
# Exit codes:
#   0 = all services in chain are healthy
#   1 = at least one service is unhealthy
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
HEALTH_CHECK_TIMEOUT_SECS=5

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

# Check if a container is running and has a healthcheck that passes
check_container_health() {
  local container="$1"
  local description="$2"

  if ! docker ps --filter "name=$container" --filter "status=running" --quiet | grep -q .; then
    mark_fail "${description}: container not running"
    return 1
  fi

  # Get the healthcheck status from Docker inspect
  local health_status
  health_status=$(docker inspect "$container" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")

  case "$health_status" in
    "healthy")
      mark_pass "${description}: healthy"
      return 0
      ;;
    "unhealthy")
      mark_fail "${description}: unhealthy"
      return 1
      ;;
    "starting")
      mark_fail "${description}: still starting (timeout)"
      return 1
      ;;
    "none")
      # No healthcheck defined, check if it's just running
      mark_pass "${description}: running (no healthcheck)"
      return 0
      ;;
  esac
}

# Test HTTP endpoint health for services with HTTP health checks
test_http_health() {
  local url="$1"
  local description="$2"
  local timeout_secs="${3:-5}"

  local http_code
  http_code=$(curl -sS --connect-timeout 2 --max-time "$timeout_secs" -o /dev/null -w '%{http_code}' \
    "$url" 2>/dev/null || echo "000")

  if [ "$http_code" = "200" ]; then
    mark_pass "${description}: HTTP 200"
    return 0
  else
    mark_fail "${description}: HTTP ${http_code}"
    return 1
  fi
}

main() {
  status_line INFO "Service Dependency Chain Test"
  status_line INFO ""
  status_line INFO "Chain order: postgres → redis → node → backend → frontend"
  status_line INFO ""

  # Layer 1: Infrastructure (Postgres, Redis)
  status_line INFO "[ Layer 1: Infrastructure ]"
  check_container_health "wrfcoin-testnet-postgres" "Postgres" || true
  check_container_health "wrfcoin-testnet-redis" "Redis" || true
  echo ""

  # Layer 2: Blockchain (Node)
  status_line INFO "[ Layer 2: Blockchain ]"
  check_container_health "wrfcoin-testnet-node" "Node" || true
  test_http_health "http://127.0.0.1:8556/node/sync/status" "Node RPC" || true
  echo ""

  # Layer 3: Backend services
  status_line INFO "[ Layer 3: Backend Services ]"
  check_container_health "wrfcoin-testnet-backend" "Backend" || true
  test_http_health "http://127.0.0.1:4001/health" "Backend health" || true
  echo ""

  # Layer 4: Frontend
  status_line INFO "[ Layer 4: Frontend ]"
  check_container_health "wrfcoin-testnet-frontend" "Frontend" || true
  test_http_health "http://127.0.0.1:5000/health" "Frontend health" || true
  echo ""

  # Summary
  if [ "$FAIL_COUNT" -eq 0 ]; then
    status_line SUMMARY "PASS — all services healthy"
    return 0
  else
    status_line SUMMARY "FAIL — $FAIL_COUNT service(s) unhealthy"
    return 1
  fi
}

main "$@"
