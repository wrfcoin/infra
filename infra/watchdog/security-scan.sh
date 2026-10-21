#!/usr/bin/env bash
# =============================================================================
# security-scan.sh — Security pattern detection on API gateway logs
# =============================================================================
#
# USAGE:
#   ./security-scan.sh [OPTIONS]
#
# DESCRIPTION:
#   Scans nginx/API gateway access logs for suspicious patterns:
#     - SQL injection attempts
#     - XSS (cross-site scripting) attempts
#     - Auth bypass floods (401/403 bursts from single IP)
#     - Path traversal attempts
#   Outputs alerts to stdout and optionally appends to a JSONL alert log.
#
# OPTIONS:
#   -l <file>       Access log file to scan (default: /var/log/nginx/access.log)
#   -o <file>       Output JSONL file for alerts (default: none / stdout only)
#   -n <lines>      Number of recent log lines to scan (default: 10000)
#   -t <seconds>    Time window for rate-based checks in seconds (default: 300)
#   -a <count>      Auth-failure flood threshold per IP (default: 20)
#   -d              Dry-run: print all matches without writing output file
#   -q              Quiet: suppress per-match stdout output (file output only)
#   -h              Show this help
#
# DEPENDENCIES: awk, grep, jq, date
#
# OUTPUT FORMAT (JSONL):
#   {"timestamp":"...","severity":"...","category":"...","source_ip":"...",
#    "method":"...","path":"...","status":...,"detail":"..."}
#
# EXAMPLES:
#   # Scan default nginx log, print to stdout
#   ./security-scan.sh
#
#   # Scan custom log, write alerts to JSONL, last 50000 lines
#   ./security-scan.sh -l /var/log/nginx/api-access.log -o /var/log/wrfcoin/security-alerts.jsonl -n 50000
#
#   # Tighten flood detection: flag any IP with 10+ 401s in 5 minutes
#   ./security-scan.sh -a 10 -t 300
#
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
LOG_FILE="/var/log/nginx/access.log"
OUTPUT_FILE=""
SCAN_LINES=10000
AUTH_FLOOD_THRESHOLD=20
TIME_WINDOW=300
DRY_RUN=false
QUIET=false

ALERT_COUNT=0

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while getopts "l:o:n:t:a:dqh" opt; do
  case "$opt" in
    l) LOG_FILE="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    n) SCAN_LINES="$OPTARG" ;;
    t) TIME_WINDOW="$OPTARG" ;;
    a) AUTH_FLOOD_THRESHOLD="$OPTARG" ;;
    d) DRY_RUN=true ;;
    q) QUIET=true ;;
    h)
      sed -n '2,/^# ===\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Validate log file
# --------------------------------------------------------------------------- #
if [ ! -f "$LOG_FILE" ]; then
  echo "ERROR: Log file not found: $LOG_FILE" >&2
  exit 1
fi

# --------------------------------------------------------------------------- #
# Ensure output directory exists
# --------------------------------------------------------------------------- #
if [ -n "$OUTPUT_FILE" ] && ! "$DRY_RUN"; then
  OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
  mkdir -p "$OUTPUT_DIR" 2>/dev/null || {
    echo "ERROR: Cannot create output directory $OUTPUT_DIR" >&2
    exit 1
  }
fi

# --------------------------------------------------------------------------- #
# Emit alert helper
# --------------------------------------------------------------------------- #
emit_alert() {
  local sev="$1" category="$2" ip="$3" method="$4" path="$5" status="$6" detail="$7"
  local ts
  ts=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
  local path_json detail_json
  path_json=$(printf '%s' "$path" | jq -Rs '.')
  detail_json=$(printf '%s' "$detail" | jq -Rs '.')
  local line
  line=$(printf '{"timestamp":"%s","severity":"%s","category":"%s","source_ip":"%s","method":"%s","path":%s,"status":%s,"detail":%s}' \
    "$ts" "$sev" "$category" "$ip" "$method" "$path_json" "$status" "$detail_json")

  if ! "$QUIET"; then
    echo "[ALERT][$sev][$category] ip=$ip status=$status path=$path | $detail"
  fi

  if [ -n "$OUTPUT_FILE" ] && ! "$DRY_RUN"; then
    echo "$line" >> "$OUTPUT_FILE"
  fi

  ALERT_COUNT=$((ALERT_COUNT + 1))
}

# --------------------------------------------------------------------------- #
# Build working set from log
# --------------------------------------------------------------------------- #
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

LOG_SAMPLE="$TMPDIR_WORK/sample.log"
tail -n "$SCAN_LINES" "$LOG_FILE" > "$LOG_SAMPLE"

# --------------------------------------------------------------------------- #
# Pattern 1: SQL Injection detection
# Matches common SQLi tokens in request URI or query string
# --------------------------------------------------------------------------- #
echo "[security-scan] Checking SQL injection patterns..." >&2

SQL_PATTERNS="(union(\s|%20|%09)+(all(\s|%20|%09)+)?select|select(\s|%20|%09)+.*from|insert(\s|%20|%09)+into|update(\s|%20|%09)+.*set(\s|%20|%09)|delete(\s|%20|%09)+from|drop(\s|%20|%09)+(table|database)|exec(\s|%20|\+)*(xp_|sp_)|benchmark\s*\(|sleep\s*\(|waitfor\s+delay|'(\s*)or(\s*)('|1)|--(\s|$)|xp_cmdshell|information_schema|sysobjects)"

grep -iP "$SQL_PATTERNS" "$LOG_SAMPLE" 2>/dev/null | while IFS= read -r line; do
  # Parse nginx combined log format: IP - - [date] "METHOD path HTTP/x.x" status size ...
  IP=$(echo "$line" | awk '{print $1}')
  METHOD=$(echo "$line" | awk '{print $6}' | tr -d '"')
  PATH_REQ=$(echo "$line" | awk '{print $7}')
  STATUS=$(echo "$line" | awk '{print $9}')
  [ -z "$STATUS" ] && STATUS=0
  emit_alert "high" "sql-injection" "$IP" "$METHOD" "$PATH_REQ" "$STATUS" "SQL injection pattern detected in request"
done

# --------------------------------------------------------------------------- #
# Pattern 2: XSS detection
# Matches common XSS payloads in URI
# --------------------------------------------------------------------------- #
echo "[security-scan] Checking XSS patterns..." >&2

XSS_PATTERNS="(<script|%3Cscript|javascript:|vbscript:|onload\s*=|onerror\s*=|onmouseover\s*=|onfocus\s*=|alert\s*\(|document\.cookie|document\.write|eval\s*\(|fromcharcode|%3Csvg|<svg|<iframe|%3Ciframe)"

grep -iP "$XSS_PATTERNS" "$LOG_SAMPLE" 2>/dev/null | while IFS= read -r line; do
  IP=$(echo "$line" | awk '{print $1}')
  METHOD=$(echo "$line" | awk '{print $6}' | tr -d '"')
  PATH_REQ=$(echo "$line" | awk '{print $7}')
  STATUS=$(echo "$line" | awk '{print $9}')
  [ -z "$STATUS" ] && STATUS=0
  emit_alert "high" "xss" "$IP" "$METHOD" "$PATH_REQ" "$STATUS" "XSS pattern detected in request"
done

# --------------------------------------------------------------------------- #
# Pattern 3: Path traversal detection
# --------------------------------------------------------------------------- #
echo "[security-scan] Checking path traversal patterns..." >&2

TRAVERSAL_PATTERNS="(\.\./|\.\.\\\\|%2e%2e%2f|%2e%2e/|\.\.%2f|%2e%2e%5c|/etc/passwd|/etc/shadow|/proc/self|/windows/win\.ini|/boot\.ini|/etc/hosts)"

grep -iP "$TRAVERSAL_PATTERNS" "$LOG_SAMPLE" 2>/dev/null | while IFS= read -r line; do
  IP=$(echo "$line" | awk '{print $1}')
  METHOD=$(echo "$line" | awk '{print $6}' | tr -d '"')
  PATH_REQ=$(echo "$line" | awk '{print $7}')
  STATUS=$(echo "$line" | awk '{print $9}')
  [ -z "$STATUS" ] && STATUS=0
  emit_alert "critical" "path-traversal" "$IP" "$METHOD" "$PATH_REQ" "$STATUS" "Path traversal attempt detected"
done

# --------------------------------------------------------------------------- #
# Pattern 4: Auth bypass flood (401/403 bursts from single IP)
# Count 401 and 403 responses per IP in the sample
# --------------------------------------------------------------------------- #
echo "[security-scan] Checking auth failure floods..." >&2

awk '{
  ip=$1; status=$9
  if (status == "401" || status == "403") {
    count[ip]++
  }
}
END {
  for (ip in count) {
    print count[ip], ip
  }
}' "$LOG_SAMPLE" | sort -rn | while read -r count ip; do
  if [ "$count" -ge "$AUTH_FLOOD_THRESHOLD" ]; then
    emit_alert "high" "auth-flood" "$ip" "-" "/" "$count" \
      "Auth failure flood: $count x 401/403 responses (threshold: $AUTH_FLOOD_THRESHOLD)"
  fi
done

# --------------------------------------------------------------------------- #
# Pattern 5: Scanner/probe detection (unusually high distinct endpoint hits)
# --------------------------------------------------------------------------- #
echo "[security-scan] Checking for automated scanning behavior..." >&2

awk '{
  ip=$1
  path=$7
  key=ip SUBSEP path
  if (!(key in seen)) {
    seen[key]=1
    unique_paths[ip]++
  }
  requests[ip]++
}
END {
  for (ip in unique_paths) {
    if (unique_paths[ip] > 100) {
      print unique_paths[ip], requests[ip], ip
    }
  }
}' "$LOG_SAMPLE" | sort -rn | while read -r unique_paths total_reqs ip; do
  emit_alert "medium" "scanner-probe" "$ip" "-" "-" "$unique_paths" \
    "Scanning behavior: $unique_paths unique endpoints, $total_reqs total requests"
done

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo "[security-scan] Scan complete. Total alerts: $ALERT_COUNT" >&2
if [ -n "$OUTPUT_FILE" ] && ! "$DRY_RUN"; then
  echo "[security-scan] Alerts written to: $OUTPUT_FILE" >&2
fi

exit 0
