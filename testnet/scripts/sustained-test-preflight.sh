#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — 48-hour Sustained Test Preflight Checklist
#
# Validates the testnet stack before starting a long-running sustained
# operation test. Produces pass/warn/fail lines for each check and ends with a
# GO/NO-GO verdict.
#
# By default this script performs a single authenticated weather contribution
# test submission (commit + reveal). Use --skip-submit to avoid that write.
#
# Usage:
#   sustained-test-preflight.sh [--skip-submit]
#
# Dependencies: bash 4+, curl, jq, docker, awk, python3
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
TESTNET_ENV_FILE="${TESTNET_ENV_FILE:-${TESTNET_DIR}/.env}"

NODE_API="${NODE_API:-http://127.0.0.1:8556}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3100}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
LOKI_URL="${LOKI_URL:-http://127.0.0.1:3101}"

CONTRIBUTOR="${CONTRIBUTOR:-0x0000000000000000000000000000000000000b02}"
STATION_ID="${STATION_ID:-sustained-preflight-station}"

MIN_HEALTHY_CONTAINERS="${MIN_HEALTHY_CONTAINERS:-18}"
MIN_VOLUME_FREE_BYTES="${MIN_VOLUME_FREE_BYTES:-21474836480}"         # 20 GiB
POSTGRES_WARN_USAGE_PCT="${POSTGRES_WARN_USAGE_PCT:-50}"
POSTGRES_DEFAULT_MAX_CONNECTIONS="${POSTGRES_DEFAULT_MAX_CONNECTIONS:-200}"
REDIS_MAX_MEMORY_BYTES="${REDIS_MAX_MEMORY_BYTES:-536870912}"         # 512 MiB
REDIS_WARN_USAGE_PCT="${REDIS_WARN_USAGE_PCT:-50}"
MEMPOOL_MAX_BYTES="${MEMPOOL_MAX_BYTES:-1048576}"                     # 1 MiB
MIN_CONTRIBUTOR_BALANCE_BASE_UNITS="${MIN_CONTRIBUTOR_BALANCE_BASE_UNITS:-10000000000}" # 100 WRF
PERFORM_TEST_SUBMISSION=1

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; then
  C_PASS=$'\033[32m'
  C_WARN=$'\033[33m'
  C_FAIL=$'\033[31m'
  C_HEAD=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_PASS=""
  C_WARN=""
  C_FAIL=""
  C_HEAD=""
  C_RESET=""
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-submit)
      PERFORM_TEST_SUBMISSION=0
      shift
      ;;
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

log_section() {
  printf '\n%s[%s]%s %s\n' "${C_HEAD}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${C_RESET}" "$1"
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '%sPASS%s %s\n' "${C_PASS}" "${C_RESET}" "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '%sWARN%s %s\n' "${C_WARN}" "${C_RESET}" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '%sFAIL%s %s\n' "${C_FAIL}" "${C_RESET}" "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# infra#1073: the bearer reaches curl on stdin (-H @-) from the builtin printf,
# never through argv, so ps and /proc/<pid>/cmdline cannot read it. An empty
# token sends no Authorization header at all.
curl_with_bearer() { # curl_with_bearer <token> [curl args...]
  local token="$1"
  shift
  if [ -z "${token}" ]; then
    curl "$@"
    return
  fi
  printf 'Authorization: Bearer %s\n' "${token}" | curl -H @- "$@"
}

has_compose() {
  docker compose version >/dev/null 2>&1 || have docker-compose
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" "$@"
  else
    docker-compose -f "${COMPOSE_FILE}" "$@"
  fi
}

env_file_value() {
  local key="$1"
  if [ ! -f "${TESTNET_ENV_FILE}" ]; then
    return 1
  fi

  awk -F= -v key="${key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "${TESTNET_ENV_FILE}"
}

df_snapshot() {
  local path="$1"
  df -B1 -P "${path}" 2>/dev/null | awk 'NR==2 {gsub(/%/, "", $5); printf "%s %s %s %s\n", $2, $3, $4, $5}'
}

prom_query() {
  local query="$1"
  curl -sf --max-time 10 --get \
    --data-urlencode "query=${query}" \
    "${PROMETHEUS_URL}/api/v1/query" 2>/dev/null || true
}

prom_scalar() {
  local query="$1"
  prom_query "${query}" | jq -r '
    if .status == "success" and (.data.result | length) > 0
    then .data.result[0].value[1]
    else ""
    end
  ' 2>/dev/null || true
}

to_int() {
  python3 - "$1" <<'PY'
import sys
value = sys.argv[1]
try:
    print(int(float(value)))
except Exception:
    print(0)
PY
}

format_base_units() {
  python3 - "$1" <<'PY'
import sys
raw = int(sys.argv[1] or "0")
whole, frac = divmod(raw, 100_000_000)
if frac:
    text = f"{whole}.{frac:08d}".rstrip("0").rstrip(".")
else:
    text = str(whole)
print(text)
PY
}

testnet_container_names() {
  compose ps --format json 2>/dev/null \
    | jq -r 'if type == "array" then .[] else . end | .Name' 2>/dev/null || true
}

check_dependencies() {
  log_section "Dependencies"

  local missing=0
  for cmd in curl jq docker awk python3; do
    if have "${cmd}"; then
      pass "dependency present: ${cmd}"
    else
      fail "dependency missing: ${cmd}"
      missing=$((missing + 1))
    fi
  done

  if has_compose; then
    pass "docker compose available"
  else
    fail "docker compose unavailable"
    missing=$((missing + 1))
  fi

  if [ -f "${COMPOSE_FILE}" ]; then
    pass "compose file present: ${COMPOSE_FILE}"
  else
    fail "compose file missing: ${COMPOSE_FILE}"
    missing=$((missing + 1))
  fi

  if [ -f "${TESTNET_ENV_FILE}" ]; then
    pass "env file present: ${TESTNET_ENV_FILE}"
  else
    warn "env file missing: ${TESTNET_ENV_FILE} (auth-dependent checks may fail)"
  fi

  return "${missing}"
}

check_container_health() {
  local healthy_count expected_count issues
  expected_count="$(compose ps --services 2>/dev/null | awk 'NF{count++} END{print count+0}')"
  healthy_count="$(docker ps --filter "health=healthy" --format '{{.Names}}' 2>/dev/null | grep -c '^wrfcoin-testnet-' || true)"

  issues="$(
    while IFS= read -r name; do
      [ -z "${name}" ] && continue
      docker inspect "${name}" 2>/dev/null \
        | jq -r '
            .[0] as $c
            | ($c.State.Status // "unknown") as $status
            | ($c.State.Health.Status // "no-healthcheck") as $health
            | select($status != "running" or $health != "healthy")
            | "\($c.Name | ltrimstr("/")) status=\($status) health=\($health)"
          ' 2>/dev/null || true
    done < <(testnet_container_names)
  )"

  if [ -n "${issues}" ]; then
    fail "container health check found unhealthy services"
    printf '%s\n' "${issues}" | sed 's/^/  /'
    return 1
  fi

  if [ "${healthy_count}" -lt "${MIN_HEALTHY_CONTAINERS}" ]; then
    fail "healthy container count ${healthy_count} is below required floor ${MIN_HEALTHY_CONTAINERS}"
    return 1
  fi

  pass "all ${healthy_count} healthy containers reported healthy (compose services=${expected_count})"
}

check_volume_free_space() {
  local failures=0 seen_file output
  seen_file="${TMP_DIR}/volumes-seen.txt"
  : > "${seen_file}"

  while IFS= read -r container; do
    [ -z "${container}" ] && continue
    output="$(docker inspect "${container}" 2>/dev/null | jq -r '
      .[0].Mounts[]? | select(.Type == "volume") | [.Name, .Source] | @tsv
    ' 2>/dev/null || true)"

    while IFS=$'\t' read -r volume mountpoint; do
      [ -z "${volume:-}" ] && continue
      if grep -qx "${volume}" "${seen_file}"; then
        continue
      fi
      echo "${volume}" >> "${seen_file}"

      local total used avail pct
      read -r total used avail pct < <(df_snapshot "${mountpoint}")
      if [ -z "${avail:-}" ]; then
        fail "volume ${volume} could not be inspected at ${mountpoint}"
        failures=$((failures + 1))
        continue
      fi

      if [ "${avail}" -lt "${MIN_VOLUME_FREE_BYTES}" ]; then
        fail "volume ${volume} free space ${avail} bytes is below ${MIN_VOLUME_FREE_BYTES}"
        failures=$((failures + 1))
      else
        pass "volume ${volume} free space ${avail} bytes (use=${pct}%)"
      fi
    done <<< "${output}"
  done < <(testnet_container_names)

  return "${failures}"
}

check_postgres_connections() {
  local activity max_conn threshold
  activity="$(compose exec -T postgres psql -U wrfcoin -d wrfcoin -tAc 'SELECT count(*) FROM pg_stat_activity;' 2>/dev/null | tr -d '[:space:]' || true)"
  max_conn="$(compose exec -T postgres psql -U wrfcoin -d wrfcoin -tAc 'SHOW max_connections;' 2>/dev/null | tr -d '[:space:]' || true)"

  [ -z "${activity}" ] && activity="0"
  [ -z "${max_conn}" ] && max_conn="${POSTGRES_DEFAULT_MAX_CONNECTIONS}"
  threshold=$(( max_conn * POSTGRES_WARN_USAGE_PCT / 100 ))

  if [ "${activity}" -lt "${threshold}" ]; then
    pass "postgres connections ${activity}/${max_conn} (< ${POSTGRES_WARN_USAGE_PCT}% threshold)"
  else
    fail "postgres connections ${activity}/${max_conn} exceeds ${POSTGRES_WARN_USAGE_PCT}% threshold"
    return 1
  fi
}

check_redis_memory() {
  local info used maxmemory threshold
  info="$(compose exec -T redis redis-cli INFO memory 2>/dev/null || true)"
  used="$(printf '%s\n' "${info}" | awk -F: '$1=="used_memory"{print $2}' | tr -d '\r[:space:]')"
  maxmemory="$(printf '%s\n' "${info}" | awk -F: '$1=="maxmemory"{print $2}' | tr -d '\r[:space:]')"

  [ -z "${used}" ] && used="0"
  if [ -z "${maxmemory}" ] || [ "${maxmemory}" = "0" ]; then
    maxmemory="${REDIS_MAX_MEMORY_BYTES}"
  fi
  threshold=$(( maxmemory * REDIS_WARN_USAGE_PCT / 100 ))

  if [ "${used}" -lt "${threshold}" ]; then
    pass "redis memory ${used}/${maxmemory} bytes (< ${REDIS_WARN_USAGE_PCT}% threshold)"
  else
    fail "redis memory ${used}/${maxmemory} bytes exceeds ${REDIS_WARN_USAGE_PCT}% threshold"
    return 1
  fi
}

check_ntp_sync() {
  local ntp_sync chrony_line

  if have timedatectl; then
    ntp_sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
    if [ "${ntp_sync}" = "yes" ]; then
      pass "timedatectl reports NTPSynchronized=yes"
      return 0
    fi
  fi

  if have chronyc; then
    chrony_line="$(chronyc tracking 2>/dev/null | awk -F': +' '/Leap status/{print $2}' | tr -d '\r' || true)"
    if [ "${chrony_line}" = "Normal" ]; then
      pass "chronyc tracking reports Leap status Normal"
      return 0
    fi
  fi

  fail "NTP synchronization could not be confirmed via timedatectl or chronyc"
  return 1
}

check_readyz() {
  local body code status
  body="$(mktemp "${TMP_DIR}/readyz.XXXX")"
  code="$(curl -sS --max-time 5 -o "${body}" -w '%{http_code}' "${NODE_API}/readyz" 2>/dev/null || true)"
  status="$(jq -r '.status // empty' "${body}" 2>/dev/null || true)"

  if [ "${code}" = "200" ] && [ "${status}" = "ready" ]; then
    pass "node /readyz returned {\"status\":\"ready\"}"
  else
    fail "node /readyz check failed (code=${code:-000}, body=$(tr -d '\n' < "${body}" | cut -c1-160))"
    return 1
  fi
}

check_metrics_endpoint() {
  local metrics_file code height
  metrics_file="$(mktemp "${TMP_DIR}/metrics.XXXX")"
  code="$(curl -sS --max-time 10 -o "${metrics_file}" -w '%{http_code}' "${NODE_API}/metrics" 2>/dev/null || true)"
  height="$(prom_scalar 'wrfcoin_blockchain_block_height')"

  if [ "${code}" != "200" ]; then
    fail "node /metrics returned HTTP ${code:-000}"
    return 1
  fi

  if ! grep -q '^#' "${metrics_file}" || ! grep -q 'wrfcoin_blockchain_block_height' "${metrics_file}"; then
    fail "node /metrics did not look like Prometheus output"
    return 1
  fi

  if [ "$(to_int "${height:-0}")" -le 0 ]; then
    fail "wrfcoin_blockchain_block_height is not > 0 (value=${height:-empty})"
    return 1
  fi

  pass "node /metrics is valid and block height=${height}"
}

check_finalized_height_progress() {
  local changes current
  changes="$(prom_scalar 'changes(wrfcoin_chain_finalized_height[15m])')"
  current="$(prom_scalar 'wrfcoin_chain_finalized_height')"

  if [ "$(to_int "${current:-0}")" -le 0 ]; then
    fail "wrfcoin_chain_finalized_height is missing or zero"
    return 1
  fi

  if [ "$(to_int "${changes:-0}")" -gt 0 ]; then
    pass "finalized height is incrementing (changes over 15m=${changes})"
  else
    fail "finalized height has not advanced in the last 15 minutes"
    return 1
  fi
}

check_block_height_recent_growth() {
  local delta
  delta="$(prom_scalar 'increase(wrfcoin_blockchain_block_height[10m])')"
  if [ "$(to_int "${delta:-0}")" -gt 0 ]; then
    pass "block height advanced over the last 10m (delta=${delta})"
  else
    fail "block height did not increase over the last 10m"
    return 1
  fi
}

check_mempool_size() {
  local body_file code bytes fallback
  body_file="$(mktemp "${TMP_DIR}/blockchain.XXXX")"
  code="$(curl -sS --max-time 10 -o "${body_file}" -w '%{http_code}' "${NODE_API}/blockchain" 2>/dev/null || true)"

  if [ "${code}" != "200" ]; then
    fail "blockchain endpoint unavailable for mempool inspection (HTTP ${code:-000})"
    return 1
  fi

  bytes="$(
    python3 - "${body_file}" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8') as handle:
    payload = json.load(handle)
pending = payload.get('pending_transactions')
if pending is None:
    pending = payload.get('pending_txs')
if pending is None:
    pending = payload.get('mempool')
if pending is None:
    print(-1)
else:
    print(len(json.dumps(pending, separators=(",", ":"), sort_keys=True).encode("utf-8")))
PY
  )"

  if [ "${bytes}" -ge 0 ] 2>/dev/null; then
    if [ "${bytes}" -lt "${MEMPOOL_MAX_BYTES}" ]; then
      pass "mempool payload size ${bytes} bytes (< ${MEMPOOL_MAX_BYTES})"
    else
      fail "mempool payload size ${bytes} bytes exceeds ${MEMPOOL_MAX_BYTES}"
      return 1
    fi
    return 0
  fi

  fallback="$(prom_scalar 'wrfcoin_blockchain_mempool_size')"
  if [ "$(to_int "${fallback:-0}")" -eq 0 ]; then
    warn "mempool byte size unavailable; falling back to wrfcoin_blockchain_mempool_size=${fallback:-0}"
  else
    fail "mempool byte size unavailable and fallback metric is non-zero (${fallback:-0})"
    return 1
  fi
}

check_prometheus_targets() {
  local targets_file code unhealthy
  targets_file="$(mktemp "${TMP_DIR}/targets.XXXX")"
  code="$(curl -sS --max-time 10 -o "${targets_file}" -w '%{http_code}' "${PROMETHEUS_URL}/api/v1/targets" 2>/dev/null || true)"

  if [ "${code}" != "200" ]; then
    fail "Prometheus /api/v1/targets returned HTTP ${code:-000}"
    return 1
  fi

  unhealthy="$(jq -r '
    .data.activeTargets[]
    | select(.health != "up")
    | "\(.labels.job // .scrapePool // "unknown") => \(.health)"
  ' "${targets_file}" 2>/dev/null || true)"

  if [ -n "${unhealthy}" ]; then
    fail "Prometheus has unhealthy targets"
    printf '%s\n' "${unhealthy}" | sed 's/^/  /'
    return 1
  fi

  pass "Prometheus reports all active scrape targets healthy"
}

check_grafana() {
  local body_file code
  body_file="$(mktemp "${TMP_DIR}/grafana.XXXX")"
  code="$(curl -sS --max-time 10 -o "${body_file}" -w '%{http_code}' "${GRAFANA_URL}/api/health" 2>/dev/null || true)"

  if [ "${code}" = "200" ]; then
    pass "Grafana reachable at ${GRAFANA_URL}"
  else
    fail "Grafana health check failed (HTTP ${code:-000})"
    return 1
  fi
}

check_alertmanager() {
  local alerts_file code firing
  alerts_file="$(mktemp "${TMP_DIR}/alerts.XXXX")"
  code="$(curl -sS --max-time 10 -o "${alerts_file}" -w '%{http_code}' "${ALERTMANAGER_URL}/api/v2/alerts" 2>/dev/null || true)"

  if [ "${code}" != "200" ]; then
    fail "AlertManager alerts endpoint returned HTTP ${code:-000}"
    return 1
  fi

  firing="$(jq '[.[] | select(.status.state == "active")] | length' "${alerts_file}" 2>/dev/null || echo "0")"
  if [ "${firing}" = "0" ]; then
    pass "AlertManager has no firing alerts"
  else
    fail "AlertManager has ${firing} firing alert(s)"
    return 1
  fi
}

check_loki() {
  local code
  code="$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "${LOKI_URL}/ready" 2>/dev/null || true)"
  if [ "${code}" = "200" ]; then
    pass "Loki ready endpoint is healthy"
  else
    fail "Loki ready endpoint failed (HTTP ${code:-000})"
    return 1
  fi
}

check_weather_collector() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'wrfcoin-testnet-weather-collector'; then
    fail "weather collector container is not running"
    return 1
  fi

  if docker logs --since 15m wrfcoin-testnet-weather-collector 2>&1 | grep -q '.'; then
    pass "weather collector is running and emitted logs in the last 15m"
  else
    fail "weather collector is running but no recent logs were observed"
    return 1
  fi
}

check_contributor_balance() {
  local addr_file code balance_raw balance_display minimum_display
  addr_file="$(mktemp "${TMP_DIR}/address.XXXX")"
  code="$(curl -sS --max-time 10 -o "${addr_file}" -w '%{http_code}' "${NODE_API}/addresses/${CONTRIBUTOR}" 2>/dev/null || true)"

  if [ "${code}" != "200" ]; then
    fail "contributor balance lookup failed (HTTP ${code:-000})"
    return 1
  fi

  balance_raw="$(jq -r '.data.balance // .balance // 0' "${addr_file}" 2>/dev/null || echo "0")"
  balance_display="$(format_base_units "${balance_raw}")"
  minimum_display="$(format_base_units "${MIN_CONTRIBUTOR_BALANCE_BASE_UNITS}")"

  if [ "$(to_int "${balance_raw}")" -ge "$(to_int "${MIN_CONTRIBUTOR_BALANCE_BASE_UNITS}")" ]; then
    pass "contributor balance ${balance_display} WRF meets threshold ${minimum_display} WRF"
  else
    fail "contributor balance ${balance_display} WRF is below threshold ${minimum_display} WRF"
    return 1
  fi
}

build_test_payload() {
  local seq="$1"
  python3 - "${STATION_ID}" "${seq}" <<'PY'
import json, sys, time
station_id = sys.argv[1]
seq = int(sys.argv[2])
now_ms = int(time.time() * 1000)
payload = {
    "station_id": station_id,
    "recorded_at_ms": now_ms,
    "temperature_c": 18.5 + (seq % 7) * 0.2,
    "humidity_pct": 52.0 + (seq % 5) * 0.5,
    "pressure_hpa": 1012.4 + (seq % 3) * 0.1,
    "wind_speed_ms": 1.8,
    "source": "sustained-preflight",
}
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

build_commit_hash() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import hashlib, sys
payload, nonce, station_id, now_s = sys.argv[1:5]
preimage = payload + "||" + nonce + "||" + station_id + "||" + now_s + "||contribution"
print(hashlib.sha3_256(preimage.encode()).hexdigest())
PY
}

get_auth_token() {
  local token
  token="$(env_file_value WRFCOIN_CONTRIBUTOR_TOKEN || true)"
  if [ -z "${token}" ]; then
    token="$(env_file_value WRFCOIN_OPERATOR_TOKEN || true)"
  fi
  printf '%s' "${token}"
}

check_test_submission() {
  if [ "${PERFORM_TEST_SUBMISSION}" -eq 0 ]; then
    warn "test submission skipped via --skip-submit"
    return 0
  fi

  local token payload nonce now_s commit_hash commit_code reveal_code
  token="$(get_auth_token)"
  if [ -z "${token}" ]; then
    fail "no contributor/operator token available for commit/reveal preflight"
    return 1
  fi

  payload="$(build_test_payload 1)"
  nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  now_s="$(date +%s)"
  commit_hash="$(build_commit_hash "${payload}" "${nonce}" "${STATION_ID}" "${now_s}")"

  commit_code="$(curl_with_bearer "${token}" -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -X POST "${NODE_API}/transactions/contribution/commit" \
    -H 'Content-Type: application/json' \
    -d "{\"contributor\":\"${CONTRIBUTOR}\",\"station_id\":\"${STATION_ID}\",\"commit_hash\":\"${commit_hash}\"}" \
    2>/dev/null || echo "000")"

  reveal_code="$(curl_with_bearer "${token}" -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -X POST "${NODE_API}/transactions/contribution/reveal" \
    -H 'Content-Type: application/json' \
    -d "{\"contributor\":\"${CONTRIBUTOR}\",\"station_id\":\"${STATION_ID}\",\"payload\":${payload},\"nonce\":\"${nonce}\",\"commit_hash\":\"${commit_hash}\",\"timestamp\":${now_s}}" \
    2>/dev/null || echo "000")"

  if [ "${commit_code}" = "200" ] && [ "${reveal_code}" = "200" ]; then
    pass "test contribution commit/reveal succeeded (commit=200 reveal=200)"
  else
    fail "test contribution submit failed (commit=${commit_code} reveal=${reveal_code})"
    return 1
  fi
}

main() {
  log_section "WRFCoin sustained test preflight"
  printf 'Node API: %s\nPrometheus: %s\nGrafana: %s\nAlertManager: %s\nLoki: %s\n' \
    "${NODE_API}" "${PROMETHEUS_URL}" "${GRAFANA_URL}" "${ALERTMANAGER_URL}" "${LOKI_URL}"

  check_dependencies || true

  log_section "Infrastructure"
  check_container_health || true
  check_volume_free_space || true
  check_postgres_connections || true
  check_redis_memory || true
  check_ntp_sync || true

  log_section "Blockchain"
  check_readyz || true
  check_metrics_endpoint || true
  check_finalized_height_progress || true
  check_block_height_recent_growth || true
  check_mempool_size || true

  log_section "Monitoring"
  check_prometheus_targets || true
  check_grafana || true
  check_alertmanager || true
  check_loki || true

  log_section "Load Generator"
  check_weather_collector || true
  check_contributor_balance || true
  check_test_submission || true

  log_section "Summary"
  printf 'PASS=%d WARN=%d FAIL=%d\n' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"

  if [ "${FAIL_COUNT}" -eq 0 ]; then
    printf '%sGO%s sustained 48h test may proceed\n' "${C_PASS}" "${C_RESET}"
    exit 0
  fi

  printf '%sNO-GO%s fix the failed checks before starting the 48h sustained test\n' "${C_FAIL}" "${C_RESET}"
  exit 1
}

main "$@"
