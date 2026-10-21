#!/usr/bin/env bash
set -euo pipefail

# pre-deploy-performance-check.sh
# Validates API endpoint latency before deploying to production.
# Uses only curl (no external dependencies).

###############################################################################
# Defaults
###############################################################################
TARGET="http://localhost:4001"
REQUESTS=100
JSON_OUTPUT=false

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --target URL     Base URL to test (default: $TARGET)
  --requests N     Number of requests per endpoint (default: $REQUESTS)
  --json           Output results as JSON
  -h, --help       Show this help message

Endpoints tested:
  GET /health                  p95 threshold: 200ms
  GET /ready                   p95 threshold: 200ms
  GET /api/blockchain/status   p95 threshold: 500ms

Exit codes:
  0  All p95 latencies within thresholds
  1  One or more p95 latencies exceeded thresholds
EOF
  exit 0
}

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)   TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --requests)   REQUESTS="$2"; shift 2 ;;
    --requests=*) REQUESTS="${1#*=}"; shift ;;
    --json)     JSON_OUTPUT=true; shift ;;
    -h|--help)  usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate REQUESTS is a positive integer
if ! [[ "$REQUESTS" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --requests must be a positive integer" >&2
  exit 1
fi

###############################################################################
# Helpers
###############################################################################

# percentile INDEX SORTED_ARRAY
# Computes the value at the given percentile from a newline-separated sorted list.
percentile() {
  local pct="$1"
  shift
  local data=("$@")
  local n=${#data[@]}
  if [[ $n -eq 0 ]]; then
    echo "0"
    return
  fi
  # index = ceil(pct/100 * n) - 1, clamped to [0, n-1]
  local idx=$(( (pct * n + 99) / 100 - 1 ))
  if [[ $idx -lt 0 ]]; then idx=0; fi
  if [[ $idx -ge $n ]]; then idx=$(( n - 1 )); fi
  echo "${data[$idx]}"
}

# bench_endpoint PATH EXPECTED_STATUS P95_THRESHOLD_MS
# Sends $REQUESTS requests to $TARGET$PATH, collects latencies, computes percentiles.
# Prints results and returns 1 if p95 > threshold.
bench_endpoint() {
  local path="$1"
  local expected_status="$2"
  local threshold_ms="$3"
  local url="${TARGET}${path}"
  local latencies=()
  local failures=0

  for (( i=1; i<=REQUESTS; i++ )); do
    # curl writes time_total in seconds (e.g., 0.045); http_code as 3-digit status
    local result
    result=$(curl -s -o /dev/null -w "%{time_total} %{http_code}" --max-time 10 "$url" 2>/dev/null) || {
      failures=$(( failures + 1 ))
      continue
    }

    local time_s http_code
    time_s=$(echo "$result" | awk '{print $1}')
    http_code=$(echo "$result" | awk '{print $2}')

    if [[ "$http_code" != "$expected_status" ]]; then
      failures=$(( failures + 1 ))
      continue
    fi

    # Convert seconds to integer milliseconds: multiply by 1000 using awk
    local ms
    ms=$(awk "BEGIN { printf \"%d\", $time_s * 1000 }")
    latencies+=("$ms")
  done

  local total=${#latencies[@]}

  if [[ $total -eq 0 ]]; then
    # All requests failed
    if [[ "$JSON_OUTPUT" == "true" ]]; then
      echo "{\"endpoint\":\"$path\",\"requests\":$REQUESTS,\"successes\":0,\"failures\":$failures,\"p50\":0,\"p95\":0,\"p99\":0,\"threshold_ms\":$threshold_ms,\"pass\":false}"
    else
      echo "  FAIL $path - all $REQUESTS requests failed (0 successes, $failures failures)"
    fi
    return 1
  fi

  # Sort latencies numerically
  IFS=$'\n' sorted=($(printf '%s\n' "${latencies[@]}" | sort -n)); unset IFS

  local p50 p95 p99
  p50=$(percentile 50 "${sorted[@]}")
  p95=$(percentile 95 "${sorted[@]}")
  p99=$(percentile 99 "${sorted[@]}")

  local pass=true
  if [[ $p95 -gt $threshold_ms ]]; then
    pass=false
  fi

  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "{\"endpoint\":\"$path\",\"requests\":$REQUESTS,\"successes\":$total,\"failures\":$failures,\"p50\":$p50,\"p95\":$p95,\"p99\":$p99,\"threshold_ms\":$threshold_ms,\"pass\":$pass}"
  else
    local status_label="PASS"
    if [[ "$pass" == "false" ]]; then
      status_label="FAIL"
    fi
    printf "  %-4s %-30s  p50=%4dms  p95=%4dms  p99=%4dms  (threshold p95<%dms, %d/%d ok)\n" \
      "$status_label" "$path" "$p50" "$p95" "$p99" "$threshold_ms" "$total" "$REQUESTS"
  fi

  if [[ "$pass" == "false" ]]; then
    return 1
  fi
  return 0
}

###############################################################################
# Main
###############################################################################

# Endpoint definitions: PATH EXPECTED_STATUS P95_THRESHOLD_MS
ENDPOINTS=(
  "/health 200 200"
  "/ready 200 200"
  "/api/blockchain/status 200 500"
)

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "["
else
  echo "Pre-deploy Performance Check"
  echo "============================"
  echo "Target:   $TARGET"
  echo "Requests: $REQUESTS per endpoint"
  echo ""
fi

overall_pass=true
first_json=true

for entry in "${ENDPOINTS[@]}"; do
  read -r ep_path ep_status ep_threshold <<< "$entry"

  if [[ "$JSON_OUTPUT" == "true" && "$first_json" == "false" ]]; then
    echo ","
  fi
  first_json=false

  if ! bench_endpoint "$ep_path" "$ep_status" "$ep_threshold"; then
    overall_pass=false
  fi
done

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo ""
  echo "]"
else
  echo ""
  if [[ "$overall_pass" == "true" ]]; then
    echo "Result: ALL ENDPOINTS PASSED"
  else
    echo "Result: PERFORMANCE CHECK FAILED - one or more endpoints exceeded p95 threshold"
  fi
fi

if [[ "$overall_pass" == "false" ]]; then
  exit 1
fi
