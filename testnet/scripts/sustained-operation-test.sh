#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — 48-hour Sustained Operation Test (issue core4#758)
#
# Runs a long-duration soak test against a live testnet stack:
#   1. Pre-flight: verifies containers up, node ready, Prometheus scraping
#   2. Baseline: captures key metrics and disk/container stats to JSON
#   3. Load: starts a background commit/reveal loop against the node API
#   4. Periodic sampling: re-captures metrics and disk growth on schedule
#   5. Optional disruption checks: restart the node and weather collector
#   6. Termination: captures final metrics, evaluates pass/fail, writes report
#
# The script is idempotent and non-destructive. It only READS metrics,
# POSTS contribution commit/reveal pairs to the running node, optionally
# restarts selected containers when --with-disruptions is enabled, and writes
# output to $OUT_DIR (default /var/log/wrfcoin-sustained-test/ or
# /tmp/wrfcoin-sustained-test/).
#
# Usage:
#   sustained-operation-test.sh [--duration 48h] [--interval 15m]
#                               [--load-interval 60] [--load-profile flat]
#                               [--with-disruptions] [--dry-run]
#                               [--out-dir /path]
#
# Dependencies: bash 4+, curl, jq, docker compose (v2), awk, python3
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (CLI override-able)
# ---------------------------------------------------------------------------
DURATION="${DURATION:-48h}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-15m}"
LOAD_INTERVAL_SECS="${LOAD_INTERVAL_SECS:-60}"
LOAD_PROFILE="${LOAD_PROFILE:-flat}"
WITH_DISRUPTIONS=0
DRY_RUN=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
P2P_GUARD="${TESTNET_DIR}/check-p2p-external-addr.sh"

# Node/backend endpoints (localhost bindings per docker-compose.testnet.yml)
NODE_API="${NODE_API:-http://127.0.0.1:8556}"
BACKEND_API="${BACKEND_API:-http://127.0.0.1:4001}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
GRAFANA_URL="${GRAFANA_URL:-http://127.0.0.1:3100}"
TESTNET_ENV_FILE="${TESTNET_ENV_FILE:-${TESTNET_DIR}/.env}"
GRAFANA_DASHBOARD_UID="${GRAFANA_DASHBOARD_UID:-wrfcoin-sustained-test-48h}"
GRAFANA_SNAPSHOT_TIMEOUT_SECS="${GRAFANA_SNAPSHOT_TIMEOUT_SECS:-30}"

# Default station/contributor — used only for simulated commit/reveal load.
# The contributor address must exist as a registered account in the testnet
# state; 0x...0b02 is the documented default in TESTNET_OPERATOR_GUIDE.md.
CONTRIBUTOR="${CONTRIBUTOR:-0x0000000000000000000000000000000000000b02}"
STATION_ID="${STATION_ID:-sustained-test-station-001}"

# Pass/fail thresholds
MAX_MEMORY_GROWTH_PCT="${MAX_MEMORY_GROWTH_PCT:-20}"                 # %
MIN_PEER_COUNT="${MIN_PEER_COUNT:-0}"                               # 0 = allow solo node
MAX_API_LATENCY_P95_MS="${MAX_API_LATENCY_P95_MS:-500}"
MAX_ROOT_FS_GROWTH_BYTES="${MAX_ROOT_FS_GROWTH_BYTES:-10737418240}" # 10 GiB
MAX_VOLUME_USAGE_PCT="${MAX_VOLUME_USAGE_PCT:-85}"

# Disruption schedule (opt-in)
NODE_RESTART_AT_SECS="${NODE_RESTART_AT_SECS:-64800}"               # hour 18
COLLECTOR_RESTART_AT_SECS="${COLLECTOR_RESTART_AT_SECS:-108000}"    # hour 30
NODE_READY_TIMEOUT_SECS="${NODE_READY_TIMEOUT_SECS:-60}"
NODE_HEIGHT_RECOVERY_TIMEOUT_SECS="${NODE_HEIGHT_RECOVERY_TIMEOUT_SECS:-300}"
NODE_MEMPOOL_RECOVERY_TIMEOUT_SECS="${NODE_MEMPOOL_RECOVERY_TIMEOUT_SECS:-300}"
COLLECTOR_RESUME_TIMEOUT_SECS="${COLLECTOR_RESUME_TIMEOUT_SECS:-300}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

OUT_DIR_DEFAULT="/tmp/wrfcoin-sustained-test"
if [ -d "/var/log" ] && [ -w "/var/log" ]; then
  OUT_DIR_DEFAULT="/var/log/wrfcoin-sustained-test"
fi
OUT_DIR="${OUT_DIR:-${OUT_DIR_DEFAULT}}"

NODE_CONTAINER="wrfcoin-testnet-node"
BACKEND_CONTAINER="wrfcoin-testnet-backend"
POSTGRES_CONTAINER="wrfcoin-testnet-postgres"
REDIS_CONTAINER="wrfcoin-testnet-redis"
PROMETHEUS_CONTAINER="wrfcoin-testnet-prometheus"
LOKI_CONTAINER="wrfcoin-testnet-loki"
WEATHER_COLLECTOR_CONTAINER="wrfcoin-testnet-weather-collector"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --duration)         DURATION="$2";             shift 2 ;;
    --duration=*)       DURATION="${1#*=}";        shift ;;
    --interval)         SAMPLE_INTERVAL="$2";      shift 2 ;;
    --interval=*)       SAMPLE_INTERVAL="${1#*=}"; shift ;;
    --load-interval)    LOAD_INTERVAL_SECS="$2";   shift 2 ;;
    --load-interval=*)  LOAD_INTERVAL_SECS="${1#*=}"; shift ;;
    --load-profile)     LOAD_PROFILE="$2";         shift 2 ;;
    --load-profile=*)   LOAD_PROFILE="${1#*=}";    shift ;;
    --with-disruptions) WITH_DISRUPTIONS=1;        shift ;;
    --out-dir)          OUT_DIR="$2";              shift 2 ;;
    --out-dir=*)        OUT_DIR="${1#*=}";         shift ;;
    --dry-run)          DRY_RUN=1;                 shift ;;
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

mkdir -p "${OUT_DIR}"
JSON_LOG="${OUT_DIR}/sustained-test-${TIMESTAMP}.jsonl"
REPORT="${OUT_DIR}/sustained-test-${TIMESTAMP}.md"
LOAD_LOG="${OUT_DIR}/load-${TIMESTAMP}.log"
LOAD_PID_FILE="${OUT_DIR}/load-${TIMESTAMP}.pid"
RECOVERY_LOG="${OUT_DIR}/recovery-${TIMESTAMP}.jsonl"
SNAPSHOT_METADATA_FILE="${OUT_DIR}/grafana-snapshot-${TIMESTAMP}.json"
SNAPSHOT_REQUEST_FILE="${OUT_DIR}/grafana-snapshot-request-${TIMESTAMP}.json"
SNAPSHOT_RESPONSE_FILE="${OUT_DIR}/grafana-snapshot-response-${TIMESTAMP}.json"
SNAPSHOT_DASHBOARD_FILE="${OUT_DIR}/grafana-dashboard-${TIMESTAMP}.json"
: > "${RECOVERY_LOG}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
err() { printf '[%s] ERROR: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

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

# infra#1073: HTTP Basic credentials as a stdin header, not `-u user:password`
# argv. base64 reads the pair on stdin, so it never appears in argv either.
curl_with_basic_auth() { # curl_with_basic_auth <user> <password> [curl args...]
  local user="$1" password="$2"
  shift 2
  printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "${user}" "${password}" | base64 | tr -d '\n')" |
    curl -H @- "$@"
}

has_compose() {
  docker compose version >/dev/null 2>&1 || have docker-compose
}

compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" "$@"
  elif have docker-compose; then
    docker-compose -f "${COMPOSE_FILE}" "$@"
  else
    return 127
  fi
}

json_number_or_null() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" = "null" ]]; then
    echo "null"
  elif [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "${value}"
  else
    echo "null"
  fi
}

json_number_or_zero() {
  local value="${1:-}"
  if [[ -z "${value}" || "${value}" = "null" ]]; then
    echo "0"
  elif [[ "${value}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "${value}"
  else
    echo "0"
  fi
}

env_file_value() {
  local key="$1"
  if ! [ -f "${TESTNET_ENV_FILE}" ]; then
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

write_snapshot_metadata() {
  local status="$1" url="$2" message="$3"
  jq -cn \
    --arg status "${status}" \
    --arg url "${url}" \
    --arg message "${message}" \
    --arg dashboard_uid "${GRAFANA_DASHBOARD_UID}" \
    --arg grafana_url "${GRAFANA_URL}" \
    --arg request_file "${SNAPSHOT_REQUEST_FILE}" \
    --arg response_file "${SNAPSHOT_RESPONSE_FILE}" \
    --arg dashboard_file "${SNAPSHOT_DASHBOARD_FILE}" \
    --arg captured_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{
      status: $status,
      url: $url,
      message: $message,
      dashboard_uid: $dashboard_uid,
      grafana_url: $grafana_url,
      request_file: $request_file,
      response_file: $response_file,
      dashboard_file: $dashboard_file,
      captured_at: $captured_at
    }' > "${SNAPSHOT_METADATA_FILE}"
}

export_grafana_snapshot() {
  local grafana_user grafana_password dashboard_code snapshot_code snapshot_url

  grafana_user="${GRAFANA_ADMIN_USER:-$(env_file_value GRAFANA_ADMIN_USER 2>/dev/null || echo "admin")}"
  grafana_password="${GRAFANA_ADMIN_PASSWORD:-$(env_file_value GRAFANA_ADMIN_PASSWORD 2>/dev/null || true)}"

  if [ -z "${grafana_password}" ]; then
    write_snapshot_metadata "skipped" "" "Grafana admin password was not available"
    log "grafana snapshot: skipped (missing Grafana credentials)"
    return 0
  fi

  dashboard_code="$(curl_with_basic_auth "${grafana_user}" "${grafana_password}" \
    -sS --max-time "${GRAFANA_SNAPSHOT_TIMEOUT_SECS}" \
    -o "${SNAPSHOT_DASHBOARD_FILE}" \
    -w '%{http_code}' \
    "${GRAFANA_URL}/api/dashboards/uid/${GRAFANA_DASHBOARD_UID}" 2>/dev/null || echo "000")"

  if [ "${dashboard_code}" != "200" ]; then
    write_snapshot_metadata "failed" "" "Grafana dashboard lookup failed with HTTP ${dashboard_code}"
    err "grafana snapshot: dashboard lookup failed (HTTP ${dashboard_code})"
    return 1
  fi

  python3 - "${SNAPSHOT_DASHBOARD_FILE}" "${SNAPSHOT_REQUEST_FILE}" "${SCRIPT_START_ISO}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" <<'PY'
import json
import sys

dashboard_path, request_path, time_from, time_to = sys.argv[1:5]
with open(dashboard_path, "r", encoding="utf-8") as handle:
    payload = json.load(handle)

dashboard = payload.get("dashboard") or {}
dashboard["id"] = None
dashboard["time"] = {"from": time_from, "to": time_to}

request = {
    "dashboard": dashboard,
    "name": dashboard.get("title", "WRFCoin Sustained Test 48h"),
    "expires": 0,
}

with open(request_path, "w", encoding="utf-8") as handle:
    json.dump(request, handle, indent=2, sort_keys=True)
PY

  snapshot_code="$(curl_with_basic_auth "${grafana_user}" "${grafana_password}" \
    -sS --max-time "${GRAFANA_SNAPSHOT_TIMEOUT_SECS}" \
    -H 'Content-Type: application/json' \
    -X POST \
    -o "${SNAPSHOT_RESPONSE_FILE}" \
    -w '%{http_code}' \
    --data @"${SNAPSHOT_REQUEST_FILE}" \
    "${GRAFANA_URL}/api/snapshots" 2>/dev/null || echo "000")"

  if [ "${snapshot_code}" = "200" ]; then
    snapshot_url="$(jq -r '.url // empty' "${SNAPSHOT_RESPONSE_FILE}" 2>/dev/null || true)"
    write_snapshot_metadata "exported" "${snapshot_url}" "Grafana snapshot created successfully"
    log "grafana snapshot: exported${snapshot_url:+ (${snapshot_url})}"
    return 0
  fi

  write_snapshot_metadata "failed" "" "Grafana snapshot export failed with HTTP ${snapshot_code}"
  err "grafana snapshot: export failed (HTTP ${snapshot_code})"
  return 1
}

# parse_duration "48h" -> seconds
parse_duration() {
  local d="$1" n unit
  if [[ "$d" =~ ^([0-9]+)([smhd]?)$ ]]; then
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-s}"
    case "$unit" in
      s) echo "$n" ;;
      m) echo $((n * 60)) ;;
      h) echo $((n * 3600)) ;;
      d) echo $((n * 86400)) ;;
    esac
  else
    err "unparseable duration: $d (expect like 48h, 15m, 90s, 2d)"
    return 1
  fi
}

validate_config() {
  case "${LOAD_PROFILE}" in
    flat|ramp) ;;
    *)
      err "invalid --load-profile=${LOAD_PROFILE} (expected flat or ramp)"
      return 1
      ;;
  esac

  if ! [[ "${LOAD_INTERVAL_SECS}" =~ ^[0-9]+$ ]] || [ "${LOAD_INTERVAL_SECS}" -lt 1 ]; then
    err "--load-interval must be a positive integer"
    return 1
  fi

  return 0
}

# Query a single scalar from Prometheus; prints empty string on error.
prom_scalar() {
  local query="$1" result
  result="$(curl -sf --max-time 5 \
    --data-urlencode "query=${query}" \
    "${PROMETHEUS_URL}/api/v1/query" 2>/dev/null || true)"
  if [ -z "${result}" ]; then
    echo ""
    return 0
  fi
  echo "${result}" | jq -r '
    if .status == "success" and (.data.result | length) > 0
    then .data.result[0].value[1]
    else ""
    end
  ' 2>/dev/null || echo ""
}

path_size_bytes() {
  local path="$1"
  if ! [ -e "${path}" ]; then
    echo "0"
    return 0
  fi

  if du -sb "${path}" >/dev/null 2>&1; then
    du -sb "${path}" 2>/dev/null | awk '{print $1}'
  else
    du -sk "${path}" 2>/dev/null | awk '{print $1 * 1024}'
  fi
}

df_snapshot() {
  local path="$1"
  if ! [ -e "${path}" ]; then
    echo "0 0 0 0"
    return 0
  fi

  df -B1 -P "${path}" 2>/dev/null \
    | awk 'NR==2 {gsub(/%/, "", $5); printf "%s %s %s %s\n", $2, $3, $4, $5}' \
    || echo "0 0 0 0"
}

container_path_size_bytes() {
  local container="$1" path="$2"
  docker exec "${container}" sh -lc "
    target='${path}'
    if [ ! -e \"\$target\" ]; then
      echo 0
      exit 0
    fi
    if du -sb \"\$target\" >/dev/null 2>&1; then
      du -sb \"\$target\" | awk '{print \$1}'
    else
      du -sk \"\$target\" | awk '{print \$1 * 1024}'
    fi
  " 2>/dev/null | tr -d '[:space:]' || echo "0"
}

container_df_snapshot() {
  local container="$1" path="$2"
  docker exec "${container}" sh -lc "
    target='${path}'
    if [ ! -e \"\$target\" ]; then
      echo '0 0 0 0'
      exit 0
    fi
    df -B1 -P \"\$target\" | awk 'NR==2 {gsub(/%/, \"\", \$5); printf \"%s %s %s %s\n\", \$2, \$3, \$4, \$5}'
  " 2>/dev/null || echo "0 0 0 0"
}

resolve_container_mount_info() {
  local container="$1" destination="$2"
  docker inspect "${container}" 2>/dev/null \
    | jq -r --arg dest "${destination}" '
        .[0].Mounts[]?
        | select(.Type == "volume" and .Destination == $dest)
        | [.Name, .Source] | @tsv
      ' 2>/dev/null \
    | head -n 1 || true
}

build_volume_entry_json() {
  local label="$1" container="$2" destination="$3"
  local info volume_name mountpoint size_bytes fs_total fs_used fs_avail fs_pct

  info="$(resolve_container_mount_info "${container}" "${destination}")"
  if [ -z "${info}" ]; then
    return 0
  fi

  volume_name="${info%%$'\t'*}"
  mountpoint="${info#*$'\t'}"
  size_bytes="$(path_size_bytes "${mountpoint}")"
  read -r fs_total fs_used fs_avail fs_pct < <(df_snapshot "${mountpoint}")

  jq -cn \
    --arg label "${label}" \
    --arg container "${container}" \
    --arg volume "${volume_name}" \
    --arg destination "${destination}" \
    --arg mountpoint "${mountpoint}" \
    --argjson bytes "$(json_number_or_zero "${size_bytes}")" \
    --argjson fs_total_bytes "$(json_number_or_zero "${fs_total}")" \
    --argjson fs_used_bytes "$(json_number_or_zero "${fs_used}")" \
    --argjson fs_avail_bytes "$(json_number_or_zero "${fs_avail}")" \
    --argjson fs_use_pct "$(json_number_or_zero "${fs_pct}")" \
    '{
      label: $label,
      container: $container,
      volume: $volume,
      destination: $destination,
      mountpoint: $mountpoint,
      bytes: $bytes,
      fs_total_bytes: $fs_total_bytes,
      fs_used_bytes: $fs_used_bytes,
      fs_avail_bytes: $fs_avail_bytes,
      fs_use_pct: $fs_use_pct
    }'
}

build_tracked_path_entry_json() {
  local label="$1" container="$2" path="$3" volume_destination="$4"
  local info volume_name bytes fs_total fs_used fs_avail fs_pct

  volume_name=""
  if [ -n "${volume_destination}" ]; then
    info="$(resolve_container_mount_info "${container}" "${volume_destination}")"
    if [ -n "${info}" ]; then
      volume_name="${info%%$'\t'*}"
    fi
  fi

  bytes="$(container_path_size_bytes "${container}" "${path}")"
  read -r fs_total fs_used fs_avail fs_pct < <(container_df_snapshot "${container}" "${path}")

  jq -cn \
    --arg label "${label}" \
    --arg container "${container}" \
    --arg path "${path}" \
    --arg volume "${volume_name}" \
    --arg volume_destination "${volume_destination}" \
    --argjson bytes "$(json_number_or_zero "${bytes}")" \
    --argjson fs_total_bytes "$(json_number_or_zero "${fs_total}")" \
    --argjson fs_used_bytes "$(json_number_or_zero "${fs_used}")" \
    --argjson fs_avail_bytes "$(json_number_or_zero "${fs_avail}")" \
    --argjson fs_use_pct "$(json_number_or_zero "${fs_pct}")" \
    '{
      label: $label,
      container: $container,
      path: $path,
      volume: $volume,
      volume_destination: $volume_destination,
      bytes: $bytes,
      fs_total_bytes: $fs_total_bytes,
      fs_used_bytes: $fs_used_bytes,
      fs_avail_bytes: $fs_avail_bytes,
      fs_use_pct: $fs_use_pct
    }'
}

collect_disk_snapshot() {
  local root_total root_used root_avail root_pct
  read -r root_total root_used root_avail root_pct < <(df_snapshot "/")

  local tracked_paths_json volume_entries_json

  tracked_paths_json="$(
    {
      build_tracked_path_entry_json "postgres_data_dir" "${POSTGRES_CONTAINER}" "/var/lib/postgresql/data" "/var/lib/postgresql/data"
      build_tracked_path_entry_json "postgres_wal_archive" "${POSTGRES_CONTAINER}" "/var/lib/postgresql/data/backup/wal" "/var/lib/postgresql/data/backup"
      build_tracked_path_entry_json "prometheus_tsdb" "${PROMETHEUS_CONTAINER}" "/prometheus" "/prometheus"
      build_tracked_path_entry_json "loki_data" "${LOKI_CONTAINER}" "/loki" "/loki"
      build_tracked_path_entry_json "loki_chunks" "${LOKI_CONTAINER}" "/loki/chunks" "/loki"
    } | jq -sc '.'
  )"

  volume_entries_json="$(
    {
      build_volume_entry_json "node_data" "${NODE_CONTAINER}" "/app/data"
      build_volume_entry_json "postgres_data" "${POSTGRES_CONTAINER}" "/var/lib/postgresql/data"
      build_volume_entry_json "postgres_backup" "${POSTGRES_CONTAINER}" "/var/lib/postgresql/data/backup"
      build_volume_entry_json "redis_data" "${REDIS_CONTAINER}" "/data"
      build_volume_entry_json "prometheus_data" "${PROMETHEUS_CONTAINER}" "/prometheus"
      build_volume_entry_json "loki_data" "${LOKI_CONTAINER}" "/loki"
    } | jq -sc '.'
  )"

  jq -cn \
    --argjson root_total_bytes "$(json_number_or_zero "${root_total}")" \
    --argjson root_used_bytes "$(json_number_or_zero "${root_used}")" \
    --argjson root_avail_bytes "$(json_number_or_zero "${root_avail}")" \
    --argjson root_use_pct "$(json_number_or_zero "${root_pct}")" \
    --argjson tracked_paths "${tracked_paths_json:-[]}" \
    --argjson volumes "${volume_entries_json:-[]}" \
    '{
      host_root: {
        total_bytes: $root_total_bytes,
        used_bytes: $root_used_bytes,
        avail_bytes: $root_avail_bytes,
        use_pct: $root_use_pct
      },
      tracked_paths: $tracked_paths,
      volumes: $volumes
    }'
}

blockchain_snapshot() {
  local response
  response="$(curl -sf --max-time 5 "${NODE_API}/blockchain" 2>/dev/null || true)"
  if [ -z "${response}" ]; then
    echo '{"height":0,"pending_transactions":0}'
    return 0
  fi

  echo "${response}" | jq -c '
    {
      height: (.height // .block_height // 0),
      pending_transactions:
        (if (.pending_transactions | type) == "array" then (.pending_transactions | length)
         elif (.pending_transactions | type) == "number" then .pending_transactions
         elif (.pending_txs | type) == "number" then .pending_txs
         elif (.mempool_size | type) == "number" then .mempool_size
         else 0 end)
    }
  ' 2>/dev/null || echo '{"height":0,"pending_transactions":0}'
}

get_block_height() {
  blockchain_snapshot | jq -r '.height // 0' 2>/dev/null || echo "0"
}

get_pending_transactions() {
  blockchain_snapshot | jq -r '.pending_transactions // 0' 2>/dev/null || echo "0"
}

record_recovery_event() {
  local name="$1" status="$2" started_at="$3" completed_at="$4" duration_secs="$5" details_json="$6"
  jq -cn \
    --arg name "${name}" \
    --arg status "${status}" \
    --arg started_at "${started_at}" \
    --arg completed_at "${completed_at}" \
    --argjson duration_secs "$(json_number_or_zero "${duration_secs}")" \
    --argjson details "${details_json:-{}}" \
    '{
      name: $name,
      status: $status,
      started_at: $started_at,
      completed_at: $completed_at,
      duration_secs: $duration_secs,
      details: $details
    }' >> "${RECOVERY_LOG}"
}

wait_for_readyz() {
  local timeout_secs="$1"
  local start now code
  start="$(date +%s)"

  while :; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
    if [ "${code}" = "200" ]; then
      now="$(date +%s)"
      echo $((now - start))
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout_secs}" ]; then
      return 1
    fi
    sleep 5
  done
}

wait_for_height_at_least() {
  local minimum_height="$1" timeout_secs="$2"
  local start now current_height
  start="$(date +%s)"

  while :; do
    current_height="$(get_block_height)"
    if [ "$(json_number_or_zero "${current_height}")" -ge "$(json_number_or_zero "${minimum_height}")" ]; then
      now="$(date +%s)"
      printf '%s %s\n' $((now - start)) "${current_height}"
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout_secs}" ]; then
      printf '%s %s\n' $((now - start)) "${current_height:-0}"
      return 1
    fi
    sleep 5
  done
}

wait_for_mempool_recovery() {
  local baseline_mempool="$1" timeout_secs="$2"
  local start now current_mempool
  start="$(date +%s)"

  if [ "$(json_number_or_zero "${baseline_mempool}")" -le 0 ]; then
    current_mempool="$(get_pending_transactions)"
    printf 'not_applicable %s %s\n' "0" "${current_mempool:-0}"
    return 0
  fi

  while :; do
    current_mempool="$(get_pending_transactions)"
    if [ "$(json_number_or_zero "${current_mempool}")" -ge "$(json_number_or_zero "${baseline_mempool}")" ] || [ "$(json_number_or_zero "${current_mempool}")" -gt 0 ]; then
      now="$(date +%s)"
      printf 'recovered %s %s\n' $((now - start)) "${current_mempool}"
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout_secs}" ]; then
      printf 'failed %s %s\n' $((now - start)) "${current_mempool:-0}"
      return 1
    fi
    sleep 5
  done
}

postgres_sanity_check() {
  compose exec -T postgres psql -U wrfcoin -d wrfcoin -tAc "SELECT 1;" 2>/dev/null \
    | tr -d '[:space:]' | grep -qx '1'
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

wait_for_container_logs() {
  local container="$1" since_iso="$2" timeout_secs="$3"
  local start now
  start="$(date +%s)"

  while :; do
    if docker logs --since "${since_iso}" "${container}" 2>&1 | grep -q '.'; then
      now="$(date +%s)"
      echo $((now - start))
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "${timeout_secs}" ]; then
      return 1
    fi
    sleep 5
  done
}

perform_node_restart_check() {
  local started_at completed_at event_start_epoch
  local pre_height pre_mempool ready_wait ready_status
  local height_status height_wait post_height
  local mempool_status mempool_wait post_mempool
  local pg_ok status details

  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  event_start_epoch="$(date +%s)"
  pre_height="$(get_block_height)"
  pre_mempool="$(get_pending_transactions)"

  log "disruption: restarting ${NODE_CONTAINER} at t+$((event_start_epoch - SCRIPT_START_EPOCH))s"
  if ! "${P2P_GUARD}" --env-file "${TESTNET_ENV_FILE}" --require; then
    err "node restart disruption refused: advertised external address lacks a reachability proof"
    return 1
  fi
  if ! docker restart "${NODE_CONTAINER}" >/dev/null 2>&1; then
    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="$(jq -cn \
      --arg container "${NODE_CONTAINER}" \
      --argjson pre_height "$(json_number_or_zero "${pre_height}")" \
      --argjson pre_mempool "$(json_number_or_zero "${pre_mempool}")" \
      '{container: $container, pre_height: $pre_height, pre_mempool: $pre_mempool, error: "docker restart failed"}')"
    record_recovery_event "node_restart" "failed" "${started_at}" "${completed_at}" "$(( $(date +%s) - event_start_epoch ))" "${details}"
    err "node restart disruption failed immediately"
    return 1
  fi

  if ready_wait="$(wait_for_readyz "${NODE_READY_TIMEOUT_SECS}")"; then
    ready_status="ready"
  else
    ready_wait="${NODE_READY_TIMEOUT_SECS}"
    ready_status="timeout"
  fi

  if read -r height_wait post_height < <(wait_for_height_at_least "${pre_height}" "${NODE_HEIGHT_RECOVERY_TIMEOUT_SECS}"); then
    height_status="recovered"
  else
    height_status="failed"
  fi

  if read -r mempool_status mempool_wait post_mempool < <(wait_for_mempool_recovery "${pre_mempool}" "${NODE_MEMPOOL_RECOVERY_TIMEOUT_SECS}"); then
    :
  else
    mempool_status="failed"
  fi

  if postgres_sanity_check; then
    pg_ok="true"
  else
    pg_ok="false"
  fi

  status="success"
  if [ "${ready_status}" != "ready" ] || [ "${height_status}" != "recovered" ] || [ "${mempool_status}" = "failed" ] || [ "${pg_ok}" != "true" ]; then
    status="failed"
  fi

  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  details="$(jq -cn \
    --arg container "${NODE_CONTAINER}" \
    --argjson pre_height "$(json_number_or_zero "${pre_height}")" \
    --argjson pre_mempool "$(json_number_or_zero "${pre_mempool}")" \
    --arg ready_status "${ready_status}" \
    --argjson ready_wait_secs "$(json_number_or_zero "${ready_wait}")" \
    --arg height_status "${height_status}" \
    --argjson height_recovery_secs "$(json_number_or_zero "${height_wait}")" \
    --argjson post_height "$(json_number_or_zero "${post_height}")" \
    --arg mempool_status "${mempool_status}" \
    --argjson mempool_recovery_secs "$(json_number_or_zero "${mempool_wait}")" \
    --argjson post_mempool "$(json_number_or_zero "${post_mempool}")" \
    --argjson postgres_ok "${pg_ok}" \
    '{
      container: $container,
      pre_height: $pre_height,
      pre_mempool: $pre_mempool,
      ready_status: $ready_status,
      ready_wait_secs: $ready_wait_secs,
      height_status: $height_status,
      height_recovery_secs: $height_recovery_secs,
      post_height: $post_height,
      mempool_status: $mempool_status,
      mempool_recovery_secs: $mempool_recovery_secs,
      post_mempool: $post_mempool,
      postgres_ok: $postgres_ok
    }')"
  record_recovery_event "node_restart" "${status}" "${started_at}" "${completed_at}" "$(( $(date +%s) - event_start_epoch ))" "${details}"

  if [ "${status}" = "success" ]; then
    log "node restart disruption recovered in ${ready_wait}s (height=${post_height}, mempool=${post_mempool})"
    return 0
  fi

  err "node restart disruption failed recovery checks"
  return 1
}

perform_collector_restart_check() {
  local started_at completed_at event_start_epoch
  local pre_height pre_mempool post_height post_mempool
  local log_wait height_status height_wait log_status status details

  started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  event_start_epoch="$(date +%s)"

  if ! container_exists "${WEATHER_COLLECTOR_CONTAINER}"; then
    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="$(jq -cn --arg container "${WEATHER_COLLECTOR_CONTAINER}" '{container: $container, reason: "collector container not present"}')"
    record_recovery_event "weather_collector_restart" "skipped" "${started_at}" "${completed_at}" "0" "${details}"
    log "collector disruption skipped: ${WEATHER_COLLECTOR_CONTAINER} not present"
    return 0
  fi

  if ! container_running "${WEATHER_COLLECTOR_CONTAINER}"; then
    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="$(jq -cn --arg container "${WEATHER_COLLECTOR_CONTAINER}" '{container: $container, reason: "collector container exists but is not running"}')"
    record_recovery_event "weather_collector_restart" "skipped" "${started_at}" "${completed_at}" "0" "${details}"
    log "collector disruption skipped: ${WEATHER_COLLECTOR_CONTAINER} not running"
    return 0
  fi

  pre_height="$(get_block_height)"
  pre_mempool="$(get_pending_transactions)"
  local restart_anchor
  restart_anchor="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  log "disruption: restarting ${WEATHER_COLLECTOR_CONTAINER} at t+$((event_start_epoch - SCRIPT_START_EPOCH))s"
  if ! docker restart "${WEATHER_COLLECTOR_CONTAINER}" >/dev/null 2>&1; then
    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    details="$(jq -cn \
      --arg container "${WEATHER_COLLECTOR_CONTAINER}" \
      --argjson pre_height "$(json_number_or_zero "${pre_height}")" \
      --argjson pre_mempool "$(json_number_or_zero "${pre_mempool}")" \
      '{container: $container, pre_height: $pre_height, pre_mempool: $pre_mempool, error: "docker restart failed"}')"
    record_recovery_event "weather_collector_restart" "failed" "${started_at}" "${completed_at}" "$(( $(date +%s) - event_start_epoch ))" "${details}"
    err "weather collector restart disruption failed immediately"
    return 1
  fi

  if log_wait="$(wait_for_container_logs "${WEATHER_COLLECTOR_CONTAINER}" "${restart_anchor}" "${COLLECTOR_RESUME_TIMEOUT_SECS}")"; then
    log_status="observed_logs"
  else
    log_status="no_logs"
    log_wait="${COLLECTOR_RESUME_TIMEOUT_SECS}"
  fi

  if read -r height_wait post_height < <(wait_for_height_at_least "$((pre_height + 1))" "${COLLECTOR_RESUME_TIMEOUT_SECS}"); then
    height_status="advanced"
  else
    height_status="failed"
  fi

  post_mempool="$(get_pending_transactions)"

  status="success"
  if [ "${log_status}" != "observed_logs" ] || [ "${height_status}" != "advanced" ]; then
    status="failed"
  fi

  completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  details="$(jq -cn \
    --arg container "${WEATHER_COLLECTOR_CONTAINER}" \
    --argjson pre_height "$(json_number_or_zero "${pre_height}")" \
    --argjson pre_mempool "$(json_number_or_zero "${pre_mempool}")" \
    --arg log_status "${log_status}" \
    --argjson collector_resume_secs "$(json_number_or_zero "${log_wait}")" \
    --arg height_status "${height_status}" \
    --argjson height_recovery_secs "$(json_number_or_zero "${height_wait}")" \
    --argjson post_height "$(json_number_or_zero "${post_height}")" \
    --argjson post_mempool "$(json_number_or_zero "${post_mempool}")" \
    '{
      container: $container,
      pre_height: $pre_height,
      pre_mempool: $pre_mempool,
      log_status: $log_status,
      collector_resume_secs: $collector_resume_secs,
      height_status: $height_status,
      height_recovery_secs: $height_recovery_secs,
      post_height: $post_height,
      post_mempool: $post_mempool
    }')"
  record_recovery_event "weather_collector_restart" "${status}" "${started_at}" "${completed_at}" "$(( $(date +%s) - event_start_epoch ))" "${details}"

  if [ "${status}" = "success" ]; then
    log "weather collector restart recovered in ${log_wait}s (height=${post_height}, mempool=${post_mempool})"
    return 0
  fi

  err "weather collector restart disruption failed recovery checks"
  return 1
}

load_phase_for_elapsed() {
  local elapsed_secs="$1"
  if [ "${LOAD_PROFILE}" = "flat" ]; then
    echo "flat"
    return 0
  fi

  if [ "${elapsed_secs}" -lt $((6 * 3600)) ]; then
    echo "baseline"
  elif [ "${elapsed_secs}" -lt $((12 * 3600)) ]; then
    echo "light-pressure"
  elif [ "${elapsed_secs}" -lt $((24 * 3600)) ]; then
    echo "moderate-pressure"
  elif [ "${elapsed_secs}" -lt $((36 * 3600)) ]; then
    echo "sustained-pressure"
  else
    echo "cooldown"
  fi
}

load_interval_for_elapsed() {
  local elapsed_secs="$1"
  if [ "${LOAD_PROFILE}" = "flat" ]; then
    echo "${LOAD_INTERVAL_SECS}"
    return 0
  fi

  if [ "${elapsed_secs}" -lt $((6 * 3600)) ]; then
    echo "60"
  elif [ "${elapsed_secs}" -lt $((12 * 3600)) ]; then
    echo "12"
  elif [ "${elapsed_secs}" -lt $((36 * 3600)) ]; then
    echo "3"
  else
    echo "60"
  fi
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
  log "=== Pre-flight checks ==="
  local failures=0

  for cmd in curl jq docker awk python3; do
    if ! have "$cmd"; then
      err "required command not found: $cmd"
      failures=$((failures + 1))
    fi
  done

  if ! has_compose; then
    err "docker compose v2 or docker-compose is required"
    failures=$((failures + 1))
  fi

  if ! [ -f "${COMPOSE_FILE}" ]; then
    err "compose file not found: ${COMPOSE_FILE}"
    failures=$((failures + 1))
  fi

  if [ "${failures}" -gt 0 ]; then
    err "pre-flight failed — missing dependencies"
    return 1
  fi

  # Container health
  local unhealthy
  if has_compose; then
    unhealthy="$(compose ps --format json 2>/dev/null \
      | jq -r 'if type == "array" then .[] else . end
               | select(.State != "running") | .Name' 2>/dev/null || true)"
    if [ -n "${unhealthy}" ]; then
      err "containers not in running state:"
      printf '%s\n' "${unhealthy}" | sed 's/^/  /' >&2
      failures=$((failures + 1))
    else
      log "containers: all running"
    fi
  else
    err "docker compose unavailable"
    failures=$((failures + 1))
  fi

  # Node readiness
  local readyz_code
  readyz_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
  if [ "${readyz_code}" = "200" ]; then
    log "node /readyz: 200"
  else
    err "node /readyz: HTTP ${readyz_code} (expected 200)"
    failures=$((failures + 1))
  fi

  # Prometheus reachability
  local prom_code
  prom_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${PROMETHEUS_URL}/-/ready" || echo "000")"
  if [ "${prom_code}" = "200" ]; then
    log "prometheus /-/ready: 200"
  else
    err "prometheus /-/ready: HTTP ${prom_code}"
    failures=$((failures + 1))
  fi

  # Verify Prometheus is actually scraping the node job (metric present)
  local height
  height="$(prom_scalar 'wrfcoin_blockchain_block_height')"
  if [ -n "${height}" ] && [ "${height}" != "null" ]; then
    log "prometheus scraping wrfcoin-node (height=${height})"
  else
    err "prometheus has no wrfcoin_blockchain_block_height sample — scrape target down?"
    failures=$((failures + 1))
  fi

  if [ "${failures}" -gt 0 ]; then
    err "pre-flight failed with ${failures} error(s)"
    return 1
  fi
  log "pre-flight: OK"
  return 0
}

# ---------------------------------------------------------------------------
# Metric capture
# ---------------------------------------------------------------------------
# Capture a snapshot of all tracked metrics as a single JSON line. Tag is
# e.g. "baseline", "t+15m", "final".
capture_metrics() {
  local tag="$1"
  local now
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  local height mempool
  height="$(prom_scalar 'wrfcoin_blockchain_block_height')"
  mempool="$(prom_scalar 'wrfcoin_blockchain_mempool_size')"

  local node_rss backend_rss
  node_rss="$(prom_scalar 'process_resident_memory_bytes{job="wrfcoin-node"}')"
  backend_rss="$(prom_scalar 'process_resident_memory_bytes{job="wrfcoin-backend"}')"

  local fork_count reorg_total
  fork_count="$(prom_scalar 'wrfcoin_chain_fork_count')"
  reorg_total="$(prom_scalar 'wrfcoin_chain_reorg_total')"

  # Peer count: pull from /network/info (Prometheus label may not cover this).
  local peer_count
  peer_count="$(curl -sf --max-time 5 "${NODE_API}/network/info" 2>/dev/null \
    | jq -r '
        if (.connected_peers | type) == "array" then (.connected_peers | length)
        elif (.connected_peers | type) == "number" then .connected_peers
        elif (.peer_count | type) == "number" then .peer_count
        else 0 end' 2>/dev/null || echo "0")"

  # API latency: sample /blockchain 5 times, report p95 in ms.
  local latencies=() _i lat lat_p95
  for _i in 1 2 3 4 5; do
    lat="$(curl -sf --max-time 5 -o /dev/null -w '%{time_total}' "${NODE_API}/blockchain" 2>/dev/null || echo "0")"
    latencies+=("${lat}")
  done
  lat_p95="$(printf '%s\n' "${latencies[@]}" \
    | sort -g | awk 'BEGIN{c=0} {a[c++]=$1} END{if(c>0){i=int((c-1)*0.95+0.5); printf "%.3f", a[i]*1000}}')"
  [ -z "${lat_p95}" ] && lat_p95="0"

  # PostgreSQL backend count — query directly (no postgres_exporter).
  local pg_backends
  pg_backends="$(compose exec -T postgres psql -U wrfcoin -d wrfcoin -tAc \
    "SELECT numbackends FROM pg_stat_database WHERE datname='wrfcoin';" 2>/dev/null \
    | tr -d '[:space:]' || true)"
  [ -z "${pg_backends}" ] && pg_backends="0"

  # Container RSS via docker stats (fallback/cross-check vs prom node_rss).
  local node_ctr_mem backend_ctr_mem
  node_ctr_mem="$(docker stats --no-stream --format '{{.MemUsage}}' "${NODE_CONTAINER}" 2>/dev/null \
    | awk -F'/' '{print $1}' | tr -d '[:space:]' || echo "")"
  backend_ctr_mem="$(docker stats --no-stream --format '{{.MemUsage}}' "${BACKEND_CONTAINER}" 2>/dev/null \
    | awk -F'/' '{print $1}' | tr -d '[:space:]' || echo "")"

  local disk_json
  disk_json="$(collect_disk_snapshot)"

  # Service exit / restart count: anything with Exited in the last sample.
  local exited
  exited="$(docker ps -a --filter "label=com.docker.compose.project" \
    --format '{{.Names}}|{{.Status}}' 2>/dev/null \
    | awk -F'|' '$2 ~ /Exited|Restarting/ {print $1}' | tr '\n' ',' | sed 's/,$//' || true)"

  local rec
  rec="$(jq -cn \
    --arg tag "${tag}" \
    --arg ts "${now}" \
    --argjson height "$(json_number_or_null "${height}")" \
    --argjson mempool "$(json_number_or_null "${mempool}")" \
    --argjson node_rss "$(json_number_or_null "${node_rss}")" \
    --argjson backend_rss "$(json_number_or_null "${backend_rss}")" \
    --argjson fork_count "$(json_number_or_null "${fork_count}")" \
    --argjson reorg_total "$(json_number_or_null "${reorg_total}")" \
    --argjson peer_count "$(json_number_or_zero "${peer_count}")" \
    --argjson pg_backends "$(json_number_or_zero "${pg_backends}")" \
    --argjson lat_p95_ms "$(json_number_or_zero "${lat_p95}")" \
    --arg node_ctr_mem "${node_ctr_mem}" \
    --arg backend_ctr_mem "${backend_ctr_mem}" \
    --arg exited "${exited}" \
    --argjson disk "${disk_json}" \
    '{
      tag: $tag,
      ts: $ts,
      block_height: $height,
      mempool_size: $mempool,
      node_process_rss_bytes: $node_rss,
      backend_process_rss_bytes: $backend_rss,
      chain_fork_count: $fork_count,
      chain_reorg_total: $reorg_total,
      peer_count: $peer_count,
      pg_numbackends: $pg_backends,
      api_latency_p95_ms: $lat_p95_ms,
      node_container_mem: $node_ctr_mem,
      backend_container_mem: $backend_ctr_mem,
      exited_containers: $exited,
      disk: $disk
    }')"
  echo "${rec}" >> "${JSON_LOG}"
  echo "${rec}"
}

# ---------------------------------------------------------------------------
# Load generator — runs in background
# ---------------------------------------------------------------------------
spawn_load_generator() {
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "load generator: dry-run mode, not spawning"
    return 0
  fi

  # Pick up contributor token from testnet .env for authenticated submits.
  local token=""
  if [ -f "${TESTNET_DIR}/.env" ]; then
    token="$(grep -E '^WRFCOIN_CONTRIBUTOR_TOKEN=' "${TESTNET_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)"
    if [ -z "${token}" ]; then
      token="$(grep -E '^WRFCOIN_OPERATOR_TOKEN=' "${TESTNET_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)"
    fi
  fi

  log "load generator: starting (profile=${LOAD_PROFILE}, flat cadence=${LOAD_INTERVAL_SECS}s, station=${STATION_ID})"
  : > "${LOAD_LOG}"

  (
    trap 'exit 0' TERM INT
    local n=0
    while true; do
      n=$((n + 1))
      local now_ms now_s nonce elapsed_secs current_interval current_phase
      now_ms="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"
      now_s=$((now_ms / 1000))
      elapsed_secs=$((now_s - SCRIPT_START_EPOCH))
      current_interval="$(load_interval_for_elapsed "${elapsed_secs}")"
      current_phase="$(load_phase_for_elapsed "${elapsed_secs}")"
      nonce="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"

      local payload
      payload="$(python3 -c "
import json
obs = {
  'station_id': '${STATION_ID}',
  'recorded_at_ms': ${now_ms},
  'temperature_c': 20.0 + (${n} % 10) * 0.1,
  'humidity_pct': 55.0 + (${n} % 20) * 0.2,
  'pressure_hpa': 1013.2 + (${n} % 5) * 0.05,
  'wind_speed_ms': 2.5,
  'source': 'sustained-test'
}
print(json.dumps(obs, sort_keys=True, separators=(',', ':')))
")"

      local commit_hash
      commit_hash="$(python3 -c "
import hashlib
preimage = '${payload}' + '||' + '${nonce}' + '||${STATION_ID}||${now_s}||contribution'
print(hashlib.sha3_256(preimage.encode()).hexdigest())
")"

      local commit_code reveal_code
      commit_code="$(curl_with_bearer "${token}" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "${NODE_API}/transactions/contribution/commit" \
        -H 'Content-Type: application/json' \
        -d "{\"contributor\":\"${CONTRIBUTOR}\",\"station_id\":\"${STATION_ID}\",\"commit_hash\":\"${commit_hash}\"}" \
        2>/dev/null || echo "000")"

      reveal_code="$(curl_with_bearer "${token}" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "${NODE_API}/transactions/contribution/reveal" \
        -H 'Content-Type: application/json' \
        -d "{\"contributor\":\"${CONTRIBUTOR}\",\"station_id\":\"${STATION_ID}\",\"payload\":${payload},\"nonce\":\"${nonce}\",\"commit_hash\":\"${commit_hash}\",\"timestamp\":${now_s}}" \
        2>/dev/null || echo "000")"

      printf '[%s] load#%d profile=%s phase=%s interval=%ss commit=%s reveal=%s station=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${n}" "${LOAD_PROFILE}" "${current_phase}" "${current_interval}" "${commit_code}" "${reveal_code}" "${STATION_ID}" >> "${LOAD_LOG}"

      sleep "${current_interval}"
    done
  ) &

  echo $! > "${LOAD_PID_FILE}"
  log "load generator: PID $(cat "${LOAD_PID_FILE}"), logs at ${LOAD_LOG}"
}

stop_load_generator() {
  if [ -f "${LOAD_PID_FILE}" ]; then
    local pid
    pid="$(cat "${LOAD_PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      log "load generator: stopped PID ${pid}"
    fi
    rm -f "${LOAD_PID_FILE}"
  fi
}

# ---------------------------------------------------------------------------
# Evaluation / report generation
# ---------------------------------------------------------------------------
evaluate_and_report() {
  log "=== Evaluating test results ==="
  if ! [ -s "${JSON_LOG}" ]; then
    err "no samples in ${JSON_LOG}"
    return 1
  fi

  local oom_events summary_json verdict
  oom_events="$(docker events --since "${SCRIPT_START_EPOCH:-1}" --until "$(date +%s)" \
    --filter 'event=oom' --format '{{.Actor.Attributes.name}}' 2>/dev/null | sort -u | paste -sd',' - || true)"

  summary_json="$(
    MAX_MEMORY_GROWTH_PCT="${MAX_MEMORY_GROWTH_PCT}" \
    MIN_PEER_COUNT="${MIN_PEER_COUNT}" \
    MAX_API_LATENCY_P95_MS="${MAX_API_LATENCY_P95_MS}" \
    MAX_ROOT_FS_GROWTH_BYTES="${MAX_ROOT_FS_GROWTH_BYTES}" \
    MAX_VOLUME_USAGE_PCT="${MAX_VOLUME_USAGE_PCT}" \
    WITH_DISRUPTIONS="${WITH_DISRUPTIONS}" \
    OOM_EVENTS="${oom_events}" \
    python3 - "${JSON_LOG}" "${RECOVERY_LOG}" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone


def parse_ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def to_float(value, default=0.0):
    try:
        if value in (None, "", "null"):
            return default
        return float(value)
    except Exception:
        return default


def load_jsonl(path):
    if not path or not os.path.exists(path):
        return []
    items = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            items.append(json.loads(line))
    return items


def unique_exits(samples):
    values = set()
    for sample in samples:
        raw = sample.get("exited_containers") or ""
        for item in raw.split(","):
            item = item.strip()
            if item:
                values.add(item)
    return sorted(values)


def monotonic_heights(samples):
    previous = -1
    for sample in samples:
        current = int(to_float(sample.get("block_height"), 0))
        if current < previous:
            return False
        previous = current
    return True


def summarize_collection(samples, collection_name, id_key):
    first_items = {item.get(id_key): item for item in samples[0].get("disk", {}).get(collection_name, []) if item.get(id_key)}
    last_items = {item.get(id_key): item for item in samples[-1].get("disk", {}).get(collection_name, []) if item.get(id_key)}

    all_keys = sorted(set(first_items.keys()) | set(last_items.keys()))
    summaries = []

    duration_hours = max(
        (parse_ts(samples[-1]["ts"]) - parse_ts(samples[0]["ts"])).total_seconds() / 3600,
        1e-9,
    )

    for key in all_keys:
        first_item = first_items.get(key, {})
        last_item = last_items.get(key, {})
        max_use_pct = 0.0

        for sample in samples:
            for item in sample.get("disk", {}).get(collection_name, []):
                if item.get(id_key) == key:
                    max_use_pct = max(max_use_pct, to_float(item.get("fs_use_pct"), 0))

        start_bytes = to_float(first_item.get("bytes"), 0)
        end_bytes = to_float(last_item.get("bytes"), 0)
        growth_bytes = end_bytes - start_bytes
        growth_per_hour = growth_bytes / duration_hours if duration_hours else 0.0
        projection_30d = growth_per_hour * 24 * 30

        summary = {
            id_key: key,
            "label": last_item.get("label") or first_item.get("label") or key,
            "container": last_item.get("container") or first_item.get("container"),
            "path": last_item.get("path") or first_item.get("path"),
            "destination": last_item.get("destination") or first_item.get("destination"),
            "volume": last_item.get("volume") or first_item.get("volume"),
            "start_bytes": start_bytes,
            "end_bytes": end_bytes,
            "growth_bytes": growth_bytes,
            "growth_per_hour_bytes": growth_per_hour,
            "projection_30d_bytes": projection_30d,
            "fs_use_pct_max": max_use_pct,
        }
        summaries.append(summary)

    return summaries


samples = load_jsonl(sys.argv[1])
events = load_jsonl(sys.argv[2])

if not samples:
    print(json.dumps({"verdict": "FAIL", "failures": ["no samples captured"]}))
    sys.exit(0)

duration_hours = max(
    (parse_ts(samples[-1]["ts"]) - parse_ts(samples[0]["ts"])).total_seconds() / 3600,
    1e-9,
)

first = samples[0]
last = samples[-1]

node_growth_pct = 0.0
backend_growth_pct = 0.0

node_start = to_float(first.get("node_process_rss_bytes"), 0)
node_end = to_float(last.get("node_process_rss_bytes"), 0)
backend_start = to_float(first.get("backend_process_rss_bytes"), 0)
backend_end = to_float(last.get("backend_process_rss_bytes"), 0)

if node_start > 0:
    node_growth_pct = ((node_end - node_start) / node_start) * 100.0
if backend_start > 0:
    backend_growth_pct = ((backend_end - backend_start) / backend_start) * 100.0

tracked_paths = summarize_collection(samples, "tracked_paths", "label")
volumes = summarize_collection(samples, "volumes", "volume")

host_root_start = to_float(first.get("disk", {}).get("host_root", {}).get("used_bytes"), 0)
host_root_end = to_float(last.get("disk", {}).get("host_root", {}).get("used_bytes"), 0)
host_root_growth = host_root_end - host_root_start
host_root_max_use_pct = max(
    [to_float(sample.get("disk", {}).get("host_root", {}).get("use_pct"), 0) for sample in samples] or [0]
)
max_volume_use_pct = max([entry.get("fs_use_pct_max", 0) for entry in volumes] or [0])

failures = []
warnings = []

max_memory_growth_pct = float(os.environ.get("MAX_MEMORY_GROWTH_PCT", "20"))
min_peer_count = float(os.environ.get("MIN_PEER_COUNT", "0"))
max_latency_p95 = float(os.environ.get("MAX_API_LATENCY_P95_MS", "500"))
max_root_fs_growth = float(os.environ.get("MAX_ROOT_FS_GROWTH_BYTES", str(10 * 1024 * 1024 * 1024)))
max_volume_pct = float(os.environ.get("MAX_VOLUME_USAGE_PCT", "85"))
with_disruptions = os.environ.get("WITH_DISRUPTIONS", "0") == "1"
oom_events = [item for item in os.environ.get("OOM_EVENTS", "").split(",") if item]

if node_growth_pct > max_memory_growth_pct:
    failures.append(f"node RSS grew {node_growth_pct:.2f}% (limit {max_memory_growth_pct:.0f}%)")
if backend_growth_pct > max_memory_growth_pct:
    failures.append(f"backend RSS grew {backend_growth_pct:.2f}% (limit {max_memory_growth_pct:.0f}%)")
if not monotonic_heights(samples):
    failures.append("block height not monotonic")

height_start = int(to_float(first.get("block_height"), 0))
height_end = int(to_float(last.get("block_height"), 0))
height_delta = height_end - height_start
if height_delta <= 0:
    failures.append(f"block height did not advance (delta={height_delta})")

min_peers = min([to_float(sample.get("peer_count"), 0) for sample in samples] or [0])
if min_peers < min_peer_count:
    failures.append(f"peer count dropped below {int(min_peer_count)} (min observed={int(min_peers)})")

max_latency = max([to_float(sample.get("api_latency_p95_ms"), 0) for sample in samples] or [0])
if max_latency > max_latency_p95:
    failures.append(f"API latency p95 exceeded {max_latency_p95:.0f}ms (max={max_latency:.2f}ms)")

exited_containers = unique_exits(samples)
if exited_containers:
    failures.append("containers exited/restarted during run")

if host_root_growth > max_root_fs_growth:
    failures.append(
        f"root filesystem grew {host_root_growth:.0f} bytes (limit {max_root_fs_growth:.0f} bytes)"
    )

if max_volume_use_pct > max_volume_pct:
    failures.append(
        f"tracked volume filesystem usage exceeded {max_volume_pct:.0f}% (max={max_volume_use_pct:.2f}%)"
    )

if oom_events:
    failures.append(f"OOM kill(s) observed: {', '.join(sorted(oom_events))}")

for event in events:
    status = event.get("status")
    if status == "failed":
        failures.append(f"recovery event failed: {event.get('name')}")
    elif status == "skipped":
        reason = event.get("details", {}).get("reason", "no reason recorded")
        warnings.append(f"{event.get('name')} skipped: {reason}")

if with_disruptions and not events:
    failures.append("disruption mode enabled but no recovery events were recorded")

summary = {
    "samples": len(samples),
    "duration_hours": duration_hours,
    "height_start": height_start,
    "height_end": height_end,
    "height_delta": height_delta,
    "height_monotonic": monotonic_heights(samples),
    "node_rss_start": node_start,
    "node_rss_end": node_end,
    "node_growth_pct": node_growth_pct,
    "backend_rss_start": backend_start,
    "backend_rss_end": backend_end,
    "backend_growth_pct": backend_growth_pct,
    "min_peers": min_peers,
    "max_latency_p95_ms": max_latency,
    "exited_containers": exited_containers,
    "oom_events": oom_events,
    "disk": {
        "host_root_start_bytes": host_root_start,
        "host_root_end_bytes": host_root_end,
        "host_root_growth_bytes": host_root_growth,
        "host_root_use_pct_max": host_root_max_use_pct,
        "max_volume_use_pct": max_volume_use_pct,
        "tracked_paths": tracked_paths,
        "volumes": volumes,
    },
    "recovery_events": events,
    "warnings": warnings,
    "failures": failures,
    "verdict": "FAIL" if failures else "PASS",
}

print(json.dumps(summary))
PY
  )"

  verdict="$(echo "${summary_json}" | jq -r '.verdict')"

  {
    echo "# WRFCoin Sustained Operation Test — ${verdict}"
    echo
    echo "- **Started:** ${SCRIPT_START_ISO}"
    echo "- **Ended:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "- **Duration configured:** ${DURATION}"
    echo "- **Sample interval:** ${SAMPLE_INTERVAL}"
    echo "- **Load profile:** ${LOAD_PROFILE}"
    if [ "${LOAD_PROFILE}" = "flat" ]; then
      echo "- **Flat load cadence:** ${LOAD_INTERVAL_SECS}s per commit/reveal"
    else
      echo "- **Ramp profile:** 1 tx/min (0-6h), 5 tx/min (6-12h), 20 tx/min (12-36h), 1 tx/min (36-48h)"
    fi
    echo "- **Disruptions enabled:** $( [ "${WITH_DISRUPTIONS}" -eq 1 ] && echo yes || echo no )"
    echo "- **Samples captured:** $(echo "${summary_json}" | jq -r '.samples')"
    echo "- **JSON log:** \`${JSON_LOG}\`"
    echo "- **Load log:** \`${LOAD_LOG}\`"
    echo "- **Recovery log:** \`${RECOVERY_LOG}\`"
    if [ -f "${SNAPSHOT_METADATA_FILE}" ]; then
      echo "- **Grafana snapshot metadata:** \`${SNAPSHOT_METADATA_FILE}\`"
    fi
    echo
    echo "## Verdict: ${verdict}"
    echo
    if [ "$(echo "${summary_json}" | jq '.failures | length')" -gt 0 ]; then
      echo "**Failures:**"
      echo "${summary_json}" | jq -r '.failures[] | "- " + .'
      echo
    fi
    if [ "$(echo "${summary_json}" | jq '.warnings | length')" -gt 0 ]; then
      echo "**Warnings:**"
      echo "${summary_json}" | jq -r '.warnings[] | "- " + .'
      echo
    fi
    echo "## Grafana Snapshot"
    echo
    if [ -f "${SNAPSHOT_METADATA_FILE}" ]; then
      echo "- **Status:** $(jq -r '.status // "unknown"' "${SNAPSHOT_METADATA_FILE}")"
      echo "- **Message:** $(jq -r '.message // ""' "${SNAPSHOT_METADATA_FILE}")"
      if [ -n "$(jq -r '.url // empty' "${SNAPSHOT_METADATA_FILE}")" ]; then
        echo "- **Snapshot URL:** $(jq -r '.url' "${SNAPSHOT_METADATA_FILE}")"
      fi
      echo "- **Dashboard export JSON:** \`${SNAPSHOT_DASHBOARD_FILE}\`"
      echo "- **Snapshot request JSON:** \`${SNAPSHOT_REQUEST_FILE}\`"
      echo "- **Snapshot response JSON:** \`${SNAPSHOT_RESPONSE_FILE}\`"
    else
      echo "Grafana snapshot export was not attempted."
    fi
    echo
    echo "## Key metrics (baseline -> final)"
    echo
    echo "| Metric | Baseline | Final | Delta |"
    echo "|---|---|---|---|"
    echo "${summary_json}" | jq -r '
      "| block_height | \(.height_start) | \(.height_end) | \(.height_delta) |",
      "| node RSS (bytes) | \(.node_rss_start) | \(.node_rss_end) | \(.node_growth_pct | tostring + "%") |",
      "| backend RSS (bytes) | \(.backend_rss_start) | \(.backend_rss_end) | \(.backend_growth_pct | tostring + "%") |",
      "| host root used (bytes) | \(.disk.host_root_start_bytes) | \(.disk.host_root_end_bytes) | \(.disk.host_root_growth_bytes) |",
      "| min peer_count observed | - | - | \(.min_peers) |",
      "| max API latency p95 (ms) | - | - | \(.max_latency_p95_ms) |"
    '
    echo
    echo "## Disk growth by tracked path"
    echo
    echo "| Path | Start bytes | End bytes | Growth bytes | Bytes/hour | 30d projection | Max fs use % |"
    echo "|---|---|---|---|---|---|---|"
    echo "${summary_json}" | jq -r '
      .disk.tracked_paths[]
      | "| \(.label) | \(.start_bytes) | \(.end_bytes) | \(.growth_bytes) | \(.growth_per_hour_bytes) | \(.projection_30d_bytes) | \(.fs_use_pct_max) |"
    '
    echo
    echo "## Per-volume breakdown"
    echo
    echo "| Volume | Container | Start bytes | End bytes | Growth bytes | Bytes/hour | 30d projection | Max fs use % |"
    echo "|---|---|---|---|---|---|---|---|"
    echo "${summary_json}" | jq -r '
      .disk.volumes[]
      | "| \(.volume) | \(.container) | \(.start_bytes) | \(.end_bytes) | \(.growth_bytes) | \(.growth_per_hour_bytes) | \(.projection_30d_bytes) | \(.fs_use_pct_max) |"
    '
    echo
    echo "## Recovery events"
    echo
    if [ "$(echo "${summary_json}" | jq '.recovery_events | length')" -gt 0 ]; then
      echo "| Event | Status | Duration (s) | Notes |"
      echo "|---|---|---|---|"
      echo "${summary_json}" | jq -r '
        .recovery_events[]
        | "| \(.name) | \(.status) | \(.duration_secs) | "
          + (
              if .name == "node_restart" then
                "ready=" + ((.details.ready_wait_secs // 0) | tostring)
                + "s, height=" + ((.details.post_height // 0) | tostring)
                + ", mempool=" + ((.details.post_mempool // 0) | tostring)
                + ", postgres_ok=" + ((.details.postgres_ok // false) | tostring)
              elif .name == "weather_collector_restart" then
                "logs=" + (.details.log_status // .details.reason // "n/a")
                + ", height=" + ((.details.post_height // 0) | tostring)
                + ", mempool=" + ((.details.post_mempool // 0) | tostring)
              else
                (.details | tostring)
              end
            )
          + " |"
      '
    else
      echo "No recovery events were recorded."
    fi
    echo
    echo "## Thresholds"
    echo
    echo "- memory growth: < ${MAX_MEMORY_GROWTH_PCT}%"
    echo "- root filesystem growth: < ${MAX_ROOT_FS_GROWTH_BYTES} bytes"
    echo "- tracked volume filesystem usage: < ${MAX_VOLUME_USAGE_PCT}%"
    echo "- min peer count: ${MIN_PEER_COUNT}"
    echo "- max API latency p95: ${MAX_API_LATENCY_P95_MS}ms"
    echo "- no OOM kills, no unexpected container exits, monotonic height"
    echo
    echo "## Raw verdict JSON"
    echo
    echo '```json'
    echo "${summary_json}" | jq .
    echo '```'
  } > "${REPORT}"

  log "report written: ${REPORT}"
  log "verdict: ${verdict}"
  if [ "${verdict}" = "FAIL" ]; then
    echo "${summary_json}" | jq -r '.failures[] | "  - " + .' | while read -r line; do
      err "${line}"
    done
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------
main() {
  log "=== WRFCoin sustained operation test (issue core4#758) ==="
  log "duration=${DURATION} interval=${SAMPLE_INTERVAL} load_profile=${LOAD_PROFILE} flat_load=${LOAD_INTERVAL_SECS}s disruptions=${WITH_DISRUPTIONS}"
  log "output directory: ${OUT_DIR}"

  if ! validate_config; then
    exit 1
  fi

  SCRIPT_START_EPOCH="$(date +%s)"
  SCRIPT_START_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  export SCRIPT_START_EPOCH SCRIPT_START_ISO

  if ! preflight; then
    err "aborting due to pre-flight failures"
    exit 1
  fi

  log "=== Baseline capture (t=0) ==="
  capture_metrics "baseline" >/dev/null
  log "baseline written to ${JSON_LOG}"

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "dry-run: pre-flight + baseline succeeded; exiting before long-running loop"
    write_snapshot_metadata "skipped" "" "Dry-run mode does not export Grafana snapshots"
    evaluate_and_report || true
    exit 0
  fi

  trap 'stop_load_generator; exit 130' INT TERM
  trap 'stop_load_generator' EXIT

  spawn_load_generator

  local duration_secs interval_secs end_epoch next_sample_epoch
  local node_restart_done collector_restart_done
  duration_secs="$(parse_duration "${DURATION}")"
  interval_secs="$(parse_duration "${SAMPLE_INTERVAL}")"
  end_epoch=$((SCRIPT_START_EPOCH + duration_secs))
  next_sample_epoch=$((SCRIPT_START_EPOCH + interval_secs))
  node_restart_done=0
  collector_restart_done=0

  log "=== Sampling loop (every ${SAMPLE_INTERVAL} until $(date -u -d "@${end_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')) ==="

  while :; do
    local now_epoch next_wake sleep_for elapsed tag
    now_epoch="$(date +%s)"
    if [ "${now_epoch}" -ge "${end_epoch}" ]; then
      break
    fi

    next_wake="${end_epoch}"
    if [ "${next_sample_epoch}" -lt "${next_wake}" ]; then
      next_wake="${next_sample_epoch}"
    fi
    if [ "${WITH_DISRUPTIONS}" -eq 1 ] && [ "${node_restart_done}" -eq 0 ] && [ $((SCRIPT_START_EPOCH + NODE_RESTART_AT_SECS)) -lt "${next_wake}" ]; then
      next_wake=$((SCRIPT_START_EPOCH + NODE_RESTART_AT_SECS))
    fi
    if [ "${WITH_DISRUPTIONS}" -eq 1 ] && [ "${collector_restart_done}" -eq 0 ] && [ $((SCRIPT_START_EPOCH + COLLECTOR_RESTART_AT_SECS)) -lt "${next_wake}" ]; then
      next_wake=$((SCRIPT_START_EPOCH + COLLECTOR_RESTART_AT_SECS))
    fi

    now_epoch="$(date +%s)"
    if [ "${next_wake}" -gt "${now_epoch}" ]; then
      sleep_for=$((next_wake - now_epoch))
      [ "${sleep_for}" -lt 1 ] && sleep_for=1
      sleep "${sleep_for}"
    fi

    now_epoch="$(date +%s)"

    if [ "${WITH_DISRUPTIONS}" -eq 1 ] && [ "${node_restart_done}" -eq 0 ] && [ "${now_epoch}" -ge $((SCRIPT_START_EPOCH + NODE_RESTART_AT_SECS)) ]; then
      perform_node_restart_check || true
      node_restart_done=1
    fi

    if [ "${WITH_DISRUPTIONS}" -eq 1 ] && [ "${collector_restart_done}" -eq 0 ] && [ "${now_epoch}" -ge $((SCRIPT_START_EPOCH + COLLECTOR_RESTART_AT_SECS)) ]; then
      perform_collector_restart_check || true
      collector_restart_done=1
    fi

    if [ "${now_epoch}" -ge "${next_sample_epoch}" ] && [ "${now_epoch}" -lt "${end_epoch}" ]; then
      elapsed=$((now_epoch - SCRIPT_START_EPOCH))
      tag="$(printf 't+%ds' "${elapsed}")"
      capture_metrics "${tag}" >/dev/null
      log "sampled ${tag}"
      next_sample_epoch=$((now_epoch + interval_secs))
    fi
  done

  log "=== Final capture ==="
  capture_metrics "final" >/dev/null
  export_grafana_snapshot || true

  stop_load_generator
  trap - EXIT

  if evaluate_and_report; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
