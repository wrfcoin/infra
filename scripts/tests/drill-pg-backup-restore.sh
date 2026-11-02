#!/usr/bin/env bash
# Backup and restore drill against real postgres:15-alpine with throwaway data, in
# its own compose project and volumes, with no published ports. Same mount layout
# and WAL config as testnet/docker-compose.testnet.yml. Needs Docker, so it runs by
# hand and is not in the CI suite list:
#   bash scripts/tests/drill-pg-backup-restore.sh
# It removes only its own project, by exact name.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASEBACKUP="${ROOT}/testnet/scripts/pg-basebackup.sh"
RESTORE="${ROOT}/testnet/scripts/pg-restore-pitr.sh"
PRUNE="${ROOT}/testnet/scripts/pg-wal-prune.sh"
IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"
PROJECT="pgdrill$$"
TMP="$(mktemp -d)"
S1="${PROJECT}-scratch-1"; S2="${PROJECT}-scratch-2"
FAILED=()

export COMPOSE_PROJECT_NAME="${PROJECT}"
export COMPOSE_FILE="${TMP}/compose.yml"
export PG_BASEBACKUP_LOCK="${TMP}/lock"
export PG_BASEBACKUP_METRICS_DIR="${TMP}/metrics"
export POSTGRES_CONTAINER="${PROJECT}-postgres"
DATA_VOLUME="${PROJECT}_postgres-data"
BACKUP_VOLUME="${PROJECT}_postgres-backup"

cat > "${COMPOSE_FILE}" <<YAML
services:
  postgres:
    image: ${IMAGE}
    pull_policy: never
    container_name: ${POSTGRES_CONTAINER}
    command: [postgres, -c, config_file=/etc/postgresql/postgresql.conf, -c, max_connections=200]
    environment:
      POSTGRES_DB: drilldb
      POSTGRES_USER: drillrole
      POSTGRES_PASSWORD: drill-throwaway
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - postgres-backup:/var/lib/postgresql/data/backup
      - ${ROOT}/testnet/postgresql.wal.conf:/etc/postgresql/postgresql.conf:ro
volumes:
  postgres-data: {}
  postgres-backup: {}
YAML

compose() { docker compose -f "${COMPOSE_FILE}" "$@"; }
cleanup() {
  docker rm -f "${S1}-pg" "${S2}-pg" >/dev/null 2>&1
  docker volume rm "${S1}" "${S2}" >/dev/null 2>&1
  compose down -v >/dev/null 2>&1
  rm -rf "${TMP}"
}
trap cleanup EXIT

ok() { echo "ok   $1"; }
bad() { FAILED+=("$1"); echo "FAIL $1" >&2; }
expect() { # expect NAME WANT GOT
  if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1: want '$2', got '$3'"; fi
}
sql() { docker exec -u postgres "$1" psql -U drillrole -d drilldb -XAtc "$2"; }
live() { sql "${POSTGRES_CONTAINER}" "$1"; }
started() { docker inspect "${POSTGRES_CONTAINER}" --format '{{.State.StartedAt}}'; }
in_backup() { docker exec "${POSTGRES_CONTAINER}" sh -c "$1"; }
switch_and_wait() { # force the current segment out, then wait for the archiver
  local seg
  seg="$(live "SELECT pg_walfile_name(pg_switch_wal())")"
  for _ in $(seq 1 60); do
    in_backup "test -f /var/lib/postgresql/data/backup/wal/${seg}" && return 0
    sleep 1
  done
  bad "segment ${seg} never reached the archive"
  return 1
}
expect_refused() { # expect_refused NAME ARGS...: exit 3, live container and rows unchanged
  local name="$1" before rows rc; shift
  before="$(started)"; rows="$(live 'SELECT count(*) FROM drill')"
  bash "${RESTORE}" "$@" >"${TMP}/out" 2>&1; rc=$?
  if [ "${rc}" = 3 ] && [ "$(started)" = "${before}" ] && [ "$(live 'SELECT count(*) FROM drill')" = "${rows}" ]; then
    ok "refused: ${name}"
  else
    bad "refused: ${name}: rc=${rc} $(tail -n 2 "${TMP}/out")"
  fi
}

echo "== bring up"
compose up -d >/dev/null || exit 1
for _ in $(seq 1 60); do live 'SELECT 1' >/dev/null 2>&1 && break; sleep 1; done
live 'CREATE TABLE drill (n int primary key, at timestamptz default now())' >/dev/null
live 'INSERT INTO drill (n) SELECT generate_series(1,5)' >/dev/null

echo "== a fresh backup volume is root-owned, which is the archiver failure"
sleep 3
expect "archiver cannot write yet" "yes" "$(docker logs "${POSTGRES_CONTAINER}" 2>&1 | grep -q 'backup/wal.*Permission denied' && echo yes || echo no)"

echo "== refusals before any backup exists"
expect_refused "no target at all"
expect_refused "scratch, but no base backup" --scratch-volume "${S1}"
docker volume inspect "${S1}" >/dev/null 2>&1 && bad "a refused restore created a volume" || ok "a refused restore creates no volume"

echo "== first base backup"
out="$(bash "${BASEBACKUP}" 2>&1)" || bad "pg-basebackup failed: ${out}"
expect "backup result recorded" "wrfcoin_pg_basebackup_last_run_success 1" "$(grep '^wrfcoin_pg_basebackup_last_run_success ' "${PG_BASEBACKUP_METRICS_DIR}/wrfcoin_pg_basebackup.prom")"
expect "exactly one base backup" 1 "$(in_backup 'ls -1 /var/lib/postgresql/data/backup/base | wc -l' | tr -d ' ')"
first="$(in_backup 'ls -1 /var/lib/postgresql/data/backup/base | head -n1')"
expect "backup files belong to postgres (uid 70)" 70 "$(in_backup "stat -c %u /var/lib/postgresql/data/backup/base/${first}/PG_VERSION")"
expect "the pruner accepts it" 0 "$(sh "${PRUNE}" >/dev/null 2>&1; echo $?)"
echo "${out}" | grep -q 'drill-throwaway\|drillrole' && bad "backup log printed the role or password" || ok "backup log prints no role or password"

echo "== rows after the backup must come back from WAL"
live 'INSERT INTO drill (n) SELECT generate_series(6,8)' >/dev/null
switch_and_wait
wal_before="$(in_backup 'ls -1 /var/lib/postgresql/data/backup/wal | sort | tr "\n" " "')"
live_started="$(started)"

echo "== live-target refusals"
expect_refused "old --confirm form" --target-time "2026-01-01 00:00:00+00" --confirm
expect_refused "scratch pointed at the live volume" --scratch-volume "${DATA_VOLUME}"
expect_refused "scratch pointed at the backup volume" --scratch-volume "${BACKUP_VOLUME}"
expect_refused "--live with no target" --live
expect_refused "--live with no confirmation" --live --target-volume "${DATA_VOLUME}"
expect_refused "--live with a mismatched confirmation" --live --target-volume "${DATA_VOLUME}" --confirm-overwrite yes
expect_refused "--live at some other volume" --live --target-volume "${S1}" --confirm-overwrite "${S1}"
expect_refused "--live and scratch together" --live --scratch-volume "${S1}" --target-volume "${DATA_VOLUME}" --confirm-overwrite "${DATA_VOLUME}"
docker volume create "${PROJECT}-unlabelled" >/dev/null
expect_refused "scratch over an existing volume" --scratch-volume "${PROJECT}-unlabelled"
expect_refused "cleanup of an unlabelled volume" --cleanup-scratch --scratch-volume "${PROJECT}-unlabelled"
docker volume inspect "${PROJECT}-unlabelled" >/dev/null 2>&1 && ok "unlabelled volume survived cleanup" || bad "unlabelled volume was removed"
docker volume rm "${PROJECT}-unlabelled" >/dev/null

echo "== scratch restore from base + WAL"
out="$(bash "${RESTORE}" --scratch-volume "${S1}" 2>&1)"; rc=$?
expect "scratch restore exit" 0 "${rc}"; [ "${rc}" = 0 ] || echo "${out}" >&2
expect "all rows, including those after the backup" 8 "$(sql "${S1}-pg" 'SELECT count(*) FROM drill')"
expect "scratch was promoted" f "$(sql "${S1}-pg" 'SELECT pg_is_in_recovery()')"
replayed="$(docker logs "${S1}-pg" 2>&1 | grep -c 'restored log file')"
[ "${replayed}" -gt 0 ] && ok "WAL came from the archive (${replayed} files)" || bad "no WAL restored from the archive"
expect "scratch has no network" none "$(docker inspect "${S1}-pg" --format '{{.HostConfig.NetworkMode}}')"
expect "scratch archiving is off" off "$(sql "${S1}-pg" 'SHOW archive_mode')"
expect "archive is read-only to scratch" denied "$(docker exec "${S1}-pg" sh -c 'touch /var/lib/postgresql/data/backup/wal/x 2>/dev/null && echo written || echo denied')"
sql "${S1}-pg" 'INSERT INTO drill (n) VALUES (100)' >/dev/null
expect "scratch writes stay in scratch" 8 "$(live 'SELECT count(*) FROM drill')"
expect "live archive unchanged by the scratch" "${wal_before}" "$(in_backup 'ls -1 /var/lib/postgresql/data/backup/wal | sort | head -n '"$(echo "${wal_before}" | wc -w)"' | tr "\n" " "')"
expect "no new timeline in the archive" 0 "$(in_backup 'ls -1 /var/lib/postgresql/data/backup/wal | grep -c history' | tr -d ' ')"
expect "live container not restarted" "${live_started}" "$(started)"
expect_refused "second restore over an existing scratch" --scratch-volume "${S1}"

echo "== point in time"
live 'INSERT INTO drill (n) SELECT generate_series(9,11)' >/dev/null
sleep 2; pit="$(live "SELECT to_char(now() AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US') || '+00'")"; sleep 2
live 'INSERT INTO drill (n) SELECT generate_series(12,13)' >/dev/null
switch_and_wait
expect_refused "a quote in the target time" --scratch-volume "${S2}" --target-time "2026'"
expect_refused "a path in the base backup id" --scratch-volume "${S2}" --base-backup "../../x"
out="$(bash "${RESTORE}" --scratch-volume "${S2}" --target-time "${pit}" 2>&1)"; rc=$?
expect "point-in-time restore exit" 0 "${rc}"; [ "${rc}" = 0 ] || echo "${out}" >&2
expect "rows up to the target time only" 11 "$(sql "${S2}-pg" 'SELECT count(*) FROM drill')"

echo "== cleanup by exact name"
for s in "${S1}" "${S2}"; do
  bash "${RESTORE}" --cleanup-scratch --scratch-volume "${s}" >/dev/null 2>&1 || bad "cleanup ${s}"
  docker inspect "${s}-pg" >/dev/null 2>&1 && bad "container ${s}-pg left over" || ok "container ${s}-pg gone"
  docker volume inspect "${s}" >/dev/null 2>&1 && bad "volume ${s} left over" || ok "volume ${s} gone"
done
expect "cleanup is idempotent" 0 "$(bash "${RESTORE}" --cleanup-scratch --scratch-volume "${S1}" >/dev/null 2>&1; echo $?)"

echo "== keep 3, and no WAL deleted without --prune-wal"
for _ in 1 2 3; do
  sleep 1
  live "INSERT INTO drill (n) SELECT coalesce(max(n),0)+1 FROM drill" >/dev/null
  switch_and_wait
  bash "${BASEBACKUP}" >/dev/null 2>&1 || bad "repeat base backup failed"
done
kept="$(in_backup 'ls -1 /var/lib/postgresql/data/backup/base')"
expect "3 kept" 3 "$(echo "${kept}" | wc -l | tr -d ' ')"
echo "${kept}" | grep -qx "${first}" && bad "the oldest backup was not the one removed" || ok "the oldest backup is the one removed"
expect "WAL older than the oldest kept backup still there" yes "$(in_backup "test -f /var/lib/postgresql/data/backup/wal/$(echo "${wal_before}" | awk '{print $1}')" && echo yes || echo no)"
bash "${BASEBACKUP}" --prune-wal >/dev/null 2>&1 || bad "--prune-wal run failed"
expect "--prune-wal removed the old WAL" no "$(in_backup "test -f /var/lib/postgresql/data/backup/wal/$(echo "${wal_before}" | awk '{print $1}')" && echo yes || echo no)"
out="$(bash "${RESTORE}" --scratch-volume "${S1}" 2>&1)" || { bad "restore after pruning failed"; echo "${out}" >&2; }
expect "restore from pruned archive has every row" "$(live 'SELECT count(*) FROM drill')" "$(sql "${S1}-pg" 'SELECT count(*) FROM drill')"
bash "${RESTORE}" --cleanup-scratch --scratch-volume "${S1}" >/dev/null 2>&1

echo "== a failed backup leaves nothing behind"
before="$(in_backup 'ls -1 /var/lib/postgresql/data/backup/base | tr "\n" " "')"
docker exec -u postgres "${POSTGRES_CONTAINER}" sh -c 'sed -i "1i host replication all 127.0.0.1/32 reject" "$PGDATA/pg_hba.conf"; pg_ctl reload -D "$PGDATA" >/dev/null'
docker exec -u postgres "${POSTGRES_CONTAINER}" sh -c 'sed -i "1i local replication all reject" "$PGDATA/pg_hba.conf"; pg_ctl reload -D "$PGDATA" >/dev/null'
sleep 1
bash "${BASEBACKUP}" >/dev/null 2>&1; rc=$?
[ "${rc}" != 0 ] && ok "failed backup exits non-zero (${rc})" || bad "backup with replication rejected reported success"
expect "failed backup leaves the kept backups as they were" "${before}" "$(in_backup 'ls -1 /var/lib/postgresql/data/backup/base | tr "\n" " "')"
docker exec -u postgres "${POSTGRES_CONTAINER}" sh -c 'sed -i "1,2d" "$PGDATA/pg_hba.conf"; pg_ctl reload -D "$PGDATA" >/dev/null'

echo "== live restore, with the exact confirmation"
want="$(live 'SELECT count(*) FROM drill')"
live "INSERT INTO drill (n) SELECT coalesce(max(n),0)+1 FROM drill" >/dev/null
switch_and_wait
want=$(( want + 1 ))
out="$(bash "${RESTORE}" --live --target-volume "${DATA_VOLUME}" --confirm-overwrite "${DATA_VOLUME}" 2>&1)"; rc=$?
expect "live restore exit" 0 "${rc}"; [ "${rc}" = 0 ] || echo "${out}" >&2
expect "rows after the live restore" "${want}" "$(live 'SELECT count(*) FROM drill')"
expect "same container, not recreated" "${POSTGRES_CONTAINER}" "$(docker inspect "${POSTGRES_CONTAINER}" --format '{{.Name}}' | tr -d /)"
expect "old data kept aside" 1 "$(in_backup 'ls -1d /var/lib/postgresql/data/pgdata.pre-restore-* | wc -l' | tr -d ' ')"
expect "data lands in the real PGDATA" "/var/lib/postgresql/data/pgdata" "$(live 'SHOW data_directory')"
expect "promoted" f "$(live 'SELECT pg_is_in_recovery()')"
switch_and_wait && ok "the archiver still archives after the restore"
echo "${out}" | grep -q 'drill-throwaway' && bad "restore log printed the password" || ok "restore log prints no password"

if (( ${#FAILED[@]} )); then printf 'FAILED: %s\n' "${FAILED[*]}" >&2; exit 1; fi
echo "pg backup and restore drill: all checks passed"
