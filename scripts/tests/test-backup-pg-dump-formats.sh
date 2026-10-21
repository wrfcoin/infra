#!/usr/bin/env bash
# Owner ruling 2026-09-27 08:20Z: testnet/backup.sh writes BOTH the plain-SQL
# postgres.sql (used by RESTORE_DRILL.md, UPGRADE_RUNBOOK.md and
# backup-restore-verification.sh) AND a custom-format postgres.dump
# (pg_dump -Fc), and it verifies the latter with `pg_restore --list`.
#
# Offline: `docker` is a PATH shim. Only the postgres steps are asserted; the
# redis/chain/config steps fail against the shim, which is expected here.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="${BACKUP_UNDER_TEST:-${ROOT}/testnet/backup.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()
check() { local name="$1"; shift; echo "$name"; if ! "$@"; then FAILED+=("$name"); echo "  CASE FAILED: $name" >&2; fi; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_DOCKER_CALLS"
args=" $* "
case "$args" in
  *" exec -T postgres pg_dump -U wrfcoin -Fc wrfcoin "*)
    [[ "${FAKE_FC_FAIL:-0}" == 1 ]] && exit 1
    printf 'PGDMP\001\016\000fake-custom-archive'; head -c 4096 /dev/zero
    [[ "${FAKE_FC_PARTIAL:-0}" == 1 ]] && { echo "pg_dump: error: connection lost" >&2; exit 1; }
    : ;;
  *" exec -T postgres pg_dump -U wrfcoin wrfcoin "*)
    printf -- '-- PostgreSQL database dump\nCOPY public.accounts (id) FROM stdin;\n\\.\n-- PostgreSQL database dump complete\n' ;;
  *" exec -T postgres pg_restore --list "*)
    head="$(head -c 5)"
    [[ "$head" == PGDMP && "${FAKE_RESTORE_FAIL:-0}" != 1 ]] || { echo "pg_restore: error: input file does not appear to be a valid archive" >&2; exit 1; }
    printf ';\n; Archive created at 2026-09-27\n;\n215; 1259 16385 TABLE public accounts wrfcoin\n3350; 0 16385 TABLE DATA public accounts wrfcoin\n' ;;
  *" exec -T redis redis-cli"*)
    cat > "$FAKE_REDIS_STDIN"
    grep -q "^AUTH ${FAKE_REDIS_PASSWORD}\$" "$FAKE_REDIS_STDIN" && grep -q '^BGSAVE$' "$FAKE_REDIS_STDIN" \
      && printf 'OK\nBackground saving started\n' || printf 'NOAUTH Authentication required.\n' ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/docker"

REDIS_SECRET="redis-secret-$RANDOM$RANDOM-not-in-argv"
run() { # extra env assignments...
  rm -rf "$TMP/backups"; : > "$TMP/calls"; : > "$TMP/redis-stdin"
  env PATH="$TMP/bin:$PATH" FAKE_DOCKER_CALLS="$TMP/calls" BACKUP_DIR="$TMP/backups" \
    REDIS_PASSWORD="$REDIS_SECRET" FAKE_REDIS_PASSWORD="$REDIS_SECRET" FAKE_REDIS_STDIN="$TMP/redis-stdin" \
    COMPOSE_FILE="$TMP/compose.yml" "$@" bash "$BACKUP" < /dev/null > "$TMP/out" 2>&1   # per-case overrides last
  DEST="$(ls -1d "$TMP"/backups/*/ 2>/dev/null | head -1)"
}

writes_both_formats() {
  run
  [[ -n "$DEST" ]] || { cat "$TMP/out" >&2; return 1; }
  head -1 "$DEST/postgres.sql" | grep -q '^-- PostgreSQL database dump' || { echo "    no plain-SQL dump" >&2; return 1; }
  [[ "$(head -c 5 "$DEST/postgres.dump")" == PGDMP ]] || { echo "    no custom-format postgres.dump" >&2; return 1; }
  grep -q 'exec -T postgres pg_dump -U wrfcoin -Fc wrfcoin' "$TMP/calls" || return 1
}

custom_dump_is_verified_with_pg_restore_list() {
  run
  grep -q 'exec -T postgres pg_restore --list' "$TMP/calls" || { echo "    pg_restore --list never ran" >&2; return 1; }
  grep -q 'TABLE DATA public accounts' "$DEST/postgres.dump.list" || { echo "    listing not kept next to the dump" >&2; return 1; }
  grep -q 'PostgreSQL custom dump: pg_restore --list OK' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  ! grep -q 'ERROR: PostgreSQL' "$TMP/out" || { grep 'ERROR: PostgreSQL' "$TMP/out" >&2; return 1; }
}

unreadable_custom_dump_is_an_error() {
  run FAKE_RESTORE_FAIL=1
  grep -q 'ERROR: PostgreSQL custom dump: pg_restore --list could not read' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
}

partial_custom_dump_is_never_published() {
  # pg_dump emits real-looking bytes, then fails: no final-name archive or list may exist
  run FAKE_FC_PARTIAL=1
  grep -q 'ERROR: PostgreSQL custom dump: pg_dump -Fc failed' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  [[ ! -e "$DEST/postgres.dump" && ! -e "$DEST/postgres.dump.list" ]] || { ls -la "$DEST" >&2; echo "    a partial dump was published" >&2; return 1; }
  [[ -z "$(find "$DEST" -name '.postgres.dump.*')" ]] || { echo "    the partial was left behind" >&2; return 1; }
}

unverifiable_custom_dump_is_never_published() {
  run FAKE_RESTORE_FAIL=1
  [[ ! -e "$DEST/postgres.dump" && ! -e "$DEST/postgres.dump.list" ]] || { ls -la "$DEST" >&2; echo "    an unverified dump was published" >&2; return 1; }
  [[ -z "$(find "$DEST" -name '.postgres.dump.*')" ]] || return 1
}

redis_password_never_in_docker_argv() {
  run
  ! grep -qF "$REDIS_SECRET" "$TMP/calls" || { echo "    REDIS_PASSWORD appeared in docker argv" >&2; return 1; }
  ! grep -qF "$REDIS_SECRET" "$TMP/out" || { echo "    REDIS_PASSWORD appeared in the backup log" >&2; return 1; }
  grep -qx "AUTH $REDIS_SECRET" "$TMP/redis-stdin" || { echo "    AUTH was not sent on stdin" >&2; return 1; }
  grep -q 'exec -T redis redis-cli' "$TMP/calls" || return 1
  ! grep -q 'ERROR: Redis: BGSAVE' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
}

redis_auth_failure_is_an_error() {
  run FAKE_REDIS_PASSWORD=something-else
  grep -q 'ERROR: Redis: BGSAVE was not confirmed' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
}

planted_partial_path_is_never_followed() {
  # round-62 audit: the temp dump must not be a predictable name that a planted
  # link could redirect. DEST is BACKUP_DIR/<timestamp>, so plant links in the
  # dirs of the next few seconds' timestamps.
  local victim="$TMP/outside-victim" t d i
  printf 'VICTIM-UNCHANGED\n' > "$victim"
  rm -rf "$TMP/backups"; mkdir -p "$TMP/backups"
  for i in 0 1 2 3 4 5; do
    t="$(date -d "+$i sec" +%Y%m%d_%H%M%S)"; d="$TMP/backups/$t"; mkdir -p "$d"
    ln -s "$victim" "$d/.postgres.dump.partial"; ln -s "$victim" "$d/.postgres.dump.partial.list"
  done
  : > "$TMP/calls"; : > "$TMP/redis-stdin"
  env PATH="$TMP/bin:$PATH" FAKE_DOCKER_CALLS="$TMP/calls" BACKUP_DIR="$TMP/backups" \
    REDIS_PASSWORD="$REDIS_SECRET" FAKE_REDIS_PASSWORD="$REDIS_SECRET" FAKE_REDIS_STDIN="$TMP/redis-stdin" \
    COMPOSE_FILE="$TMP/compose.yml" bash "$BACKUP" < /dev/null > "$TMP/out" 2>&1
  grep -qx 'VICTIM-UNCHANGED' "$victim" || { echo "    a planted link redirected the dump" >&2; return 1; }
  grep -q 'PostgreSQL custom dump: pg_restore --list OK' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
}

failed_custom_dump_is_an_error() {
  run FAKE_FC_FAIL=1
  grep -q 'ERROR: PostgreSQL custom dump: pg_dump -Fc failed' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  # the plain dump is still taken
  head -1 "$DEST/postgres.sql" | grep -q '^-- PostgreSQL database dump' || return 1
}

[[ -f "$BACKUP" ]] || { echo "BACKUP_PG_TESTS=FAIL $BACKUP missing" >&2; exit 1; }
check writes_both_formats writes_both_formats
check custom_dump_is_verified_with_pg_restore_list custom_dump_is_verified_with_pg_restore_list
check unreadable_custom_dump_is_an_error unreadable_custom_dump_is_an_error
check failed_custom_dump_is_an_error failed_custom_dump_is_an_error
check planted_partial_path_is_never_followed planted_partial_path_is_never_followed
check partial_custom_dump_is_never_published partial_custom_dump_is_never_published
check unverifiable_custom_dump_is_never_published unverifiable_custom_dump_is_never_published
check redis_password_never_in_docker_argv redis_password_never_in_docker_argv
check redis_auth_failure_is_an_error redis_auth_failure_is_an_error

if [[ ${#FAILED[@]} -gt 0 ]]; then echo "BACKUP_PG_TESTS=FAIL cases: ${FAILED[*]}" >&2; exit 1; fi
echo BACKUP_PG_TESTS=PASS
