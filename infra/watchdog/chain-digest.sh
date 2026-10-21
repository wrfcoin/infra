#!/usr/bin/env bash
# =============================================================================
# chain-digest.sh — Chain state narrative digest
# =============================================================================
#
# USAGE:
#   ./chain-digest.sh [OPTIONS]
#
# DESCRIPTION:
#   Queries the WRFCoin native-chain API for recent block data and produces
#   a human-readable digest summarizing:
#     - Block production rate (blocks/minute)
#     - Finality lag (confirmed vs head block delta)
#     - Validator set changes (new/removed validators)
#     - Transaction throughput (TPS estimate)
#     - Chain health status
#
# OPTIONS:
#   -u <url>        Base URL of native-chain API (default: http://localhost:8556)
#   -b <n>          Number of recent blocks to analyze (default: 50)
#   -o <file>       Write JSON digest to this file (optional)
#   -t <seconds>    HTTP request timeout in seconds (default: 10)
#   -q              Quiet: suppress banner, only print digest
#   -j              Output raw JSON instead of human-readable text
#   -h              Show this help
#
# DEPENDENCIES: curl, jq
#
# API ENDPOINTS USED:
#   GET /blocks/latest           — Latest block info
#   GET /blocks?limit=<n>        — Recent N blocks
#   GET /consensus/status        — Finality/consensus state
#   GET /validators              — Current validator set
#   GET /chain/status            — Overall chain health
#
# EXAMPLES:
#   # Quick digest from local chain
#   ./chain-digest.sh
#
#   # Remote testnet, analyze 100 blocks, save JSON
#   ./chain-digest.sh -u http://testnet.wrfcoin.io:8556 -b 100 -o /tmp/chain-digest.json
#
#   # JSON output for machine consumption
#   ./chain-digest.sh -j
#
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Defaults
# --------------------------------------------------------------------------- #
API_URL="http://localhost:8556"
BLOCK_COUNT=50
OUTPUT_FILE=""
TIMEOUT=10
QUIET=false
JSON_OUTPUT=false

# --------------------------------------------------------------------------- #
# Parse arguments
# --------------------------------------------------------------------------- #
while getopts "u:b:o:t:qjh" opt; do
  case "$opt" in
    u) API_URL="$OPTARG" ;;
    b) BLOCK_COUNT="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    q) QUIET=true ;;
    j) JSON_OUTPUT=true ;;
    h)
      sed -n '2,/^# ===\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# HTTP helper: returns empty string on failure (non-fatal)
# --------------------------------------------------------------------------- #
api_get() {
  local endpoint="$1"
  curl -sf --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    -H "Accept: application/json" \
    "${API_URL}${endpoint}" 2>/dev/null || echo ""
}

# --------------------------------------------------------------------------- #
# Fetch chain data
# --------------------------------------------------------------------------- #
! "$QUIET" && echo "[chain-digest] Querying $API_URL ..." >&2

TS=$(date --utc +"%Y-%m-%dT%H:%M:%SZ")

# Latest block
LATEST_BLOCK_JSON=$(api_get "/blocks/latest")
# Recent blocks
RECENT_BLOCKS_JSON=$(api_get "/blocks?limit=${BLOCK_COUNT}")
# Consensus/finality status
CONSENSUS_JSON=$(api_get "/consensus/status")
# Validators
VALIDATORS_JSON=$(api_get "/validators")
# Chain status
CHAIN_STATUS_JSON=$(api_get "/chain/status")

# --------------------------------------------------------------------------- #
# Parse: latest block
# --------------------------------------------------------------------------- #
LATEST_HEIGHT=0
LATEST_TIMESTAMP=""
LATEST_HASH=""
LATEST_TX_COUNT=0

if [ -n "$LATEST_BLOCK_JSON" ]; then
  LATEST_HEIGHT=$(echo "$LATEST_BLOCK_JSON" | jq -r '.height // .block_number // .blockNumber // 0' 2>/dev/null || echo 0)
  LATEST_TIMESTAMP=$(echo "$LATEST_BLOCK_JSON" | jq -r '.timestamp // .time // ""' 2>/dev/null || echo "")
  LATEST_HASH=$(echo "$LATEST_BLOCK_JSON" | jq -r '.hash // .block_hash // ""' 2>/dev/null || echo "")
  LATEST_TX_COUNT=$(echo "$LATEST_BLOCK_JSON" | jq -r '.transactions // .tx_count // 0 | if type == "array" then length else . end' 2>/dev/null || echo 0)
fi

# --------------------------------------------------------------------------- #
# Parse: block production rate from recent blocks
# --------------------------------------------------------------------------- #
BLOCK_RATE="unknown"
TIME_SPAN_SECONDS=0
AVG_BLOCK_TIME="unknown"
TPS="unknown"
TOTAL_TXS=0

if [ -n "$RECENT_BLOCKS_JSON" ]; then
  # Extract timestamps from blocks array
  BLOCK_TIMES=$(echo "$RECENT_BLOCKS_JSON" | jq -r \
    '[.blocks // .data // . | if type == "array" then .[] else . end | .timestamp // .time // ""] | map(select(. != "")) | .[]' \
    2>/dev/null || echo "")

  TOTAL_TXS=$(echo "$RECENT_BLOCKS_JSON" | jq \
    '[.blocks // .data // . | if type == "array" then .[] else . end | .transactions // .tx_count // 0 | if type == "array" then length else (. | tonumber) end] | add // 0' \
    2>/dev/null || echo 0)

  if [ -n "$BLOCK_TIMES" ]; then
    # Get first and last timestamp to compute span
    FIRST_TS=$(echo "$BLOCK_TIMES" | head -1)
    LAST_TS=$(echo "$BLOCK_TIMES" | tail -1)

    if [ -n "$FIRST_TS" ] && [ -n "$LAST_TS" ]; then
      FIRST_EPOCH=$(date -d "$FIRST_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$FIRST_TS" +%s 2>/dev/null || echo 0)
      LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_TS" +%s 2>/dev/null || echo 0)
      TIME_SPAN_SECONDS=$(( FIRST_EPOCH > LAST_EPOCH ? FIRST_EPOCH - LAST_EPOCH : LAST_EPOCH - FIRST_EPOCH ))

      if [ "$TIME_SPAN_SECONDS" -gt 0 ]; then
        BLOCK_RATE=$(awk "BEGIN {printf \"%.2f\", $BLOCK_COUNT / ($TIME_SPAN_SECONDS / 60)}")
        AVG_BLOCK_TIME=$(awk "BEGIN {printf \"%.1f\", $TIME_SPAN_SECONDS / $BLOCK_COUNT}")
        TPS=$(awk "BEGIN {printf \"%.2f\", $TOTAL_TXS / $TIME_SPAN_SECONDS}")
      fi
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Parse: finality lag
# --------------------------------------------------------------------------- #
FINALIZED_HEIGHT=0
FINALITY_LAG="unknown"
FINALITY_STATUS="unknown"

if [ -n "$CONSENSUS_JSON" ]; then
  FINALIZED_HEIGHT=$(echo "$CONSENSUS_JSON" | jq -r \
    '.finalized_height // .last_finalized_block // .finalizedBlock // 0' 2>/dev/null || echo 0)
  if [ "$LATEST_HEIGHT" -gt 0 ] && [ "$FINALIZED_HEIGHT" -gt 0 ]; then
    LAG=$(( LATEST_HEIGHT - FINALIZED_HEIGHT ))
    FINALITY_LAG="${LAG} blocks"
    if [ "$LAG" -le 3 ]; then
      FINALITY_STATUS="healthy"
    elif [ "$LAG" -le 10 ]; then
      FINALITY_STATUS="degraded"
    else
      FINALITY_STATUS="lagging"
    fi
  fi
elif [ -n "$CHAIN_STATUS_JSON" ]; then
  FINALIZED_HEIGHT=$(echo "$CHAIN_STATUS_JSON" | jq -r \
    '.finalized_height // .last_finalized // 0' 2>/dev/null || echo 0)
fi

# --------------------------------------------------------------------------- #
# Parse: validator set
# --------------------------------------------------------------------------- #
VALIDATOR_COUNT=0
ACTIVE_VALIDATORS=0
VALIDATOR_CHANGES=""

if [ -n "$VALIDATORS_JSON" ]; then
  VALIDATOR_COUNT=$(echo "$VALIDATORS_JSON" | jq \
    '[.validators // .data // . | if type == "array" then .[] else . end] | length' \
    2>/dev/null || echo 0)
  ACTIVE_VALIDATORS=$(echo "$VALIDATORS_JSON" | jq \
    '[.validators // .data // . | if type == "array" then .[] else . end | select(.status == "active" or .active == true)] | length' \
    2>/dev/null || echo "$VALIDATOR_COUNT")
  # Check for recent joins/leaves
  JOINED=$(echo "$VALIDATORS_JSON" | jq \
    '[.validators // .data // . | if type == "array" then .[] else . end | select(.status == "joining" or .joined_at != null)] | length' \
    2>/dev/null || echo 0)
  LEFT=$(echo "$VALIDATORS_JSON" | jq \
    '[.validators // .data // . | if type == "array" then .[] else . end | select(.status == "leaving" or .exiting == true)] | length' \
    2>/dev/null || echo 0)
  if [ "$JOINED" -gt 0 ] || [ "$LEFT" -gt 0 ]; then
    VALIDATOR_CHANGES="${JOINED} joining, ${LEFT} leaving"
  else
    VALIDATOR_CHANGES="none"
  fi
fi

# --------------------------------------------------------------------------- #
# Overall health determination
# --------------------------------------------------------------------------- #
CHAIN_HEALTH="unknown"
if [ -n "$CHAIN_STATUS_JSON" ]; then
  CHAIN_HEALTH=$(echo "$CHAIN_STATUS_JSON" | jq -r '.status // .health // "unknown"' 2>/dev/null || echo "unknown")
fi

# Derive health from what we know if not provided
if [ "$CHAIN_HEALTH" = "unknown" ]; then
  if [ "$LATEST_HEIGHT" -gt 0 ]; then
    if [ "$FINALITY_STATUS" = "healthy" ]; then
      CHAIN_HEALTH="healthy"
    elif [ "$FINALITY_STATUS" = "lagging" ]; then
      CHAIN_HEALTH="degraded"
    else
      CHAIN_HEALTH="online"
    fi
  else
    CHAIN_HEALTH="unreachable"
  fi
fi

# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #
if "$JSON_OUTPUT"; then
  jq -n \
    --arg ts "$TS" \
    --arg health "$CHAIN_HEALTH" \
    --argjson latest_height "$LATEST_HEIGHT" \
    --arg latest_hash "$LATEST_HASH" \
    --arg latest_ts "$LATEST_TIMESTAMP" \
    --argjson finalized_height "$FINALIZED_HEIGHT" \
    --arg finality_lag "$FINALITY_LAG" \
    --arg finality_status "$FINALITY_STATUS" \
    --arg block_rate "$BLOCK_RATE" \
    --arg avg_block_time "$AVG_BLOCK_TIME" \
    --arg tps "$TPS" \
    --argjson total_txs "$TOTAL_TXS" \
    --argjson validator_count "$VALIDATOR_COUNT" \
    --argjson active_validators "$ACTIVE_VALIDATORS" \
    --arg validator_changes "$VALIDATOR_CHANGES" \
    '{
      timestamp: $ts,
      chain_health: $health,
      latest_block: {
        height: $latest_height,
        hash: $latest_hash,
        timestamp: $latest_ts
      },
      finality: {
        finalized_height: $finalized_height,
        lag: $finality_lag,
        status: $finality_status
      },
      throughput: {
        block_rate_per_min: $block_rate,
        avg_block_time_seconds: $avg_block_time,
        tps: $tps,
        total_txs_in_sample: $total_txs
      },
      validators: {
        total: $validator_count,
        active: $active_validators,
        recent_changes: $validator_changes
      }
    }'
else
  # Human-readable output
  if ! "$QUIET"; then
    echo "========================================"
    echo "  WRFCoin Chain Digest — $TS"
    echo "========================================"
  fi
  echo ""
  echo "Chain Health    : $CHAIN_HEALTH"
  echo ""
  echo "Block Status"
  echo "  Latest height   : $LATEST_HEIGHT"
  if [ -n "$LATEST_HASH" ]; then
    echo "  Latest hash     : ${LATEST_HASH:0:16}..."
  fi
  if [ -n "$LATEST_TIMESTAMP" ]; then
    echo "  Latest block ts : $LATEST_TIMESTAMP"
  fi
  echo ""
  echo "Block Production (last $BLOCK_COUNT blocks)"
  echo "  Rate            : ${BLOCK_RATE} blocks/min"
  echo "  Avg block time  : ${AVG_BLOCK_TIME}s"
  echo "  TPS estimate    : $TPS"
  echo "  Total txs       : $TOTAL_TXS"
  echo ""
  echo "Finality"
  echo "  Finalized height: $FINALIZED_HEIGHT"
  echo "  Lag             : $FINALITY_LAG"
  echo "  Status          : $FINALITY_STATUS"
  echo ""
  echo "Validators"
  echo "  Total           : $VALIDATOR_COUNT"
  echo "  Active          : $ACTIVE_VALIDATORS"
  echo "  Recent changes  : $VALIDATOR_CHANGES"
  echo ""
fi

# --------------------------------------------------------------------------- #
# Write to file if requested
# --------------------------------------------------------------------------- #
if [ -n "$OUTPUT_FILE" ]; then
  OUTPUT_DIR=$(dirname "$OUTPUT_FILE")
  mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
  # Re-run with -j flag and redirect
  "$0" -u "$API_URL" -b "$BLOCK_COUNT" -t "$TIMEOUT" -q -j > "$OUTPUT_FILE" 2>/dev/null
  echo "[chain-digest] JSON digest written to: $OUTPUT_FILE" >&2
fi

exit 0
