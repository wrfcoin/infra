#!/usr/bin/env bash
# Reset a non-seed testnet node and resync it from the canonical genesis.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUT_PINS_FILE="${CUT_PINS_FILE:-${SCRIPT_DIR}/../cut-pins.env}"
if [ ! -f "${CUT_PINS_FILE}" ]; then
  printf 'ERROR: canonical cut pins not found: %s\n' "${CUT_PINS_FILE}" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../cut-pins.env
. "${CUT_PINS_FILE}"
: "${WRFCOIN_CUT_GENESIS_HASH:?cut-pins.env does not define WRFCOIN_CUT_GENESIS_HASH}"

readonly CANONICAL_GENESIS_HASH="0x${WRFCOIN_CUT_GENESIS_HASH#0x}"
readonly CANONICAL_NETWORK_ID="testnet"
readonly CANONICAL_CHAIN_ID="${WRFCOIN_CHAIN_ID:-${WRFCOIN_CUT_CHAIN_ID:-777}}"
[[ "$CANONICAL_CHAIN_ID" == "${WRFCOIN_CUT_CHAIN_ID:-777}" ]] || { echo "ERROR: configured chain differs from cut pins" >&2; exit 1; }
readonly CANONICAL_BOOTSTRAP_PEER_ID="12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr"

P2P_GUARD="${SCRIPT_DIR}/../check-p2p-external-addr.sh"
SERVICE="wrfcoin-node"
NODE_CONTAINER="${WRFCOIN_NODE_CONTAINER:-wrfcoin-testnet-node}"
NODE_IMAGE=""
NODE_API="${NODE_API:-http://127.0.0.1:8556}"
RESET_TIMEOUT_SECS="${RESET_TIMEOUT_SECS:-600}"
P2P_EXTERNAL_ADDR=""
CONFIRM=0
RESET_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

usage() {
  cat <<'EOF'
Usage:
  bash testnet/scripts/reset-node-from-genesis.sh --confirm

Options:
  --confirm              Required acknowledgement of the chain-state reset.
  --service NAME         Node service to reset (default: wrfcoin-node).
  --container NAME       Running node container (default: wrfcoin-testnet-node).
  --node-api URL         Local launch_api URL (default: http://127.0.0.1:8556).
  --timeout SECONDS      Maximum time for each sync phase (default: 600).

The script operates on the existing container so its exact Compose-created
configuration, secrets, named volumes, and bind mounts are preserved.
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

require_p2p_guard() {
  "${P2P_GUARD}" --require "${P2P_EXTERNAL_ADDR}"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm)
        CONFIRM=1
        shift
        ;;
      --service)
        [ "$#" -ge 2 ] || die "--service requires a value" || return 2
        SERVICE="$2"
        shift 2
        ;;
      --container)
        [ "$#" -ge 2 ] || die "--container requires a value" || return 2
        NODE_CONTAINER="$2"
        shift 2
        ;;
      --node-api)
        [ "$#" -ge 2 ] || die "--node-api requires a value" || return 2
        NODE_API="${2%/}"
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || die "--timeout requires a value" || return 2
        RESET_TIMEOUT_SECS="$2"
        shift 2
        ;;
      -h|--help)
        usage
        return 10
        ;;
      *)
        die "unknown argument: $1" || return 2
        ;;
    esac
  done
}

container_env_value() {
  local env_json="$1"
  local name="$2"
  jq -r --arg prefix "${name}=" '
    [.[] | select(startswith($prefix)) | ltrimstr($prefix)] | last // ""
  ' <<<"${env_json}"
}

validate_container_env_json() {
  local env_json="$1"
  local network_id chain_id bootstrap
  network_id="$(container_env_value "${env_json}" WRFCOIN_NETWORK_ID)"
  chain_id="$(container_env_value "${env_json}" WRFCOIN_CHAIN_ID)"
  bootstrap="$(container_env_value "${env_json}" WRFCOIN_P2P_BOOTSTRAP)"

  [ "${network_id}" = "${CANONICAL_NETWORK_ID}" ] \
    || { die "${SERVICE} network_id is ${network_id:-unset}, expected ${CANONICAL_NETWORK_ID}"; return 1; }
  [ "${chain_id}" = "${CANONICAL_CHAIN_ID}" ] \
    || { die "${SERVICE} chain_id is ${chain_id:-unset}, expected ${CANONICAL_CHAIN_ID}"; return 1; }
  [ -n "${bootstrap}" ] \
    || { die "${SERVICE} has no bootstrap peer configured"; return 1; }
  case "${bootstrap}" in
    *"/p2p/${CANONICAL_BOOTSTRAP_PEER_ID}"*) ;;
    *)
      die "${SERVICE} is not pinned to the canonical bootstrap peer"
      return 1
      ;;
  esac
}

preflight() {
  local command env_json running
  [ "${CONFIRM}" -eq 1 ] \
    || { die "re-run with --confirm after reading the operator guide"; return 1; }
  [ "${SERVICE}" = "wrfcoin-node" ] \
    || {
      die "refusing to reset ${SERVICE}; only the recoverable wrfcoin-node service is allowed"
      return 1
    }
  case "${RESET_TIMEOUT_SECS}" in
    ''|*[!0-9]*)
      die "--timeout must be a positive integer"
      return 1
      ;;
    0)
      die "--timeout must be greater than zero"
      return 1
      ;;
  esac
  for command in docker curl jq; do
    command -v "${command}" >/dev/null 2>&1 \
      || { die "missing required command: ${command}"; return 1; }
  done

  env_json="$(docker inspect "${NODE_CONTAINER}" --format '{{json .Config.Env}}')"
  validate_container_env_json "${env_json}"
  P2P_EXTERNAL_ADDR="$(container_env_value "${env_json}" WRFCOIN_P2P_EXTERNAL_ADDR)"
  require_p2p_guard
  running="$(docker inspect "${NODE_CONTAINER}" --format '{{.State.Running}}')"
  [ "${running}" = "true" ] \
    || { die "${NODE_CONTAINER} is not running; preserve state and diagnose before reset"; return 1; }
  NODE_IMAGE="$(docker inspect "${NODE_CONTAINER}" --format '{{.Config.Image}}')"
  [ -n "${NODE_IMAGE}" ] \
    || { die "could not resolve image for ${NODE_CONTAINER}"; return 1; }
}

read_node_info() {
  curl -fsS --max-time 5 "${NODE_API}/network/info"
}

wait_for_health() {
  local deadline
  deadline=$(( $(date +%s) + RESET_TIMEOUT_SECS ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if curl -fsS --max-time 5 "${NODE_API}/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_genesis_import() {
  local deadline payload height peers
  deadline=$(( $(date +%s) + RESET_TIMEOUT_SECS ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    payload="$(read_node_info 2>/dev/null || true)"
    payload="${payload:-"{}"}"
    height="$(jq -r '.chain_height // 0' <<<"${payload}" 2>/dev/null || printf '0')"
    peers="$(jq -r '.peer_count // 0' <<<"${payload}" 2>/dev/null || printf '0')"
    if [ "${height}" -ge 1 ] && [ "${peers}" -ge 1 ]; then
      log "canonical seed supplied block 1; current height=${height}, peers=${peers}"
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_for_canonical_identity() {
  local deadline payload genesis network chain height peers
  deadline=$(( $(date +%s) + RESET_TIMEOUT_SECS ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    payload="$(read_node_info 2>/dev/null || true)"
    payload="${payload:-"{}"}"
    genesis="$(jq -r '.genesis_hash // ""' <<<"${payload}" 2>/dev/null || true)"
    network="$(jq -r '.network_id // ""' <<<"${payload}" 2>/dev/null || true)"
    chain="$(jq -r '.chain_id // ""' <<<"${payload}" 2>/dev/null || true)"
    height="$(jq -r '.chain_height // 0' <<<"${payload}" 2>/dev/null || printf '0')"
    peers="$(jq -r '.peer_count // 0' <<<"${payload}" 2>/dev/null || printf '0')"
    if [ "${genesis}" = "${CANONICAL_GENESIS_HASH}" ] \
      && [ "${network}" = "${CANONICAL_NETWORK_ID}" ] \
      && [ "${chain}" = "${CANONICAL_CHAIN_ID}" ] \
      && [ "${height}" -ge 1 ] \
      && [ "${peers}" -ge 1 ]; then
      printf '%s\n' "${payload}"
      return 0
    fi
    sleep 2
  done
  return 1
}

archive_chain_state() {
  docker run --rm --volumes-from "${NODE_CONTAINER}" --entrypoint /bin/sh "${NODE_IMAGE}" -c '
    set -eu
    stamp="$1"
    backup="/app/data/reset-backups/${stamp}"
    test -d "${backup}"
    for file in wrfcoin.redb equivocation_evidence.redb; do
      if [ -e "/app/data/${file}" ]; then
        mv "/app/data/${file}" "${backup}/${file}"
      fi
    done
    test -f "${backup}/wrfcoin.redb"
  ' sh "${RESET_STAMP}"
}

reserve_archive_directory() {
  docker run --rm --volumes-from "${NODE_CONTAINER}" --entrypoint /bin/sh "${NODE_IMAGE}" -c '
    set -eu
    stamp="$1"
    base="/app/data/reset-backups"
    mkdir -p "${base}"
    # Bounded: every mkdir failure used to be treated as a name collision, so
    # a non-collision error (EACCES/ENOSPC/EROFS) spun this loop forever with
    # the node already stopped. Cap it so those fail fast and run_reset can
    # restart the original node.
    suffix=0
    while [ "${suffix}" -le 100 ]; do
      candidate="${stamp}"
      if [ "${suffix}" -gt 0 ]; then
        candidate="${stamp}-${suffix}"
      fi
      if mkdir "${base}/${candidate}" 2>/dev/null; then
        printf "%s\\n" "${candidate}"
        exit 0
      fi
      suffix=$((suffix + 1))
    done
    printf "reset-backups is not writable, out of space, or has 100+ archive-name collisions; refusing to archive\\n" >&2
    exit 1
  ' sh "${RESET_STAMP}"
}

restore_chain_state() {
  docker run --rm --volumes-from "${NODE_CONTAINER}" --entrypoint /bin/sh "${NODE_IMAGE}" -c '
    set -eu
    stamp="$1"
    backup="/app/data/reset-backups/${stamp}"
    for file in wrfcoin.redb equivocation_evidence.redb; do
      if [ -e "${backup}/${file}" ]; then
        mv -f "${backup}/${file}" "/app/data/${file}"
      fi
    done
    test -f /app/data/wrfcoin.redb
  ' sh "${RESET_STAMP}"
}

rollback() {
  log "reset failed; restoring archived chain state ${RESET_STAMP}"
  docker stop "${NODE_CONTAINER}" >/dev/null 2>&1 || true
  if restore_chain_state; then
    if ! require_p2p_guard; then
      log "rollback guard rejected; node remains stopped and archive is retained"
      return 1
    fi
    docker start "${NODE_CONTAINER}" >/dev/null
    wait_for_health || true
    log "rollback restored the pre-reset chain database"
  else
    log "automatic rollback failed; archive remains at /app/data/reset-backups/${RESET_STAMP}"
  fi
}

run_reset() {
  local before after
  preflight
  before="$(read_node_info 2>/dev/null || printf '{}')"
  log "pre-reset identity: $(jq -c '{network_id,chain_id,genesis_hash,chain_height,peer_count}' <<<"${before}")"

  log "stopping ${SERVICE}"
  docker stop "${NODE_CONTAINER}" >/dev/null
  if ! RESET_STAMP="$(reserve_archive_directory)"; then
    if ! require_p2p_guard; then
      die "P2P guard rejected before archive-recovery restart; original state remains stopped"
      return 1
    fi
    docker start "${NODE_CONTAINER}" >/dev/null || true
    die "could not reserve a unique archive directory; original state was not removed"
    return 1
  fi
  if ! archive_chain_state; then
    rollback
    die "could not archive wrfcoin.redb; archived state was restored"
    return 1
  fi
  log "archived chain databases under /app/data/reset-backups/${RESET_STAMP}"

  if ! require_p2p_guard; then
    rollback
    die "P2P guard rejected before empty-chain start"
    return 1
  fi
  if ! docker start "${NODE_CONTAINER}" >/dev/null; then
    rollback
    die "node failed to start with empty chain state"
    return 1
  fi
  if ! wait_for_genesis_import; then
    rollback
    die "node did not import block 1 from the canonical bootstrap peer"
    return 1
  fi

  # genesis_hash is cached at launch_api boot. Restart after block 1 arrives so
  # the boot-time #2035 assertion resolves and verifies the imported identity.
  log "restarting ${SERVICE} for boot-time canonical genesis verification"
  if ! require_p2p_guard; then
    rollback
    die "P2P guard rejected before post-genesis restart"
    return 1
  fi
  if ! docker restart "${NODE_CONTAINER}" >/dev/null; then
    rollback
    die "node restart failed after genesis import"
    return 1
  fi
  if ! after="$(wait_for_canonical_identity)"; then
    rollback
    die "node did not return with the canonical genesis identity"
    return 1
  fi

  log "PASS: canonical genesis restored"
  printf '%s\n' "${after}" | jq '{
    network_id, chain_id, genesis_hash, chain_height, peer_count, sync_status
  }'
  log "rollback archive retained at /app/data/reset-backups/${RESET_STAMP}"
}

main() {
  local parse_status=0
  parse_args "$@" || parse_status=$?
  if [ "${parse_status}" -eq 10 ]; then
    return 0
  fi
  [ "${parse_status}" -eq 0 ] || return "${parse_status}"
  run_reset
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
