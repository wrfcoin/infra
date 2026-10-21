#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${WRFCOIN_STACK_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BACKEND_ROOT="$ROOT/backend"
CORE4_ROOT="$ROOT/core4"
COMPUTE_AGENT_DIR="$ROOT/infra/infra/compute-agent"
CLI_DIR="$CORE4_ROOT/tools/cli/WrfcoinCLI"
# docker-compose.dev.yml lives in the infra repo; root copy is a convenience duplicate.
# Default relaunch uses the local dev data-services compose; pass --testnet for the operator stack.
COMPOSE_FILE="${WRFCOIN_COMPOSE_FILE:-$SCRIPT_DIR/../docker-compose.dev.yml}"

# Auto-source env files so REDIS_PASSWORD / POSTGRES_DEV_PASSWORD are available
# to docker-compose without requiring manual `export` before each launch.
# Explicit env vars already in the shell take precedence.
if [ -z "${REDIS_PASSWORD:-}" ] || [ -z "${JWT_SECRET:-}" ]; then
  # Source both env files so critical secrets land in the child env.
  # backend/.env is loaded last so it wins on conflict (has the full set).
  for _env_candidate in "$CORE4_ROOT/.env" "$BACKEND_ROOT/.env"; do
    if [ -f "$_env_candidate" ]; then
      set -a
      # shellcheck disable=SC1090
      source "$_env_candidate"
      set +a
    fi
  done
  unset _env_candidate
fi
CONTRACT_GATE_SCRIPT="$SCRIPT_DIR/launch-critical-contract-gate.cjs"
LOG_DIR="${WRFCOIN_RELAUNCH_LOG_DIR:-/tmp/wrfcoin-relaunch}"
SMOKE_LOG_DIR="$LOG_DIR/smoke"
BACKUP_DIR="$LOG_DIR/backups/$(date +%Y%m%d-%H%M%S)"
JWT_SECRET_PATH="${WRFCOIN_JWT_SECRET_PATH:-$LOG_DIR/jwt-secret.local}"
COMPUTE_WALLET_PATH="${WRFCOIN_COMPUTE_WALLET_PATH:-$COMPUTE_AGENT_DIR/.keys/wallet.json}"
COMPUTE_WALLET_ADDRESS="${WRFCOIN_COMPUTE_WALLET_ADDRESS:-0x1111111111111111111111111111111111111111}"
COMPUTE_NODE_ID="${WRFCOIN_COMPUTE_NODE_ID:-compute-local}"
FAST_MODE="${WRFCOIN_RELAUNCH_FAST:-0}"
TESTNET_MODE=0
TESTNET_COMPOSE_FILE="$SCRIPT_DIR/../testnet/docker-compose.testnet.yml"
RUN_SMOKE="${WRFCOIN_RELAUNCH_SMOKE:-1}"
RUN_CONTRACT_GATE="${WRFCOIN_RELAUNCH_CONTRACT_GATE:-1}"
USE_CORE4_FIXTURE_STUB="${WRFCOIN_RELAUNCH_CORE4_FIXTURE_STUB:-0}"
CONTRACT_CORE4_STUB_PORT="${WRFCOIN_CONTRACT_CORE4_STUB_PORT:-18556}"
CONTRACT_CORE4_STUB_URL="http://127.0.0.1:${CONTRACT_CORE4_STUB_PORT}"
CONTRACT_CORE4_LIVE_URL="http://127.0.0.1:8556"
CONTRACT_GATE_CORE4_BASE_URL="$CONTRACT_CORE4_LIVE_URL"
if [ "$USE_CORE4_FIXTURE_STUB" = "1" ]; then
  CONTRACT_GATE_CORE4_BASE_URL="$CONTRACT_CORE4_STUB_URL"
fi
JSON_REPORT="$LOG_DIR/relaunch-report.json"

mkdir -p "$LOG_DIR"
mkdir -p "$SMOKE_LOG_DIR"

SERVICE_PORTS=(5000 3001 8556 18556 3000 4000 8000 4001 6003 3333)
PREFLIGHT_ENV_LINES=""
PREFLIGHT_DEP_LINES=""
PREFLIGHT_PORT_LINES=""
PREFLIGHT_CONTAINER_LINES=""
PREFLIGHT_LOG_LINES=""
CLEANUP_LINES=""
COMPUTE_AGENT_EXPECTED=0

usage() {
  cat <<'EOF'
Usage: relaunch-testnet-stack.sh [--fast] [--testnet] [--skip-smoke|--with-smoke] [--full] [--clean]

Options:
  --fast        Faster startup profile (shorter readiness timeouts).
                Unless explicitly overridden, smoke checks are skipped.
  --testnet     Use testnet compose file and container-based service startup
                instead of bare-process dev mode.
  --full        Full startup profile (default timeouts).
  --skip-smoke  Skip CLI smoke checks.
  --with-smoke  Force CLI smoke checks.
  --clean       Run docker-compose down before starting.
  -h, --help    Show this help.

Environment:
  WRFCOIN_RELAUNCH_FAST=1      Same as --fast
  WRFCOIN_RELAUNCH_SMOKE=0|1   Disable/enable smoke checks
  WRFCOIN_RELAUNCH_CONTRACT_GATE=0|1  Disable/enable launch contract suite
  WRFCOIN_RELAUNCH_CORE4_FIXTURE_STUB=0|1  Use the Core4 fixture stub for contract-gate websocket validation
  WRFCOIN_JWT_SECRET_PATH=...  File path used to persist local JWT secret
EOF
}

CLEAN_MODE=0
SMOKE_FLAG_EXPLICIT=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    --testnet) TESTNET_MODE=1 ;;
    --full) FAST_MODE=0 ;;
    --skip-smoke) RUN_SMOKE=0; SMOKE_FLAG_EXPLICIT=1 ;;
    --with-smoke) RUN_SMOKE=1; SMOKE_FLAG_EXPLICIT=1 ;;
    --clean) CLEAN_MODE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $arg"; usage; exit 1 ;;
  esac
done

if [ "$TESTNET_MODE" = "1" ]; then
  COMPOSE_FILE="$TESTNET_COMPOSE_FILE"
fi

if [ "$FAST_MODE" = "1" ] && [ "$SMOKE_FLAG_EXPLICIT" = "0" ] && [ -z "${WRFCOIN_RELAUNCH_SMOKE:-}" ]; then
  RUN_SMOKE=0
fi

if [ "$USE_CORE4_FIXTURE_STUB" != "0" ] && [ "$USE_CORE4_FIXTURE_STUB" != "1" ]; then
  echo "ERROR: WRFCOIN_RELAUNCH_CORE4_FIXTURE_STUB must be 0 or 1."
  exit 1
fi

append_report_line() {
  local var_name="$1"
  local line="$2"
  local current="${!var_name:-}"

  if [ -n "$current" ]; then
    printf -v "$var_name" '%s\n%s' "$current" "$line"
  else
    printf -v "$var_name" '%s' "$line"
  fi
}

json_array_from_lines() {
  local lines="${1:-}"

  if [ -z "$lines" ]; then
    printf '[]'
    return 0
  fi

  printf '%s\n' "$lines" | sed '/^$/d' | jq -R . | jq -s .
}

print_report_block() {
  local title="$1"
  local lines="${2:-}"

  echo "==> ${title}"
  if [ -z "$lines" ]; then
    echo "  (none)"
    return 0
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "  - $line"
  done <<< "$lines"
}

record_cleanup_action() {
  append_report_line CLEANUP_LINES "$1"
}

resolve_operator_token_source() {
  if [ -n "${WRFCOIN_OPERATOR_TOKEN:-}" ]; then
    printf '%s' 'env:WRFCOIN_OPERATOR_TOKEN'
    return
  fi

  if [ -f "$ROOT/core4/.env" ] && awk -F= '/^WRFCOIN_OPERATOR_TOKEN=/{found=1} END{exit found?0:1}' "$ROOT/core4/.env"; then
    printf '%s' 'file:core4/.env'
    return
  fi

  if [ -f "$ROOT/backend/.env" ] && awk -F= '/^WRFCOIN_OPERATOR_TOKEN=/{found=1} END{exit found?0:1}' "$ROOT/backend/.env"; then
    printf '%s' 'file:backend/.env'
    return
  fi

  printf '%s' 'missing'
}

resolve_jwt_secret_source() {
  if [ -n "${JWT_SECRET:-}" ]; then
    printf '%s' 'env:JWT_SECRET'
    return
  fi

  if [ -f "$ROOT/core4/.env" ] && awk -F= '/^JWT_SECRET=/{found=1} END{exit found?0:1}' "$ROOT/core4/.env"; then
    printf '%s' 'file:core4/.env'
    return
  fi

  if [ -f "$ROOT/backend/.env" ] && awk -F= '/^JWT_SECRET=/{found=1} END{exit found?0:1}' "$ROOT/backend/.env"; then
    printf '%s' 'file:backend/.env'
    return
  fi

  if [ -f "$JWT_SECRET_PATH" ] && [ -s "$JWT_SECRET_PATH" ]; then
    printf '%s' "file:${JWT_SECRET_PATH}"
    return
  fi

  printf '%s' 'fallback:operator-token'
}

resolve_database_url_source() {
  if [ -n "${DATABASE_URL:-}" ]; then
    printf '%s' 'env:DATABASE_URL'
    return
  fi

  if [ -f "$ROOT/backend/.env" ] && awk -F= '/^DATABASE_URL=/{found=1} END{exit found?0:1}' "$ROOT/backend/.env"; then
    printf '%s' 'file:backend/.env'
    return
  fi

  if [ -f "$ROOT/core4/.env" ] && awk -F= '/^DATABASE_URL=/{found=1} END{exit found?0:1}' "$ROOT/core4/.env"; then
    printf '%s' 'file:core4/.env'
    return
  fi

  printf '%s' 'default:docker-compose.dev.yml'
}

collect_preflight_report() {
  local cmd resolved

  append_report_line PREFLIGHT_ENV_LINES "root directory: $ROOT ($( [ -d "$ROOT" ] && printf present || printf missing ))"
  append_report_line PREFLIGHT_ENV_LINES "compose file: $COMPOSE_FILE ($( [ -f "$COMPOSE_FILE" ] && printf present || printf missing ))"
  append_report_line PREFLIGHT_ENV_LINES "backend .env: $ROOT/backend/.env ($( [ -f "$ROOT/backend/.env" ] && printf present || printf missing ))"
  append_report_line PREFLIGHT_ENV_LINES "core4 .env: $ROOT/core4/.env ($( [ -f "$ROOT/core4/.env" ] && printf present || printf missing ))"
  append_report_line PREFLIGHT_ENV_LINES "compute wallet path: $COMPUTE_WALLET_PATH ($( [ -s "$COMPUTE_WALLET_PATH" ] && printf present || printf missing ))"
  append_report_line PREFLIGHT_ENV_LINES "operator token source: $(resolve_operator_token_source)"
  append_report_line PREFLIGHT_ENV_LINES "jwt secret source: $(resolve_jwt_secret_source)"
  append_report_line PREFLIGHT_ENV_LINES "database url source: $(resolve_database_url_source)"
  append_report_line PREFLIGHT_ENV_LINES "contract gate enabled: $RUN_CONTRACT_GATE"
  append_report_line PREFLIGHT_ENV_LINES "smoke enabled: $RUN_SMOKE"
  append_report_line PREFLIGHT_ENV_LINES "core4 fixture stub enabled: $USE_CORE4_FIXTURE_STUB"
  append_report_line PREFLIGHT_ENV_LINES "contract gate core4 base url: $CONTRACT_GATE_CORE4_BASE_URL"

  for cmd in docker docker-compose npm node cargo curl awk jq; do
    resolved="$(command -v "$cmd" 2>/dev/null || true)"
    if [ -n "$resolved" ]; then
      append_report_line PREFLIGHT_DEP_LINES "command $cmd: $resolved"
    else
      append_report_line PREFLIGHT_DEP_LINES "command $cmd: missing"
    fi
  done
  # lsof is optional on Windows; netstat is used as fallback
  resolved="$(command -v lsof 2>/dev/null || true)"
  if [ -n "$resolved" ]; then
    append_report_line PREFLIGHT_DEP_LINES "command lsof: $resolved"
  else
    append_report_line PREFLIGHT_DEP_LINES "command lsof: missing (using netstat fallback)"
  fi
  append_report_line PREFLIGHT_DEP_LINES "backend tsx: $( [ -x "$BACKEND_ROOT/node_modules/.bin/tsx" ] && printf ready || printf missing )"
  append_report_line PREFLIGHT_DEP_LINES "frontend vite: $( [ -x "$ROOT/frontend/node_modules/.bin/vite" ] && printf ready || printf missing )"
  append_report_line PREFLIGHT_DEP_LINES "compute-agent tsx: $( [ -x "$COMPUTE_AGENT_DIR/node_modules/.bin/tsx" ] && printf ready || printf missing )"
  append_report_line PREFLIGHT_DEP_LINES "cli dir: $CLI_DIR ($( [ -d "$CLI_DIR" ] && printf present || printf missing ))"

  local port pids
  for port in "${SERVICE_PORTS[@]}"; do
    if command -v lsof >/dev/null 2>&1; then
      pids=$(lsof -ti ":${port}" -sTCP:LISTEN 2>/dev/null || true)
    else
      pids=$(netstat -ano 2>/dev/null | awk "/[: ]${port} .*LISTENING/{print \$NF}" | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
    fi
    if [ -n "$pids" ]; then
      append_report_line PREFLIGHT_PORT_LINES ":${port} -> listeners ${pids}"
    else
      append_report_line PREFLIGHT_PORT_LINES ":${port} -> free"
    fi
  done

  local container_name status
  while IFS= read -r container_name; do
    [ -n "$container_name" ] || continue
    status=$(docker ps -a --filter "name=^/${container_name}$" --format '{{.Status}}' 2>/dev/null || true)
    if [ -n "$status" ]; then
      append_report_line PREFLIGHT_CONTAINER_LINES "${container_name} -> ${status}"
    else
      append_report_line PREFLIGHT_CONTAINER_LINES "${container_name} -> absent"
    fi
  done < <(list_compose_container_names)

  local log_count smoke_count
  log_count=$(find "$LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')
  smoke_count=$(find "$SMOKE_LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')
  append_report_line PREFLIGHT_LOG_LINES "log dir: $LOG_DIR"
  append_report_line PREFLIGHT_LOG_LINES "top-level files before backup: ${log_count}"
  append_report_line PREFLIGHT_LOG_LINES "smoke log files before backup: ${smoke_count}"
}

check_deps() {
  echo "==> Checking dependencies"
  local missing=()
  for cmd in docker docker-compose npm node cargo curl awk jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required dependencies: ${missing[*]}"
    exit 1
  fi
}

check_env() {
  echo "==> Checking environment"
  local dirs=("$ROOT" "$BACKEND_ROOT" "$CORE4_ROOT" "$COMPUTE_AGENT_DIR")
  for d in "${dirs[@]}"; do
    if [ ! -d "$d" ]; then
      echo "ERROR: Required directory not found: $d"
      exit 1
    fi
  done

  if [ ! -f "$COMPOSE_FILE" ]; then
    echo "ERROR: compose file not found: $COMPOSE_FILE"
    exit 1
  fi

  if [ "$RUN_CONTRACT_GATE" = "1" ] && [ ! -f "$CONTRACT_GATE_SCRIPT" ]; then
    echo "ERROR: launch-critical contract gate not found: $CONTRACT_GATE_SCRIPT"
    exit 1
  fi
}

backup_logs() {
  local top_level_files smoke_files
  top_level_files=$(find "$LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')
  smoke_files=$(find "$SMOKE_LOG_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')

  if [ -d "$LOG_DIR" ] && find "$LOG_DIR" -maxdepth 1 -type f -print -quit | grep -q .; then
    echo "==> Backing up old logs to $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    find "$LOG_DIR" -maxdepth 1 -type f -exec mv {} "$BACKUP_DIR/" \;
    if [ -d "$SMOKE_LOG_DIR" ]; then
      mv "$SMOKE_LOG_DIR" "$BACKUP_DIR/smoke"
      mkdir -p "$SMOKE_LOG_DIR"
    fi
    record_cleanup_action "backed up ${top_level_files} top-level log files and ${smoke_files} smoke log files to ${BACKUP_DIR}"
  else
    record_cleanup_action "log backup skipped; no prior log artifacts detected"
  fi
}

stop_services() {
  echo "==> Stopping existing services"
  record_cleanup_action "begin service and container cleanup"
  for pid_file in "$LOG_DIR"/*.pid; do
    if [ -f "$pid_file" ]; then
      local pid
      pid=$(cat "$pid_file")
      if kill -0 "$pid" 2>/dev/null; then
        echo "Stopping service with PID $pid ($(basename "$pid_file" .pid))"
        kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
        record_cleanup_action "stopped pid $(basename "$pid_file") -> ${pid}"
      else
        record_cleanup_action "removed stale pid file $(basename "$pid_file") -> ${pid}"
      fi
      rm -f "$pid_file"
    fi
  done

  for port in "${SERVICE_PORTS[@]}"; do
    stop_port "$port"
  done

  echo "==> Resetting Docker infra"
  teardown_docker_infra
  remove_named_compose_containers

  if [ "$CLEAN_MODE" = "1" ]; then
    echo "==> Clean mode requested; removing dev-stack volumes"
    if cd "$ROOT" && docker-compose -f "$COMPOSE_FILE" down --volumes --remove-orphans >/dev/null 2>&1; then
      :
    fi
    record_cleanup_action "clean mode requested; compose volumes removed"
  fi

  if ! verify_cleanup_state; then
    print_report_block "Cleanup Summary" "$CLEANUP_LINES"
    echo "ERROR: cleanup left reused-host state behind"
    exit 1
  fi

  print_report_block "Cleanup Summary" "$CLEANUP_LINES"
}

list_compose_container_names() {
  awk '
    /^[[:space:]]*container_name:[[:space:]]*/ {
      value=$2
      gsub(/["'\''"]/, "", value)
      print value
    }
  ' "$COMPOSE_FILE"
}

get_container_running_state() {
  local container_name="$1"
  docker inspect -f '{{if .State.Running}}running{{else}}stopped{{end}}' "$container_name" 2>/dev/null || printf 'missing'
}

get_container_health_state() {
  local container_name="$1"
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_name" 2>/dev/null || printf 'missing'
}

describe_container_state() {
  local container_name="$1"
  local running_state health_state
  running_state="$(get_container_running_state "$container_name")"
  health_state="$(get_container_health_state "$container_name")"
  printf 'running=%s health=%s' "$running_state" "$health_state"
}

print_container_diagnostic() {
  local label="$1"
  local container_name="$2"

  echo "${label} diagnostic ${container_name}: $(describe_container_state "$container_name")"
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
    echo "--- Last 10 lines of docker logs for ${container_name} ---"
    docker logs --tail 10 "$container_name" 2>&1 || true
  fi
}

wait_container_healthy() {
  local label="$1"
  local container_name="$2"
  local timeout_secs="$3"

  local start now running_state health_state
  start=$(date +%s)

  while true; do
    running_state="$(get_container_running_state "$container_name")"
    health_state="$(get_container_health_state "$container_name")"

    if [ "$running_state" = "running" ] && [ "$health_state" = "healthy" ]; then
      echo "${label}: healthy"
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_secs" ]; then
      echo "${label}: TIMEOUT (running=${running_state} health=${health_state})"
      print_container_diagnostic "$label" "$container_name"
      return 1
    fi

    sleep 1
  done
}

teardown_docker_infra() {
  if cd "$ROOT" && docker-compose -f "$COMPOSE_FILE" down --remove-orphans >/dev/null 2>&1; then
    :
  fi
  record_cleanup_action "docker-compose down --remove-orphans issued for ${COMPOSE_FILE}"
}

remove_named_compose_containers() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
      echo "Removing existing Docker container: $name"
      docker rm -f "$name" >/dev/null
      record_cleanup_action "removed named compose container ${name}"
    else
      record_cleanup_action "named compose container ${name} already absent"
    fi
  done < <(list_compose_container_names)
}

verify_cleanup_state() {
  local failed=0
  local port pids container_name

  for port in "${SERVICE_PORTS[@]}"; do
    if command -v lsof >/dev/null 2>&1; then
      pids=$(lsof -ti ":${port}" -sTCP:LISTEN 2>/dev/null || true)
    else
      pids=$(netstat -ano 2>/dev/null | awk "/[: ]${port} .*LISTENING/{print \$NF}" | sort -u | tr '\n' ' ' | sed 's/ *$//' || true)
    fi
    if [ -n "$pids" ]; then
      record_cleanup_action "cleanup failure: port :${port} still has listeners ${pids}"
      failed=1
    else
      record_cleanup_action "cleanup verified: port :${port} is clear"
    fi
  done

  while IFS= read -r container_name; do
    [ -n "$container_name" ] || continue
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$container_name"; then
      record_cleanup_action "cleanup failure: container ${container_name} still exists"
      failed=1
    else
      record_cleanup_action "cleanup verified: container ${container_name} absent"
    fi
  done < <(list_compose_container_names)

  [ "$failed" -eq 0 ]
}

_port_pids() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti ":${port}" -sTCP:LISTEN 2>/dev/null || true
  else
    netstat -ano 2>/dev/null | awk "/[: ]${port} .*LISTENING/{print \$NF}" | sort -u | tr '\n' ' ' | sed 's/ *$//' || true
  fi
}

_kill_pids() {
  local pids="$1"
  local force="${2:-}"
  if command -v lsof >/dev/null 2>&1; then
    # Unix: use kill
    if [ -n "$force" ]; then
      # shellcheck disable=SC2086
      kill -9 ${pids} 2>/dev/null || true
    else
      # shellcheck disable=SC2086
      kill ${pids} 2>/dev/null || true
    fi
  else
    # Windows: use taskkill
    for pid in ${pids}; do
      if [ -n "$force" ]; then
        taskkill //F //PID "$pid" >/dev/null 2>&1 || true
      else
        taskkill //PID "$pid" >/dev/null 2>&1 || true
      fi
    done
  fi
}

stop_port() {
  local port="$1"
  local pids
  pids=$(_port_pids "$port")
  if [ -z "$pids" ]; then
    record_cleanup_action "port :${port} already clear"
    return 0
  fi

  echo "Stopping listeners on :${port} -> ${pids}"
  record_cleanup_action "port :${port} had listeners ${pids}"
  _kill_pids "$pids"
  sleep 1

  local still
  still=$(_port_pids "$port")
  if [ -n "$still" ]; then
    echo "Force-stopping listeners on :${port} -> ${still}"
    record_cleanup_action "port :${port} required force stop for ${still}"
    _kill_pids "$still" force
  fi
}

resolve_operator_token() {
  if [ -n "${WRFCOIN_OPERATOR_TOKEN:-}" ]; then
    printf '%s' "$WRFCOIN_OPERATOR_TOKEN"
    return
  fi

  local core4_env backend_env token
  core4_env="$ROOT/core4/.env"
  backend_env="$ROOT/backend/.env"

  if [ -f "$core4_env" ]; then
    token=$(awk -F= '/^WRFCOIN_OPERATOR_TOKEN=/{v=$2} END{print v}' "$core4_env")
    if [ -n "$token" ]; then
      printf '%s' "$token"
      return
    fi
  fi

  if [ -f "$backend_env" ]; then
    token=$(awk -F= '/^WRFCOIN_OPERATOR_TOKEN=/{v=$2} END{print v}' "$backend_env")
    if [ -n "$token" ]; then
      printf '%s' "$token"
      return
    fi
  fi

  printf ''
}

resolve_jwt_secret() {
  if [ -n "${JWT_SECRET:-}" ]; then
    printf '%s' "$JWT_SECRET"
    return
  fi

  local core4_env backend_env secret
  core4_env="$ROOT/core4/.env"
  backend_env="$ROOT/backend/.env"

  if [ -f "$core4_env" ]; then
    secret=$(awk -F= '/^JWT_SECRET=/{v=$2} END{print v}' "$core4_env")
    if [ -n "$secret" ]; then
      printf '%s' "$secret"
      return
    fi
  fi

  if [ -f "$backend_env" ]; then
    secret=$(awk -F= '/^JWT_SECRET=/{v=$2} END{print v}' "$backend_env")
    if [ -n "$secret" ]; then
      printf '%s' "$secret"
      return
    fi
  fi

  if [ -f "$JWT_SECRET_PATH" ]; then
    secret=$(tr -d '\r\n' < "$JWT_SECRET_PATH")
    if [ -n "$secret" ]; then
      printf '%s' "$secret"
      return
    fi
  fi

  # Deterministic local fallback: use existing validated operator token.
  printf '%s' "$WRFCOIN_OPERATOR_TOKEN"
}

resolve_database_url() {
  if [ -n "${DATABASE_URL:-}" ]; then
    printf '%s' "$DATABASE_URL"
    return
  fi

  local core4_env backend_env db_url postgres_dev_password
  core4_env="$ROOT/core4/.env"
  backend_env="$ROOT/backend/.env"

  if [ -f "$backend_env" ]; then
    db_url=$(awk -F= '/^DATABASE_URL=/{v=$2} END{print v}' "$backend_env")
    if [ -n "$db_url" ]; then
      printf '%s' "$db_url"
      return
    fi
  fi

  if [ -f "$core4_env" ]; then
    db_url=$(awk -F= '/^DATABASE_URL=/{v=$2} END{print v}' "$core4_env")
    if [ -n "$db_url" ]; then
      printf '%s' "$db_url"
      return
    fi
  fi

  postgres_dev_password="${POSTGRES_DEV_PASSWORD:-}"
  if [ -z "$postgres_dev_password" ] && [ -f "$backend_env" ]; then
    postgres_dev_password=$(awk -F= '/^POSTGRES_DEV_PASSWORD=/{v=$2} END{print v}' "$backend_env")
  fi
  if [ -z "$postgres_dev_password" ] && [ -f "$core4_env" ]; then
    postgres_dev_password=$(awk -F= '/^POSTGRES_DEV_PASSWORD=/{v=$2} END{print v}' "$core4_env")
  fi

  if [ -n "$postgres_dev_password" ]; then
    printf 'postgresql://wrfcoin:%s@127.0.0.1:5432/wrfcoin' "$postgres_dev_password"
    return
  fi

  echo "ERROR: DATABASE_URL is unset and POSTGRES_DEV_PASSWORD could not be derived for local relaunch." >&2
  return 1
}

wait_http() {
  local label="$1"
  local url="$2"
  local timeout_secs="$3"

  local start now code
  start=$(date +%s)

  while true; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      echo "${label}: ${code}"
      return 0
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_secs" ]; then
      echo "${label}: TIMEOUT"
      local log_file="$LOG_DIR/${label}.log"
      if [ -f "$log_file" ]; then
        echo "--- Last 10 lines of $log_file ---"
        tail -n 10 "$log_file"
      fi
      return 1
    fi

    sleep 1
  done
}

# backend#1234: /health dependency detail and /metrics need an operator/reader
# bearer. The token goes to curl on stdin (-H @-) so it never shows in argv.
curl_with_operator_bearer() {
  printf 'Authorization: Bearer %s\n' "${WRFCOIN_OPERATOR_TOKEN:-}" | curl -H @- "$@"
}

print_main_api_health_diagnostic() {
  local body
  body=$(curl_with_operator_bearer -s "http://localhost:4001/health" || true)

  if [ -n "$body" ]; then
    echo "main-api diagnostic /health: $body"
    return
  fi

  echo "main-api diagnostic /health: UNREACHABLE"
}

wait_main_api_ready() {
  local timeout_secs="$1"

  wait_http "main-api" "http://localhost:4001/ready" "$timeout_secs" || {
    print_main_api_health_diagnostic
    return 1
  }
}

print_compute_contribution_health_diagnostic() {
  local body
  body=$(curl -s "http://localhost:6003/health" || true)

  if [ -n "$body" ]; then
    echo "compute-contribution diagnostic /health: $body"
    return
  fi

  echo "compute-contribution diagnostic /health: UNREACHABLE"
}

wait_compute_contribution_ready() {
  local timeout_secs="$1"

  wait_http "compute-contribution" "http://localhost:6003/ready" "$timeout_secs" || {
    print_compute_contribution_health_diagnostic
    return 1
  }
}

wait_prometheus_ready() {
  local timeout_secs="$1"
  # Skip if prometheus container is not running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wrfcoin-prometheus"; then
    echo "prometheus: skipped (not in compose)"
    return 0
  fi
  wait_http "prometheus" "http://localhost:9090/-/ready" "$timeout_secs" || {
    print_container_diagnostic "prometheus" "wrfcoin-prometheus"
    return 1
  }
}

wait_grafana_ready() {
  local timeout_secs="$1"
  # Skip if grafana container is not running
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "wrfcoin-grafana"; then
    echo "grafana: skipped (not in compose)"
    return 0
  fi
  wait_http "grafana" "http://localhost:3100/api/health" "$timeout_secs" || {
    print_container_diagnostic "grafana" "wrfcoin-grafana"
    return 1
  }
}

wait_docker_infra_ready() {
  local stateful_timeout_secs="$1"
  local monitoring_timeout_secs="$2"

  echo "==> Waiting for docker infra readiness"
  wait_container_healthy "postgres" "wrfcoin-postgres" "$stateful_timeout_secs" || return 1
  wait_container_healthy "redis" "wrfcoin-redis" "$stateful_timeout_secs" || return 1
  wait_prometheus_ready "$monitoring_timeout_secs" || return 1
  wait_grafana_ready "$monitoring_timeout_secs" || return 1
}

wait_db_migrate() {
  local timeout_secs="$1"
  local container_name
  container_name="wrfcoin-testnet-db-migrate"
  local start now exit_code status
  start=$(date +%s)

  echo "==> Waiting for db-migrate to complete"
  while true; do
    status=$(docker inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null || echo "missing")
    if [ "$status" = "exited" ]; then
      exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$container_name" 2>/dev/null || echo "-1")
      if [ "$exit_code" = "0" ]; then
        echo "db-migrate: completed successfully"
        return 0
      else
        echo "db-migrate: FAILED (exit code $exit_code)"
        docker logs --tail 20 "$container_name" 2>&1 || true
        return 1
      fi
    fi

    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout_secs" ]; then
      echo "db-migrate: TIMEOUT (status=${status})"
      docker logs --tail 20 "$container_name" 2>&1 || true
      return 1
    fi

    sleep 2
  done
}

ensure_compute_wallet() {
  local wallet_dir
  wallet_dir=$(dirname "$COMPUTE_WALLET_PATH")
  mkdir -p "$wallet_dir"

  if [ -s "$COMPUTE_WALLET_PATH" ]; then
    return 0
  fi

  echo "==> Generating compute-agent wallet key at ${COMPUTE_WALLET_PATH}"
  (
    cd "$COMPUTE_AGENT_DIR"
    node scripts/generate-wallet.mjs "$COMPUTE_WALLET_PATH"
  )
}

ensure_compute_agent_deps() {
  if [ -x "$COMPUTE_AGENT_DIR/node_modules/.bin/tsx" ]; then
    return 0
  fi

  echo "==> Installing compute-agent dependencies"
  (
    cd "$COMPUTE_AGENT_DIR"
    npm install --no-audit --no-fund
  )
}

start_compute_agent() {
  echo "==> Starting compute-agent"
  (
    cd "$COMPUTE_AGENT_DIR"
    nohup env \
      WALLET_KEY_PATH="$COMPUTE_WALLET_PATH" \
      WALLET_ADDRESS="$COMPUTE_WALLET_ADDRESS" \
      NODE_ID="$COMPUTE_NODE_ID" \
      TASK_API_URL="http://127.0.0.1:6003" \
      STORAGE_API_URL="http://127.0.0.1:7000" \
      HEALTH_PORT="3333" \
      npm run dev > "$LOG_DIR/compute-agent.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/compute-agent.pid"
  )
}

ensure_backend_deps() {
  if [ -x "$BACKEND_ROOT/node_modules/.bin/tsx" ]; then
    return 0
  fi

  echo "==> Installing backend dependencies"
  (
    cd "$BACKEND_ROOT"
    npm install --include=dev --no-audit --no-fund
  )
}
ensure_frontend_deps() {
  if [ -x "$ROOT/frontend/node_modules/.bin/vite" ] && [ -d "$ROOT/frontend/node_modules/tailwindcss" ]; then
    return 0
  fi

  echo "==> Installing frontend dependencies (vite/tailwindcss)"
  (
    cd "$ROOT/frontend"
    npm install --include=dev --no-audit --no-fund
  )
}

ensure_jwt_secret() {
  local jwt_secret
  jwt_secret="$(resolve_jwt_secret)"

  if [ "${#jwt_secret}" -lt 32 ]; then
    echo "ERROR: JWT secret must be at least 32 characters for relaunch."
    exit 1
  fi

  printf '%s\n' "$jwt_secret" > "$JWT_SECRET_PATH"
  chmod 600 "$JWT_SECRET_PATH" 2>/dev/null || true

  export JWT_SECRET="$jwt_secret"
  export WRFCOIN_JWT_SECRET_PATH="$JWT_SECRET_PATH"
}

run_dev_migrations() {
  echo "==> Running database migrations (dev mode)"
  (
    cd "$BACKEND_ROOT"
    npx --yes drizzle-kit migrate 2>&1 | tail -5
  ) || {
    echo "WARN: database migration failed (non-fatal in dev mode)"
  }
}

verify_metrics_endpoints() {
  echo "==> Verifying Prometheus /metrics endpoints"
  local failed=0
  local svc_url label url
  for svc_url in \
    "backend:http://localhost:4001/metrics" \
    "governance:http://localhost:8000/metrics" \
    "cross-chain:http://localhost:3000/metrics" \
    "iot:http://localhost:3002/metrics"
  do
    label="${svc_url%%:http*}"
    url="http${svc_url#*:http}"
    if [ "$label" = "backend" ]; then
      check_http_once "metrics-${label}" "$url" operator-bearer || failed=1
    else
      check_http_once "metrics-${label}" "$url" || failed=1
    fi
  done
  return $failed
}

run_smoke_command() {
  local name="$1"
  shift
  local logfile="$SMOKE_LOG_DIR/${name}.log"

  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: relaunch-run-smoke-command-forwards-argv
  if "$@" >"$logfile" 2>&1; then
    echo "smoke:${name}: PASS"
    return 0
  fi

  echo "smoke:${name}: FAIL (log: $logfile)"
  return 1
}

start_contract_core4_stub() {
  echo "==> Starting contract-gate core4 fixture source"
  (
    cd "$ROOT"
    nohup env \
      CORE4_STUB_HOST=127.0.0.1 \
      CORE4_STUB_PORT="$CONTRACT_CORE4_STUB_PORT" \
      CORE4_FIXTURE_PATH="$ROOT/core4/contract-fixtures/launch-realtime-event-source.json" \
      node "$SCRIPT_DIR/launch-contract-core4-stub.cjs" > "$LOG_DIR/contract-core4-stub.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/contract-core4-stub.pid"
  )
}

verify_pid_alive() {
  local pid_file="$1"
  local pid
  if [ ! -f "$pid_file" ]; then
    return 1
  fi
  pid=$(cat "$pid_file")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

verify_container_running() {
  local container_name="$1"
  [ -n "$container_name" ] || return 1
  [ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" = "true" ]
}

check_container_healthy_once() {
  local label="$1"
  local container_name="$2"
  local running_state health_state

  running_state="$(get_container_running_state "$container_name")"
  health_state="$(get_container_health_state "$container_name")"
  if [ "$running_state" = "running" ] && [ "$health_state" = "healthy" ]; then
    echo "${label}: healthy"
    return 0
  fi

  echo "${label}: running=${running_state} health=${health_state}"
  return 1
}

check_http_once() {
  local label="$1"
  local url="$2"
  local auth="${3:-}"
  local code
  if [ "$auth" = "operator-bearer" ]; then
    code=$(curl_with_operator_bearer -s -o /dev/null -w '%{http_code}' "$url" || true)
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
  fi
  if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    echo "${label}: ${code}"
    return 0
  fi

  echo "${label}: ${code:-UNREACHABLE}"
  return 1
}

check_main_api_live_once() {
  check_http_once "steady-main-api" "http://localhost:4001/live" || {
    print_main_api_health_diagnostic
    return 1
  }
}

run_steady_state_liveness() {
  local settle_secs="$1"

  if [ "$settle_secs" -gt 0 ]; then
    echo "==> Waiting ${settle_secs}s for steady-state liveness window"
    sleep "$settle_secs"
  fi

  local failed=0

  if [ "$TESTNET_MODE" != "1" ]; then
    local pid_file
    for pid_file in \
      "$LOG_DIR/backend-dev.pid" \
      "$LOG_DIR/frontend-dev.pid" \
      "$LOG_DIR/cross-chain.pid" \
      "$LOG_DIR/governance.pid" \
      "$LOG_DIR/main-api.pid" \
      "$LOG_DIR/compute-contribution.pid" \
      "$LOG_DIR/testnet.pid"
    do
      if ! verify_pid_alive "$pid_file"; then
        failed=1
        echo "steady-state: dead pid $(basename "$pid_file")"
      fi
    done
    if [ "$COMPUTE_AGENT_EXPECTED" = "1" ] && ! verify_pid_alive "$LOG_DIR/compute-agent.pid"; then
      failed=1
      echo "steady-state: dead pid compute-agent.pid"
    fi
    if [ "$RUN_CONTRACT_GATE" = "1" ] && [ "$USE_CORE4_FIXTURE_STUB" = "1" ] && ! verify_pid_alive "$LOG_DIR/contract-core4-stub.pid"; then
      failed=1
      echo "steady-state: dead pid contract-core4-stub.pid"
    fi
  fi

  if [ "$TESTNET_MODE" = "1" ]; then
    for cn in wrfcoin-testnet-node wrfcoin-testnet-backend wrfcoin-testnet-governance wrfcoin-testnet-cross-chain wrfcoin-testnet-iot; do
      check_container_healthy_once "steady-${cn}" "$cn" || { failed=1; print_container_diagnostic "steady-${cn}" "$cn"; }
    done
  fi

  local container_name
  while IFS= read -r container_name; do
    [ -n "$container_name" ] || continue
    if ! verify_container_running "$container_name"; then
      failed=1
      echo "steady-state: container not running $container_name"
    fi
  done < <(list_compose_container_names)

  check_container_healthy_once "steady-postgres" "wrfcoin-postgres" || {
    failed=1
    print_container_diagnostic "steady-postgres" "wrfcoin-postgres"
  }
  check_container_healthy_once "steady-redis" "wrfcoin-redis" || {
    failed=1
    print_container_diagnostic "steady-redis" "wrfcoin-redis"
  }

  check_http_once "steady-backend-dev" "http://localhost:3001/api/health" || failed=1
  check_http_once "steady-frontend-dev" "http://localhost:5000" || failed=1
  check_http_once "steady-cross-chain" "http://localhost:3000/health" || failed=1
  check_http_once "steady-governance" "http://localhost:8000/health" || failed=1
  check_http_once "steady-iot" "http://localhost:3002/health" || failed=1
  check_http_once "steady-prometheus" "http://localhost:9090/-/ready" || {
    failed=1
    print_container_diagnostic "steady-prometheus" "wrfcoin-prometheus"
  }
  check_http_once "steady-grafana" "http://localhost:3100/api/health" || {
    failed=1
    print_container_diagnostic "steady-grafana" "wrfcoin-grafana"
  }
  check_main_api_live_once || failed=1
  check_http_once "steady-compute-contribution" "http://localhost:6003/health" || failed=1
  if [ "$COMPUTE_AGENT_EXPECTED" = "1" ]; then
    check_http_once "steady-compute-agent" "http://localhost:3333/health" || failed=1
  else
    echo "steady-compute-agent: SKIPPED"
  fi
  check_http_once "steady-testnet" "http://localhost:8556/health" || failed=1
  if [ "$RUN_CONTRACT_GATE" = "1" ] && [ "$USE_CORE4_FIXTURE_STUB" = "1" ]; then
    check_http_once "steady-contract-core4-stub" "$CONTRACT_CORE4_STUB_URL/health" || failed=1
  fi

  if [ "$failed" -ne 0 ]; then
    return 1
  fi

  return 0
}

generate_report() {
  local preflight_env_json preflight_dep_json preflight_port_json preflight_container_json
  local preflight_log_json cleanup_json

  preflight_env_json="$(json_array_from_lines "$PREFLIGHT_ENV_LINES")"
  preflight_dep_json="$(json_array_from_lines "$PREFLIGHT_DEP_LINES")"
  preflight_port_json="$(json_array_from_lines "$PREFLIGHT_PORT_LINES")"
  preflight_container_json="$(json_array_from_lines "$PREFLIGHT_CONTAINER_LINES")"
  preflight_log_json="$(json_array_from_lines "$PREFLIGHT_LOG_LINES")"
  cleanup_json="$(json_array_from_lines "$CLEANUP_LINES")"

  jq -n \
    --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson fast_mode "$FAST_MODE" \
    --argjson smoke_enabled "$RUN_SMOKE" \
    --argjson contract_gate_enabled "$RUN_CONTRACT_GATE" \
    --arg service_start "$SERVICE_START_STATUS" \
    --arg health_checks "$HEALTH_CHECK_STATUS" \
    --arg cli_compute "$CLI_COMPUTE_STATUS" \
    --arg cli_forecast "$CLI_FORECAST_STATUS" \
    --arg contract_gate "$CONTRACT_GATE_STATUS" \
    --arg steady_state "$STEADY_STATE_STATUS" \
    --arg db_migrate "$DB_MIGRATE_STATUS" \
    --arg metrics "$METRICS_STATUS" \
    --arg iot_smoke "$IOT_SMOKE_STATUS" \
    --argjson preflight_env "$preflight_env_json" \
    --argjson preflight_dependencies "$preflight_dep_json" \
    --argjson preflight_ports "$preflight_port_json" \
    --argjson preflight_containers "$preflight_container_json" \
    --argjson preflight_logs "$preflight_log_json" \
    --argjson cleanup "$cleanup_json" \
    '{
      timestamp: $timestamp,
      fast_mode: $fast_mode,
      smoke_enabled: $smoke_enabled,
      contract_gate_enabled: $contract_gate_enabled,
      preflight: {
        env: $preflight_env,
        dependencies: $preflight_dependencies,
        ports: $preflight_ports,
        containers: $preflight_containers,
        logs: $preflight_logs
      },
      cleanup: $cleanup,
      results: {
        service_start: $service_start,
        health_checks: $health_checks,
        cli_compute: $cli_compute,
        cli_forecast: $cli_forecast,
        contract_gate: $contract_gate,
        steady_state: $steady_state,
        db_migrate: $db_migrate,
        metrics: $metrics,
        iot_smoke: $iot_smoke
      }
    }' > "$JSON_REPORT"
  echo "Report generated: $JSON_REPORT"
}

collect_preflight_report
print_report_block "Preflight Environment" "$PREFLIGHT_ENV_LINES"
print_report_block "Preflight Dependencies" "$PREFLIGHT_DEP_LINES"
print_report_block "Preflight Ports" "$PREFLIGHT_PORT_LINES"
print_report_block "Preflight Containers" "$PREFLIGHT_CONTAINER_LINES"
print_report_block "Preflight Logs" "$PREFLIGHT_LOG_LINES"

check_deps
check_env
backup_logs
stop_services

echo "==> Starting Docker infra"
(cd "$ROOT" && docker-compose -f "$COMPOSE_FILE" up -d)

STATEFUL_INFRA_TIMEOUT=60
MONITORING_TIMEOUT=60
if [ "$FAST_MODE" = "1" ]; then
  STATEFUL_INFRA_TIMEOUT=30
  MONITORING_TIMEOUT=30
fi

wait_docker_infra_ready "$STATEFUL_INFRA_TIMEOUT" "$MONITORING_TIMEOUT"

DB_MIGRATE_STATUS="SKIPPED"
METRICS_STATUS="SKIPPED"
IOT_SMOKE_STATUS="SKIPPED"

if [ "$TESTNET_MODE" = "1" ]; then
  # Testnet mode: wait for db-migrate, then container health
  DB_MIGRATE_TIMEOUT=120
  if [ "$FAST_MODE" = "1" ]; then DB_MIGRATE_TIMEOUT=60; fi
  DB_MIGRATE_STATUS="PASS"
  wait_db_migrate "$DB_MIGRATE_TIMEOUT" || DB_MIGRATE_STATUS="FAIL"

  TESTNET_CONTAINER_TIMEOUT=180
  TESTNET_SVC_TIMEOUT=120
  if [ "$FAST_MODE" = "1" ]; then
    TESTNET_CONTAINER_TIMEOUT=90
    TESTNET_SVC_TIMEOUT=60
  fi

  echo "==> Waiting for testnet container readiness"
  HEALTH_CHECK_STATUS="PASS"
  wait_container_healthy "testnet-node" "wrfcoin-testnet-node" "$TESTNET_CONTAINER_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_container_healthy "testnet-backend" "wrfcoin-testnet-backend" "$TESTNET_SVC_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_container_healthy "testnet-governance" "wrfcoin-testnet-governance" "$TESTNET_SVC_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_container_healthy "testnet-cross-chain" "wrfcoin-testnet-cross-chain" "$TESTNET_SVC_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_container_healthy "testnet-iot" "wrfcoin-testnet-iot" "$TESTNET_SVC_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"

  # Also HTTP-verify endpoints
  wait_http "testnet-node-http" "http://localhost:8556/readyz" 30 || HEALTH_CHECK_STATUS="FAIL"
  wait_http "testnet-backend-http" "http://localhost:4001/health" 30 || HEALTH_CHECK_STATUS="FAIL"
  wait_http "testnet-governance-http" "http://localhost:8000/health" 30 || HEALTH_CHECK_STATUS="FAIL"
  wait_http "testnet-cross-chain-http" "http://localhost:3000/health" 30 || HEALTH_CHECK_STATUS="FAIL"
  wait_http "testnet-iot-http" "http://localhost:3002/health" 30 || HEALTH_CHECK_STATUS="FAIL"

  # No bare processes in testnet mode
  SERVICE_START_STATUS="PASS"
  COMPUTE_AGENT_EXPECTED=0

else
  # Dev mode: existing bare-process startup
  DB_MIGRATE_STATUS="SKIPPED"

  echo "==> Resolving operator token"
  WRFCOIN_OPERATOR_TOKEN="$(resolve_operator_token)"
  if ! printf '%s' "$WRFCOIN_OPERATOR_TOKEN" | grep -Eq '^[0-9a-f]{64}$'; then
    echo "ERROR: WRFCOIN_OPERATOR_TOKEN missing or invalid (expected 64 hex chars)."
    exit 1
  fi
  export WRFCOIN_OPERATOR_TOKEN

  echo "==> Resolving local JWT secret"
  ensure_jwt_secret
  echo "JWT secret path: $JWT_SECRET_PATH"

  echo "==> Resolving local DATABASE_URL"
  DATABASE_URL="$(resolve_database_url)"
  export DATABASE_URL
  echo "DATABASE_URL source: ${DATABASE_URL%%:*}://***@${DATABASE_URL##*@}"

  ensure_backend_deps
  ensure_frontend_deps

  run_dev_migrations

  echo "==> Starting backend + frontend"
  (
    cd "$BACKEND_ROOT"
    nohup npm run dev > "$LOG_DIR/backend-dev.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/backend-dev.pid"
  )
  (
    cd "$ROOT/frontend"
    nohup npm run dev > "$LOG_DIR/frontend-dev.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/frontend-dev.pid"
  )

  echo "==> Starting core microservices"
  (
    cd "$BACKEND_ROOT"
    nohup npx tsx server/cross_chain_protocol_server.js > "$LOG_DIR/cross-chain.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/cross-chain.pid"
  )
  (
    cd "$BACKEND_ROOT"
    nohup npx tsx server/governance_server_minimal.js > "$LOG_DIR/governance.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/governance.pid"
  )

  echo "==> Starting compute API surfaces"
  (
    cd "$BACKEND_ROOT"
    if [ "$RUN_CONTRACT_GATE" = "1" ]; then
      nohup env \
        PORT="4001" \
        CORE4_API_URL="$CONTRACT_GATE_CORE4_BASE_URL" \
        BLOCKCHAIN_NODE_URL="$CONTRACT_GATE_CORE4_BASE_URL" \
        npx tsx server/enhanced_unified_api_optimized.ts > "$LOG_DIR/main-api.log" 2>&1 < /dev/null &
    else
      nohup env PORT="4001" npx tsx server/enhanced_unified_api_optimized.ts > "$LOG_DIR/main-api.log" 2>&1 < /dev/null &
    fi
    echo $! > "$LOG_DIR/main-api.pid"
  )
  (
    cd "$BACKEND_ROOT"
    nohup npx tsx server/compute_contribution_server.js > "$LOG_DIR/compute-contribution.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/compute-contribution.pid"
  )

  ensure_compute_wallet
  ensure_compute_agent_deps

  if [ "$RUN_CONTRACT_GATE" = "1" ] && [ "$USE_CORE4_FIXTURE_STUB" = "1" ]; then
    start_contract_core4_stub
  fi

  echo "==> Starting testnet launch_api"
  (
    cd "$ROOT/core4"
    nohup env \
      WRFCOIN_API_HOST=127.0.0.1 \
      WRFCOIN_API_PORT=8556 \
      WRFCOIN_DATA_DIR=./data/testnet \
      WRFCOIN_NETWORK=testnet \
      WRFCOIN_OPERATOR_TOKEN="$WRFCOIN_OPERATOR_TOKEN" \
      RUST_LOG=info \
      cargo run -p wrfcoin-native-chain --bin launch_api > "$LOG_DIR/testnet.log" 2>&1 < /dev/null &
    echo $! > "$LOG_DIR/testnet.pid"
  )

  SERVICE_START_STATUS="PASS"
  for pf in \
    "$LOG_DIR/backend-dev.pid" \
    "$LOG_DIR/frontend-dev.pid" \
    "$LOG_DIR/cross-chain.pid" \
    "$LOG_DIR/governance.pid" \
    "$LOG_DIR/main-api.pid" \
    "$LOG_DIR/compute-contribution.pid" \
    "$LOG_DIR/testnet.pid"
  do
    if ! verify_pid_alive "$pf"; then
      SERVICE_START_STATUS="FAIL"
      echo "WARN: service PID not alive for $(basename "$pf")"
    fi
  done
  if [ "$RUN_CONTRACT_GATE" = "1" ] && [ "$USE_CORE4_FIXTURE_STUB" = "1" ] && ! verify_pid_alive "$LOG_DIR/contract-core4-stub.pid"; then
    SERVICE_START_STATUS="FAIL"
    echo "WARN: service PID not alive for contract-core4-stub.pid"
  fi

  FRONTEND_TIMEOUT=90
  BACKEND_TIMEOUT=90
  CROSS_CHAIN_TIMEOUT=90
  GOVERNANCE_TIMEOUT=90
  MAIN_API_TIMEOUT=180
  COMPUTE_CONTRIB_TIMEOUT=180
  COMPUTE_AGENT_TIMEOUT=120
  TESTNET_TIMEOUT=180
  CONTRACT_CORE4_STUB_TIMEOUT=60

  if [ "$FAST_MODE" = "1" ]; then
    FRONTEND_TIMEOUT=20
    BACKEND_TIMEOUT=45
    CROSS_CHAIN_TIMEOUT=45
    GOVERNANCE_TIMEOUT=45
    MAIN_API_TIMEOUT=45
    COMPUTE_CONTRIB_TIMEOUT=45
    COMPUTE_AGENT_TIMEOUT=45
    TESTNET_TIMEOUT=60
    CONTRACT_CORE4_STUB_TIMEOUT=20
  fi

  echo "==> Waiting for readiness"
  HEALTH_CHECK_STATUS="PASS"
  wait_http "backend-dev" "http://localhost:3001/api/health" "$BACKEND_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_http "frontend-dev" "http://localhost:5000" "$FRONTEND_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_http "cross-chain" "http://localhost:3000/health" "$CROSS_CHAIN_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  wait_http "governance" "http://localhost:8000/health" "$GOVERNANCE_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  if [ "$RUN_CONTRACT_GATE" = "1" ] && [ "$USE_CORE4_FIXTURE_STUB" = "1" ]; then
    wait_http "contract-core4-stub" "$CONTRACT_CORE4_STUB_URL/health" "$CONTRACT_CORE4_STUB_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  fi
  wait_main_api_ready "$MAIN_API_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  if wait_compute_contribution_ready "$COMPUTE_CONTRIB_TIMEOUT"; then
    COMPUTE_AGENT_EXPECTED=1
    start_compute_agent
    if ! verify_pid_alive "$LOG_DIR/compute-agent.pid"; then
      SERVICE_START_STATUS="FAIL"
      echo "WARN: service PID not alive for compute-agent.pid"
    fi
    wait_http "compute-agent" "http://localhost:3333/health" "$COMPUTE_AGENT_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
  else
    HEALTH_CHECK_STATUS="FAIL"
    SERVICE_START_STATUS="FAIL"
    COMPUTE_AGENT_EXPECTED=0
    echo "WARN: skipping compute-agent start because compute-contribution readiness failed"
  fi
  wait_http "testnet" "http://localhost:8556/health" "$TESTNET_TIMEOUT" || HEALTH_CHECK_STATUS="FAIL"
fi

STEADY_STATE_WINDOW=15
CONTRACT_GATE_TIMEOUT_MS=15000
if [ "$FAST_MODE" = "1" ]; then
  STEADY_STATE_WINDOW=5
  CONTRACT_GATE_TIMEOUT_MS=10000
fi

echo "==> Running CLI smoke checks (enabled=${RUN_SMOKE})"
CLI_COMPUTE_STATUS="SKIPPED"
CLI_FORECAST_STATUS="SKIPPED"
if [ "$RUN_SMOKE" = "1" ]; then
  CLI_COMPUTE_STATUS="PASS"
  CLI_FORECAST_STATUS="PASS"
  SMOKE_SPEC_FILE="$SMOKE_LOG_DIR/compute-smoke-spec.json"
  SMOKE_FORECAST_FILE="$SMOKE_LOG_DIR/forecast-smoke-data.json"

  cat > "$SMOKE_SPEC_FILE" <<'JSON'
{
  "model": "wrf-arw",
  "domainBounds": {
    "north": 49.0,
    "south": 33.0,
    "east": -66.0,
    "west": -125.0
  },
  "resolutionKm": 12,
  "forecastHours": 6
}
JSON

  cat > "$SMOKE_FORECAST_FILE" <<'JSON'
{
  "summary": "smoke-forecast",
  "runAt": "2026-03-10T00:00:00Z"
}
JSON

  if [ -d "$CLI_DIR" ]; then
    (
      cd "$CLI_DIR"
      run_smoke_command "compute-list-providers" cargo run --quiet -- --json compute list-providers
    ) || CLI_COMPUTE_STATUS="FAIL"

    (
      cd "$CLI_DIR"
      run_smoke_command "compute-submit-task" cargo run --quiet -- --json compute submit-task --provider "wrf-arw" --spec-file "$SMOKE_SPEC_FILE" --timeout 300
    ) || CLI_COMPUTE_STATUS="FAIL"

    (
      cd "$CLI_DIR"
      run_smoke_command "forecast-list" cargo run --quiet -- --json forecast list --limit 1
    ) || CLI_FORECAST_STATUS="FAIL"
  else
    echo "CLI directory missing: $CLI_DIR"
    CLI_COMPUTE_STATUS="FAIL"
    CLI_FORECAST_STATUS="FAIL"
  fi
fi

IOT_SMOKE_STATUS="SKIPPED"
if [ "$RUN_SMOKE" = "1" ] && [ -n "${WRFCOIN_OPERATOR_TOKEN:-}" ]; then
  IOT_SMOKE_STATUS="PASS"
  # infra#1066: the bearer travels on stdin (curl_with_operator_bearer), never argv.
  run_smoke_command "iot-sensor-reading" \
    curl_with_operator_bearer -sf -X POST http://localhost:3002/api/iot/readings \
    -H "Content-Type: application/json" \
    -d '{"sensor_id":"smoke-test-1","reading_type":"temperature","value":22.5}' \
    || IOT_SMOKE_STATUS="FAIL"
fi

echo "==> Verifying metrics endpoints"
METRICS_STATUS="PASS"
verify_metrics_endpoints || METRICS_STATUS="FAIL"

echo "==> Running launch-critical contract gate (enabled=${RUN_CONTRACT_GATE})"
CONTRACT_GATE_STATUS="SKIPPED"
if [ "$RUN_CONTRACT_GATE" = "1" ]; then
  CONTRACT_GATE_STATUS="PASS"
  CONTRACT_GATE_REPORT_DIR="$SMOKE_LOG_DIR/launch-contract-suite"
  mkdir -p "$CONTRACT_GATE_REPORT_DIR"
  run_smoke_command \
    "launch-critical-contract-gate" \
    env \
    BACKEND_REPO_DIR="$BACKEND_ROOT" \
    MOBILE_REPO_DIR="$ROOT/mobile" \
    CORE4_REPO_DIR="$ROOT/core4" \
    INFRA_REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" \
    REPORT_DIR="$CONTRACT_GATE_REPORT_DIR" \
    MAIN_API_BASE_URL="http://127.0.0.1:4001" \
    MAIN_API_WS_URL="ws://127.0.0.1:4001/ws" \
    COMPUTE_API_BASE_URL="http://127.0.0.1:6003" \
    CORE4_API_BASE_URL="$CONTRACT_GATE_CORE4_BASE_URL" \
    CONTRACT_WS_TIMEOUT_MS="$CONTRACT_GATE_TIMEOUT_MS" \
    node "$CONTRACT_GATE_SCRIPT" || CONTRACT_GATE_STATUS="FAIL"
fi

echo "==> Running steady-state liveness pass"
STEADY_STATE_STATUS="PASS"
run_steady_state_liveness "$STEADY_STATE_WINDOW" || STEADY_STATE_STATUS="FAIL"
echo ""
echo "Relaunch complete. Logs: ${LOG_DIR}"
echo "PIDs:"
for file in "$LOG_DIR"/*.pid; do
  [ -f "$file" ] || continue
  printf '  %s -> %s\n' "$(basename "$file")" "$(cat "$file")"
done
echo ""
echo "Mode:"
echo "  fast mode: ${FAST_MODE}"
echo "  testnet mode: ${TESTNET_MODE}"
echo "  smoke enabled: ${RUN_SMOKE}"
echo "  contract gate enabled: ${RUN_CONTRACT_GATE}"
echo "  core4 fixture stub enabled: ${USE_CORE4_FIXTURE_STUB}"
echo "  contract gate core4 base url: ${CONTRACT_GATE_CORE4_BASE_URL}"
echo ""
echo "Smoke matrix:"
echo "  service start: ${SERVICE_START_STATUS}"
echo "  health checks: ${HEALTH_CHECK_STATUS}"
echo "  db migrate: ${DB_MIGRATE_STATUS}"
echo "  metrics: ${METRICS_STATUS}"
echo "  cli compute: ${CLI_COMPUTE_STATUS}"
echo "  cli forecast: ${CLI_FORECAST_STATUS}"
echo "  iot smoke: ${IOT_SMOKE_STATUS}"
echo "  contract gate: ${CONTRACT_GATE_STATUS}"
echo "  steady state: ${STEADY_STATE_STATUS}"

generate_report

FAILED_CHECKS=()
for check in \
  "$SERVICE_START_STATUS:service start" \
  "$HEALTH_CHECK_STATUS:health checks" \
  "$DB_MIGRATE_STATUS:db migrate" \
  "$METRICS_STATUS:metrics" \
  "$CLI_COMPUTE_STATUS:cli compute" \
  "$CLI_FORECAST_STATUS:cli forecast" \
  "$IOT_SMOKE_STATUS:iot smoke" \
  "$CONTRACT_GATE_STATUS:contract gate" \
  "$STEADY_STATE_STATUS:steady state"
do
  status="${check%%:*}"
  name="${check#*:}"
  if [ "$status" = "FAIL" ]; then
    FAILED_CHECKS+=("$name")
  fi
done

if [ ${#FAILED_CHECKS[@]} -gt 0 ]; then
  echo ""
  echo "Relaunch failed checks: ${FAILED_CHECKS[*]}"
  exit 1
fi
