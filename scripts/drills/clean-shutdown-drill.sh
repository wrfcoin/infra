#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — Operator panic-stop / clean-shutdown drill (issue infra#469)
#
# Validates that the N5 Pro 3-file compose stack can be stopped and restarted
# without chain-state loss. This is the recovery-confidence companion to the
# backup/restore drill (testnet/scripts/backup-restore-verification.sh): that
# script proves you can rebuild from a backup; THIS script proves a routine
# stop/start (or an ungraceful crash) round-trips cleanly with NO restore.
#
# What it does:
#   1. Pre-flight: stack running, node /readyz == 200, tools present
#   2. Record pre-shutdown chain head (height + tip hash) via the node API
#   3. Stop the stack:
#        --mode clean  (default)  docker compose down   (graceful SIGTERM)
#        --mode panic             docker compose kill    (SIGKILL — simulates
#                                 a power loss / OOM kill / hard crash)
#   4. Restart: docker compose up -d, wait for node /readyz
#   5. Assert chain head is preserved (post height >= pre height; tip matches
#      exactly when no new blocks were produced during the window)
#   6. Scan the node log SINCE restart for WAL-replay / corruption / panic
#      errors and fail if any are found
#
# This drill is NON-DESTRUCTIVE: it NEVER removes, moves, or wipes named
# Docker volumes, and never runs `compose down -v`. Chain data persists in the
# `node-data` volume across the stop/start, which is exactly what is verified.
#
# Usage:
#   clean-shutdown-drill.sh [--mode clean|panic] [--i-understand]
#                           [--compose-file PATH] [--node-api URL]
#                           [--timeout SECONDS]
#
# Refuses to run unless invoked with --i-understand or I_UNDERSTAND=1, because
# it stops the live testnet stack.
#
# Deployment constraint: local builds only, no ghcr.io push (see
# testnet/docker-compose.override.yml). This script pulls/builds nothing; it
# only stops and starts already-deployed containers.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TESTNET_DIR="${TESTNET_DIR:-${REPO_ROOT}/testnet}"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"

NODE_API="${NODE_API:-http://127.0.0.1:8556}"
NODE_SERVICE="${NODE_SERVICE:-wrfcoin-node}"
READY_TIMEOUT_SECS="${READY_TIMEOUT_SECS:-600}"   # max wait for /readyz on restart
STOP_GRACE_SECS="${STOP_GRACE_SECS:-30}"          # settle time after stop
MODE="clean"
CONFIRM=0

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-/var/log/wrfcoin-shutdown-drill}"
[ -w "/var/log" ] || LOG_DIR="/tmp/wrfcoin-shutdown-drill"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/shutdown-drill-${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)          MODE="$2";          shift 2 ;;
    --mode=*)        MODE="${1#*=}";     shift ;;
    --compose-file)  COMPOSE_FILE="$2";  shift 2 ;;
    --compose-file=*) COMPOSE_FILE="${1#*=}"; shift ;;
    --node-api)      NODE_API="$2";      shift 2 ;;
    --node-api=*)    NODE_API="${1#*=}"; shift ;;
    --timeout)       READY_TIMEOUT_SECS="$2"; shift 2 ;;
    --timeout=*)     READY_TIMEOUT_SECS="${1#*=}"; shift ;;
    --i-understand)  CONFIRM=1;          shift ;;
    -h|--help)
      awk '/^# ===/{n++; if(n==2) exit} n>=1' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

case "${MODE}" in
  clean|panic) ;;
  *) echo "Invalid --mode '${MODE}' (expected: clean|panic)" >&2; exit 2 ;;
esac

if [ "${CONFIRM}" -ne 1 ] && [ "${I_UNDERSTAND:-0}" != "1" ]; then
  cat >&2 <<EOF
This drill will STOP and RESTART the live testnet stack:
  compose file : ${COMPOSE_FILE}
  mode         : ${MODE} ($([ "${MODE}" = panic ] && echo 'SIGKILL — simulates a hard crash' || echo 'graceful SIGTERM'))

It is NON-destructive: named Docker volumes are never removed or wiped, so
chain data in 'node-data' persists across the restart (that persistence is
what the drill verifies).

Re-run with --i-understand (or I_UNDERSTAND=1) to proceed.
EOF
  exit 3
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG}"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "${LOG}" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

# Query chain state from the node API. Prints "<height>|<tip_hash>".
# Mirrors backup-restore-verification.sh so both drills agree on the shape.
capture_chain_state() {
  local payload height tip
  payload="$(curl -sf --max-time 5 "${NODE_API}/blockchain" 2>/dev/null || echo "")"
  if [ -z "${payload}" ]; then
    echo "|"
    return 0
  fi
  height="$(echo "${payload}" | jq -r '.data.height // .height // empty' 2>/dev/null || true)"
  tip="$(echo "${payload}" | jq -r '.data.tip // .tip // empty' 2>/dev/null || true)"
  printf '%s|%s\n' "${height}" "${tip}"
}

# Wait for node readiness up to $1 seconds. Accepts a 200 from /readyz, falling
# back to /health (the compose healthcheck endpoint) for older node builds.
wait_for_ready() {
  local timeout="${1:-600}"
  local deadline=$(( $(date +%s) + timeout ))
  local code
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
    if [ "${code}" = "200" ]; then return 0; fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/health" || echo "000")"
    if [ "${code}" = "200" ]; then return 0; fi
    sleep 5
  done
  return 1
}

# Scan node logs emitted since the restart marker for WAL-replay / corruption /
# panic signatures. Returns 0 if clean, 1 if any error signature is found.
WAL_ERROR_REGEX='(wal|write-ahead).*(error|fail|corrupt)|replay.*(error|fail)|failed to (open|load|replay|recover)|corrupt|malformed|recovery failed|panicked|SIGABRT'

check_wal_replay_clean() {
  local since="$1" logs
  # --no-log-prefix is not portable across compose versions; tolerate absence.
  logs="$(compose logs --since "${since}" "${NODE_SERVICE}" 2>/dev/null || \
          compose logs "${NODE_SERVICE}" 2>/dev/null || echo "")"
  if [ -z "${logs}" ]; then
    err "could not read ${NODE_SERVICE} logs to verify WAL replay — treating as INCONCLUSIVE"
    return 1
  fi
  local hits
  hits="$(printf '%s\n' "${logs}" | grep -iE "${WAL_ERROR_REGEX}" || true)"
  if [ -n "${hits}" ]; then
    err "WAL replay / corruption signatures found in node log after restart:"
    printf '%s\n' "${hits}" | head -30 | tee -a "${LOG}" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
  log "=== Pre-flight ==="
  for cmd in curl jq docker; do
    have "${cmd}" || { err "missing required command: ${cmd}"; return 1; }
  done

  [ -f "${COMPOSE_FILE}" ] || { err "compose file not found: ${COMPOSE_FILE}"; return 1; }

  if ! compose ps --format json >/dev/null 2>&1; then
    err "docker compose unavailable or stack not initialized for ${COMPOSE_FILE}"
    return 1
  fi

  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
  if [ "${code}" != "200" ]; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/health" || echo "000")"
  fi
  if [ "${code}" != "200" ]; then
    err "node not healthy before drill (readyz/health != 200, got ${code})"
    err "refusing to run a shutdown drill against an already-unhealthy stack"
    return 1
  fi
  log "node healthy: ${NODE_API} (${code})"
  log "compose file: ${COMPOSE_FILE}"
  log "mode:         ${MODE}"
  log "log file:     ${LOG}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== WRFCoin clean-shutdown / panic-stop drill (issue infra#469) ==="
  preflight || { err "pre-flight failed"; exit 1; }

  # 1. Record pre-shutdown chain head
  log "=== Capturing pre-shutdown chain head ==="
  local before_state before_height before_tip
  before_state="$(capture_chain_state)"
  before_height="$(echo "${before_state}" | awk -F'|' '{print $1}')"
  before_tip="$(echo "${before_state}"    | awk -F'|' '{print $2}')"
  log "pre-shutdown: height=${before_height:-<n/a>} tip=${before_tip:-<n/a>}"
  if [ -z "${before_height}" ]; then
    err "failed to read chain height from ${NODE_API}/blockchain"
    exit 1
  fi

  # 2. Stop the stack (graceful or simulated crash) — volumes are preserved.
  if [ "${MODE}" = "panic" ]; then
    log "=== PANIC stop: docker compose kill (SIGKILL) ==="
    compose kill 2>&1 | tee -a "${LOG}"
    # After kill, remove the stopped containers (NOT volumes) so `up` recreates
    # them exactly as a crash + operator restart would. No -v => volumes kept.
    compose down 2>&1 | tee -a "${LOG}"
  else
    log "=== CLEAN stop: docker compose down (graceful SIGTERM) ==="
    compose down 2>&1 | tee -a "${LOG}"
  fi
  log "stack stopped; settling for ${STOP_GRACE_SECS}s"
  sleep "${STOP_GRACE_SECS}"

  # 3. Restart and time the WAL-replay window from this marker.
  local restart_ts
  restart_ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  log "=== Restart: docker compose up -d (marker ${restart_ts}) ==="
  compose up -d 2>&1 | tee -a "${LOG}"

  log "waiting up to ${READY_TIMEOUT_SECS}s for node readiness..."
  if ! wait_for_ready "${READY_TIMEOUT_SECS}"; then
    err "node did not become ready within ${READY_TIMEOUT_SECS}s after restart — DRILL FAILED"
    err "inspect: docker compose -f ${COMPOSE_FILE} logs ${NODE_SERVICE}"
    exit 1
  fi
  log "node is ready"

  # 4. Verify chain head preserved
  log "=== Verifying chain head ==="
  local after_state after_height after_tip
  after_state="$(capture_chain_state)"
  after_height="$(echo "${after_state}" | awk -F'|' '{print $1}')"
  after_tip="$(echo "${after_state}"    | awk -F'|' '{print $2}')"
  log "post-restart: height=${after_height:-<n/a>} tip=${after_tip:-<n/a>}"

  if [ -z "${after_height}" ]; then
    err "failed to read chain height after restart — DRILL FAILED"
    exit 1
  fi

  local delta=$(( after_height - before_height ))
  if [ "${delta}" -lt 0 ]; then
    err "chain height REGRESSED: ${after_height} < ${before_height} (delta=${delta})"
    err "this indicates chain-state loss across the restart — DRILL FAILED"
    exit 1
  fi
  if [ "${delta}" -eq 0 ]; then
    if [ -n "${before_tip}" ] && [ "${after_tip}" != "${before_tip}" ]; then
      err "tip hash changed with no height change: ${before_tip} -> ${after_tip} — DRILL FAILED"
      exit 1
    fi
    log "chain head preserved exactly (height=${after_height}, tip matches)"
  else
    log "chain advanced by ${delta} block(s) after restart — head preserved, node resumed producing"
  fi

  # 5. WAL replay must be clean
  log "=== Scanning node log for WAL replay / corruption errors ==="
  if ! check_wal_replay_clean "${restart_ts}"; then
    err "WAL replay verification FAILED — see signatures above"
    exit 1
  fi
  log "no WAL replay / corruption errors in node log since restart"

  # 6. Success
  log "=== SUCCESS ==="
  log "panic-stop/clean-shutdown drill PASSED (mode=${MODE})"
  log ""
  log "Drill report (copy to the issue #469 / ops audit log):"
  log "  Date:           $(date -u '+%Y-%m-%d')"
  log "  Operator:       ${USER:-unknown}"
  log "  Mode:           ${MODE}"
  log "  Pre height/tip: ${before_height} / ${before_tip:-<n/a>}"
  log "  Post height/tip:${after_height} / ${after_tip:-<n/a>}"
  log "  WAL replay:     clean"
  log "  Full log:       ${LOG}"
  exit 0
}

main "$@"
