#!/usr/bin/env bash
# test-backend-node-connectivity.sh — HTTP connectivity test for the testnet stack
#
# Verifies the Rust blockchain node and backend API are reachable and
# responding correctly at their documented endpoints.
#
# Usage:
#   bash scripts/test-backend-node-connectivity.sh [NODE_HOST] [NODE_PORT] [BACKEND_PORT]
#
# Arguments:
#   NODE_HOST     Target host (default: localhost, use wrfcoin-node inside Docker)
#   NODE_PORT     Node API port (default: 8556)
#   BACKEND_PORT  Backend API port (default: 4001)
#
# Exits:
#   0 — all tests passed
#   1 — one or more tests failed
#   2 — node unreachable (pre-flight failure)
#
# Endpoints tested (per docs/TESTNET_OPERATOR_GUIDE.md):
#   Node:    GET /readyz, GET /blockchain, GET /network/info
#   Backend: GET /health

set -euo pipefail

# ── Arguments ───────────────────────────────────────────────────────────────
NODE_HOST="${1:-localhost}"
NODE_PORT="${2:-8556}"
BACKEND_PORT="${3:-4001}"

NODE_BASE="http://${NODE_HOST}:${NODE_PORT}"
BACKEND_BASE="http://${NODE_HOST}:${BACKEND_PORT}"

# ── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
FAILURES=()

# ── Helpers ─────────────────────────────────────────────────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

pass() {
  local name="$1"
  PASS=$((PASS + 1))
  green "  PASS  ${name}"
}

fail() {
  local name="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  FAILURES+=("${name}")
  red "  FAIL  ${name}${detail:+  (${detail})}"
}

header() { printf '\n\033[1;34m══ %s ══\033[0m\n' "$*"; }

# ── Pre-flight: node reachable ──────────────────────────────────────────────
header "Pre-flight: connectivity to ${NODE_BASE}"

if ! curl -sf --max-time 5 "${NODE_BASE}/readyz" > /dev/null 2>&1; then
  red "  Node is not reachable at ${NODE_BASE}/readyz"
  red "  The node may not be running. Start it with: docker compose up -d"
  red ""
  red "  Exiting with code 2 (node unreachable — not a test failure)."
  exit 2
fi
green "  Node reachable at ${NODE_BASE}"

# ══════════════════════════════════════════════════════════════════════════════
header "Group A: Node Endpoints (${NODE_BASE})"
# ══════════════════════════════════════════════════════════════════════════════

# A1 — /readyz returns HTTP 200
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 10 "${NODE_BASE}/readyz" 2>/dev/null || echo "000")
if [ "${HTTP_CODE}" = "200" ]; then
  pass "A1: GET /readyz returns 200"
else
  fail "A1: GET /readyz returns 200" "got HTTP ${HTTP_CODE}"
fi

# A2 — /blockchain returns JSON with height field
BLOCKCHAIN_BODY=$(curl -sf --max-time 10 "${NODE_BASE}/blockchain" 2>/dev/null || echo "")
if [ -n "${BLOCKCHAIN_BODY}" ]; then
  HAS_HEIGHT=$(echo "${BLOCKCHAIN_BODY}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('yes' if 'height' in data else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

  if [ "${HAS_HEIGHT}" = "yes" ]; then
    HEIGHT=$(echo "${BLOCKCHAIN_BODY}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('height','?'))" 2>/dev/null || echo "?")
    pass "A2: GET /blockchain returns JSON with height (height=${HEIGHT})"
  else
    fail "A2: GET /blockchain returns JSON with height" "response missing 'height' field"
  fi
else
  fail "A2: GET /blockchain returns JSON with height" "empty response or endpoint unreachable"
fi

# A3 — /network/info returns JSON
NET_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 10 "${NODE_BASE}/network/info" 2>/dev/null || echo "000")
if [ "${NET_CODE}" = "200" ]; then
  pass "A3: GET /network/info returns 200"
else
  # Some node builds may not have this endpoint yet — soft fail
  fail "A3: GET /network/info returns 200" "got HTTP ${NET_CODE}"
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Group B: Backend Endpoints (${BACKEND_BASE})"
# ══════════════════════════════════════════════════════════════════════════════

# B1 — Backend /health returns HTTP 200
BACKEND_CODE=$(curl -sf -o /dev/null -w '%{http_code}' --max-time 10 "${BACKEND_BASE}/health" 2>/dev/null || echo "000")
if [ "${BACKEND_CODE}" = "200" ]; then
  pass "B1: GET /health returns 200"
else
  if [ "${BACKEND_CODE}" = "000" ]; then
    fail "B1: GET /health returns 200" "backend not reachable at ${BACKEND_BASE}"
  else
    fail "B1: GET /health returns 200" "got HTTP ${BACKEND_CODE}"
  fi
fi

# B2 — Backend /health response contains status field
if [ "${BACKEND_CODE}" = "200" ]; then
  HEALTH_BODY=$(curl -sf --max-time 10 "${BACKEND_BASE}/health" 2>/dev/null || echo "")
  HAS_STATUS=$(echo "${HEALTH_BODY}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('yes' if 'status' in data else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

  if [ "${HAS_STATUS}" = "yes" ]; then
    pass "B2: /health response contains 'status' field"
  else
    fail "B2: /health response contains 'status' field" "field not found in response"
  fi
else
  fail "B2: /health response contains 'status' field" "skipped — backend not healthy"
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Summary"
# ══════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL))
printf '\n'
printf '  Total: %d  ' "${TOTAL}"
green "PASS: ${PASS}"
printf '  '
if [[ ${FAIL} -gt 0 ]]; then
  red "FAIL: ${FAIL}"
  printf '\n  Failed tests:\n'
  for f in "${FAILURES[@]}"; do
    red "    - ${f}"
  done
  printf '\n'
  exit 1
else
  green "FAIL: 0"
  printf '\n'
  green "All tests passed!"
  exit 0
fi
