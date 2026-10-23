#!/usr/bin/env bash
set -euo pipefail

# infra#72: Automated P2P Partition Testing in CI
#
# This script orchestrates a network partition test between multiple WRFCoin nodes.
# It uses Docker to create a real network partition and verifies that the blockchain
# can recover and continue syncing after the partition is healed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_DIR="${REPORT_DIR:-$REPO_ROOT/artifacts/p2p-partition}"

# Configuration
IMAGE="${P2P_PARTITION_IMAGE:-wrfcoin/wrfcoin-node:latest}"
OPERATOR_TOKEN="${WRFCOIN_OPERATOR_TOKEN:-dev-operator-token}"
SETUP_TIMEOUT_SECONDS="${P2P_PARTITION_SETUP_TIMEOUT_SECONDS:-60}"
RECOVERY_TIMEOUT_SECONDS="${P2P_PARTITION_RECOVERY_TIMEOUT_SECONDS:-60}"
PARTITION_HOLD_SECONDS="${P2P_PARTITION_HOLD_SECONDS:-10}"
NETWORK_NAME="${P2P_PARTITION_NETWORK_NAME:-wrfcoin-p2p-partition-${GITHUB_RUN_ID:-$$}}"
CONTAINER_PREFIX="${P2P_PARTITION_CONTAINER_PREFIX:-wrf-node-${GITHUB_RUN_ID:-$$}}"
DRY_RUN=0

PHASE_BASELINE="pending"
PHASE_PARTITION="pending"
PHASE_RECOVERY="pending"
PHASE_TEARDOWN="pending"
LAST_ERROR=""
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

CONTAINERS=()
CLEANUP_ACTIONS=()

usage() {
  cat <<'EOF'
Usage: run-p2p-partition-ci.sh [--artifact-dir PATH] [--image IMAGE] [--dry-run]

Options:
  --artifact-dir PATH   Write logs and summaries under PATH.
  --image IMAGE         Docker image to use for peer containers.
  --dry-run             Validate configuration and emit a dry-run summary without touching Docker.
  -h, --help            Show this help.

Environment:
  WRFCOIN_OPERATOR_TOKEN                     API token for nodes (default: dev-operator-token)
  P2P_PARTITION_IMAGE                        Peer image (default: wrfcoin/wrfcoin-node:latest)
  P2P_PARTITION_SETUP_TIMEOUT_SECONDS        Baseline readiness timeout (default: 60)
  P2P_PARTITION_RECOVERY_TIMEOUT_SECONDS     Recovery timeout after reconnect (default: 60)
  P2P_PARTITION_HOLD_SECONDS                 Time to hold the partition (default: 10)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact-dir) REPORT_DIR="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$REPORT_DIR"
COMMAND_LOG="$REPORT_DIR/command-output.txt"
SUMMARY_MD="$REPORT_DIR/summary.md"
SUMMARY_JSON="$REPORT_DIR/summary.json"
CLEANUP_LOG="$REPORT_DIR/cleanup.log"

exec > >(tee "$COMMAND_LOG") 2>&1

phase() { printf '\n[%s] %s\n' "$(date -u +"%H:%M:%S")" "$*"; }
log() { printf '[%s] %s\n' "$(date -u +"%H:%M:%S")" "$*"; }

record_cleanup_action() {
  CLEANUP_ACTIONS+=("$1")
  printf '%s\n' "$1" >> "$CLEANUP_LOG"
}

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

write_summary() {
  local finished_at status duration
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  duration="$(( $(date +%s) - $(date -d "$STARTED_AT" +%s) ))"
  status="${LAST_ERROR:+failed}"
  status="${status:-passed}"

  cat > "$SUMMARY_MD" <<EOF
# P2P Partition Gate Summary

- Status: ${status}
- Started: ${STARTED_AT}
- Finished: ${finished_at}
- Duration: ${duration}s
- Image: ${IMAGE}

## Phase Results
| Phase | Result |
| --- | --- |
| Baseline | ${PHASE_BASELINE} |
| Partition | ${PHASE_PARTITION} |
| Recovery | ${PHASE_RECOVERY} |
| Teardown | ${PHASE_TEARDOWN} |

## Failure Detail
${LAST_ERROR:-None}
EOF
}

cleanup() {
  local exit_code="$1"
  phase "cleanup"
  PHASE_TEARDOWN="running"

  if [ "$exit_code" -ne 0 ]; then
    # Capture node state before the containers are removed, so a failed gate
    # explains itself in the job log and in the uploaded artifact.
    {
      printf '\n--- docker ps -a (%s) ---\n' "$CONTAINER_PREFIX"
      docker ps -a --filter "name=${CONTAINER_PREFIX}" 2>&1 || true
      for container in "${CONTAINERS[@]:-}"; do
        [ -n "$container" ] || continue
        printf '\n--- docker inspect state: %s ---\n' "$container"
        docker inspect --format '{{json .State}}' "$container" 2>&1 || true
        printf '\n--- docker logs --tail 200: %s ---\n' "$container"
        docker logs --tail 200 "$container" 2>&1 || true
      done
    } | tee "$REPORT_DIR/node-logs.txt" || true
  fi

  for container in "${CONTAINERS[@]:-}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
    record_cleanup_action "removed container ${container}"
  done

  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  record_cleanup_action "removed network ${NETWORK_NAME}"

  PHASE_TEARDOWN="${LAST_ERROR:+completed-with-failure}"
  PHASE_TEARDOWN="${PHASE_TEARDOWN:-passed}"
  write_summary
  exit "$exit_code"
}

on_error() {
  local line="$1"
  LAST_ERROR="${LAST_ERROR:-command failed near line ${line}}"
}

trap 'on_error $LINENO' ERR
trap 'cleanup $?' EXIT

# --- API Probes ---

api_call() {
  local container="$1"
  local method="$2"
  local path="$3"
  local data="${4:-}"
  local container_name="${CONTAINER_PREFIX}-${container}"
  
  # infra#1073: the bearer reaches the in-container curl on stdin (-H @-, via
  # docker exec -i) from the builtin printf, so neither the host's docker argv
  # nor the container's curl argv carries it.
  local cmd=(curl -s -X "$method" -H @- "http://localhost:8556$path")
  if [ -n "$data" ]; then
    cmd+=(-H "Content-Type: application/json" -d "$data")
  fi

  printf 'Authorization: Bearer %s\n' "$OPERATOR_TOKEN" |
    docker exec -i "$container_name" "${cmd[@]}"
}

get_height() {
  api_call "$1" GET "/metrics" | jq -r '.data.chain_height // 0'
}

mine_block() {
  log "Mining block on $1..."
  api_call "$1" POST "/blocks/mine" '{"miner_address":"0x0000000000000000000000000000000000000000"}' > /dev/null
}

wait_for_health() {
  local name="$1"
  local timeout="$2"
  local started
  started="$(date +%s)"

  while true; do
    local resp
    resp=$(api_call "$name" GET "/health" 2>/dev/null || echo '{"status":"down"}')
    if [[ "$resp" == *"healthy"* ]]; then
      log "$name is healthy"
      return 0
    fi

    if [ $(( $(date +%s) - started )) -ge "$timeout" ]; then
      LAST_ERROR="$name did not become healthy within ${timeout}s"
      return 1
    fi
    sleep 2
  done
}

start_node() {
  local name="$1"
  local p2p_port="$2"
  local bootstrap="$3"
  local container_name="${CONTAINER_PREFIX}-${name}"

  log "Starting node $name..."
  docker run -d \
    --name "$container_name" \
    --network "$NETWORK_NAME" \
    -e WRFCOIN_P2P_ENABLED=true \
    -e WRFCOIN_P2P_PORT="$p2p_port" \
    -e WRFCOIN_P2P_BOOTSTRAP="$bootstrap" \
    -e WRFCOIN_OPERATOR_TOKEN="$OPERATOR_TOKEN" \
    -e RUST_LOG=info \
    "$IMAGE" > /dev/null

  CONTAINERS+=("$container_name")
}

# --- Main Execution ---

phase "preflight"
if [ "$DRY_RUN" -eq 1 ]; then
  PHASE_BASELINE="skipped"; PHASE_PARTITION="skipped"; PHASE_RECOVERY="skipped"; PHASE_TEARDOWN="passed"
  exit 0
fi

docker network create "$NETWORK_NAME" >/dev/null
record_cleanup_action "created network ${NETWORK_NAME}"

phase "starting cluster"
# Node A (seed)
start_node node-a 9000 ""
# Node B (connects to A)
start_node node-b 9000 "node-a:9000"
# Node C (connects to B)
start_node node-c 9000 "node-b:9000"

phase "baseline readiness"
PHASE_BASELINE="running"
wait_for_health node-a "$SETUP_TIMEOUT_SECONDS"
wait_for_health node-b "$SETUP_TIMEOUT_SECONDS"
wait_for_health node-c "$SETUP_TIMEOUT_SECONDS"
PHASE_BASELINE="passed"

phase "simulating partition (isolate node-c)"
PHASE_PARTITION="running"
docker network disconnect "$NETWORK_NAME" "${CONTAINER_PREFIX}-node-c"
record_cleanup_action "disconnected node-c"

# Mine blocks on both sides of the partition
mine_block node-a
mine_block node-c
mine_block node-c

HEIGHT_A=$(get_height node-a)
HEIGHT_C=$(get_height node-c)
log "Heights during partition - Node A: $HEIGHT_A, Node C: $HEIGHT_C"

sleep "$PARTITION_HOLD_SECONDS"
PHASE_PARTITION="passed"

phase "recovering partition"
PHASE_RECOVERY="running"
docker network connect "$NETWORK_NAME" "${CONTAINER_PREFIX}-node-c"
record_cleanup_action "reconnected node-c"

log "Waiting for nodes to re-sync..."
started="$(date +%s)"
while true; do
  HEIGHT_A=$(get_height node-a)
  HEIGHT_B=$(get_height node-b)
  HEIGHT_C=$(get_height node-c)
  
  log "Current heights - A: $HEIGHT_A, B: $HEIGHT_B, C: $HEIGHT_C"
  
  if [ "$HEIGHT_A" -eq "$HEIGHT_C" ] && [ "$HEIGHT_A" -eq "$HEIGHT_B" ] && [ "$HEIGHT_A" -gt 0 ]; then
    log "✅ Cluster re-synced at height $HEIGHT_A"
    break
  fi

  if [ $(( $(date +%s) - started )) -ge "$RECOVERY_TIMEOUT_SECONDS" ]; then
    LAST_ERROR="Cluster failed to re-sync within ${RECOVERY_TIMEOUT_SECONDS}s"
    exit 1
  fi
  sleep 5
done
PHASE_RECOVERY="passed"

phase "completed"
log "P2P partition recovery test PASSED"
