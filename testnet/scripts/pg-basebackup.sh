#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — PostgreSQL Base Backup + WAL Archive Rotation
#
# What it does:
#   1. Creates a physical base backup with pg_basebackup
#   2. Keeps only the newest N base backups (default: 3)
#   3. Prunes WAL archive files older than M days (default: 7)
#
# Usage:
#   bash testnet/scripts/pg-basebackup.sh
#   BASE_BACKUP_KEEP_COUNT=5 WAL_RETENTION_DAYS=14 bash testnet/scripts/pg-basebackup.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

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

POSTGRES_PASSWORD="$(read_env_or_default POSTGRES_PASSWORD "")"
BASE_BACKUP_KEEP_COUNT="$(read_env_or_default BASE_BACKUP_KEEP_COUNT "$(read_env_or_default PG_BASEBACKUP_KEEP_COUNT 3)")"
WAL_RETENTION_DAYS="$(read_env_or_default WAL_RETENTION_DAYS "$(read_env_or_default PG_WAL_RETENTION_DAYS 7)")"

if [ -z "${POSTGRES_PASSWORD}" ]; then
  err "POSTGRES_PASSWORD is required (export it or set it in testnet/.env)."
  exit 1
fi

case "${BASE_BACKUP_KEEP_COUNT}" in
  ''|*[!0-9]*) err "BASE_BACKUP_KEEP_COUNT must be a positive integer"; exit 1 ;;
esac
case "${WAL_RETENTION_DAYS}" in
  ''|*[!0-9]*) err "WAL_RETENTION_DAYS must be a non-negative integer"; exit 1 ;;
esac

log "=== PostgreSQL base backup start ==="
log "Compose file: ${COMPOSE_FILE}"
log "Retention: keep ${BASE_BACKUP_KEEP_COUNT} base backup(s), WAL ${WAL_RETENTION_DAYS} day(s)"

compose ps postgres >/dev/null

# Ensure backup directories exist and are writable by postgres.
compose exec -T --user root postgres sh -ceu \
  "mkdir -p /var/lib/postgresql/data/backup/base /var/lib/postgresql/data/backup/wal && chown -R postgres:postgres /var/lib/postgresql/data/backup"

BASE_DIR="/var/lib/postgresql/data/backup/base/${TIMESTAMP}"

log "Running pg_basebackup to ${BASE_DIR} ..."
compose exec -T -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres \
  pg_basebackup -h 127.0.0.1 -p 5432 -U wrfcoin -D "${BASE_DIR}" -Fp -Xs -P

compose exec -T postgres sh -ceu \
  "du -sh '${BASE_DIR}' | awk '{print \$1}' > '${BASE_DIR}/backup-size.txt'"

log "Pruning old base backups ..."
compose exec -T --user root postgres sh -ceu \
  "find /var/lib/postgresql/data/backup/base -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -nr \
    | awk -v keep='${BASE_BACKUP_KEEP_COUNT}' 'NR>keep {print \$2}' \
    | xargs -r rm -rf"

log "Pruning WAL archive files older than ${WAL_RETENTION_DAYS} day(s) ..."
compose exec -T --user root postgres sh -ceu \
  "find /var/lib/postgresql/data/backup/wal -mindepth 1 -maxdepth 1 -type f -mtime +${WAL_RETENTION_DAYS} -delete"

log "Current base backups:"
compose exec -T postgres sh -ceu \
  "ls -1dt /var/lib/postgresql/data/backup/base/* 2>/dev/null || true"

log "=== PostgreSQL base backup complete ==="
