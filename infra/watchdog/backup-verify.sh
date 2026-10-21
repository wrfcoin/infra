#!/usr/bin/env bash
# =============================================================================
# backup-verify.sh — Backup verification and reporting
# =============================================================================
#
# USAGE:
#   ./backup-verify.sh [OPTIONS]
#
# DESCRIPTION:
#   Cron-friendly script that verifies backup integrity across three checks:
#     (a) Backup file exists and is newer than the configured max age
#     (b) SHA-256 checksum matches the stored .sha256 file
#     (c) Backup file size is above the configured minimum threshold
#   Outputs a structured pass/fail report to stdout and exits non-zero on any failure.
#
# OPTIONS:
#   -f <file>       Backup file to verify (required)
#   -m <minutes>    Maximum allowed age in minutes (default: 1440 = 24h)
#   -s <bytes>      Minimum file size in bytes (default: 1048576 = 1 MB)
#   -c <file>       Checksum file path (default: <backup-file>.sha256)
#   -o <file>       Write JSON report to this file (optional)
#   -r <dir>        Verify all *.tar.gz / *.sql.gz / *.bak in this directory
#   -q              Quiet mode: only print summary line
#   -h              Show this help
#
# EXIT CODES:
#   0 — All checks passed
#   1 — One or more checks failed
#   2 — Usage error
#
# DEPENDENCIES: sha256sum, stat, date, jq (optional for JSON output)
#
# EXAMPLES:
#   # Verify a single backup file
#   ./backup-verify.sh -f /backups/wrfcoin-db-2026-04-05.sql.gz
#
#   # Verify all backups in a directory, max age 12h, min size 10MB
#   ./backup-verify.sh -r /backups -m 720 -s 10485760
#
#   # Cron usage: verify and write JSON report, alert on failure
#   ./backup-verify.sh -f /backups/latest.tar.gz -o /var/log/wrfcoin/backup-report.json
#
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
BACKUP_FILE=""
BACKUP_DIR=""
MAX_AGE_MINUTES=1440   # 24 hours
MIN_SIZE_BYTES=1048576 # 1 MB
CHECKSUM_FILE=""
REPORT_FILE=""
QUIET=false

PASS=0
FAIL=0
TOTAL_CHECKS=0

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while getopts "f:m:s:c:o:r:qh" opt; do
  case "$opt" in
    f) BACKUP_FILE="$OPTARG" ;;
    m) MAX_AGE_MINUTES="$OPTARG" ;;
    s) MIN_SIZE_BYTES="$OPTARG" ;;
    c) CHECKSUM_FILE="$OPTARG" ;;
    o) REPORT_FILE="$OPTARG" ;;
    r) BACKUP_DIR="$OPTARG" ;;
    q) QUIET=true ;;
    h)
      sed -n '2,/^# ===\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

if [ -z "$BACKUP_FILE" ] && [ -z "$BACKUP_DIR" ]; then
  echo "ERROR: Must specify -f <file> or -r <directory>" >&2
  exit 2
fi

# --------------------------------------------------------------------------- #
# Report accumulation
# --------------------------------------------------------------------------- #
REPORT_ENTRIES=()
OVERALL_STATUS="PASS"

record_check() {
  local file="$1" check="$2" result="$3" detail="$4"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  if [ "$result" = "PASS" ]; then
    PASS=$((PASS + 1))
    ! "$QUIET" && printf "  [PASS] %-20s %s\n" "$check" "$detail"
  else
    FAIL=$((FAIL + 1))
    OVERALL_STATUS="FAIL"
    printf "  [FAIL] %-20s %s\n" "$check" "$detail"
  fi
  # Accumulate for JSON report
  if [ -n "$REPORT_FILE" ]; then
    local detail_json
    detail_json=$(printf '%s' "$detail" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$detail")
    REPORT_ENTRIES+=("{\"file\":\"$file\",\"check\":\"$check\",\"result\":\"$result\",\"detail\":$detail_json}")
  fi
}

# --------------------------------------------------------------------------- #
# Verify a single file
# --------------------------------------------------------------------------- #
verify_file() {
  local backup_file="$1"
  local chksum_file="${CHECKSUM_FILE:-${backup_file}.sha256}"

  ! "$QUIET" && echo ""
  ! "$QUIET" && echo "Verifying: $backup_file"

  # --- Check (a): File exists and is newer than MAX_AGE_MINUTES --- #
  if [ ! -f "$backup_file" ]; then
    record_check "$backup_file" "existence" "FAIL" "File does not exist: $backup_file"
    return
  fi

  # File age check
  FILE_MTIME=$(stat -c %Y "$backup_file" 2>/dev/null || stat -f %m "$backup_file" 2>/dev/null)
  NOW=$(date +%s)
  AGE_SECONDS=$(( NOW - FILE_MTIME ))
  AGE_MINUTES=$(( AGE_SECONDS / 60 ))
  MAX_AGE_SECONDS=$(( MAX_AGE_MINUTES * 60 ))

  if [ "$AGE_SECONDS" -le "$MAX_AGE_SECONDS" ]; then
    record_check "$backup_file" "recency" "PASS" \
      "Age: ${AGE_MINUTES}m (max: ${MAX_AGE_MINUTES}m)"
  else
    record_check "$backup_file" "recency" "FAIL" \
      "Too old: ${AGE_MINUTES}m (max: ${MAX_AGE_MINUTES}m)"
  fi

  # --- Check (b): Checksum verification --- #
  if [ -f "$chksum_file" ]; then
    STORED_HASH=$(awk '{print $1}' "$chksum_file")
    COMPUTED_HASH=$(sha256sum "$backup_file" | awk '{print $1}')
    if [ "$STORED_HASH" = "$COMPUTED_HASH" ]; then
      record_check "$backup_file" "checksum" "PASS" \
        "SHA-256 match: ${COMPUTED_HASH:0:16}..."
    else
      record_check "$backup_file" "checksum" "FAIL" \
        "SHA-256 mismatch: stored=${STORED_HASH:0:16}... computed=${COMPUTED_HASH:0:16}..."
    fi
  else
    record_check "$backup_file" "checksum" "FAIL" \
      "Checksum file not found: $chksum_file"
  fi

  # --- Check (c): Minimum file size --- #
  FILE_SIZE=$(stat -c %s "$backup_file" 2>/dev/null || stat -f %z "$backup_file" 2>/dev/null || echo 0)
  FILE_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $FILE_SIZE / 1048576}")
  MIN_SIZE_MB=$(awk "BEGIN {printf \"%.2f\", $MIN_SIZE_BYTES / 1048576}")

  if [ "$FILE_SIZE" -ge "$MIN_SIZE_BYTES" ]; then
    record_check "$backup_file" "size" "PASS" \
      "Size: ${FILE_SIZE_MB}MB (min: ${MIN_SIZE_MB}MB)"
  else
    record_check "$backup_file" "size" "FAIL" \
      "Too small: ${FILE_SIZE_MB}MB (min: ${MIN_SIZE_MB}MB)"
  fi
}

# --------------------------------------------------------------------------- #
# Run verifications
# --------------------------------------------------------------------------- #
TS=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")

if [ -n "$BACKUP_DIR" ]; then
  if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory not found: $BACKUP_DIR" >&2
    exit 1
  fi
  FILE_COUNT=0
  while IFS= read -r -d $'\0' f; do
    verify_file "$f"
    FILE_COUNT=$((FILE_COUNT + 1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name "*.tar.gz" -o -name "*.sql.gz" -o -name "*.bak" -o -name "*.dump" \) \
    -print0 2>/dev/null | sort -z)

  if [ "$FILE_COUNT" -eq 0 ]; then
    echo "WARNING: No backup files found in $BACKUP_DIR" >&2
  fi
else
  verify_file "$BACKUP_FILE"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo "========================================"
echo "Backup Verification Report — $TS"
echo "========================================"
printf "Total checks : %d\n" "$TOTAL_CHECKS"
printf "Passed       : %d\n" "$PASS"
printf "Failed       : %d\n" "$FAIL"
printf "Overall      : %s\n" "$OVERALL_STATUS"
echo "========================================"

# --------------------------------------------------------------------------- #
# Write JSON report if requested
# --------------------------------------------------------------------------- #
if [ -n "$REPORT_FILE" ]; then
  REPORT_DIR=$(dirname "$REPORT_FILE")
  mkdir -p "$REPORT_DIR" 2>/dev/null || true

  # Build JSON array from accumulated entries
  ENTRIES_JSON=""
  for entry in "${REPORT_ENTRIES[@]:-}"; do
    if [ -n "$ENTRIES_JSON" ]; then
      ENTRIES_JSON="${ENTRIES_JSON},${entry}"
    else
      ENTRIES_JSON="$entry"
    fi
  done

  cat > "$REPORT_FILE" <<EOF
{
  "timestamp": "$TS",
  "overall": "$OVERALL_STATUS",
  "total_checks": $TOTAL_CHECKS,
  "passed": $PASS,
  "failed": $FAIL,
  "checks": [${ENTRIES_JSON}]
}
EOF
  echo "Report written to: $REPORT_FILE" >&2
fi

# Exit non-zero if any check failed
[ "$OVERALL_STATUS" = "PASS" ] && exit 0 || exit 1
