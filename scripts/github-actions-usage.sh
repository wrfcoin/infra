#!/usr/bin/env bash
# github-actions-usage.sh — GitHub Actions usage and cost estimator for WRFCoin repos
#
# Usage:
#   ./github-actions-usage.sh [--days 30] [--format table|csv]
#
# Requirements:
#   - gh CLI authenticated (gh auth status)
#   - jq installed
#
# Cost model: $0.008 per Linux runner minute (GitHub-hosted standard 2-core)
# Reference: https://docs.github.com/en/billing/managing-billing-for-github-actions/about-billing-for-github-actions

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
DAYS=30
FORMAT="table"

# WRFCoin repos to audit
REPOS=(
  "wrfcoin/core4"
  "wrfcoin/backend"
  "wrfcoin/frontend"
  "wrfcoin/smart-contracts"
  "wrfcoin/infra"
  "wrfcoin/security-testing"
  "wrfcoin/mobile"
)

COST_PER_MINUTE=0.008   # USD per Linux runner minute

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)
      DAYS="$2"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '/^# /p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--days 30] [--format table|csv]" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if ! command -v gh &>/dev/null; then
  echo "ERROR: gh CLI not found. Install from https://cli.github.com/" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq not found. Install via: apt-get install jq / brew install jq" >&2
  exit 1
fi

if ! gh auth status &>/dev/null 2>&1; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ "$FORMAT" != "table" && "$FORMAT" != "csv" ]]; then
  echo "ERROR: --format must be 'table' or 'csv'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Date window calculation
# ---------------------------------------------------------------------------
# Compute ISO-8601 cutoff date (DAYS ago), portable across Linux and macOS
if date --version 2>/dev/null | grep -q GNU; then
  # GNU date
  SINCE=$(date -u -d "${DAYS} days ago" '+%Y-%m-%dT%H:%M:%SZ')
else
  # BSD date (macOS)
  SINCE=$(date -u -v "-${DAYS}d" '+%Y-%m-%dT%H:%M:%SZ')
fi

# ---------------------------------------------------------------------------
# Data collection
# ---------------------------------------------------------------------------
declare -a RESULT_REPOS=()
declare -a RESULT_RUNS=()
declare -a RESULT_MINUTES=()
declare -a RESULT_COSTS=()

TOTAL_RUNS=0
TOTAL_MINUTES=0

for REPO in "${REPOS[@]}"; do
  run_count=0
  total_ms=0
  page=1

  while true; do
    # Fetch one page of workflow runs (100 per page max)
    response=$(gh api \
      -H "Accept: application/vnd.github+json" \
      "/repos/${REPO}/actions/runs?per_page=100&page=${page}&created=>=${SINCE}" \
      2>/dev/null || echo '{"workflow_runs":[]}')

    # Extract run_duration_ms values; fall back to 0 for nulls
    page_runs=$(echo "$response" | jq '[.workflow_runs[].run_duration_ms // 0]')
    page_count=$(echo "$page_runs" | jq 'length')

    if [[ "$page_count" -eq 0 ]]; then
      break
    fi

    page_ms=$(echo "$page_runs" | jq 'add // 0')
    run_count=$(( run_count + page_count ))
    total_ms=$(( total_ms + page_ms ))

    # If fewer than 100 results, we've reached the last page
    if [[ "$page_count" -lt 100 ]]; then
      break
    fi

    page=$(( page + 1 ))
  done

  # Convert ms → minutes (ceiling division)
  total_minutes=$(( (total_ms + 59999) / 60000 ))

  # Estimated cost: minutes * rate (use awk for float arithmetic)
  estimated_cost=$(awk "BEGIN { printf \"%.4f\", ${total_minutes} * ${COST_PER_MINUTE} }")

  RESULT_REPOS+=("$REPO")
  RESULT_RUNS+=("$run_count")
  RESULT_MINUTES+=("$total_minutes")
  RESULT_COSTS+=("$estimated_cost")

  TOTAL_RUNS=$(( TOTAL_RUNS + run_count ))
  TOTAL_MINUTES=$(( TOTAL_MINUTES + total_minutes ))
done

TOTAL_COST=$(awk "BEGIN { printf \"%.4f\", ${TOTAL_MINUTES} * ${COST_PER_MINUTE} }")

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
emit_csv() {
  echo "REPO,RUNS,TOTAL_MINUTES,ESTIMATED_COST_USD"
  for i in "${!RESULT_REPOS[@]}"; do
    echo "${RESULT_REPOS[$i]},${RESULT_RUNS[$i]},${RESULT_MINUTES[$i]},${RESULT_COSTS[$i]}"
  done
  echo "TOTAL,${TOTAL_RUNS},${TOTAL_MINUTES},${TOTAL_COST}"
}

emit_table() {
  local sep="+---------------------------------+-------+---------------+---------------------+"
  local hdr="| REPO                            | RUNS  | TOTAL_MINUTES | ESTIMATED_COST_USD  |"

  echo ""
  echo "  GitHub Actions Usage Report — last ${DAYS} days"
  echo "  Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "  Cost model: \$${COST_PER_MINUTE}/minute (GitHub Actions Linux runner)"
  echo ""
  echo "$sep"
  echo "$hdr"
  echo "$sep"

  for i in "${!RESULT_REPOS[@]}"; do
    printf "| %-31s | %5s | %13s | %19s |\n" \
      "${RESULT_REPOS[$i]}" \
      "${RESULT_RUNS[$i]}" \
      "${RESULT_MINUTES[$i]}" \
      "\$${RESULT_COSTS[$i]}"
  done

  echo "$sep"
  printf "| %-31s | %5s | %13s | %19s |\n" \
    "TOTAL" \
    "${TOTAL_RUNS}" \
    "${TOTAL_MINUTES}" \
    "\$${TOTAL_COST}"
  echo "$sep"
  echo ""
}

case "$FORMAT" in
  csv)   emit_csv ;;
  table) emit_table ;;
esac
