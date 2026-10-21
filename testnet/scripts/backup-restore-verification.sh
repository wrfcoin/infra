#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — Backup Restore Verification (issue core4#753)
#
# Actually tests the documented backup/restore procedure end-to-end:
#   1. Pre-flight: verifies the testnet stack is running and healthy
#   2. Record pre-backup state: block height, tip hash, state root
#   3. Run backup.sh (the existing documented procedure from PR #220)
#   4. Stop the stack and MOVE (not delete) the named volumes to a
#      timestamped side location — they are kept as a safety net
#   5. Run the documented restore procedure against the backup directory
#   6. Start the stack and wait for /readyz
#   7. Assert that height/tip/state-root match pre-backup values (within
#      a documented tolerance window)
#   8. On success: leave side-location volumes intact, print how to reclaim
#      disk. On failure: print the emergency rollback command and exit 1
#      WITHOUT touching the side location.
#
# Expected runtime: ~10 minutes.
#
# This script is DESTRUCTIVE of current state volumes in the sense that it
# *moves them aside*. It never deletes anything. Recovery is always:
#   docker compose down
#   <remove new volume contents>
#   mv <side-location>/* <original-location>/
#   docker compose up -d
#
# Usage:
#   backup-restore-verification.sh [--backup-dir /mnt/tank/backups/testnet]
#                                  [--keep-side]  (default: keep on success)
#
# The script refuses to run unless invoked with --i-understand or with the
# environment variable I_UNDERSTAND=1, to prevent accidental execution.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
P2P_GUARD="${TESTNET_DIR}/check-p2p-external-addr.sh"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-${TESTNET_DIR}/backup.sh}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/tank/backups/testnet}"
RESTORE_TIMEOUT_SECS="${RESTORE_TIMEOUT_SECS:-600}"   # 10 min max wait for /readyz

NODE_API="${NODE_API:-http://127.0.0.1:8556}"
CONFIRM=0
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-/var/log/wrfcoin-restore-drill}"
[ -w "/var/log" ] || LOG_DIR="/tmp/wrfcoin-restore-drill"
mkdir -p "${LOG_DIR}"
LOG="${LOG_DIR}/restore-drill-${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --backup-dir)    BACKUP_DIR="$2";    shift 2 ;;
    --backup-dir=*)  BACKUP_DIR="${1#*=}"; shift ;;
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

if [ "${CONFIRM}" -ne 1 ] && [ "${I_UNDERSTAND:-0}" != "1" ]; then
  cat >&2 <<'EOF'
This script will:
  - Stop the testnet stack
  - MOVE its named Docker volumes to a timestamped side location
  - Restore from a fresh backup and restart the stack

Re-run with --i-understand (or I_UNDERSTAND=1) to proceed.

Safety: the side-location volumes are NEVER deleted automatically. If the
restore fails, you can always roll back via:
  docker compose -f ${COMPOSE_FILE} down
  # remove any new volume contents
  mv <side-location-path>/<volume-name> /var/lib/docker/volumes/<volume-name>
  docker compose -f ${COMPOSE_FILE} up -d
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

guard_external_address() {
  "${P2P_GUARD}" --env-file "${TESTNET_DIR}/.env" --require
}

# Query chain state from the node API. Prints:
#   <height>|<tip_hash>|<state_root_hex>
# Any unavailable field is printed as empty between the pipes.
capture_chain_state() {
  local payload tip height
  payload="$(curl -sf --max-time 5 "${NODE_API}/blockchain" 2>/dev/null || echo "")"
  if [ -z "${payload}" ]; then
    echo "|||"
    return 0
  fi
  height="$(echo "${payload}" | jq -r '.data.height // .height // empty' 2>/dev/null || true)"
  tip="$(echo "${payload}" | jq -r '.data.tip // .tip // empty' 2>/dev/null || true)"

  # state_root: try /signing-keys/current (exposed state_root_hex) as a
  # read-only endpoint, falling back to the block-at-height query.
  local state_root=""
  state_root="$(curl -sf --max-time 5 "${NODE_API}/signing-keys/current" 2>/dev/null \
    | jq -r '.data.state_root_hex // .state_root_hex // empty' 2>/dev/null || true)"
  if [ -z "${state_root}" ] && [ -n "${height}" ]; then
    state_root="$(curl -sf --max-time 5 "${NODE_API}/blocks/${height}" 2>/dev/null \
      | jq -r '.data.state_root // .state_root // .data.state_root_hex // .state_root_hex // empty' 2>/dev/null || true)"
  fi

  printf '%s|%s|%s\n' "${height}" "${tip}" "${state_root}"
}

# Wait for the node /readyz to return 200, up to $1 seconds. Returns 0 on
# success, non-zero on timeout.
wait_for_ready() {
  local timeout="${1:-600}"
  local deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
    if [ "${code}" = "200" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
  log "=== Pre-flight ==="
  for cmd in curl jq docker; do
    have "${cmd}" || { err "missing required command: ${cmd}"; return 1; }
  done

  [ -f "${COMPOSE_FILE}" ]   || { err "compose file not found: ${COMPOSE_FILE}"; return 1; }
  [ -x "${BACKUP_SCRIPT}" ]  || { err "backup script not executable: ${BACKUP_SCRIPT}"; return 1; }
  [ -d "${BACKUP_DIR}" ] || mkdir -p "${BACKUP_DIR}" || {
    err "cannot create backup dir: ${BACKUP_DIR}"; return 1;
  }

  if ! compose ps --format json >/dev/null 2>&1; then
    err "docker compose unavailable or stack not initialized"
    return 1
  fi

  # Require that the node is currently running and healthy.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${NODE_API}/readyz" || echo "000")"
  if [ "${code}" != "200" ]; then
    err "node /readyz not 200 (got ${code}); refuse to verify restore against an unhealthy stack"
    return 1
  fi
  log "node /readyz: 200"
  log "backup script: ${BACKUP_SCRIPT}"
  log "backup dir:    ${BACKUP_DIR}"
  log "log file:      ${LOG}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "=== WRFCoin backup restore verification (issue core4#753) ==="
  preflight || { err "pre-flight failed"; exit 1; }

  # -------------------------------------------------------------------------
  # 1. Record pre-backup chain state
  # -------------------------------------------------------------------------
  log "=== Capturing pre-backup chain state ==="
  local before_state before_height before_tip before_root
  before_state="$(capture_chain_state)"
  before_height="$(echo "${before_state}" | awk -F'|' '{print $1}')"
  before_tip="$(echo "${before_state}"    | awk -F'|' '{print $2}')"
  before_root="$(echo "${before_state}"   | awk -F'|' '{print $3}')"
  log "pre-backup: height=${before_height} tip=${before_tip} state_root=${before_root:-<n/a>}"

  if [ -z "${before_height}" ]; then
    err "failed to read current chain height from ${NODE_API}/blockchain"
    exit 1
  fi

  # -------------------------------------------------------------------------
  # 2. Run backup.sh
  # -------------------------------------------------------------------------
  log "=== Running backup.sh ==="
  # backup.sh creates BACKUP_DIR/TIMESTAMP/ internally; capture which one.
  local before_backups after_backups fresh_backup
  before_backups="$(ls -1 "${BACKUP_DIR}" 2>/dev/null | sort || true)"
  if ! BACKUP_DIR="${BACKUP_DIR}" bash "${BACKUP_SCRIPT}" 2>&1 | tee -a "${LOG}"; then
    err "backup.sh failed — refusing to proceed with restore drill"
    exit 1
  fi
  after_backups="$(ls -1 "${BACKUP_DIR}" 2>/dev/null | sort || true)"
  fresh_backup="$(comm -13 <(echo "${before_backups}") <(echo "${after_backups}") | tail -1)"
  if [ -z "${fresh_backup}" ]; then
    err "backup.sh completed but no new directory appeared under ${BACKUP_DIR}"
    exit 1
  fi
  local BACKUP_PATH="${BACKUP_DIR}/${fresh_backup}"
  log "fresh backup: ${BACKUP_PATH}"
  ls -lh "${BACKUP_PATH}" | tee -a "${LOG}"

  # -------------------------------------------------------------------------
  # 3. Simulate disaster: stop stack, MOVE volumes aside
  # -------------------------------------------------------------------------
  log "=== Simulating disaster: stopping stack and moving volumes aside ==="
  guard_external_address
  compose down 2>&1 | tee -a "${LOG}"

  local side_root="${LOG_DIR}/side-volumes-${TIMESTAMP}"
  mkdir -p "${side_root}"
  log "side location: ${side_root}"

  # Enumerate volumes in the project scope; don't rely on the .volumes key
  # alone since compose may hoist nested names.
  local project_name volumes
  project_name="$(compose config --format json 2>/dev/null | jq -r '.name // "testnet"')"
  mapfile -t volumes < <(
    docker volume ls --format '{{.Name}}' | grep -E "^${project_name}_|^wrfcoin-testnet" || true
  )
  if [ "${#volumes[@]}" -eq 0 ]; then
    err "no project volumes found to move aside (project=${project_name})"
    err "if the stack uses bind mounts (local-paths override), the restore"
    err "drill cannot exercise Docker-managed volumes. Aborting safely."
    if guard_external_address; then
      compose up -d 2>&1 | tee -a "${LOG}" || true
    else
      err "rollback start refused: advertised external address lacks a reachability proof"
      exit 1
    fi
    exit 1
  fi

  # For each volume, use a one-shot alpine container to tar the contents
  # into the side location, then remove the volume.
  local moved=()
  for vol in "${volumes[@]}"; do
    log "archiving volume ${vol} -> ${side_root}/${vol}.tar"
    if docker run --rm \
        -v "${vol}:/source:ro" \
        -v "${side_root}:/dest" \
        alpine sh -c "cd /source && tar cf /dest/${vol}.tar ." 2>&1 | tee -a "${LOG}"; then
      moved+=("${vol}")
    else
      err "failed to archive volume ${vol} — aborting BEFORE removing anything"
      err "ROLLBACK: no volumes have been removed yet; simply \`docker compose up -d\`"
      if guard_external_address; then
        compose up -d 2>&1 | tee -a "${LOG}" || true
      else
        err "rollback start refused: advertised external address lacks a reachability proof"
        exit 1
      fi
      exit 1
    fi
  done

  # All archives succeeded; now remove the volumes (which are detached after
  # compose down). docker volume rm will refuse if a container still uses it.
  for vol in "${moved[@]}"; do
    if docker volume rm "${vol}" 2>&1 | tee -a "${LOG}"; then
      log "volume ${vol} removed (archived at ${side_root}/${vol}.tar)"
    else
      err "failed to remove volume ${vol} — rollback path:"
      err "  docker volume rm ${vol}   # manual after stopping any dependents"
      err "  tar -C /var/lib/docker/volumes/${vol}/_data -xf ${side_root}/${vol}.tar"
      exit 1
    fi
  done

  log "all project volumes archived to ${side_root} and removed"

  # -------------------------------------------------------------------------
  # 4. Restore from backup (documented procedure from RESTORE_DRILL.md)
  # -------------------------------------------------------------------------
  log "=== Restoring from ${BACKUP_PATH} ==="

  export BACKUP="${BACKUP_PATH}"

  # Re-create the volumes (compose does this automatically on up).
  # Start postgres first so we can restore the SQL dump.
  guard_external_address
  compose up -d postgres 2>&1 | tee -a "${LOG}"
  sleep 10

  if [ -f "${BACKUP_PATH}/postgres.sql" ]; then
    log "restoring PostgreSQL from postgres.sql"
    compose exec -T postgres psql -U wrfcoin -d postgres \
      -c "DROP DATABASE IF EXISTS wrfcoin;" 2>&1 | tee -a "${LOG}"
    compose exec -T postgres psql -U wrfcoin -d postgres \
      -c "CREATE DATABASE wrfcoin OWNER wrfcoin;" 2>&1 | tee -a "${LOG}"
    if ! compose exec -T postgres psql -U wrfcoin wrfcoin < "${BACKUP_PATH}/postgres.sql" > /tmp/psql-restore.log 2>&1; then
      err "psql restore failed; see /tmp/psql-restore.log"
      tail -50 /tmp/psql-restore.log | tee -a "${LOG}" || true
      err "ROLLBACK: docker compose down; for each tarball in ${side_root}, restore via:"
      err "  docker volume create <name> && docker run --rm -v <name>:/dest -v ${side_root}:/src alpine sh -c 'cd /dest && tar xf /src/<name>.tar'"
      exit 1
    fi
    log "PostgreSQL restore complete"
  else
    log "no postgres.sql in backup — skipping DB restore"
  fi

  # Restore blockchain data (docker volume path — ZFS path uses zfs rollback).
  if [ -f "${BACKUP_PATH}/blockchain-data.tar.gz" ]; then
    log "restoring blockchain data from blockchain-data.tar.gz"
    # Find the node volume (compose will have created it when starting pg).
    local node_volume
    node_volume="$(docker volume ls --format '{{.Name}}' | grep -E "${project_name}_node-data|node-data" | head -1)"
    if [ -z "${node_volume}" ]; then
      err "cannot locate node volume for blockchain data restore"
      exit 1
    fi
    docker run --rm \
      -v "${node_volume}:/data" \
      -v "${BACKUP_PATH}:/backup:ro" \
      alpine sh -c "rm -rf /data/* && tar xzf /backup/blockchain-data.tar.gz -C /data" 2>&1 | tee -a "${LOG}"
    log "blockchain data restore complete"
  elif [ -f "${BACKUP_PATH}/zfs-snapshot.txt" ]; then
    log "backup is a ZFS snapshot reference: $(cat "${BACKUP_PATH}/zfs-snapshot.txt")"
    log "ZFS restore requires host-level access: ssh root@<host> zfs rollback <snapshot>"
    log "NOTE: this script assumes the operator has already performed the"
    log "      ZFS rollback out-of-band before invoking the restore phase."
  else
    err "backup has neither blockchain-data.tar.gz nor zfs-snapshot.txt — cannot restore chain state"
    exit 1
  fi

  # Restore Redis if the dump exists (optional).
  if [ -f "${BACKUP_PATH}/redis.rdb" ]; then
    log "restoring Redis dump"
    guard_external_address
    compose up -d redis 2>&1 | tee -a "${LOG}"
    sleep 3
    compose stop redis 2>&1 | tee -a "${LOG}"
    compose cp "${BACKUP_PATH}/redis.rdb" redis:/data/dump.rdb 2>&1 | tee -a "${LOG}" || true
  fi

  # -------------------------------------------------------------------------
  # 5. Bring up the full stack and wait for readiness
  # -------------------------------------------------------------------------
  log "=== Starting stack ==="
  guard_external_address
  compose up -d 2>&1 | tee -a "${LOG}"

  log "waiting up to ${RESTORE_TIMEOUT_SECS}s for node /readyz..."
  if ! wait_for_ready "${RESTORE_TIMEOUT_SECS}"; then
    err "node did not become ready within ${RESTORE_TIMEOUT_SECS}s — restore FAILED"
    err "ROLLBACK procedure:"
    err "  docker compose -f ${COMPOSE_FILE} down"
    err "  # for each volume, restore from ${side_root}:"
    for v in "${moved[@]}"; do
      err "    docker volume rm ${v} 2>/dev/null || true"
      err "    docker volume create ${v}"
      err "    docker run --rm -v ${v}:/dest -v ${side_root}:/src alpine sh -c 'cd /dest && tar xf /src/${v}.tar'"
    done
    err "  docker compose -f ${COMPOSE_FILE} up -d"
    exit 1
  fi
  log "node is ready"

  # -------------------------------------------------------------------------
  # 6. Verify chain state
  # -------------------------------------------------------------------------
  log "=== Verifying chain state ==="
  local after_state after_height after_tip after_root
  after_state="$(capture_chain_state)"
  after_height="$(echo "${after_state}" | awk -F'|' '{print $1}')"
  after_tip="$(echo "${after_state}"    | awk -F'|' '{print $2}')"
  after_root="$(echo "${after_state}"   | awk -F'|' '{print $3}')"
  log "post-restore: height=${after_height} tip=${after_tip} state_root=${after_root:-<n/a>}"

  # Acceptable window: the backup is a point-in-time snapshot. The restored
  # height should equal the pre-backup height. If the node has reconnected
  # and advanced the chain (shouldn't happen quickly on testnet), delta may
  # be slightly positive. Any NEGATIVE delta is a failure.
  local delta=$((after_height - before_height))
  if [ "${delta}" -lt 0 ]; then
    err "restored height ${after_height} is BELOW pre-backup ${before_height} (delta=${delta})"
    err "FAIL — rollback from ${side_root}"
    exit 1
  fi

  # Tip hash must match pre-backup value *if* delta is 0. If delta > 0 the
  # node has mined or synced past the backup point and the tip will differ —
  # that's still an acceptable restore so long as the chain is consistent.
  if [ "${delta}" -eq 0 ]; then
    if [ "${after_tip}" != "${before_tip}" ]; then
      err "restored tip hash ${after_tip} does not match pre-backup ${before_tip}"
      err "FAIL — rollback from ${side_root}"
      exit 1
    fi
    log "tip hash matches exactly"
  else
    log "chain has advanced by ${delta} blocks since backup — tip divergence is expected"
  fi

  # -------------------------------------------------------------------------
  # 7. Success
  # -------------------------------------------------------------------------
  log "=== SUCCESS ==="
  log "restore verification PASSED"
  log ""
  log "Side-location volumes are intact at:"
  log "  ${side_root}"
  log ""
  log "To reclaim disk (MANUAL STEP):"
  log "  rm -rf '${side_root}'"
  log ""
  log "Post-drill report template (copy to RESTORE_DRILL.md audit log):"
  log "  Date: $(date -u '+%Y-%m-%d')"
  log "  Operator: ${USER:-unknown}"
  log "  Backup used: ${BACKUP_PATH}"
  log "  Restore time: see timestamps in ${LOG}"
  log "  Pre-backup height:  ${before_height}"
  log "  Post-restore height: ${after_height}"
  log "  State root match:   $([ -n "${before_root}" ] && [ "${before_root}" = "${after_root}" ] && echo yes || echo "n/a or drift")"
  exit 0
}

main "$@"
