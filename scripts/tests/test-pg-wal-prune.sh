#!/usr/bin/env bash
# testnet/scripts/pg-wal-prune.sh must never delete a segment needed to replay
# from the oldest retained base backup, and must delete nothing when it cannot
# prove which those are.
#
# Offline: the postgres tools are PATH shims. The shim for pg_archivecleanup keeps
# the real tool's rule (older than the given file, by name without the timeline;
# history and .backup files stay).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRUNE="${ROOT}/testnet/scripts/pg-wal-prune.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()

mkdir -p "$TMP/bin"
cat > "$TMP/bin/pg_verifybackup" <<'SHIM'
#!/usr/bin/env bash
# Asserts the flags the real tool needs for backup-size.txt, which is not in the manifest.
[[ " $* " == *" -i backup-size.txt "* ]] || { echo "shim: backup-size.txt not ignored" >&2; exit 9; }
for last; do :; done
[[ ! -e "$last/.corrupt" ]]
SHIM
cat > "$TMP/bin/pg_controldata" <<'SHIM'
#!/usr/bin/env bash
if [[ -e "$1/.big-segments" ]]; then echo 'Bytes per WAL segment:                67108864'
else echo 'Bytes per WAL segment:                16777216'; fi
SHIM
cat > "$TMP/bin/pg_archivecleanup" <<'SHIM'
#!/usr/bin/env bash
dry=0; [[ "$1" == -n ]] && { dry=1; shift; }
for f in "$1"/*; do
  n="$(basename "$f")"
  [[ "$n" =~ ^[0-9A-F]{24}$ ]] || continue
  if [[ "${n:8}" < "${2:8}" ]]; then
    if [[ "$dry" == 1 ]]; then echo "$f"; else rm -f "$f"; fi
  fi
done
SHIM
chmod +x "$TMP/bin/"*

SEGMENTS=(000000010000000000000001 000000010000000000000002 000000010000000000000003
  0000000100000000000000FF 000000010000000100000000 000000010000000100000001)
fresh() {
  R="$TMP/root"; rm -rf "$R"; mkdir -p "$R/wal"
  for s in "${SEGMENTS[@]}"; do : > "$R/wal/$s"; done
  : > "$R/wal/000000010000000000000002.00000028.backup"
  : > "$R/wal/00000002.history"
}
base() { # base NAME START_SEGMENT
  local d="$R/base/$1"; mkdir -p "$d/global"; : > "$d/backup_manifest"; : > "$d/PG_VERSION"; : > "$d/global/pg_control"
  : > "$d/backup-size.txt"
  printf 'START WAL LOCATION: 0/2000028 (file %s)\nCHECKPOINT LOCATION: 0/2000060\n' "$2" > "$d/backup_label"
}
wal() { ls -1 "$R/wal" | tr '\n' ' '; }
run() { OUT="$(PATH="$TMP/bin:$PATH" sh "$PRUNE" --local-root "$R" "$@" 2>&1)"; RC=$?; }
check() { # check NAME EXPECTED_RC 'expected log text' EXPECTED_WAL (empty = unchanged)
  local name="$1" rc="$2" text="$3" want="${4:-$ALL}"
  if [[ "$RC" != "$rc" ]] || ! grep -qF -- "$text" <<<"$OUT" || [[ "$(wal)" != "$want" ]]; then
    FAILED+=("$name")
    printf 'FAIL %s\n  rc=%s want %s\n  wal=%s\n  want=%s\n  log=%s\n' "$name" "$RC" "$rc" "$(wal)" "$want" "$OUT" >&2
  else
    echo "ok   $name"
  fi
}
fresh; ALL="$(wal)"
# 03 to FF is a gap in this fixture, so fill it for the runs that must succeed.
fill() { local i; for i in $(seq 4 254); do : > "$R/wal/$(printf '0000000100000000000000%02X' "$i")"; done; }

fresh; run --apply
check "no base directory: refuse, loudly" 3 "NO BASE BACKUP"

fresh; mkdir "$R/base"; run --apply
check "empty base directory: refuse, loudly" 3 "NO BASE BACKUP"

fresh; rm -rf "$R/wal"; mkdir -p "$R/base"; run --apply
[[ "$RC" == 3 ]] && grep -qF "no WAL archive" <<<"$OUT" && echo "ok   no archive: refuse" || FAILED+=("no archive")

fresh; fill; base b1 000000010000000000000002; ALLF="$(wal)"; run
check "dry run is the default and deletes nothing" 0 "DRY RUN: would delete 1 segment(s)" "$ALLF"

fresh; fill; base b1 000000010000000000000002; ALLF="$(wal)"; run --dry-run
check "--dry-run deletes nothing" 0 "DRY RUN" "$ALLF"

fresh; fill; base b1 000000010000000000000002; ALLF="$(wal)"; run --apply
check "apply removes only what is older than the backup" 0 "deleted 1 segment(s)" "${ALLF/000000010000000000000001 /}"

fresh; fill; base b1 000000010000000000000003; base b2 000000010000000000000002; ALLF="$(wal)"; run --apply
check "the anchor is the oldest by WAL position, not by directory name" 0 "keeping WAL from 000000010000000000000002" "${ALLF/000000010000000000000001 /}"

fresh; fill; base b1 000000020000000000000002; ALLF="$(wal)"; run --apply
check "anchor file on a timeline the archive does not hold: refuse" 3 "000000020000000000000002 is not in the archive" "$ALLF"

fresh; fill; base b1 000000010000000000000001; ALLF="$(wal)"; run --apply
check "nothing older: no-op" 0 "nothing to prune" "$ALLF"

fresh; fill; base b1 000000010000000000000002; base b2 000000010000000000000003; : > "$R/base/b2/.corrupt"; ALLF="$(wal)"; run --apply
check "any backup that fails pg_verifybackup: refuse" 3 "is not valid" "$ALLF"

fresh; fill; base b1 000000010000000000000002; rm "$R/base/b1/backup_manifest"; ALLF="$(wal)"; run --apply
check "no manifest, a backup still being written: refuse" 3 "missing backup_manifest" "$ALLF"

fresh; fill; base b1 000000010000000000000002; rm "$R/base/b1/backup_label"; ALLF="$(wal)"; run --apply
check "no backup_label: refuse" 3 "missing backup_label" "$ALLF"

fresh; fill; base b1 000000010000000000000002; printf 'START WAL LOCATION: nonsense\n' > "$R/base/b1/backup_label"; ALLF="$(wal)"; run --apply
check "unreadable backup_label: refuse" 3 "no readable START WAL" "$ALLF"

fresh; fill; base b1 000000010000000000000002; : > "$R/base/b1/.big-segments"; ALLF="$(wal)"; run --apply
check "non-default WAL segment size: refuse" 3 "WAL segment size" "$ALLF"

fresh; fill; base b1 000000010000000000000002; rm "$R/wal/000000010000000000000002"; ALLF="$(wal)"; run --apply
check "anchor segment missing: refuse" 3 "is not in the archive" "$ALLF"

fresh; fill; base b1 000000010000000000000002; rm "$R/wal/000000010000000000000080"; ALLF="$(wal)"; run --apply
check "gap after the anchor: refuse" 3 "archive gap" "$ALLF"

fresh; base b1 000000010000000000000002; ALLF="$(wal)"; run --apply
check "a gap across the log boundary fixture: refuse" 3 "archive gap" "$ALLF"

fresh; fill; base b1 0000000100000000000000FF; ALLF="$(wal)"; run --apply
[[ "$RC" == 0 ]] && [[ -f "$R/wal/000000010000000100000000" ]] && [[ -f "$R/wal/000000010000000100000001" ]] && [[ ! -f "$R/wal/0000000100000000000000FE" ]] \
  && echo "ok   carries across a log boundary, FF then next log 00" || { FAILED+=("log boundary"); echo "FAIL log boundary: $OUT" >&2; }

PATH="$TMP/bin:$PATH" sh "$PRUNE" --bogus >/dev/null 2>&1; [[ $? == 2 ]] && echo "ok   unknown argument exits 2" || FAILED+=("usage")

if (( ${#FAILED[@]} )); then echo "FAILED: ${FAILED[*]}" >&2; exit 1; fi
echo "pg-wal-prune: all cases passed"
