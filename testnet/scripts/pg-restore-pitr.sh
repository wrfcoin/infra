#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet - PostgreSQL PITR Restore
#
# Restores postgres-data from a base backup and replays archived WAL up to a
# target timestamp.
#
# Usage:
#   bash testnet/scripts/pg-restore-pitr.sh \
#     --target-time "2026-04-08 02:15:00+00" \
#     --confirm
#
# Optional:
#   --base-backup 20260408_020001   # defaults to latest available
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
P2P_GUARD="${TESTNET_DIR}/check-p2p-external-addr.sh"

TARGET_TIME=""
BASE_BACKUP_ID=""
CONFIRM=0

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

guard_external_address() {
  "${P2P_GUARD}" --env-file "${TESTNET_DIR}/.env" --require
}

resolve_volume_name() {
  local volume_key="$1"
  local compose_json_file
  compose_json_file="$(mktemp)"
  trap 'rm -f "$compose_json_file"' RETURN

  compose config --format json > "$compose_json_file"
  python3 - "${volume_key}" "$compose_json_file" <<'PY'
import json
import sys

key = sys.argv[1]
compose_json_file = sys.argv[2]
with open(compose_json_file, "r", encoding="utf-8") as handle:
    cfg = json.load(handle)
vol = cfg.get("volumes", {}).get(key, {})
print(vol.get("name", key))
PY
}

usage() {
  cat <<'EOF'
Usage:
  bash testnet/scripts/pg-restore-pitr.sh --target-time "YYYY-MM-DD HH:MM:SS+00" --confirm
  bash testnet/scripts/pg-restore-pitr.sh --base-backup TIMESTAMP --target-time "..." --confirm

Options:
  --base-backup TIMESTAMP   Choose a specific backup directory under backup/base/
  --target-time TIME        PostgreSQL recovery target time (UTC recommended)
  --confirm                 Required safety flag
  --help                    Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target-time)
      TARGET_TIME="${2:-}"
      shift 2
      ;;
    --target-time=*)
      TARGET_TIME="${1#*=}"
      shift
      ;;
    --base-backup)
      BASE_BACKUP_ID="${2:-}"
      shift 2
      ;;
    --base-backup=*)
      BASE_BACKUP_ID="${1#*=}"
      shift
      ;;
    --confirm)
      CONFIRM=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ "${CONFIRM}" -ne 1 ]; then
  err "Refusing destructive restore without --confirm"
  exit 1
fi

if [ -z "${TARGET_TIME}" ]; then
  err "--target-time is required"
  exit 1
fi

POSTGRES_DATA_VOLUME="$(resolve_volume_name postgres-data)"
POSTGRES_BACKUP_VOLUME="$(resolve_volume_name postgres-backup)"

if [ -z "${BASE_BACKUP_ID}" ]; then
  BASE_BACKUP_ID="$(
    docker run --rm -v "${POSTGRES_BACKUP_VOLUME}:/backup" alpine sh -ceu \
      "ls -1dt /backup/base/* 2>/dev/null | head -n1 | xargs -r basename"
  )"
fi

if [ -z "${BASE_BACKUP_ID}" ]; then
  err "No base backup found in ${POSTGRES_BACKUP_VOLUME}:/backup/base"
  exit 1
fi

docker run --rm -v "${POSTGRES_BACKUP_VOLUME}:/backup" -e BASE_BACKUP_ID="${BASE_BACKUP_ID}" alpine sh -ceu \
  "[ -d \"/backup/base/${BASE_BACKUP_ID}\" ]"

log "=== PostgreSQL PITR restore start ==="
log "Compose file: ${COMPOSE_FILE}"
log "postgres-data volume: ${POSTGRES_DATA_VOLUME}"
log "postgres-backup volume: ${POSTGRES_BACKUP_VOLUME}"
log "Base backup: ${BASE_BACKUP_ID}"
log "Target time: ${TARGET_TIME}"

log "Stopping testnet stack ..."
guard_external_address
compose down

log "Restoring postgres-data from base backup ..."
docker run --rm \
  -v "${POSTGRES_DATA_VOLUME}:/pgdata" \
  -v "${POSTGRES_BACKUP_VOLUME}:/backup" \
  -e BASE_BACKUP_ID="${BASE_BACKUP_ID}" \
  -e TARGET_TIME="${TARGET_TIME}" \
  alpine sh -ceu '
    find /pgdata -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    cp -a "/backup/base/${BASE_BACKUP_ID}/." /pgdata/

    AUTO_CONF="/pgdata/postgresql.auto.conf"
    touch "$AUTO_CONF"
    grep -vE "^(restore_command|recovery_target_time|recovery_target_action)\s*=" "$AUTO_CONF" > "${AUTO_CONF}.tmp" || true
    mv "${AUTO_CONF}.tmp" "$AUTO_CONF"

    printf "restore_command = '\''cp /var/lib/postgresql/data/backup/wal/%f %p'\''\n" >> "$AUTO_CONF"
    printf "recovery_target_time = '\''%s'\''\n" "$TARGET_TIME" >> "$AUTO_CONF"
    printf "recovery_target_action = '\''promote'\''\n" >> "$AUTO_CONF"

    touch /pgdata/recovery.signal
    chown -R 999:999 /pgdata
  '

log "Starting postgres for WAL replay ..."
guard_external_address
compose up -d postgres

healthy=0
for _ in $(seq 1 60); do
  if compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done

if [ "${healthy}" -ne 1 ]; then
  err "postgres did not become healthy after restore"
  compose logs --tail=120 postgres || true
  exit 1
fi

log "Waiting for recovery to finish ..."
recovery_done=0
for _ in $(seq 1 60); do
  in_recovery="$(compose exec -T postgres psql -U postgres -d postgres -tAc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "${in_recovery}" = "f" ]; then
    recovery_done=1
    break
  fi
  sleep 2
done

if [ "${recovery_done}" -ne 1 ]; then
  err "postgres remained in recovery longer than expected"
  compose logs --tail=120 postgres || true
  exit 1
fi

log "Starting full testnet stack ..."
guard_external_address
compose up -d

log "=== PostgreSQL PITR restore complete ==="
