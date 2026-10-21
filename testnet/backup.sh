#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — Automated Backup
#
# Backs up PostgreSQL (plain SQL postgres.sql AND custom-format postgres.dump,
# verified with pg_restore --list), Redis, blockchain data, and configuration.
# Supports two deployment modes:
#   - ZFS-backed (reference node): takes ZFS snapshots for blockchain data
#   - Docker volumes (generic operator): copies volume data via containers
#
# Usage:
#   bash backup.sh                          # run backup
#   BACKUP_DIR=/custom/path bash backup.sh  # custom backup location
#
# Cron (daily at 3am):
#   0 3 * * * cd /root/wrfcoin/infra/testnet && bash backup.sh >> /var/log/wrfcoin-backup.log 2>&1
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.testnet.yml}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/tank/backups/testnet}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
NODE_CONTAINER="${NODE_CONTAINER:-wrfcoin-testnet-node}"   # container_name in docker-compose.testnet.yml
NODE_DATA_DIR="${NODE_DATA_DIR:-/app/data}"                # node-data mount target there
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
DEST="${BACKUP_DIR}/${TIMESTAMP}"
ERRORS=0

# Alert webhook URL — set ALERT_WEBHOOK in the environment or .env to enable
# failure notifications (e.g. a Slack/Discord/generic HTTP endpoint).
# Leave empty to skip webhook alerts (default: silent, log-only).
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; ERRORS=$((ERRORS + 1)); }

# send_alert MESSAGE — fires an HTTP POST to $ALERT_WEBHOOK if configured.
send_alert() {
  local msg="$1"
  if [ -n "${ALERT_WEBHOOK}" ]; then
    curl -sf -X POST "${ALERT_WEBHOOK}" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"[WRFCoin backup] ${msg}\"}" \
      --max-time 10 \
      > /dev/null 2>&1 || true   # never let the alert itself fail the script
  fi
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

check_file() {
  local file="$1" label="$2" min_bytes="${3:-1}"
  if [ ! -f "$file" ]; then
    err "${label}: file not found: ${file}"
    return 1
  fi
  local size
  size="$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)"
  if [ "$size" -lt "$min_bytes" ]; then
    err "${label}: file too small (${size} bytes, expected >= ${min_bytes})"
    return 1
  fi
  log "${label}: OK ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size} bytes"))"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "=== WRFCoin Testnet Backup — ${TIMESTAMP} ==="
log "Backup directory: ${DEST}"
mkdir -p "${DEST}"

# Load ALERT_WEBHOOK from .env if not already set in the environment
if [ -z "${ALERT_WEBHOOK:-}" ] && [ -f "${SCRIPT_DIR}/.env" ]; then
  ALERT_WEBHOOK="$(grep -E '^ALERT_WEBHOOK=' "${SCRIPT_DIR}/.env" | cut -d= -f2- || true)"
fi

# ---- 1. PostgreSQL --------------------------------------------------------
log "Backing up PostgreSQL..."
if compose exec -T postgres pg_dump -U wrfcoin wrfcoin > "${DEST}/postgres.sql" 2>/dev/null; then
  # Verify the dump starts with a comment (valid pg_dump output)
  if head -1 "${DEST}/postgres.sql" | grep -q '^--'; then
    check_file "${DEST}/postgres.sql" "PostgreSQL dump" 100
  else
    err "PostgreSQL dump: output does not look like valid SQL"
  fi
else
  err "PostgreSQL dump: pg_dump command failed"
fi

# Custom-format dump as well (owner ruling 2026-09-27). The plain SQL above stays
# for RESTORE_DRILL.md / UPGRADE_RUNBOOK.md / backup-restore-verification.sh.
# This one is readable by `pg_restore --list` and allows selective restores.
#
# It is written under a temporary name, verified with the server image's own
# pg_restore (reading stdin), and only then PUBLISHED as postgres.dump and
# postgres.dump.list by rename(2) (codex round 61). A failed or unverifiable
# dump never appears under the name the restore docs use: it is deleted, and
# the run counts an error.
# Temp names come from mktemp (O_EXCL, random), never a predictable path that a
# planted link could redirect (round-62 audit). The final names are published
# by rename(2), which replaces a link rather than following it.
PG_PART="$(mktemp "${DEST}/.postgres.dump.XXXXXXXX")" || { err "PostgreSQL custom dump: cannot create a temp file"; PG_PART=""; }
PG_LIST="$(mktemp "${DEST}/.postgres.dump.list.XXXXXXXX")" || { err "PostgreSQL custom dump: cannot create a temp file"; PG_LIST=""; }
if [ -n "${PG_PART}" ] && [ -n "${PG_LIST}" ] && compose exec -T postgres pg_dump -U wrfcoin -Fc wrfcoin > "${PG_PART}" 2>/dev/null; then
  if compose exec -T postgres pg_restore --list < "${PG_PART}" > "${PG_LIST}" 2>/dev/null \
     && grep -q ' TABLE ' "${PG_LIST}"; then
    chmod 0600 "${PG_PART}" "${PG_LIST}"
    mv -f "${PG_LIST}" "${DEST}/postgres.dump.list"
    mv -f "${PG_PART}" "${DEST}/postgres.dump"      # published last: its presence means verified
    check_file "${DEST}/postgres.dump" "PostgreSQL custom dump" 100
    log "PostgreSQL custom dump: pg_restore --list OK ($(grep -c ' TABLE DATA ' "${DEST}/postgres.dump.list") table data entries)"
  else
    err "PostgreSQL custom dump: pg_restore --list could not read the new dump; not published"
  fi
else
  err "PostgreSQL custom dump: pg_dump -Fc failed; not published"
fi
rm -f -- ${PG_PART:+"${PG_PART}"} ${PG_LIST:+"${PG_LIST}"}

# ---- 2. Redis -------------------------------------------------------------
log "Backing up Redis..."
# Read REDIS_PASSWORD from .env if not already set
if [ -z "${REDIS_PASSWORD:-}" ] && [ -f "${SCRIPT_DIR}/.env" ]; then
  REDIS_PASSWORD="$(grep -E '^REDIS_PASSWORD=' "${SCRIPT_DIR}/.env" | cut -d= -f2- || true)"
fi

if [ -n "${REDIS_PASSWORD:-}" ]; then
  # Trigger a background save. The password goes on redis-cli's STDIN (AUTH), never
  # into docker/compose argv, where `ps` and process listings would show it
  # (codex round 61). printf is a bash builtin, so it spawns no process with it.
  # redis-cli exits 0 even on a wrong password, so its reply is checked instead.
  bgsave_reply="$(printf 'AUTH %s\nBGSAVE\n' "${REDIS_PASSWORD}" | compose exec -T redis redis-cli 2>&1 || true)"
  if ! grep -qE 'Background saving (started|scheduled)|already in progress' <<<"${bgsave_reply}"; then
    err "Redis: BGSAVE was not confirmed (authentication or server error); copying the last dump.rdb anyway"
  fi
  sleep 2
  # Copy the RDB file
  if compose cp redis:/data/dump.rdb "${DEST}/redis.rdb" 2>/dev/null; then
    check_file "${DEST}/redis.rdb" "Redis RDB" 100
  else
    err "Redis: failed to copy dump.rdb"
  fi
else
  err "Redis: REDIS_PASSWORD not set — skipping (set in .env or export REDIS_PASSWORD)"
fi

# ---- 3. Blockchain data ---------------------------------------------------
log "Backing up blockchain data..."
if command -v zfs > /dev/null 2>&1 && zfs list tank/blockchain > /dev/null 2>&1; then
  # ZFS mode: take a snapshot (instant, no I/O impact)
  SNAP_NAME="tank/blockchain@backup-${TIMESTAMP}"
  if zfs snapshot "${SNAP_NAME}"; then
    log "ZFS snapshot: ${SNAP_NAME}"
    echo "${SNAP_NAME}" > "${DEST}/zfs-snapshot.txt"
  else
    err "ZFS snapshot failed"
  fi
else
  # Docker volume mode: copy via a temporary container.
  # Resolve the real volume from the running node's mounts (project-prefixed,
  # e.g. testnet_node-data); fall back to the compose config, which emits
  # volume objects, not "src:dst" strings (infra#1115). The resolver's stderr
  # is left visible so a failure says why.
  NODE_VOLUME=""
  if NODE_MOUNTS="$(docker inspect --format '{{json .Mounts}}' "${NODE_CONTAINER}")"; then
    NODE_VOLUME="$(python3 "${SCRIPT_DIR}/lib/resolve-node-volume.py" mounts "${NODE_DATA_DIR}" <<<"${NODE_MOUNTS}" || true)"
  fi
  if [ -z "${NODE_VOLUME}" ]; then
    log "Node container ${NODE_CONTAINER}: no mount resolved — falling back to compose config"
    NODE_VOLUME="$(compose config --format json \
      | python3 "${SCRIPT_DIR}/lib/resolve-node-volume.py" compose wrfcoin-node "${NODE_DATA_DIR}" || true)"
  fi
  if [ -n "${NODE_VOLUME}" ]; then
    log "Copying Docker volume ${NODE_VOLUME}..."
    if docker run --rm \
      -v "${NODE_VOLUME}:/source:ro" \
      -v "${DEST}:/backup" \
      alpine tar czf /backup/blockchain-data.tar.gz -C /source .; then
      check_file "${DEST}/blockchain-data.tar.gz" "Blockchain data" 100
    else
      err "Blockchain data: tar failed"
    fi
  else
    err "Blockchain data: could not determine volume name for ${NODE_DATA_DIR} — skipping"
  fi
fi

# ---- 4. Configuration -----------------------------------------------------
log "Backing up configuration..."
if [ -f "${SCRIPT_DIR}/.env" ]; then
  cp "${SCRIPT_DIR}/.env" "${DEST}/env.bak"
  chmod 600 "${DEST}/env.bak"
  log "Configuration: .env copied (permissions restricted to owner)"
else
  log "Configuration: no .env file found — skipping"
fi

# ---- 5. Retention ----------------------------------------------------------
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -maxdepth 1 -mindepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} \; 2>/dev/null || true

# Also clean up old ZFS snapshots if in ZFS mode
if command -v zfs > /dev/null 2>&1 && zfs list tank/blockchain > /dev/null 2>&1; then
  CUTOFF="$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d 2>/dev/null || date -v-"${RETENTION_DAYS}"d +%Y%m%d 2>/dev/null || echo "")"
  if [ -n "${CUTOFF}" ]; then
    zfs list -t snapshot -o name -H 2>/dev/null | grep '^tank/blockchain@backup-' | while read -r snap; do
      SNAP_DATE="${snap#*@backup-}"
      SNAP_DATE="${SNAP_DATE%%_*}"
      if [ "${SNAP_DATE}" \< "${CUTOFF}" ]; then
        if zfs destroy "${snap}" 2>/dev/null; then
          log "Removed old snapshot: ${snap}"
        fi
      fi
    done
  fi
fi

# ---- Summary ---------------------------------------------------------------
log "=== Backup complete ==="
log "Location: ${DEST}"
ls -lh "${DEST}/"
if [ "${ERRORS}" -gt 0 ]; then
  err "Completed with ${ERRORS} error(s) — review output above"
  send_alert "FAILED: ${ERRORS} error(s) on $(hostname) at ${TIMESTAMP}. Check /var/log/wrfcoin-backup.log"
  exit 1
else
  log "All checks passed."
fi
