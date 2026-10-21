#!/usr/bin/env bash
# =============================================================================
# Testnet Cold-Start Smoke Test
#
# Verifies that the full testnet stack can start cleanly and all critical
# endpoints are reachable. This test would have caught the cold-start
# regression in backend#651 where the Enhanced Unified API failed silently
# with "Unknown:No message" error during startup.
#
# Usage:
#   bash testnet/scripts/tdd/cold-start-smoke.sh
#
# Exit codes:
#   0 = all endpoints reachable and healthy
#   1 = at least one check failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
STARTUP_TIMEOUT_SECS=120

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

# Check if container has been running for < STARTUP_TIMEOUT_SECS (cold start)
is_cold_start() {
  local container="$1"
  local uptime_secs
  uptime_secs=$(docker inspect "$container" --format='{{json .State.StartedAt}}' | \
    xargs -I {} date +%s --date "{}" | \
    awk -v now="$(date +%s)" '{print now - $1}')
  [ "$uptime_secs" -lt "$STARTUP_TIMEOUT_SECS" ]
}

# Wait for backend health check
wait_for_backend_health() {
  local deadline now http_code
  deadline=$(( $(date +%s) + STARTUP_TIMEOUT_SECS ))

  status_line INFO "Waiting for backend to reach /health endpoint (timeout: ${STARTUP_TIMEOUT_SECS}s)..."

  while true; do
    http_code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:4001/health 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
      mark_pass "Backend /health endpoint returns 200"
      return 0
    fi

    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      mark_fail "Backend /health timed out after ${STARTUP_TIMEOUT_SECS}s (last HTTP ${http_code})"
      return 1
    fi

    sleep 2
  done
}

# Test weather-related endpoint
test_weather_endpoint() {
  status_line INFO "Testing weather-related endpoint..."

  local http_code
  http_code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:4001/api/weather 2>/dev/null || echo "000")

  # Accept 200 (success) or 400 (bad request with missing params) as non-error
  # 500 would indicate a startup failure
  if [ "$http_code" = "200" ] || [ "$http_code" = "400" ]; then
    mark_pass "Weather endpoint reachable (HTTP ${http_code})"
    return 0
  else
    mark_fail "Weather endpoint returned HTTP ${http_code} (expected 200 or 400)"
    return 1
  fi
}

# Test node API reachability
test_node_api() {
  status_line INFO "Testing node sync status endpoint..."

  local http_code
  http_code=$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:8556/node/sync/status 2>/dev/null || echo "000")

  if [ "$http_code" = "200" ]; then
    mark_pass "Node API reachable (HTTP ${http_code})"
    return 0
  else
    mark_fail "Node API returned HTTP ${http_code}"
    return 1
  fi
}

# Check backend logs for startup errors
check_backend_logs() {
  status_line INFO "Checking backend logs for startup errors..."

  if ! docker ps --filter "name=wrfcoin-testnet-backend" --filter "status=running" --quiet | grep -q .; then
    mark_fail "Backend container not running"
    return 1
  fi

  local logs
  logs=$(docker logs wrfcoin-testnet-backend 2>&1 | tail -50 || echo "")

  # Check for known failure patterns
  if printf '%s\n' "$logs" | grep -qi "Unknown:No message"; then
    mark_fail "Backend startup error: 'Unknown:No message' in logs (backend#651 regression)"
    return 1
  fi

  if printf '%s\n' "$logs" | grep -qi "ECONNREFUSED"; then
    mark_fail "Backend connection refused error in logs"
    return 1
  fi

  if printf '%s\n' "$logs" | grep -qi "TypeError\|ReferenceError"; then
    mark_fail "Backend has JavaScript errors in logs"
    return 1
  fi

  mark_pass "No startup errors detected in backend logs"
  return 0
}

main() {
  status_line INFO "Cold-Start Smoke Test — Enhanced Unified API startup verification"
  status_line INFO ""

  # Check if compose stack is even running
  if ! docker ps --filter "name=wrfcoin-testnet-backend" --filter "status=running" --quiet | grep -q .; then
    status_line WARN "Backend container is not running."
    status_line WARN "Start the testnet stack: cd testnet && docker compose up -d"
    echo ""
    status_line SUMMARY "FAIL — backend not running"
    return 1
  fi

  echo ""
  wait_for_backend_health || true
  check_backend_logs || true
  test_weather_endpoint || true
  test_node_api || true

  echo ""
  if [ "$FAIL_COUNT" -eq 0 ]; then
    status_line SUMMARY "PASS — backend cold-start successful"
    return 0
  else
    status_line SUMMARY "FAIL — $FAIL_COUNT startup check(s) failed"
    return 1
  fi
}

main "$@"
