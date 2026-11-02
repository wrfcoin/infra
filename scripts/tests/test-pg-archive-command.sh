#!/usr/bin/env bash
# The archive_command in testnet/postgresql.wal.conf must never leave a partial file
# under a segment's final name. Runs the configured command itself under sh, the way
# Postgres does, against a temp directory. Real Postgres coverage is in
# scripts/tests/drill-pg-backup-restore.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${ROOT}/testnet/postgresql.wal.conf"
ARCHIVE_PATH="/var/lib/postgresql/data/backup/wal"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()
SEG="000000010000000000000042"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED+=("$1"); }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

TEMPLATE="$(sed -n "s/^archive_command = '\(.*\)'\$/\1/p" "$CONF")"
[[ -n "$TEMPLATE" ]] || { echo "FAIL: no archive_command in $CONF"; exit 1; }
[[ "$TEMPLATE" == *"$ARCHIVE_PATH"* ]] || { echo "FAIL: archive_command does not use $ARCHIVE_PATH"; exit 1; }

WAL="$TMP/archive/wal"
FINAL="$WAL/$SEG"
TEMP="$WAL/.$SEG.tmp"
mkdir -p "$TMP/data/pg_wal" "$TMP/shim"
head -c 65536 /dev/urandom > "$TMP/data/pg_wal/$SEG"
SOURCE="$TMP/data/pg_wal/$SEG"

# Substitutes as Postgres does, with the relative %p Postgres passes from its data dir.
archive() {
  local cmd="${TEMPLATE//$ARCHIVE_PATH/$WAL}"
  cmd="${cmd//%p/pg_wal/$SEG}"
  cmd="${cmd//%f/$SEG}"
  ( cd "$TMP/data" && PATH="${SHIM_PATH:-}$PATH" sh -c "$cmd" ) >"$TMP/out" 2>&1
}
fresh() { rm -rf "$TMP/archive" "$TMP/shim"; mkdir -p "$TMP/shim"; unset SHIM_PATH; }
same() { cmp -s "$1" "$2" && echo same || echo differs; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }

# First copy
fresh; archive; check "first copy succeeds" 0 "$?"
check "first copy has the right bytes" same "$(same "$SOURCE" "$FINAL")"
check "first copy leaves no temp file" no "$(exists "$TEMP")"

# Identical file already there
before="$(stat -c %Y-%i "$FINAL")"
archive; check "identical file already there succeeds" 0 "$?"
check "identical file is left untouched" "$before" "$(stat -c %Y-%i "$FINAL")"

# Different file already there
fresh; mkdir -p "$WAL"; echo other > "$FINAL"
archive; check "different file already there fails" 1 "$(( $? != 0 ))"
check "different file is not overwritten" other "$(cat "$FINAL")"
check "different file leaves no temp file" no "$(exists "$TEMP")"
grep -q . "$TMP/out"; check "different file reports why in the log" 0 "$?"

# Copy interrupted half way
fresh
cat > "$TMP/shim/cp" <<'SHIM'
#!/bin/sh
head -c 100 "$1" > "$2"
exit 1
SHIM
chmod +x "$TMP/shim/cp"
SHIM_PATH="$TMP/shim:"
archive; check "interrupted copy fails" 1 "$(( $? != 0 ))"
check "interrupted copy leaves nothing under the final name" no "$(exists "$FINAL")"
check "interrupted copy really left a partial temp" 100 "$(stat -c %s "$TEMP" 2>/dev/null)"
unset SHIM_PATH
archive; check "retry after an interrupted copy succeeds" 0 "$?"
check "retry has the right bytes" same "$(same "$SOURCE" "$FINAL")"
check "retry consumes the temp file" no "$(exists "$TEMP")"

# The rename must wait until the copy is on disk
fresh
printf '#!/bin/sh\nexit 1\n' > "$TMP/shim/sync"
chmod +x "$TMP/shim/sync"
SHIM_PATH="$TMP/shim:"
archive; check "failed flush fails" 1 "$(( $? != 0 ))"
check "failed flush leaves nothing under the final name" no "$(exists "$FINAL")"
unset SHIM_PATH

if ((${#FAILED[@]})); then
  echo "PG_ARCHIVE_COMMAND_TESTS=FAIL (${#FAILED[@]})"
  exit 1
fi
echo "PG_ARCHIVE_COMMAND_TESTS=PASS"
