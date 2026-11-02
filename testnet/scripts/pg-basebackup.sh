#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet - PostgreSQL base backup
#
# What it does:
#   1. Takes a physical base backup with pg_basebackup, using a spread checkpoint
#      and no restart. It connects as the container's own POSTGRES_USER; nothing
#      secret is read on the host or put in an argv.
#   2. Checks the new backup with pg_verifybackup. A backup that fails is removed
#      and the run fails, leaving the older backups alone.
#   3. Keeps only the newest N backups (default: 3). Older ones
#      go only after the new one has passed.
#   4. With --prune-wal, runs pg-wal-prune.sh --apply. Pruning is opt-in, so
#      scheduling backups cannot start deleting WAL before a restore has been
#      proven on that host.
#
# The PITR window runs from the oldest kept base backup to now, so the keep count
# and how often this runs set its length: nightly with 3 kept is about 3 days.
#
# Usage:
#   bash testnet/scripts/pg-basebackup.sh
#   bash testnet/scripts/pg-basebackup.sh --prune-wal
#   PG_BASEBACKUP_KEEP_COUNT=5 bash testnet/scripts/pg-basebackup.sh
#
# Exit: 0 done; 1 failed; 2 usage; 75 another run holds the lock.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
LOCK_FILE="${PG_BASEBACKUP_LOCK:-/run/lock/wrfcoin-pg-basebackup.lock}"
BACKUP_ROOT="/var/lib/postgresql/data/backup"
PRUNE_WAL=0

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

# Reads one named, non-secret key: the environment first, then testnet/.env.
read_env_or_default() {
  local key="$1"
  local default_value="$2"
  local value="${!key:-}"

  if [ -z "${value}" ] && [ -f "${TESTNET_DIR}/.env" ]; then
    value="$(grep -E "^${key}=" "${TESTNET_DIR}/.env" | tail -n1 | cut -d= -f2- || true)"
  fi

  if [ -z "${value}" ]; then
    value="${default_value}"
  fi

  printf '%s' "${value}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prune-wal) PRUNE_WAL=1 ;;
    -h|--help) sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown argument: $1"; exit 2 ;;
  esac
  shift
done

BASE_BACKUP_KEEP_COUNT="$(read_env_or_default BASE_BACKUP_KEEP_COUNT "$(read_env_or_default PG_BASEBACKUP_KEEP_COUNT 3)")"

case "${BASE_BACKUP_KEEP_COUNT}" in
  ''|*[!0-9]*|0|00*) err "BASE_BACKUP_KEEP_COUNT must be a positive integer"; exit 1 ;;
esac

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  err "another base backup is running (lock ${LOCK_FILE})"
  exit 75
fi

log "=== PostgreSQL base backup start ==="
log "Compose file: ${COMPOSE_FILE}"
log "Retention: keep ${BASE_BACKUP_KEEP_COUNT} base backup(s)"

compose ps postgres >/dev/null

# The named volume is created root-owned. The archiver runs as postgres and can
# only write here once these directories belong to it.
compose exec -T --user root postgres sh -ceu \
  "mkdir -p '${BACKUP_ROOT}/base' '${BACKUP_ROOT}/wal' && chown postgres:postgres '${BACKUP_ROOT}' '${BACKUP_ROOT}/base' '${BACKUP_ROOT}/wal'"

BASE_DIR="${BACKUP_ROOT}/base/${TIMESTAMP}"
BACKUP_OK=0

# On any failure, remove the attempt, so a partial directory can't count as a kept
# backup. Only this run's exact directory is touched.
remove_failed_attempt() {
  if [ "${BACKUP_OK}" -ne 1 ]; then
    err "backup failed; removing the incomplete ${BASE_DIR}"
    compose exec -T --user root postgres rm -rf -- "${BASE_DIR}" || true
  fi
}
trap remove_failed_attempt EXIT

log "Running pg_basebackup to ${BASE_DIR} ..."
compose exec -T --user postgres postgres sh -ceu \
  "PGPASSWORD=\"\${POSTGRES_PASSWORD:-}\" pg_basebackup -h 127.0.0.1 -p 5432 -U \"\${POSTGRES_USER}\" -D '${BASE_DIR}' -Fp -Xs -c spread"

log "Verifying ${BASE_DIR} ..."
compose exec -T --user postgres postgres sh -ceu \
  "test -s '${BASE_DIR}/backup_manifest' && test -s '${BASE_DIR}/PG_VERSION' && test -s '${BASE_DIR}/backup_label' && pg_verifybackup -q '${BASE_DIR}'"

# backup-size.txt is not in the manifest, so it is written after verification.
compose exec -T --user postgres postgres sh -ceu \
  "du -sh '${BASE_DIR}' | awk '{print \$1}' > '${BASE_DIR}/backup-size.txt'"

BACKUP_OK=1
log "Backup verified: ${TIMESTAMP}"

log "Pruning old base backups ..."
# POSIX tools only: the image is Alpine, whose BusyBox find has no -printf. Only
# timestamp-named directories are candidates, and the name sorts by age.
compose exec -T --user root postgres sh -ceu \
  "cd '${BACKUP_ROOT}/base' && ls -1 | grep -E '^[0-9]{8}_[0-9]{6}\$' | LC_ALL=C sort -r | tail -n +$(( BASE_BACKUP_KEEP_COUNT + 1 )) | while read -r old; do echo \"removing base backup \$old\"; rm -rf -- \"\$old\"; done"

if [ "${PRUNE_WAL}" -eq 1 ]; then
  log "Pruning WAL archive files older than the oldest kept base backup ..."
  COMPOSE_FILE="${COMPOSE_FILE}" sh "${SCRIPT_DIR}/pg-wal-prune.sh" --apply
else
  log "WAL archive left as is (no --prune-wal)"
fi

log "Current base backups:"
compose exec -T postgres sh -ceu "ls -1 '${BACKUP_ROOT}/base'"

log "=== PostgreSQL base backup complete ==="
