#!/usr/bin/env bash
# Healthcheck gate for node readiness plus WAL replay integrity.
set -euo pipefail

NODE_READYZ_URL="${NODE_READYZ_URL:-http://localhost:8556/readyz}"
NODE_METRICS_URL="${NODE_METRICS_URL:-http://localhost:8556/metrics}"
WAL_REPLAY_METRIC="${WAL_REPLAY_METRIC:-wrfcoin_wal_replay_status}"
WAL_REPLAY_METRIC_REQUIRED="${WAL_REPLAY_METRIC_REQUIRED:-false}"
STATE_DIVERGENCE_METRIC="${STATE_DIVERGENCE_METRIC:-wrfcoin_state_divergence_total}"
STATE_DIVERGENCE_METRIC_REQUIRED="${STATE_DIVERGENCE_METRIC_REQUIRED:-true}"
HTTP_TIMEOUT_SECS="${HTTP_TIMEOUT_SECS:-5}"
CURL_BIN="${CURL_BIN:-curl}"
# #561: /metrics now requires Reader auth (core4
# metrics_endpoints_require_reader_auth). Without the token the request returns
# 401, METRICS_PAYLOAD comes back empty, and with STATE_DIVERGENCE_METRIC_
# REQUIRED=true the check fails -> node marked unhealthy -> dependents never
# start after a reboot. Send the Reader token so /metrics is reachable.
# /readyz (checked first, below) is auth-free and remains the primary gate.
READER_TOKEN="${WRFCOIN_READER_TOKEN:-}"

log() {
  printf '%s\n' "$*"
}

fail() {
  log "[FAIL] $*"
  exit 1
}

warn() {
  log "[WARN] $*"
}

pass() {
  log "[PASS] $*"
}

fetch() {
  local url="$1"
  "$CURL_BIN" -sf --max-time "$HTTP_TIMEOUT_SECS" "$url"
}

fetch_metrics() {
  local url="$1"
  if [[ -n "$READER_TOKEN" ]]; then
    # infra#1066: the header goes to curl on stdin (printf is a bash builtin),
    # so the Reader token never appears in any process argv.
    printf 'Authorization: Bearer %s\n' "$READER_TOKEN" |
      "$CURL_BIN" -sf --max-time "$HTTP_TIMEOUT_SECS" -H @- "$url"
  else
    # No token configured => /metrics auth is disabled; fetch unauthenticated.
    "$CURL_BIN" -sf --max-time "$HTTP_TIMEOUT_SECS" "$url"
  fi
}

metric_value() {
  local payload="$1"
  local metric="$2"
  awk -v metric="$metric" '
    $1 == metric || index($1, metric "{") == 1 { print $2; found=1; exit }
    END { if (!found) exit 1 }
  ' <<<"$payload"
}

require_bool() {
  local name="$1"
  local value="$2"
  case "$value" in
    true|false) ;;
    *) fail "invalid boolean for ${name}: ${value}" ;;
  esac
}

require_bool "WAL_REPLAY_METRIC_REQUIRED" "$WAL_REPLAY_METRIC_REQUIRED"
require_bool "STATE_DIVERGENCE_METRIC_REQUIRED" "$STATE_DIVERGENCE_METRIC_REQUIRED"

if ! fetch "$NODE_READYZ_URL" >/dev/null; then
  fail "node readiness endpoint is not healthy: ${NODE_READYZ_URL}"
fi

METRICS_PAYLOAD="$(fetch_metrics "$NODE_METRICS_URL" 2>/dev/null || true)"
if [[ -z "$METRICS_PAYLOAD" ]]; then
  if [[ "$WAL_REPLAY_METRIC_REQUIRED" == "true" || "$STATE_DIVERGENCE_METRIC_REQUIRED" == "true" ]]; then
    fail "metrics endpoint unavailable; cannot verify node readiness metrics"
  fi
  warn "metrics endpoint unavailable; /readyz passed but optional metrics are not confirmed"
  exit 0
fi

WAL_STATUS="$(metric_value "$METRICS_PAYLOAD" "$WAL_REPLAY_METRIC" 2>/dev/null || true)"
if [[ -z "$WAL_STATUS" ]]; then
  if [[ "$WAL_REPLAY_METRIC_REQUIRED" == "true" ]]; then
    fail "${WAL_REPLAY_METRIC} is missing from metrics"
  fi
  warn "${WAL_REPLAY_METRIC} is not exported yet; /readyz passed but WAL replay status is not confirmed"
elif ! [[ "$WAL_STATUS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  fail "${WAL_REPLAY_METRIC} is non-numeric: ${WAL_STATUS}"
elif awk -v status="$WAL_STATUS" 'BEGIN { exit !(status == 1) }'; then
  pass "${WAL_REPLAY_METRIC}=1"
else
  fail "WAL replay integrity check failed: ${WAL_REPLAY_METRIC}=${WAL_STATUS}"
fi

DIVERGENCE_TOTAL="$(metric_value "$METRICS_PAYLOAD" "$STATE_DIVERGENCE_METRIC" 2>/dev/null || true)"
if [[ -z "$DIVERGENCE_TOTAL" ]]; then
  if [[ "$STATE_DIVERGENCE_METRIC_REQUIRED" == "true" ]]; then
    fail "${STATE_DIVERGENCE_METRIC} is missing from metrics"
  fi
  warn "${STATE_DIVERGENCE_METRIC} is not exported; divergence status is not confirmed"
  exit 0
fi

if ! [[ "$DIVERGENCE_TOTAL" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  fail "${STATE_DIVERGENCE_METRIC} is non-numeric: ${DIVERGENCE_TOTAL}"
fi

if awk -v value="$DIVERGENCE_TOTAL" 'BEGIN { exit !(value == 0) }'; then
  pass "${STATE_DIVERGENCE_METRIC}=0"
  exit 0
fi

fail "state divergence detected: ${STATE_DIVERGENCE_METRIC}=${DIVERGENCE_TOTAL}"
