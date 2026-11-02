#!/usr/bin/env bash
# testnet/scripts/pg-restore-pitr.sh must change nothing unless told exactly where
# to restore, and pg-basebackup.sh must not delete anything before the new backup
# has passed. Offline: docker is a PATH shim that records every call. The real thing
# is scripts/tests/drill-pg-backup-restore.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESTORE="${ROOT}/testnet/scripts/pg-restore-pitr.sh"
BASEBACKUP="${ROOT}/testnet/scripts/pg-basebackup.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
# Knobs: SHIM_NO_LIVE, SHIM_BASES, SHIM_VERIFY_FAIL, SHIM_FAIL_MATCH, and $SHIM/vol.NAME = a volume ("1" = labelled).
echo "docker $*" >> "$SHIM/calls"
if [[ -n "${SHIM_FAIL_MATCH:-}" && "$*" == *"$SHIM_FAIL_MATCH"* ]]; then exit 1; fi
case "$1" in
  compose)
    case " $* " in
      *" ps -aq "*) [[ -n "${SHIM_NO_LIVE:-}" ]] || echo live-id ;;
      *"ls -1 "*) echo 20260101_000000 ;;
    esac ;;
  inspect)
    case "$*" in
      *'/var/lib/postgresql/data/backup'*) echo backup-vol ;;
      *'/var/lib/postgresql/data"'*) echo data-vol ;;
      *'.Config.Labels'*) [[ -e "$SHIM/ctr.$2" ]] && cat "$SHIM/ctr.$2" ;;
      *'.State.Running'*) echo true ;;
      *) [[ "$2" == live-id || -e "$SHIM/ctr.$2" ]] || exit 1 ;;
    esac ;;
  volume)
    case "$2" in
      inspect) [[ -e "$SHIM/vol.$3" ]] || exit 1; if [[ "$*" == *--format* ]]; then cat "$SHIM/vol.$3"; fi ;;
      create) n="${!#}"; echo 1 > "$SHIM/vol.$n" ;;
      rm) rm -f "$SHIM/vol.$3" ;;
    esac ;;
  rm) rm -f "$SHIM/ctr.$3" ;;
  exec)
    case "$*" in
      *pg_is_in_recovery*) echo f ;;
      *POSTGRES_USER*) printf 'shimrole' ;;
      *POSTGRES_DB*) printf 'shimdb' ;;
    esac ;;
  run)
    case "$*" in
      *pg_verifybackup*) [[ -z "${SHIM_VERIFY_FAIL:-}" ]] ;;
      *"ls -1 /backup/base"*) printf '%s' "${SHIM_BASES-20260101_000000}" ;;
    esac ;;
esac
SHIM
chmod +x "$TMP/bin/docker"

export SHIM="$TMP/shim" COMPOSE_FILE="$TMP/compose.yml" PG_BASEBACKUP_LOCK="$TMP/lock"
fresh() { rm -rf "$SHIM"; mkdir -p "$SHIM"; : > "$SHIM/calls"; unset SHIM_NO_LIVE SHIM_BASES SHIM_VERIFY_FAIL SHIM_FAIL_MATCH; }
run() { OUT="$(PATH="$TMP/bin:$PATH" bash "$@" 2>&1)"; RC=$?; }
restore() { run "$RESTORE" "$@"; }
pass() { echo "ok   $1"; }
fail() { FAILED+=("$1"); printf 'FAIL %s\n  rc=%s\n  out=%s\n  calls=\n%s\n' "$1" "$RC" "$OUT" "$(cat "$SHIM/calls")" >&2; }
# Anything that could change a volume, a container or data.
MUTATING='docker (stop|start|rm|run -d|volume (create|rm)|compose .* (up|down|stop|restart))|mv /data|cp -a'
called() { grep -qE -- "$1" "$SHIM/calls"; }
check_refused() { # check_refused NAME [expected text] ARGS...
  local name="$1" text="$2"; shift 2
  fresh; [[ -n "${PRE:-}" ]] && eval "$PRE"
  restore "$@"
  if [[ "$RC" == 3 ]] && grep -qF -- "$text" <<<"$OUT" && ! called "$MUTATING"; then pass "refuse: $name"; else fail "refuse: $name"; fi
}

check_refused "no target" "no target given"
check_refused "old --confirm alone" "--confirm alone" --target-time "2026-01-01 00:00:00+00" --confirm
check_refused "--live, no target volume" "--live needs --target-volume" --live
check_refused "--live, no confirmation" "--confirm-overwrite must repeat" --live --target-volume data-vol
check_refused "--live, wrong confirmation" "--confirm-overwrite must repeat" --live --target-volume data-vol --confirm-overwrite yes
check_refused "--live, a volume that is not live" "is not the volume" --live --target-volume other --confirm-overwrite other
check_refused "--live plus scratch" "different targets" --live --scratch-volume s --target-volume data-vol --confirm-overwrite data-vol
check_refused "live flags on a scratch restore" "only apply with --live" --scratch-volume s --target-volume data-vol --confirm-overwrite data-vol
check_refused "scratch on the live volume" "live data volume" --scratch-volume data-vol
check_refused "scratch on the backup volume" "backup volume" --scratch-volume backup-vol
check_refused "bad scratch name" "bad name" --scratch-volume 'a/b'
check_refused "bad base backup id" "bad --base-backup" --scratch-volume s --base-backup '../x'
check_refused "quote in target time" "bad --target-time" --scratch-volume s --target-time "x'y"
PRE='echo > "$SHIM/vol.s"'
check_refused "scratch volume already exists" "already exists" --scratch-volume s
PRE='echo 1 > "$SHIM/ctr.s-pg"'
check_refused "scratch container already exists" "already exists" --scratch-volume s
PRE='export SHIM_NO_LIVE=1'
check_refused "cannot tell what is live" "cannot find the postgres container" --scratch-volume s
PRE='export SHIM_BASES='
check_refused "no base backup" "no base backup" --scratch-volume s
PRE='export SHIM_VERIFY_FAIL=1'
check_refused "backup fails verification, scratch" "fails pg_verifybackup" --scratch-volume s
check_refused "backup fails verification, live: nothing stopped" "fails pg_verifybackup" --live --target-volume data-vol --confirm-overwrite data-vol
PRE='echo > "$SHIM/vol.s"'
check_refused "cleanup of an unlabelled volume" "not labelled" --cleanup-scratch --scratch-volume s
PRE='echo 1 > "$SHIM/vol.s"; echo > "$SHIM/ctr.s-pg"'
check_refused "cleanup of an unlabelled container" "not labelled" --cleanup-scratch --scratch-volume s
PRE=''

fresh; restore --help; [[ "$RC" == 0 ]] && ! called "$MUTATING" && pass "--help changes nothing" || fail "--help"
fresh; restore --bogus; [[ "$RC" == 2 ]] && pass "unknown argument exits 2" || fail "usage"

fresh; restore --scratch-volume s
if [[ "$RC" == 0 ]] \
  && called 'docker volume create --label wrfcoin.pg-restore-scratch=1 s$' \
  && called 'docker run -d --pull never --name s-pg --label wrfcoin.pg-restore-scratch=1 --network none' \
  && called '-e PGDATA=/var/lib/postgresql/data/pgdata -v s:/var/lib/postgresql/data -v backup-vol:/var/lib/postgresql/data/backup:ro' \
  && called 'postgres -c archive_mode=off -c hot_standby=off -c listen_addresses=' \
  && called 'run --rm --pull never --network none -v s:/data -v backup-vol:/backup:ro' \
  && called 'DEST=/data/pgdata ' \
  && called 'chown -R postgres:postgres' \
  && ! called 'chown -R 999' \
  && ! called 'docker (stop|start) ' && ! called 'data-vol:' && ! called 'compose .* (up|down)' && ! called '-U postgres'; then
  pass "scratch: separate volume, no network, read-only archive, live untouched"
else fail "scratch happy path"; fi

fresh; restore --live --target-volume data-vol --confirm-overwrite data-vol
stop_line="$(grep -n 'docker stop -t 60 live-id' "$SHIM/calls" | cut -d: -f1)"; verify_line="$(grep -n 'pg_verifybackup' "$SHIM/calls" | head -n1 | cut -d: -f1)"
if [[ "$RC" == 0 ]] && [[ -n "$stop_line" && "$verify_line" -lt "$stop_line" ]] \
  && called 'DEST=/data/pgdata.restoring-' && called 'pgdata.pre-restore-' && called 'docker start live-id' \
  && ! called 'compose .* (up|down)' && ! called 'find /pgdata' && ! called 'rm -rf -- /data/pgdata$'; then
  pass "live: verifies first, keeps old data, same container, no compose up or down"
else fail "live happy path"; fi

fresh; SHIM_FAIL_MATCH='DEST=/data/pgdata.restoring-'; export SHIM_FAIL_MATCH; restore --live --target-volume data-vol --confirm-overwrite data-vol
if [[ "$RC" == 1 ]] && called 'docker start live-id' && ! called 'pgdata.pre-restore-'; then pass "live: a failed copy restarts on the old data"; else fail "live failed copy"; fi

fresh; echo 1 > "$SHIM/vol.s"; echo 1 > "$SHIM/ctr.s-pg"; restore --cleanup-scratch --scratch-volume s
if [[ "$RC" == 0 ]] && called 'docker rm -f s-pg$' && called 'docker volume rm s$' && [[ "$(grep -cE 'docker (rm|volume rm)' "$SHIM/calls")" == 2 ]]; then pass "cleanup removes the labelled pair, by exact name"; else fail "cleanup"; fi

# --- pg-basebackup.sh ---------------------------------------------------------------
line_of() { grep -n -- "$1" "$SHIM/calls" | head -n1 | cut -d: -f1; }
bb() { run "$BASEBACKUP" "$@"; }

export POSTGRES_PASSWORD=shim-secret-value
fresh; bb
unset POSTGRES_PASSWORD
v="$(line_of 'pg_verifybackup -q')"; r="$(line_of 'sort -r')"; b="$(line_of 'pg_basebackup -h')"
if [[ "$RC" == 0 ]] && [[ -n "$b" && -n "$v" && -n "$r" && "$b" -lt "$v" && "$v" -lt "$r" ]]; then pass "backup, then verify, then retention"; else fail "basebackup order"; fi
called '--user postgres postgres sh -ceu PGPASSWORD=' && pass "backup runs as the postgres user, so files get its uid" || fail "backup user"
called '-U \$\{POSTGRES_USER\}|-U "\$\{POSTGRES_USER\}"' && ! called '-U postgres' && ! called '-U wrfcoin' && pass "role comes from the container's env" || fail "role"
! called 'shim-secret-value' && ! grep -qF 'shim-secret-value' <<<"$OUT" && pass "password not in any argv or the log" || fail "password leak"
called '/var/lib/postgresql/data/backup/base/[0-9]{8}_[0-9]{6}' && pass "writes where the pruner reads" || fail "path"
called '-printf' && fail "retention uses find -printf, absent from BusyBox" || pass "retention uses no find -printf"
called 'tail -n \+4' && pass "default keeps 3" || fail "keep 3"
called 'pg-wal-prune|pg_archivecleanup|--local-root' && fail "pruned without --prune-wal" || pass "no WAL pruning unless asked"

fresh; PATH="$TMP/bin:$PATH" PG_BASEBACKUP_KEEP_COUNT=5 bash "$BASEBACKUP" >/dev/null 2>&1; called 'tail -n \+6' && pass "PG_BASEBACKUP_KEEP_COUNT is honoured" || { RC=x; OUT=; fail "keep count"; }

fresh; export BASE_BACKUP_KEEP_COUNT=0; bb; unset BASE_BACKUP_KEEP_COUNT
[[ "$RC" == 1 ]] && ! called 'exec' && pass "keep count 0: refused before any exec" || fail "keep 0"

fresh; bb --prune-wal
p="$(line_of '--local-root')"; [[ "$RC" == 0 && -n "$p" && "$p" -gt "$(line_of 'sort -r')" ]] && called '--apply' && pass "--prune-wal runs the pruner after retention" || fail "--prune-wal"

for what in 'pg_basebackup -h' 'pg_verifybackup -q'; do
  fresh; export SHIM_FAIL_MATCH="$what"; bb; unset SHIM_FAIL_MATCH
  if [[ "$RC" != 0 ]] && called 'rm -rf -- /var/lib/postgresql/data/backup/base/[0-9_]+$' && ! called 'sort -r'; then
    pass "'$what' fails: attempt removed, older backups left"
  else fail "$what failure"; fi
done

fresh; bb --bogus; [[ "$RC" == 2 ]] && pass "basebackup unknown argument exits 2" || fail "basebackup usage"

fresh; exec 8>"$PG_BASEBACKUP_LOCK"; flock -n 8; bb; exec 8>&-
[[ "$RC" == 75 ]] && ! called 'exec' && pass "a second run stops at the lock" || fail "lock"

if (( ${#FAILED[@]} )); then echo "FAILED: ${FAILED[*]}" >&2; exit 1; fi
echo "pg backup and restore: all cases passed"
