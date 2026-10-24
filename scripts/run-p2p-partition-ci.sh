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
HSM_MODULE="/usr/lib/softhsm/libsofthsm2.so"
HSM_TOKEN_LABEL="wrfcoin-validator"
HSM_KEY_LABEL="wrfcoin-signing-key"
OPERATOR_TOKEN="${WRFCOIN_OPERATOR_TOKEN:-dev-operator-token}"
SETUP_TIMEOUT_SECONDS="${P2P_PARTITION_SETUP_TIMEOUT_SECONDS:-60}"
BASELINE_SYNC_TIMEOUT_SECONDS="${P2P_PARTITION_BASELINE_SYNC_TIMEOUT_SECONDS:-120}"
RECOVERY_TIMEOUT_SECONDS="${P2P_PARTITION_RECOVERY_TIMEOUT_SECONDS:-120}"
PARTITION_HOLD_SECONDS="${P2P_PARTITION_HOLD_SECONDS:-10}"
NETWORK_NAME="${P2P_PARTITION_NETWORK_NAME:-wrfcoin-p2p-partition-${GITHUB_RUN_ID:-$$}}"
CONTAINER_PREFIX="${P2P_PARTITION_CONTAINER_PREFIX:-wrf-node-${GITHUB_RUN_ID:-$$}}"
DRY_RUN=0
# linear: only the isolated node mines, so the heal is a catch-up (blocking gate).
# fork:   both sides mine, so the heal needs a follower to reorganise (known gap).
SCENARIO="${P2P_PARTITION_SCENARIO:-linear}"

PHASE_BASELINE="pending"
PHASE_PARTITION="pending"
PHASE_RECOVERY="pending"
PHASE_TEARDOWN="pending"
LAST_ERROR=""
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

CONTAINERS=()
CLEANUP_ACTIONS=()
SCRATCH_DIR=""
GENESIS_PRODUCER_SET=""
GENESIS_HASH=""
# A dedicated network id: "testnet" would select core4's compiled-in testnet
# genesis hash, which a throwaway chain can never match. Chain id stays 777.
NETWORK_ID="${P2P_PARTITION_NETWORK_ID:-ci-p2p-partition}"
NODE_RUST_LOG="${P2P_PARTITION_RUST_LOG:-info}"

usage() {
  cat <<'EOF'
Usage: run-p2p-partition-ci.sh [--artifact-dir PATH] [--image IMAGE] [--scenario linear|fork] [--dry-run]

Options:
  --artifact-dir PATH   Write logs and summaries under PATH.
  --image IMAGE         Docker image to use for peer containers.
  --scenario NAME       linear (default): only node-c mines while isolated.
                        fork: node-a and node-c both mine (divergent chains).
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
    --scenario) SCENARIO="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "$SCENARIO" in
  linear|fork) ;;
  *) echo "Unknown scenario: $SCENARIO (expected linear or fork)" >&2; exit 1 ;;
esac

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
- Scenario: ${SCENARIO}

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
        printf '\n--- docker logs --tail 400: %s ---\n' "$container"
        docker logs --tail 400 "$container" 2>&1 || true
      done
    } | tee "$REPORT_DIR/node-logs.txt" || true
  fi

  for container in "${CONTAINERS[@]:-}"; do
    docker rm -f "$container" >/dev/null 2>&1 || true
    record_cleanup_action "removed container ${container}"
  done

  docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
  record_cleanup_action "removed network ${NETWORK_NAME}"

  if [ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ]; then
    # The token dirs are chowned to the node user inside the image, so remove
    # them through the image rather than needing host sudo.
    docker run --rm --user 0 --entrypoint sh -v "$SCRATCH_DIR:/scratch" "$IMAGE" \
      -c 'rm -rf /scratch/*' >/dev/null 2>&1 || true
    rm -rf "$SCRATCH_DIR" 2>/dev/null || true
    record_cleanup_action "removed throwaway HSM tokens"
  fi

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
  api_call "$1" GET "/network/info" | jq -r '.chain_height // 0'
}

# The coinbase must pay the producer's declared payout address (#2290), so the
# miner address is the one provision_cluster put in the genesis set for the node.
payout_address_for() {
  case "$1" in
    node-a) echo 0x0000000000000000000000000000000000000001 ;;
    node-b) echo 0x0000000000000000000000000000000000000002 ;;
    node-c) echo 0x0000000000000000000000000000000000000003 ;;
    *) return 1 ;;
  esac
}

mine_block() {
  log "Mining block on $1..."
  api_call "$1" POST "/blocks/mine" "{\"miner_address\":\"$(payout_address_for "$1")\"}" > /dev/null
}

wait_for_health() {
  local name="$1"
  local timeout="$2"
  local started
  started="$(date +%s)"

  while true; do
    local resp
    resp=$(api_call "$name" GET "/health" 2>/dev/null || echo '{"status":"down"}')
    if [[ "$resp" == *'"status":"ok"'* ]]; then
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

# The release node signs blocks only through the PKCS#11 path (the key-file and
# hex-env signers are debug_assertions-only). Each node therefore gets its own
# throwaway SoftHSM2 token, created with the tooling inside the image under test
# so the module and the token format are the ones the node will load. Only the
# public key leaves the token; PINs are random per run and live in a 0600 file.
provision_token() {
  local name="$1"
  local dir="$SCRATCH_DIR/$name"
  mkdir -p "$dir"

  docker run --rm --user 0 --entrypoint sh \
    --env-file "$PIN_FILE" -v "$dir:/app/data/hsm" "$IMAGE" -c '
      set -eu
      mkdir -p /app/data/hsm/tokens
      printf "directories.tokendir = /app/data/hsm/tokens\nobjectstore.backend = file\nlog.level = ERROR\n" \
        > /app/data/hsm/softhsm2.conf
      export SOFTHSM2_CONF=/app/data/hsm/softhsm2.conf
      softhsm2-util --init-token --free --label "'"$HSM_TOKEN_LABEL"'" \
        --pin "$WRFCOIN_HSM_PIN" --so-pin "$WRFCOIN_HSM_SO_PIN" >/dev/null
      pkcs11-tool --module "'"$HSM_MODULE"'" --login --pin env:WRFCOIN_HSM_PIN \
        --token-label "'"$HSM_TOKEN_LABEL"'" --keypairgen --key-type EC:edwards25519 \
        --label "'"$HSM_KEY_LABEL"'" --id 01 >/dev/null
      chown -R 1001:1001 /app/data/hsm
      pkcs11-tool --module "'"$HSM_MODULE"'" --token-label "'"$HSM_TOKEN_LABEL"'" \
        --read-object --type pubkey --label "'"$HSM_KEY_LABEL"'" | sed "/-----/d" | base64 -d | tail -c 32 | od -An -tx1 | tr -d " \n"
    ' 2>"$dir.err" || { echo "token provisioning failed for $name (stderr below, no secrets):" >&2; sed 's/--pin [^ ]*/--pin ***/' "$dir.err" >&2; return 1; }
}

provision_cluster() {
  SCRATCH_DIR="$(mktemp -d)"
  PIN_FILE="$SCRATCH_DIR/pins.env"
  ( umask 077
    printf 'WRFCOIN_HSM_PIN=%s\nWRFCOIN_HSM_SO_PIN=%s\n' \
      "$(od -An -N8 -tu8 /dev/urandom | tr -d ' \n')" "$(od -An -N8 -tu8 /dev/urandom | tr -d ' \n')" > "$PIN_FILE" )

  local members="" idx=0 name pub
  for name in node-a node-b node-c; do
    idx=$((idx + 1))
    pub="$(provision_token "$name")"
    if ! [[ "$pub" =~ ^[0-9a-f]{64}$ ]]; then
      LAST_ERROR="could not read a 32-byte ed25519 public key for $name from its SoftHSM token"
      return 1
    fi
    log "$name producer public key: $pub"
    members+="{\"producer_id\":\"ci-$name\",\"payout_address\":\"0x$(printf '%040x' "$idx")\",\"public_key\":\"$pub\"},"
  done
  GENESIS_PRODUCER_SET="{\"version\":1,\"members\":[${members%,}]}"
  log "genesis producer set: $GENESIS_PRODUCER_SET"
}

start_node() {
  local name="$1"
  local p2p_port="$2"
  local bootstrap="$3"
  local container_name="${CONTAINER_PREFIX}-${name}"

  local extra=()
  if [ -n "$GENESIS_HASH" ]; then
    extra+=(-e "WRFCOIN_GENESIS_HASH=$GENESIS_HASH")
  fi
  if [ "$name" = node-a ]; then
    # node-a's chain must survive the restart that pins its own genesis hash.
    mkdir -p "$SCRATCH_DIR/node-a-data"
    chmod 0777 "$SCRATCH_DIR/node-a-data"
    extra+=(-v "$SCRATCH_DIR/node-a-data:/app/data")
  fi

  log "Starting node $name..."
  docker run -d \
    --name "$container_name" \
    --network "$NETWORK_NAME" \
    -e WRFCOIN_CHAIN_ID=777 \
    -e WRFCOIN_NETWORK_ID="$NETWORK_ID" \
    -e ALLOW_UNENCRYPTED_STORAGE=true \
    -e WRFCOIN_P2P_ENABLED=true \
    -e WRFCOIN_P2P_PORT="$p2p_port" \
    -e WRFCOIN_P2P_BOOTSTRAP="$bootstrap" \
    -e WRFCOIN_OPERATOR_TOKEN="$OPERATOR_TOKEN" \
    -e WRFCOIN_GENESIS_PRODUCER_SET="$GENESIS_PRODUCER_SET" \
    -e WRFCOIN_REQUIRE_PRODUCER_AUTH=1 \
    -e WRFCOIN_GENESIS_FAUCET_ADDRESS=0x2727272727272727272727272727272727272727 \
    -e WRFCOIN_GENESIS_ORACLE_SET=none \
    -e RUST_LOG="$NODE_RUST_LOG" \
    -e WRFCOIN_P2P_BOOTSTRAP_REDIAL_INTERVAL_SECS=5 \
    --env-file "$PIN_FILE" \
    -v "$SCRATCH_DIR/$name:/app/data/hsm" \
    "${extra[@]}" \
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

phase "provisioning SoftHSM producer tokens"
provision_cluster

phase "starting cluster"
# Node A (seed)
start_node node-a 9000 ""
# The genesis block (height 1) folds in a wall-clock timestamp, so the hash of
# this throwaway chain only exists once its first block does. Let node-a build
# it, read back the hash the node itself computed, then pin that hash on every
# node. Pinning is what makes the P2P genesis handshake a real check here.
wait_for_health node-a "$SETUP_TIMEOUT_SECONDS"
mine_block node-a
GENESIS_HASH="$(api_call node-a GET /network/info | jq -r '[.. | .genesis_hash? | strings] | first // empty')"
GENESIS_HASH="${GENESIS_HASH#0x}"
if ! [[ "$GENESIS_HASH" =~ ^[0-9a-f]{64}$ ]] || [[ "$GENESIS_HASH" =~ ^0+$ ]]; then
  LAST_ERROR="node-a did not report a usable genesis hash after block 1"
  exit 1
fi
log "throwaway chain genesis hash (computed by node-a): $GENESIS_HASH"
docker rm -f "${CONTAINER_PREFIX}-node-a" >/dev/null
start_node node-a 9000 ""
# libp2p only dials a bootstrap address that names the peer; node-a's identity
# persists in its data dir across the restart above.
PEER_ID_A="$(tr -d '[:space:]' < "$SCRATCH_DIR/node-a-data/peer_id.txt")"
if ! [[ "$PEER_ID_A" =~ ^12D3KooW[A-Za-z0-9]+$ ]]; then
  LAST_ERROR="could not read node-a's peer id"
  exit 1
fi
# WRFCOIN_P2P_BOOTSTRAP is comma-separated. Offer the container IP as well as the
# DNS name, so a name-resolution problem cannot hide a dial problem.
IP_A="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK_NAME\").IPAddress}}" "${CONTAINER_PREFIX}-node-a")"
BOOTSTRAP_A="/ip4/${IP_A}/tcp/9000/p2p/${PEER_ID_A},/dns4/node-a/tcp/9000/p2p/${PEER_ID_A}"
log "node-a bootstrap addresses: $BOOTSTRAP_A"
# Node B and node C both bootstrap from node-a, so isolating C leaves A-B intact.
start_node node-b 9000 "$BOOTSTRAP_A"
start_node node-c 9000 "$BOOTSTRAP_A"

phase "baseline readiness"
PHASE_BASELINE="running"
wait_for_health node-a "$SETUP_TIMEOUT_SECONDS"
wait_for_health node-b "$SETUP_TIMEOUT_SECONDS"
wait_for_health node-c "$SETUP_TIMEOUT_SECONDS"
# Partition only a cluster that already agrees on the chain; otherwise node-c
# would mine its own block 1 and the "heal" would be a fork, not a re-sync.
log "Waiting for node-b and node-c to sync node-a's chain..."
started="$(date +%s)"
while true; do
  HEIGHT_A=$(get_height node-a)
  if [ "$HEIGHT_A" -ge 1 ] && [ "$(get_height node-b)" -eq "$HEIGHT_A" ] && [ "$(get_height node-c)" -eq "$HEIGHT_A" ]; then
    log "Baseline synced at height $HEIGHT_A"
    break
  fi
  if [ $(( $(date +%s) - started )) -ge "$BASELINE_SYNC_TIMEOUT_SECONDS" ]; then
    LAST_ERROR="node-b/node-c did not sync node-a's chain within ${BASELINE_SYNC_TIMEOUT_SECONDS}s"
    exit 1
  fi
  sleep 5
done
PHASE_BASELINE="passed"

phase "simulating partition (isolate node-c)"
PHASE_PARTITION="running"
docker network disconnect "$NETWORK_NAME" "${CONTAINER_PREFIX}-node-c"
record_cleanup_action "disconnected node-c"

# Mine blocks on both sides of the partition
if [ "$SCENARIO" = fork ]; then
  mine_block node-a
fi
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
