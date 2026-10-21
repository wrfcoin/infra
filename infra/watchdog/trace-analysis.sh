#!/usr/bin/env bash
# =============================================================================
# trace-analysis.sh — Jaeger trace analysis for latency anomalies
# =============================================================================
#
# USAGE:
#   ./trace-analysis.sh [OPTIONS]
#
# DESCRIPTION:
#   Queries the Jaeger HTTP API for distributed traces and identifies P99
#   latency outliers across services. Reports services where P99 latency
#   exceeds the configured threshold (default: 2000ms / 2s).
#
#   For each service, analyzes recent traces to compute:
#     - P50, P95, P99 latency percentiles
#     - Slowest operations/endpoints
#     - Error rate (traces with error tags)
#     - Span count distribution
#
# OPTIONS:
#   -u <url>        Jaeger base URL (default: http://localhost:16686)
#   -t <ms>         P99 alert threshold in milliseconds (default: 2000)
#   -l <n>          Max traces to fetch per service (default: 200)
#   -w <minutes>    Lookback window in minutes (default: 60)
#   -s <service>    Analyze only this service (default: all services)
#   -o <file>       Write JSON report to this file (optional)
#   -T <seconds>    HTTP request timeout in seconds (default: 15)
#   -q              Quiet: suppress banner and info messages
#   -j              Output raw JSON report to stdout
#   -h              Show this help
#
# EXIT CODES:
#   0 — No P99 violations found
#   1 — One or more services exceed the P99 threshold
#   2 — Usage/connectivity error
#
# DEPENDENCIES: curl, jq, awk
#
# JAEGER API ENDPOINTS USED:
#   GET /api/services                                  — List all services
#   GET /api/traces?service=<s>&limit=<n>&lookback=<w> — Fetch traces for service
#
# EXAMPLES:
#   # Analyze all services against 2s P99 threshold
#   ./trace-analysis.sh
#
#   # Use 1s threshold, look back 30 minutes
#   ./trace-analysis.sh -t 1000 -w 30
#
#   # Analyze single service, write JSON report
#   ./trace-analysis.sh -s wrfcoin-api -o /tmp/trace-report.json
#
#   # Remote Jaeger instance, output JSON
#   ./trace-analysis.sh -u http://jaeger.wrfcoin.internal:16686 -j
#
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
JAEGER_URL="http://localhost:16686"
P99_THRESHOLD_MS=2000
MAX_TRACES=200
LOOKBACK_MINUTES=60
SINGLE_SERVICE=""
OUTPUT_FILE=""
HTTP_TIMEOUT=15
QUIET=false
JSON_OUTPUT=false

VIOLATION_COUNT=0

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while getopts "u:t:l:w:s:o:T:qjh" opt; do
  case "$opt" in
    u) JAEGER_URL="$OPTARG" ;;
    t) P99_THRESHOLD_MS="$OPTARG" ;;
    l) MAX_TRACES="$OPTARG" ;;
    w) LOOKBACK_MINUTES="$OPTARG" ;;
    s) SINGLE_SERVICE="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    T) HTTP_TIMEOUT="$OPTARG" ;;
    q) QUIET=true ;;
    j) JSON_OUTPUT=true ;;
    h)
      sed -n '2,/^# ===\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done

# --------------------------------------------------------------------------- #
# HTTP helper
# --------------------------------------------------------------------------- #
jaeger_get() {
  local path="$1"
  curl -sf --connect-timeout "$HTTP_TIMEOUT" --max-time "$HTTP_TIMEOUT" \
    -H "Accept: application/json" \
    "${JAEGER_URL}${path}" 2>/dev/null || echo ""
}

# --------------------------------------------------------------------------- #
# Compute percentile from sorted awk array (space-separated values on stdin)
# --------------------------------------------------------------------------- #
compute_percentile() {
  local pct="$1"
  awk -v p="$pct" '
  {
    n = split($0, arr, " ")
    # Sort arr
    for (i = 1; i <= n; i++) {
      for (j = i+1; j <= n; j++) {
        if (arr[i]+0 > arr[j]+0) {
          tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp
        }
      }
    }
    idx = int(n * p / 100)
    if (idx < 1) idx = 1
    if (idx > n) idx = n
    printf "%d\n", arr[idx]
  }'
}

TS=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")
LOOKBACK_US=$(( LOOKBACK_MINUTES * 60 * 1000000 ))

! "$QUIET" && ! "$JSON_OUTPUT" && echo "[trace-analysis] Connecting to Jaeger at $JAEGER_URL ..." >&2

# --------------------------------------------------------------------------- #
# Fetch service list
# --------------------------------------------------------------------------- #
SERVICES_JSON=$(jaeger_get "/api/services")
if [ -z "$SERVICES_JSON" ]; then
  echo "ERROR: Cannot reach Jaeger at $JAEGER_URL" >&2
  exit 2
fi

if [ -n "$SINGLE_SERVICE" ]; then
  SERVICES=("$SINGLE_SERVICE")
else
  mapfile -t SERVICES < <(echo "$SERVICES_JSON" | jq -r '.data[]' 2>/dev/null | sort || echo "")
fi

if [ "${#SERVICES[@]}" -eq 0 ]; then
  echo "WARNING: No services found in Jaeger" >&2
  exit 0
fi

! "$QUIET" && ! "$JSON_OUTPUT" && echo "[trace-analysis] Analyzing ${#SERVICES[@]} service(s) ..." >&2

# --------------------------------------------------------------------------- #
# Per-service analysis
# --------------------------------------------------------------------------- #
SERVICE_REPORTS=()

for SERVICE in "${SERVICES[@]}"; do
  [ -z "$SERVICE" ] && continue

  ! "$QUIET" && ! "$JSON_OUTPUT" && echo "  - $SERVICE" >&2

  # Fetch traces
  TRACES_JSON=$(jaeger_get "/api/traces?service=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$SERVICE'))" 2>/dev/null || echo "$SERVICE")&limit=${MAX_TRACES}&lookback=${LOOKBACK_MINUTES}m" 2>/dev/null)

  # Fallback URL encoding for service name
  if [ -z "$TRACES_JSON" ]; then
    ENCODED_SERVICE=$(echo "$SERVICE" | sed 's/ /%20/g; s/:/%3A/g; s/\//%2F/g')
    TRACES_JSON=$(jaeger_get "/api/traces?service=${ENCODED_SERVICE}&limit=${MAX_TRACES}&lookback=${LOOKBACK_MINUTES}m")
  fi

  if [ -z "$TRACES_JSON" ]; then
    continue
  fi

  TRACE_COUNT=$(echo "$TRACES_JSON" | jq '.data | length' 2>/dev/null || echo 0)
  [ "$TRACE_COUNT" -eq 0 ] && continue

  # Extract all root span durations (in microseconds) and error status
  # Jaeger stores duration in microseconds
  DURATIONS=$(echo "$TRACES_JSON" | jq -r '
    .data[] |
    # Find root span (span with no references or parentSpanID empty)
    .spans[] |
    select(.references == null or (.references | length) == 0) |
    .duration // 0
  ' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')

  if [ -z "$DURATIONS" ]; then
    # Fallback: use all spans
    DURATIONS=$(echo "$TRACES_JSON" | jq -r '
      .data[].spans[].duration // 0
    ' 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
  fi

  [ -z "$DURATIONS" ] && continue

  SPAN_COUNT=$(echo "$DURATIONS" | wc -w)

  # Compute percentiles (durations are in microseconds, convert to ms for output)
  P50_US=$(echo "$DURATIONS" | compute_percentile 50)
  P95_US=$(echo "$DURATIONS" | compute_percentile 95)
  P99_US=$(echo "$DURATIONS" | compute_percentile 99)

  P50_MS=$(awk "BEGIN {printf \"%.1f\", $P50_US / 1000}")
  P95_MS=$(awk "BEGIN {printf \"%.1f\", $P95_US / 1000}")
  P99_MS=$(awk "BEGIN {printf \"%.1f\", $P99_US / 1000}")

  # Count errors
  ERROR_COUNT=$(echo "$TRACES_JSON" | jq '
    [.data[].spans[] |
     .tags[] |
     select(.key == "error" and (.value == true or .value == "true"))] |
    length
  ' 2>/dev/null || echo 0)

  ERROR_RATE="0.00"
  if [ "$SPAN_COUNT" -gt 0 ]; then
    ERROR_RATE=$(awk "BEGIN {printf \"%.2f\", $ERROR_COUNT / $SPAN_COUNT * 100}")
  fi

  # Find slowest operation
  SLOWEST_OP=$(echo "$TRACES_JSON" | jq -r '
    [.data[].spans[] | {op: .operationName, dur: .duration}] |
    sort_by(-.dur) | first | "\(.op) (\(.dur // 0) us)"
  ' 2>/dev/null || echo "unknown")

  # Determine if this service violates P99 threshold
  P99_THRESHOLD_US=$(( P99_THRESHOLD_MS * 1000 ))
  VIOLATION=false
  if [ "$P99_US" -gt "$P99_THRESHOLD_US" ]; then
    VIOLATION=true
    VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
  fi

  # Build service report entry
  REPORT_ENTRY=$(jq -n \
    --arg service "$SERVICE" \
    --argjson trace_count "$TRACE_COUNT" \
    --argjson span_count "$SPAN_COUNT" \
    --arg p50_ms "$P50_MS" \
    --arg p95_ms "$P95_MS" \
    --arg p99_ms "$P99_MS" \
    --arg error_count "$ERROR_COUNT" \
    --arg error_rate "$ERROR_RATE" \
    --arg slowest_op "$SLOWEST_OP" \
    --argjson violation "$VIOLATION" \
    '{
      service: $service,
      trace_count: $trace_count,
      span_count: $span_count,
      latency_ms: {p50: ($p50_ms | tonumber), p95: ($p95_ms | tonumber), p99: ($p99_ms | tonumber)},
      errors: {count: ($error_count | tonumber), rate_pct: ($error_rate | tonumber)},
      slowest_operation: $slowest_op,
      p99_violation: $violation
    }')

  SERVICE_REPORTS+=("$REPORT_ENTRY")

  # Human-readable per-service output
  if ! "$JSON_OUTPUT"; then
    VIOLATION_MARKER=""
    "$VIOLATION" && VIOLATION_MARKER=" [P99 VIOLATION]"
    printf "  %-35s P50=%6.1fms P95=%7.1fms P99=%7.1fms err=%.1f%%%s\n" \
      "$SERVICE" "$P50_MS" "$P95_MS" "$P99_MS" "$ERROR_RATE" "$VIOLATION_MARKER"
  fi

done

# --------------------------------------------------------------------------- #
# Build final JSON report
# --------------------------------------------------------------------------- #
REPORTS_JSON="[]"
if [ "${#SERVICE_REPORTS[@]}" -gt 0 ]; then
  REPORTS_JSON=$(printf '%s\n' "${SERVICE_REPORTS[@]}" | jq -s '.')
fi

FINAL_REPORT=$(jq -n \
  --arg ts "$TS" \
  --arg jaeger_url "$JAEGER_URL" \
  --argjson lookback_minutes "$LOOKBACK_MINUTES" \
  --argjson p99_threshold_ms "$P99_THRESHOLD_MS" \
  --argjson violation_count "$VIOLATION_COUNT" \
  --argjson service_count "${#SERVICES[@]}" \
  --argjson services "$REPORTS_JSON" \
  '{
    timestamp: $ts,
    jaeger_url: $jaeger_url,
    analysis_window_minutes: $lookback_minutes,
    p99_threshold_ms: $p99_threshold_ms,
    services_analyzed: $service_count,
    p99_violations: $violation_count,
    status: (if $violation_count > 0 then "VIOLATIONS_DETECTED" else "OK" end),
    services: $services
  }')

# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
if "$JSON_OUTPUT"; then
  echo "$FINAL_REPORT"
else
  echo ""
  echo "========================================"
  echo "  Jaeger Trace Analysis — $TS"
  echo "========================================"
  echo "  Jaeger URL      : $JAEGER_URL"
  echo "  Lookback        : ${LOOKBACK_MINUTES}m"
  echo "  P99 threshold   : ${P99_THRESHOLD_MS}ms"
  echo "  Services scanned: ${#SERVICES[@]}"
  echo "  P99 violations  : $VIOLATION_COUNT"
  echo "========================================"
  if [ "$VIOLATION_COUNT" -gt 0 ]; then
    echo ""
    echo "P99 VIOLATIONS (>${P99_THRESHOLD_MS}ms):"
    echo "$FINAL_REPORT" | jq -r \
      '.services[] | select(.p99_violation) | "  \(.service): P99=\(.latency_ms.p99)ms"' 2>/dev/null || true
  fi
fi

# --------------------------------------------------------------------------- #
# Write JSON to file if requested
# --------------------------------------------------------------------------- #
if [ -n "$OUTPUT_FILE" ]; then
  OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
  mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
  echo "$FINAL_REPORT" > "$OUTPUT_FILE"
  echo "[trace-analysis] Report written to: $OUTPUT_FILE" >&2
fi

# Exit 1 if violations found
[ "$VIOLATION_COUNT" -eq 0 ] && exit 0 || exit 1
