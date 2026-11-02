#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet - PostgreSQL restore from a base backup plus archived WAL
#
# It has to be told where to restore. With no target it changes nothing.
#
# Scratch (the default way to use this, and how to test a backup):
#   bash testnet/scripts/pg-restore-pitr.sh --scratch-volume NAME
#   Creates a new labelled volume and a container with no network, the backup
#   volume mounted read-only and archiving off. The live database is not touched
#   or stopped. The scratch container stays up for checking; remove it with:
#   bash testnet/scripts/pg-restore-pitr.sh --cleanup-scratch --scratch-volume NAME
#
# Live (replaces the running database):
#   bash testnet/scripts/pg-restore-pitr.sh --live \
#     --target-volume <its data volume> --confirm-overwrite <the same name>
#   Stops only the postgres container, keeps the old data as
#   pgdata.pre-restore-<time> on the same volume, and starts the same container.
#   It doesn't recreate anything or stop other services. Stop those that write to
#   the database first, and restart them through the normal deploy path after.
#
# Options:
#   --base-backup ID        A directory under backup/base/ (default: the newest)
#   --target-time TIME      Stop replay at TIME (default: all archived WAL)
#   --scratch-container N   Scratch container name (default: <volume>-pg)
#
# Exit: 0 done; 1 failed; 2 usage; 3 refused, nothing changed.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${TESTNET_DIR}/docker-compose.testnet.yml}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"
WAIT_SECONDS="${RESTORE_WAIT_SECONDS:-1800}"
SCRATCH_LABEL="wrfcoin.pg-restore-scratch"

# The compose layout: PGDATA sits one level inside the data volume, with the
# backup volume mounted beside it. restore_command depends on these paths.
DATA_MOUNT="/var/lib/postgresql/data"
PGDATA_PATH="${DATA_MOUNT}/pgdata"
BACKUP_MOUNT="${DATA_MOUNT}/backup"

SCRATCH_VOLUME=""
SCRATCH_CONTAINER=""
LIVE=0
TARGET_VOLUME=""
CONFIRM_OVERWRITE=""
CLEANUP=0
BASE_BACKUP_ID=""
TARGET_TIME=""

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
err() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }
refuse() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] REFUSED, nothing changed: $*" >&2; exit 3; }

usage() { sed -n '2,/^# ====.*$/p' "$0" | sed 's/^# \{0,1\}//'; }

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { err "$1 needs a value"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --scratch-volume) need_value "$@"; SCRATCH_VOLUME="$2"; shift 2 ;;
    --scratch-container) need_value "$@"; SCRATCH_CONTAINER="$2"; shift 2 ;;
    --live) LIVE=1; shift ;;
    --target-volume) need_value "$@"; TARGET_VOLUME="$2"; shift 2 ;;
    --confirm-overwrite) need_value "$@"; CONFIRM_OVERWRITE="$2"; shift 2 ;;
    --cleanup-scratch) CLEANUP=1; shift ;;
    --base-backup) need_value "$@"; BASE_BACKUP_ID="$2"; shift 2 ;;
    --target-time) need_value "$@"; TARGET_TIME="$2"; shift 2 ;;
    --confirm) refuse "--confirm alone no longer selects a target; use --scratch-volume, or --live with --target-volume and --confirm-overwrite" ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; exit 2 ;;
  esac
done

# --- What is live --------------------------------------------------------------
mount_volume() { # mount_volume CONTAINER DESTINATION: the named volume mounted there
  docker inspect "$1" --format "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Name}}{{end}}{{end}}"
}

resolve_live() {
  LIVE_CONTAINER="${POSTGRES_CONTAINER:-}"
  if [ -z "${LIVE_CONTAINER}" ]; then
    LIVE_CONTAINER="$(docker compose -f "${COMPOSE_FILE}" ps -aq postgres 2>/dev/null | head -n1 || true)"
  fi
  [ -n "${LIVE_CONTAINER}" ] || refuse "cannot find the postgres container, so cannot tell what is live (set POSTGRES_CONTAINER)"
  LIVE_DATA_VOLUME="$(mount_volume "${LIVE_CONTAINER}" "${DATA_MOUNT}")" || refuse "cannot inspect ${LIVE_CONTAINER}"
  BACKUP_VOLUME="$(mount_volume "${LIVE_CONTAINER}" "${BACKUP_MOUNT}")" || refuse "cannot inspect ${LIVE_CONTAINER}"
  [ -n "${LIVE_DATA_VOLUME}" ] || refuse "${LIVE_CONTAINER} has no named volume at ${DATA_MOUNT}"
  [ -n "${BACKUP_VOLUME}" ] || refuse "${LIVE_CONTAINER} has no named volume at ${BACKUP_MOUNT}"
}

# Names only, and never logged. The stopped-container fallback is the compose default.
resolve_role() {
  PG_ROLE="${PG_ROLE:-}"
  PG_DB="${PG_DB:-}"
  if [ -z "${PG_ROLE}" ]; then
    PG_ROLE="$(docker exec "${LIVE_CONTAINER}" sh -c 'printf %s "${POSTGRES_USER:-}"' 2>/dev/null || true)"
  fi
  if [ -z "${PG_DB}" ]; then
    PG_DB="$(docker exec "${LIVE_CONTAINER}" sh -c 'printf %s "${POSTGRES_DB:-}"' 2>/dev/null || true)"
  fi
  PG_ROLE="${PG_ROLE:-wrfcoin}"   # the compose file's values, for a stopped container
  PG_DB="${PG_DB:-wrfcoin}"
}

volume_label() { docker volume inspect "$1" --format "{{index .Labels \"${SCRATCH_LABEL}\"}}" 2>/dev/null || true; }

check_scratch_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_.-]*|[_.-]*) refuse "bad name: '$1'" ;;
  esac
}

# --- Cleanup --------------------------------------------------------------------
if [ "${CLEANUP}" -eq 1 ]; then
  [ -n "${SCRATCH_VOLUME}" ] || { err "--cleanup-scratch needs --scratch-volume"; exit 2; }
  check_scratch_name "${SCRATCH_VOLUME}"
  SCRATCH_CONTAINER="${SCRATCH_CONTAINER:-${SCRATCH_VOLUME}-pg}"
  check_scratch_name "${SCRATCH_CONTAINER}"
  if docker inspect "${SCRATCH_CONTAINER}" >/dev/null 2>&1; then
    [ "$(docker inspect "${SCRATCH_CONTAINER}" --format "{{index .Config.Labels \"${SCRATCH_LABEL}\"}}")" = "1" ] \
      || refuse "container ${SCRATCH_CONTAINER} is not labelled as a scratch restore"
  fi
  if docker volume inspect "${SCRATCH_VOLUME}" >/dev/null 2>&1; then
    [ "$(volume_label "${SCRATCH_VOLUME}")" = "1" ] \
      || refuse "volume ${SCRATCH_VOLUME} is not labelled as a scratch restore"
  fi
  if docker inspect "${SCRATCH_CONTAINER}" >/dev/null 2>&1; then
    docker rm -f "${SCRATCH_CONTAINER}" >/dev/null
    log "removed container ${SCRATCH_CONTAINER}"
  fi
  if docker volume inspect "${SCRATCH_VOLUME}" >/dev/null 2>&1; then
    docker volume rm "${SCRATCH_VOLUME}" >/dev/null
    log "removed volume ${SCRATCH_VOLUME}"
  fi
  exit 0
fi

# --- Choose the target ------------------------------------------------------------
if [ "${LIVE}" -eq 1 ] && [ -n "${SCRATCH_VOLUME}" ]; then
  refuse "--live and --scratch-volume are different targets; give one"
fi
if [ "${LIVE}" -ne 1 ] && [ -z "${SCRATCH_VOLUME}" ]; then
  refuse "no target given: use --scratch-volume NAME, or --live with --target-volume and --confirm-overwrite"
fi
if [ "${LIVE}" -ne 1 ] && { [ -n "${TARGET_VOLUME}" ] || [ -n "${CONFIRM_OVERWRITE}" ]; }; then
  refuse "--target-volume and --confirm-overwrite only apply with --live"
fi

if [ -n "${BASE_BACKUP_ID}" ]; then
  case "${BASE_BACKUP_ID}" in
    *[!0-9_]*) refuse "bad --base-backup '${BASE_BACKUP_ID}': expected a directory name like 20260408_020001" ;;
  esac
fi
if [ -n "${TARGET_TIME}" ]; then
  case "${TARGET_TIME}" in
    *[!0-9A-Za-z\ :+.-]*) refuse "bad --target-time '${TARGET_TIME}'" ;;
  esac
fi

resolve_live

if [ "${LIVE}" -eq 1 ]; then
  [ -n "${TARGET_VOLUME}" ] || refuse "--live needs --target-volume naming the data volume"
  [ "${TARGET_VOLUME}" = "${LIVE_DATA_VOLUME}" ] \
    || refuse "--target-volume ${TARGET_VOLUME} is not the volume ${LIVE_CONTAINER} runs on; for anything else use --scratch-volume"
  [ "${CONFIRM_OVERWRITE}" = "${TARGET_VOLUME}" ] \
    || refuse "this replaces the live database: --confirm-overwrite must repeat the volume name exactly"
else
  check_scratch_name "${SCRATCH_VOLUME}"
  SCRATCH_CONTAINER="${SCRATCH_CONTAINER:-${SCRATCH_VOLUME}-pg}"
  check_scratch_name "${SCRATCH_CONTAINER}"
  [ "${SCRATCH_VOLUME}" != "${LIVE_DATA_VOLUME}" ] \
    || refuse "${SCRATCH_VOLUME} is the live data volume. To replace the live database use --live with --target-volume and --confirm-overwrite"
  [ "${SCRATCH_VOLUME}" != "${BACKUP_VOLUME}" ] || refuse "${SCRATCH_VOLUME} is the backup volume"
  if docker volume inspect "${SCRATCH_VOLUME}" >/dev/null 2>&1; then
    refuse "volume ${SCRATCH_VOLUME} already exists; a scratch restore needs a new one (--cleanup-scratch removes an earlier scratch restore)"
  fi
  if docker inspect "${SCRATCH_CONTAINER}" >/dev/null 2>&1; then
    refuse "container ${SCRATCH_CONTAINER} already exists"
  fi
fi

# --- Choose and check the backup ----------------------------------------------------
# One-off helpers run from the same image as the database, with no network, and
# never pull: a pull could move the tag the live container was created from.
helper() { docker run --rm --pull never --network none "$@"; }

if [ -z "${BASE_BACKUP_ID}" ]; then
  BASE_BACKUP_ID="$(helper -v "${BACKUP_VOLUME}:/backup:ro" "${POSTGRES_IMAGE}" sh -c \
    "ls -1 /backup/base 2>/dev/null | grep -E '^[0-9]{8}_[0-9]{6}\$' | LC_ALL=C sort | tail -n 1" || true)"
fi
[ -n "${BASE_BACKUP_ID}" ] || refuse "no base backup in ${BACKUP_VOLUME}"

log "Verifying base backup ${BASE_BACKUP_ID} ..."
helper -v "${BACKUP_VOLUME}:/backup:ro" "${POSTGRES_IMAGE}" \
  pg_verifybackup -q -i backup-size.txt "/backup/base/${BASE_BACKUP_ID}" \
  || refuse "base backup ${BASE_BACKUP_ID} is missing or fails pg_verifybackup"

# Copies the backup to DEST on the volume mounted at /data and adds the recovery
# settings. It runs in a directory beside any existing data, so a failure here
# leaves that data as it was.
prepare_copy() { # prepare_copy VOLUME DEST
  helper \
    -v "$1:/data" \
    -v "${BACKUP_VOLUME}:/backup:ro" \
    -e "BASE_BACKUP_ID=${BASE_BACKUP_ID}" \
    -e "TARGET_TIME=${TARGET_TIME}" \
    -e "DEST=/data/$2" \
    -e "BACKUP_MOUNT=${BACKUP_MOUNT}" \
    "${POSTGRES_IMAGE}" sh -ceu '
      rm -rf -- "$DEST"
      mkdir -p "$DEST"
      cp -a "/backup/base/${BASE_BACKUP_ID}/." "$DEST/"
      rm -f -- "$DEST/backup-size.txt"
      AUTO_CONF="$DEST/postgresql.auto.conf"
      touch "$AUTO_CONF"
      grep -vE "^(restore_command|recovery_target_time|recovery_target_action)[[:space:]]*=" "$AUTO_CONF" > "${AUTO_CONF}.tmp" || true
      mv "${AUTO_CONF}.tmp" "$AUTO_CONF"
      printf "restore_command = '\''cp %s/wal/%%f %%p'\''\n" "$BACKUP_MOUNT" >> "$AUTO_CONF"
      if [ -n "$TARGET_TIME" ]; then
        printf "recovery_target_time = '\''%s'\''\n" "$TARGET_TIME" >> "$AUTO_CONF"
        printf "recovery_target_action = '\''promote'\''\n" >> "$AUTO_CONF"
      fi
      touch "$DEST/recovery.signal"
      chown -R postgres:postgres "$DEST"
      chmod 700 "$DEST"
    '
}

# Waits until CONTAINER has left recovery. Prints the postgres log tail on failure.
wait_for_promotion() {
  local container="$1" waited=0 state
  while [ "${waited}" -lt "${WAIT_SECONDS}" ]; do
    if [ "$(docker inspect "${container}" --format '{{.State.Running}}')" != "true" ]; then
      err "${container} stopped during recovery"
      docker logs --tail 40 "${container}" >&2 2>&1 || true
      return 1
    fi
    state="$(docker exec -u postgres -e "RESTORE_ROLE=${PG_ROLE}" -e "RESTORE_DB=${PG_DB}" "${container}" sh -c \
      'PGPASSWORD="${POSTGRES_PASSWORD:-}" psql -U "$RESTORE_ROLE" -d "$RESTORE_DB" -XAtc "SELECT pg_is_in_recovery()"' 2>/dev/null | tr -d '[:space:]' || true)"
    if [ "${state}" = "f" ]; then
      return 0
    fi
    sleep 2
    waited=$(( waited + 2 ))
  done
  err "${container} was still in recovery after ${WAIT_SECONDS}s"
  docker logs --tail 40 "${container}" >&2 2>&1 || true
  return 1
}

report_replay() {
  log "WAL files restored from the archive: $(docker logs "$1" 2>&1 | grep -c 'restored log file' || true)"
}

resolve_role
log "Base backup: ${BASE_BACKUP_ID}"
log "Target time: ${TARGET_TIME:-end of the archive}"

# --- Scratch restore ------------------------------------------------------------------
if [ "${LIVE}" -ne 1 ]; then
  log "=== Scratch restore into volume ${SCRATCH_VOLUME} (live database not touched) ==="
  docker volume create --label "${SCRATCH_LABEL}=1" "${SCRATCH_VOLUME}" >/dev/null
  prepare_copy "${SCRATCH_VOLUME}" pgdata

  # archive_mode=off and the read-only mount each keep a promoted copy from
  # writing its new timeline into the real archive. hot_standby=off: the copy
  # needs no connections during replay, and a smaller max_connections than the
  # source's is then not an error. listen_addresses is empty: local socket only.
  docker run -d --pull never \
    --name "${SCRATCH_CONTAINER}" \
    --label "${SCRATCH_LABEL}=1" \
    --network none \
    --memory "${RESTORE_MEMORY:-2g}" \
    --cpus "${RESTORE_CPUS:-1}" \
    -e "PGDATA=${PGDATA_PATH}" \
    -v "${SCRATCH_VOLUME}:${DATA_MOUNT}" \
    -v "${BACKUP_VOLUME}:${BACKUP_MOUNT}:ro" \
    "${POSTGRES_IMAGE}" \
    postgres -c archive_mode=off -c hot_standby=off -c listen_addresses= >/dev/null

  log "Replaying WAL in ${SCRATCH_CONTAINER} ..."
  if ! wait_for_promotion "${SCRATCH_CONTAINER}"; then
    err "scratch restore failed; inspect it, then run: bash testnet/scripts/pg-restore-pitr.sh --cleanup-scratch --scratch-volume ${SCRATCH_VOLUME} --scratch-container ${SCRATCH_CONTAINER}"
    exit 1
  fi
  report_replay "${SCRATCH_CONTAINER}"
  log "=== Scratch restore OK: ${SCRATCH_CONTAINER} is up, recovery finished ==="
  log "Remove it with: bash testnet/scripts/pg-restore-pitr.sh --cleanup-scratch --scratch-volume ${SCRATCH_VOLUME} --scratch-container ${SCRATCH_CONTAINER}"
  exit 0
fi

# --- Live restore ---------------------------------------------------------------------
STAMP="$(date -u +%Y%m%d_%H%M%S)"
log "=== LIVE restore into ${TARGET_VOLUME}: stopping ${LIVE_CONTAINER} ==="
docker stop -t 60 "${LIVE_CONTAINER}" >/dev/null

if ! prepare_copy "${TARGET_VOLUME}" "pgdata.restoring-${STAMP}"; then
  err "could not prepare the restored data; the old data is unchanged. Starting ${LIVE_CONTAINER} on it"
  docker start "${LIVE_CONTAINER}" >/dev/null
  exit 1
fi

# The swap: two renames on one volume. If the second fails, the first is undone.
if ! helper -v "${TARGET_VOLUME}:/data" -e "STAMP=${STAMP}" "${POSTGRES_IMAGE}" sh -ceu \
  'mv /data/pgdata "/data/pgdata.pre-restore-${STAMP}"
   mv "/data/pgdata.restoring-${STAMP}" /data/pgdata || { mv "/data/pgdata.pre-restore-${STAMP}" /data/pgdata; exit 1; }'; then
  err "could not swap in the restored data; ${LIVE_CONTAINER} left stopped, check ${TARGET_VOLUME} before starting it"
  exit 1
fi

docker start "${LIVE_CONTAINER}" >/dev/null
log "Replaying WAL ..."
wait_for_promotion "${LIVE_CONTAINER}"
report_replay "${LIVE_CONTAINER}"
log "=== LIVE restore complete ==="
log "The old data is kept on ${TARGET_VOLUME} as pgdata.pre-restore-${STAMP}; delete it once you are satisfied."
log "Other services were not touched: restart them through the normal deploy path."
