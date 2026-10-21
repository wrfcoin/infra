#!/usr/bin/env bash
# =============================================================================
# incident-journal.sh — Automated incident journaling
# =============================================================================
#
# USAGE:
#   ./incident-journal.sh [OPTIONS]
#
# DESCRIPTION:
#   Reads from syslog/journald and appends structured incident events to a
#   JSONL file. Each entry contains: timestamp, severity, source, and message.
#
# OPTIONS:
#   -o <file>       Output JSONL file (default: /var/log/wrfcoin/incidents.jsonl)
#   -s <severity>   Minimum severity to capture: debug|info|warning|error|critical
#                   (default: warning)
#   -n <lines>      Number of recent journal lines to scan (default: 500)
#   -u <unit>       Systemd unit to filter (default: all wrfcoin-* units)
#   -d              Dry-run: print JSON lines to stdout instead of appending file
#   -h              Show this help
#
# DEPENDENCIES: journalctl (or /var/log/syslog), jq, date
#
# EXAMPLES:
#   # Journal last 500 lines from all wrfcoin units, append to default file
#   ./incident-journal.sh
#
#   # Dry-run, capture only errors from wrfcoin-api unit
#   ./incident-journal.sh -d -s error -u wrfcoin-api
#
#   # Write to custom file, scan last 1000 lines
#   ./incident-journal.sh -o /tmp/my-incidents.jsonl -n 1000
#
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
OUTPUT_FILE="/var/log/wrfcoin/incidents.jsonl"
MIN_SEVERITY="warning"
SCAN_LINES=500
UNIT_FILTER=""
DRY_RUN=false

# Severity rank mapping (lower = less severe)
severity_rank() {
  case "$1" in
    debug)    echo 0 ;;
    info)     echo 1 ;;
    notice)   echo 2 ;;
    warning)  echo 3 ;;
    error)    echo 4 ;;
    critical) echo 5 ;;
    alert)    echo 6 ;;
    emerg)    echo 7 ;;
    *)        echo 3 ;;
  esac
}

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while getopts "o:s:n:u:dh" opt; do
  case "$opt" in
    o) OUTPUT_FILE="$OPTARG" ;;
    s) MIN_SEVERITY="$OPTARG" ;;
    n) SCAN_LINES="$OPTARG" ;;
    u) UNIT_FILTER="$OPTARG" ;;
    d) DRY_RUN=true ;;
    h)
      sed -n '2,/^# ===\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

MIN_RANK=$(severity_rank "$MIN_SEVERITY")

# --------------------------------------------------------------------------- #
# Output helper: emit one JSON line
# --------------------------------------------------------------------------- #
emit_event() {
  local ts="$1" sev="$2" src="$3" msg="$4"
  # Escape message for JSON
  local json_msg
  json_msg=$(printf '%s' "$msg" | jq -Rs '.')
  local line
  line=$(printf '{"timestamp":"%s","severity":"%s","source":"%s","message":%s}' \
    "$ts" "$sev" "$src" "$json_msg")
  if "$DRY_RUN"; then
    echo "$line"
  else
    echo "$line" >> "$OUTPUT_FILE"
  fi
}

# --------------------------------------------------------------------------- #
# Ensure output directory exists (unless dry-run)
# --------------------------------------------------------------------------- #
if ! "$DRY_RUN"; then
  OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
  if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR" 2>/dev/null || {
      echo "ERROR: Cannot create output directory $OUTPUT_DIR" >&2
      exit 1
    }
  fi
fi

# --------------------------------------------------------------------------- #
# Source: journald (preferred) or syslog fallback
# --------------------------------------------------------------------------- #
COUNT=0

if command -v journalctl >/dev/null 2>&1; then
  # Build journalctl arguments
  JCT_ARGS=("--no-pager" "-n" "$SCAN_LINES" "--output=json")
  if [ -n "$UNIT_FILTER" ]; then
    JCT_ARGS+=("-u" "$UNIT_FILTER")
  else
    # Default: capture all wrfcoin-related units and kernel/auth messages
    JCT_ARGS+=("-u" "wrfcoin-*" "-u" "nginx" "-u" "postgresql" "-u" "redis")
  fi

  while IFS= read -r json_line; do
    [ -z "$json_line" ] && continue

    # Extract fields from journald JSON
    RAW_MSG=$(echo "$json_line" | jq -r '.MESSAGE // ""')
    RAW_SYSLOG_ID=$(echo "$json_line" | jq -r '.SYSLOG_IDENTIFIER // "_COMM" // "unknown"')
    SYSLOG_ID=$(echo "$json_line" | jq -r '.SYSLOG_IDENTIFIER // ._COMM // "unknown"')
    PRIORITY=$(echo "$json_line" | jq -r '.PRIORITY // "6"')
    SOURCE_UNIT=$(echo "$json_line" | jq -r '._SYSTEMD_UNIT // .SYSLOG_IDENTIFIER // "unknown"')
    REALTIME_US=$(echo "$json_line" | jq -r '.__REALTIME_TIMESTAMP // ""')

    # Convert syslog priority (0-7) to severity name
    case "$PRIORITY" in
      0) SEV="emerg" ;;
      1) SEV="alert" ;;
      2) SEV="critical" ;;
      3) SEV="error" ;;
      4) SEV="warning" ;;
      5) SEV="notice" ;;
      6) SEV="info" ;;
      7) SEV="debug" ;;
      *) SEV="info" ;;
    esac

    # Filter by minimum severity
    SEV_RANK=$(severity_rank "$SEV")
    if [ "$SEV_RANK" -lt "$MIN_RANK" ]; then
      continue
    fi

    # Build ISO timestamp from microseconds since epoch
    if [ -n "$REALTIME_US" ]; then
      TS=$(date -d "@$(echo "$REALTIME_US" | awk '{printf "%.6f", $1/1000000}')" \
        --utc +"%Y-%m-%dT%H:%M:%S.%6NZ" 2>/dev/null \
        || date --utc +"%Y-%m-%dT%H:%M:%SZ")
    else
      TS=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
    fi

    [ -z "$RAW_MSG" ] && continue

    emit_event "$TS" "$SEV" "$SOURCE_UNIT" "$RAW_MSG"
    COUNT=$((COUNT + 1))

  done < <(journalctl "${JCT_ARGS[@]}" 2>/dev/null || true)

elif [ -f /var/log/syslog ]; then
  # Fallback: parse /var/log/syslog
  # Format: "Mon DD HH:MM:SS hostname process[pid]: message"
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    # Detect severity keywords in message
    MSG_LOWER=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    if echo "$MSG_LOWER" | grep -qE '\b(emerg|emergency)\b'; then
      SEV="emerg"
    elif echo "$MSG_LOWER" | grep -qE '\b(crit|critical)\b'; then
      SEV="critical"
    elif echo "$MSG_LOWER" | grep -qE '\b(err|error)\b'; then
      SEV="error"
    elif echo "$MSG_LOWER" | grep -qE '\b(warn|warning)\b'; then
      SEV="warning"
    elif echo "$MSG_LOWER" | grep -qE '\b(notice)\b'; then
      SEV="notice"
    else
      SEV="info"
    fi

    SEV_RANK=$(severity_rank "$SEV")
    if [ "$SEV_RANK" -lt "$MIN_RANK" ]; then
      continue
    fi

    # Parse syslog line
    SRC=$(echo "$line" | awk '{print $5}' | sed 's/\[.*\]://' | sed 's/://')
    MSG=$(echo "$line" | cut -d: -f4- | sed 's/^ *//')
    MONTH=$(echo "$line" | awk '{print $1}')
    DAY=$(echo "$line" | awk '{print $2}')
    TIME=$(echo "$line" | awk '{print $3}')
    YEAR=$(date +%Y)
    TS=$(date -d "$MONTH $DAY $TIME $YEAR" --utc +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
      || date --utc +"%Y-%m-%dT%H:%M:%SZ")

    [ -z "$MSG" ] && continue

    emit_event "$TS" "$SEV" "${SRC:-syslog}" "$MSG"
    COUNT=$((COUNT + 1))

  done < <(tail -n "$SCAN_LINES" /var/log/syslog 2>/dev/null || true)

else
  echo "WARNING: No journald or /var/log/syslog found. No events captured." >&2
  COUNT=0
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
if "$DRY_RUN"; then
  echo "--- dry-run: $COUNT event(s) would be appended ---" >&2
else
  echo "[incident-journal] Appended $COUNT event(s) to $OUTPUT_FILE" >&2
fi
