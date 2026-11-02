#!/bin/sh
# =============================================================================
# WRFCoin Testnet - PostgreSQL WAL archive pruning, anchored on base backups
#
# Removes archived WAL older than the oldest retained base backup, and nothing
# else. A segment at or after that backup's START WAL file is needed to replay
# from it, so it is never a candidate. The window this keeps is therefore "from
# the oldest base backup to now"; pg-basebackup.sh's keep count sets its length.
#
# It refuses, deletes nothing and exits 3 when it cannot prove that is safe:
#   - no base backup directory, or none in it;
#   - any base backup that does not verify (a backup still being written counts,
#     since its backup_manifest is written last);
#   - the anchor segment missing, or a gap in the archive after it.
#
# Usage (from the host, runs inside the postgres container):
#   bash testnet/scripts/pg-wal-prune.sh            # dry run: report only
#   bash testnet/scripts/pg-wal-prune.sh --apply    # delete
#
# Exit: 0 done or nothing to do; 2 usage; 3 refused, nothing deleted.
# --local-root DIR runs the logic against DIR/base and DIR/wal directly. That is
# what the host mode runs inside the container (and what the test runs).
# POSIX sh: the postgres image is Alpine, with BusyBox and no bash or python.
# =============================================================================
set -eu

APPLY=0
ROOT=""
CONTAINER_ROOT="/var/lib/postgresql/data/backup"
SEGMENT_BYTES=16777216   # WAL file names map to positions at 256 segments per log only at 16 MB

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] pg-wal-prune: $*"; }
refuse() { log "REFUSED, nothing deleted: $*"; exit 3; }

position() { printf '%s\n' "$1" | cut -c9-24; }   # file name without its timeline

# True when position $1 sorts before position $2 (same-length uppercase hex).
before() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -n 1)" = "$1" ]
}

segments() {
  find "$WAL" -maxdepth 1 -type f | sed 's|.*/||' | grep -E '^[0-9A-F]{24}$' || true
}

# Prints a base backup's START WAL file, or logs why it is not valid and fails.
start_segment() {
  dir="$1"
  for need in backup_label backup_manifest PG_VERSION global/pg_control; do
    [ -f "$dir/$need" ] || { log "base backup $dir: missing $need" >&2; return 1; }
  done
  segment="$(sed -n 's|^START WAL LOCATION: [0-9A-F]*/[0-9A-F]* (file \([0-9A-F]\{24\}\))$|\1|p' "$dir/backup_label")"
  if ! printf '%s\n' "$segment" | grep -Eq '^[0-9A-F]{24}$'; then
    log "base backup $dir: no readable START WAL file in backup_label" >&2
    return 1
  fi
  # backup-size.txt is added by pg-basebackup.sh, so it is not in the manifest.
  if ! pg_verifybackup -q -s -i backup-size.txt "$dir" </dev/null >&2; then
    log "base backup $dir: pg_verifybackup failed" >&2
    return 1
  fi
  bytes="$(pg_controldata "$dir" </dev/null | sed -n 's/^Bytes per WAL segment: *//p')"
  if [ "$bytes" != "$SEGMENT_BYTES" ]; then
    log "base backup $dir: WAL segment size '${bytes}' is not ${SEGMENT_BYTES}" >&2
    return 1
  fi
  printf '%s\n' "$segment"
}

# Fails when the archive does not hold every position from $1 on, without a gap.
check_contiguous() {
  [ -f "$WAL/$1" ] || { log "anchor segment $1 is not in the archive"; return 1; }
  wanted="$(position "$1")"
  # String comparison on purpose: as a number, awk reads 00000000000000E0 as zero.
  held="$(segments | cut -c9-24 | LC_ALL=C sort -u | awk -v from="$wanted" '($0 "") >= (from "")')"
  while read -r pos; do
    [ -n "$pos" ] || continue
    if [ "$pos" != "$wanted" ]; then
      log "archive gap: expected position ${wanted}, found ${pos}"
      return 1
    fi
    xlog="$(printf '%s\n' "$pos" | cut -c1-8)"
    seg="$(printf '%s\n' "$pos" | cut -c9-16)"
    next=$(( 0x$xlog * 256 + 0x$seg + 1 ))
    wanted="$(printf '%08X%08X' $(( next / 256 )) $(( next % 256 )))"
  done <<HELD
$held
HELD
}

prune() {
  BASE="$ROOT/base"
  WAL="$ROOT/wal"
  [ -d "$WAL" ] || refuse "no WAL archive at $WAL"
  log "archive holds $(segments | wc -l | tr -d ' ') segment(s)"
  [ -d "$BASE" ] || refuse "NO BASE BACKUP: $BASE does not exist, so this WAL cannot be replayed from anything"

  anchor=""
  anchor_dir=""
  count=0
  for dir in "$BASE"/*; do
    [ -d "$dir" ] || continue
    count=$(( count + 1 ))
    segment="$(start_segment "$dir")" || refuse "base backup $dir is not valid; fix or remove it first"
    log "base backup $(basename "$dir"): valid, starts at $segment"
    if [ -z "$anchor" ] || before "$(position "$segment")" "$(position "$anchor")"; then
      anchor="$segment"
      anchor_dir="$dir"
    fi
  done
  [ "$count" -gt 0 ] || refuse "NO BASE BACKUP: $BASE is empty, so this WAL cannot be replayed from anything"
  log "oldest retained base backup: $(basename "$anchor_dir"), keeping WAL from $anchor"

  check_contiguous "$anchor" || refuse "the archive cannot replay from $anchor"

  listed="$(pg_archivecleanup -n "$WAL" "$anchor" </dev/null)"
  candidates=0
  anchor_pos="$(position "$anchor")"
  for path in $listed; do
    name="$(basename "$path")"
    # Belt and braces on the tool's own answer: only WAL older than the anchor.
    printf '%s\n' "$name" | grep -Eq '^[0-9A-F]{24}$' || refuse "unexpected candidate $name"
    before "$(position "$name")" "$anchor_pos" || refuse "candidate $name is not older than $anchor"
    candidates=$(( candidates + 1 ))
  done
  if [ "$candidates" -eq 0 ]; then
    log "nothing older than $anchor; nothing to prune"
    return 0
  fi
  if [ "$APPLY" -ne 1 ]; then
    log "DRY RUN: would delete ${candidates} segment(s) older than $anchor; rerun with --apply"
    return 0
  fi
  pg_archivecleanup "$WAL" "$anchor" </dev/null
  [ -f "$WAL/$anchor" ] || { log "ERROR: anchor segment $anchor is gone after cleanup"; exit 1; }
  log "deleted ${candidates} segment(s) older than $anchor; $(segments | wc -l | tr -d ' ') remain"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --local-root) ROOT="${2:?--local-root needs a directory}"; shift ;;
    -h|--help) sed -n '2,/^# ====.*$/p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$ROOT" ]; then
  prune
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/../docker-compose.testnet.yml}"
if [ "$APPLY" -eq 1 ]; then mode="--apply"; else mode="--dry-run"; fi
exec docker compose -f "$COMPOSE_FILE" exec -T postgres sh -s -- --local-root "$CONTAINER_ROOT" "$mode" <"$0"
