#!/usr/bin/env bash
# Chaos testing: random container kills + network partition injection
#
# Usage:
#   ./chaos-test.sh [OPTIONS]
#
# Options:
#   --interval SECONDS      Sleep between chaos events (default: 30)
#   --pattern PATTERN       Docker container name/label filter (default: wrfcoin_)
#   --cycles N              Number of chaos cycles to run (default: 10; 0 = infinite)
#   --dry-run               List targets and show what would happen — no kills
#   --mode kill|network|mix Chaos mode: container kills, network partitions, or both (default: mix)
#   --recovery SECONDS      Wait time after partition before reconnect (default: 15)
#   --health-timeout SECS   Max seconds to wait for container healthy after kill (default: 60)
#   --compose-dir DIR       Directory containing docker-compose.yml for health check context
#   --log-file PATH         Append JSON event log to this file (default: /tmp/chaos-results.jsonl)
#   --fail-fast             Exit non-zero if any container fails to recover
#
# Issue: #126
#
# Example:
#   # Dry-run to see targets
#   ./chaos-test.sh --pattern wrfcoin_ --dry-run
#
#   # 5 kill cycles against testnet services, 20s interval
#   ./chaos-test.sh --pattern wrfcoin-testnet- --cycles 5 --interval 20
#
#   # Network partition mode, 3 cycles
#   ./chaos-test.sh --mode network --cycles 3 --recovery 30
#
# Output:
#   Each event is logged as a JSON line to --log-file with keys:
#     cycle, mode, container, network, action, started_at, recovered_at,
#     restart_secs, health_ok, error
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
INTERVAL=30
PATTERN="wrfcoin_"
CYCLES=10
DRY_RUN=false
MODE="mix"
RECOVERY_SECS=15
HEALTH_TIMEOUT=60
COMPOSE_DIR=""
LOG_FILE="/tmp/chaos-results.jsonl"
FAIL_FAST=false

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf '\e[32m[%s INFO]\e[0m  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn()    { printf '\e[33m[%s WARN]\e[0m  %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
error()   { printf '\e[31m[%s ERROR]\e[0m %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
ts_now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch()   { date +%s; }

log_event() {
  # Append a JSON record to the log file
  local cycle="$1" mode="$2" container="$3" network="${4:-}" action="$5"
  local started_at="$6" recovered_at="${7:-}" restart_secs="${8:-null}"
  local health_ok="${9:-true}" err="${10:-}"

  printf '{"cycle":%d,"mode":"%s","container":"%s","network":"%s","action":"%s",' \
    "$cycle" "$mode" "$container" "$network" "$action" >> "$LOG_FILE"
  printf '"started_at":"%s","recovered_at":"%s","restart_secs":%s,"health_ok":%s,"error":"%s"}\n' \
    "$started_at" "${recovered_at:-}" "${restart_secs}" "${health_ok}" "${err//\"/\'}" >> "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)       INTERVAL="$2";       shift 2 ;;
    --pattern)        PATTERN="$2";        shift 2 ;;
    --cycles)         CYCLES="$2";         shift 2 ;;
    --dry-run)        DRY_RUN=true;        shift   ;;
    --mode)           MODE="$2";           shift 2 ;;
    --recovery)       RECOVERY_SECS="$2";  shift 2 ;;
    --health-timeout) HEALTH_TIMEOUT="$2"; shift 2 ;;
    --compose-dir)    COMPOSE_DIR="$2";    shift 2 ;;
    --log-file)       LOG_FILE="$2";       shift 2 ;;
    --fail-fast)      FAIL_FAST=true;      shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ "$MODE" =~ ^(kill|network|mix)$ ]] || { error "Invalid --mode: $MODE"; exit 1; }

# ---------------------------------------------------------------------------
# List running containers matching the pattern
# ---------------------------------------------------------------------------
get_targets() {
  docker ps --format '{{.Names}}' | grep -E "$PATTERN" || true
}

# ---------------------------------------------------------------------------
# Wait for a container to be running+healthy (or just running if no healthcheck)
# ---------------------------------------------------------------------------
wait_healthy() {
  local container="$1"
  local deadline=$(( $(epoch) + HEALTH_TIMEOUT ))

  while [[ $(epoch) -lt $deadline ]]; do
    local status
    status=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "missing")

    case "$status" in
      running)
        # Check for healthcheck
        local health
        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$container" 2>/dev/null || echo "missing")
        if [[ "$health" == "healthy" || "$health" == "no-healthcheck" ]]; then
          return 0
        fi
        ;;
      missing) : ;;  # still coming up
    esac
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Chaos mode: KILL
# ---------------------------------------------------------------------------
do_kill() {
  local cycle="$1"
  local targets
  targets=$(get_targets)

  if [[ -z "$targets" ]]; then
    warn "No containers matching pattern '${PATTERN}' — skipping kill cycle"
    return
  fi

  # Pick a random target
  local target
  target=$(echo "$targets" | shuf | head -1)

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would kill container: ${target}"
    return
  fi

  local started_at
  started_at="$(ts_now)"
  local t0
  t0=$(epoch)

  info "Cycle ${cycle} | KILL | Target: ${target}"
  docker kill "$target" 2>/dev/null || {
    warn "docker kill failed for ${target} (already dead?)"
    log_event "$cycle" "kill" "$target" "" "kill" "$started_at" "" "null" "false" "docker kill failed"
    (( FAIL_COUNT++ )) || true
    return
  }

  info "  Waiting for ${target} to recover (timeout: ${HEALTH_TIMEOUT}s)..."
  if wait_healthy "$target"; then
    local t1
    t1=$(epoch)
    local secs=$(( t1 - t0 ))
    info "  Recovered in ${secs}s"
    log_event "$cycle" "kill" "$target" "" "kill+recover" "$started_at" "$(ts_now)" "$secs" "true" ""
    (( PASS_COUNT++ )) || true
  else
    error "  ${target} did NOT recover within ${HEALTH_TIMEOUT}s"
    log_event "$cycle" "kill" "$target" "" "kill+timeout" "$started_at" "$(ts_now)" "null" "false" "recovery timeout"
    (( FAIL_COUNT++ )) || true
    if [[ "$FAIL_FAST" == "true" ]]; then
      error "FAIL_FAST enabled — aborting"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Chaos mode: NETWORK PARTITION
# ---------------------------------------------------------------------------
do_network() {
  local cycle="$1"
  local targets
  targets=$(get_targets)

  if [[ -z "$targets" ]]; then
    warn "No containers matching pattern '${PATTERN}' — skipping network cycle"
    return
  fi

  local target
  target=$(echo "$targets" | shuf | head -1)

  # Find all networks for this container (exclude 'host' and 'none')
  local networks
  networks=$(docker inspect "$target" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
    | tr ' ' '\n' | grep -vE '^(host|none|bridge|)$' || true)

  if [[ -z "$networks" ]]; then
    warn "Container ${target} has no user-defined networks — skipping partition"
    return
  fi

  # Pick a random network to partition
  local net
  net=$(echo "$networks" | shuf | head -1)

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would disconnect ${target} from network ${net} for ${RECOVERY_SECS}s"
    return
  fi

  local started_at
  started_at="$(ts_now)"
  local t0
  t0=$(epoch)

  info "Cycle ${cycle} | NETWORK | Target: ${target} | Net: ${net} | Duration: ${RECOVERY_SECS}s"
  docker network disconnect "$net" "$target" 2>/dev/null || {
    warn "Failed to disconnect ${target} from ${net}"
    log_event "$cycle" "network" "$target" "$net" "disconnect-failed" "$started_at" "" "null" "false" "disconnect failed"
    (( FAIL_COUNT++ )) || true
    return
  }

  info "  Partitioned. Waiting ${RECOVERY_SECS}s before reconnect..."
  sleep "$RECOVERY_SECS"

  docker network connect "$net" "$target" 2>/dev/null || {
    error "Failed to reconnect ${target} to ${net}"
    log_event "$cycle" "network" "$target" "$net" "reconnect-failed" "$started_at" "$(ts_now)" "null" "false" "reconnect failed"
    (( FAIL_COUNT++ )) || true
    return
  }

  # Verify container is still healthy after reconnect
  if wait_healthy "$target"; then
    local t1
    t1=$(epoch)
    local secs=$(( t1 - t0 ))
    info "  Healthy after partition+reconnect (${secs}s total)"
    log_event "$cycle" "network" "$target" "$net" "partition+reconnect" "$started_at" "$(ts_now)" "$secs" "true" ""
    (( PASS_COUNT++ )) || true
  else
    error "  ${target} NOT healthy after reconnect"
    log_event "$cycle" "network" "$target" "$net" "partition+unhealthy" "$started_at" "$(ts_now)" "null" "false" "unhealthy after reconnect"
    (( FAIL_COUNT++ )) || true
    if [[ "$FAIL_FAST" == "true" ]]; then
      error "FAIL_FAST enabled — aborting"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
info "========================================================"
info "WRFCoin Chaos Test"
info "  Pattern  : ${PATTERN}"
info "  Mode     : ${MODE}"
info "  Cycles   : ${CYCLES} (0 = infinite)"
info "  Interval : ${INTERVAL}s"
info "  Dry-run  : ${DRY_RUN}"
info "  Log      : ${LOG_FILE}"
info "========================================================"

if [[ "$DRY_RUN" == "true" ]]; then
  info "DRY-RUN mode — listing matching containers:"
  get_targets | while read -r c; do info "  ${c}"; done
  info "(no containers will be affected)"
fi

CYCLE=1
while [[ "$CYCLES" -eq 0 || "$CYCLE" -le "$CYCLES" ]]; do
  case "$MODE" in
    kill)    do_kill    "$CYCLE" ;;
    network) do_network "$CYCLE" ;;
    mix)
      if (( CYCLE % 2 == 0 )); then
        do_network "$CYCLE"
      else
        do_kill "$CYCLE"
      fi
      ;;
  esac

  if [[ "$CYCLES" -ne 0 && "$CYCLE" -ge "$CYCLES" ]]; then
    break
  fi

  info "  Sleeping ${INTERVAL}s before next cycle..."
  sleep "$INTERVAL"
  (( CYCLE++ )) || true
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL=$(( PASS_COUNT + FAIL_COUNT ))
info "========================================================"
info "Chaos run complete"
info "  Cycles executed : ${CYCLE}"
info "  Pass            : ${PASS_COUNT} / ${TOTAL}"
info "  Fail            : ${FAIL_COUNT} / ${TOTAL}"
info "  Results log     : ${LOG_FILE}"
info "========================================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  error "${FAIL_COUNT} container(s) failed to recover — check ${LOG_FILE}"
  exit 1
fi
