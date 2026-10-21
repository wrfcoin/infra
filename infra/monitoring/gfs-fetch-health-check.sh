#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_GFS_ENDPOINT="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl"
readonly DEFAULT_DRY_RUN_FIXTURE="./testdata/gfs-success.grib2.fixture"
readonly DEFAULT_CYCLE_DATE="20260311"
readonly DEFAULT_FORECAST_HOUR="000"

GFS_HEALTH_MODE="${GFS_HEALTH_MODE:-dry-run}"
GFS_ENDPOINT="${GFS_ENDPOINT:-$DEFAULT_GFS_ENDPOINT}"
GFS_TIMEOUT_SECONDS="${GFS_TIMEOUT_SECONDS:-20}"
GFS_METRICS_OUTPUT_PATH="${GFS_METRICS_OUTPUT_PATH:-./gfs_fetch_health.prom}"
GFS_HEALTH_STATE_DIR="${GFS_HEALTH_STATE_DIR:-./.gfs-fetch-health}"
GFS_HEALTH_DRY_RUN_FIXTURE="${GFS_HEALTH_DRY_RUN_FIXTURE:-$DEFAULT_DRY_RUN_FIXTURE}"
GFS_HEALTH_LOOP_INTERVAL_SECONDS="${GFS_HEALTH_LOOP_INTERVAL_SECONDS:-300}"
GFS_HEALTH_RUN_ONCE="${GFS_HEALTH_RUN_ONCE:-1}"
GFS_CYCLE_DATE="${GFS_CYCLE_DATE:-}"
GFS_CYCLE_HOUR="${GFS_CYCLE_HOUR:-}"
GFS_FORECAST_HOUR="${GFS_FORECAST_HOUR:-$DEFAULT_FORECAST_HOUR}"
GFS_LEFT_LON="${GFS_LEFT_LON:--125}"
GFS_RIGHT_LON="${GFS_RIGHT_LON:--66}"
GFS_TOP_LAT="${GFS_TOP_LAT:-49}"
GFS_BOTTOM_LAT="${GFS_BOTTOM_LAT:-24}"

readonly STATE_LAST_SUCCESS_FILE="$GFS_HEALTH_STATE_DIR/last_success_unixtime"
readonly STATE_LAST_REASON_FILE="$GFS_HEALTH_STATE_DIR/last_failure_reason"
readonly STATE_LAST_MODE_FILE="$GFS_HEALTH_STATE_DIR/last_mode"

log() {
  printf '%s\n' "$*" >&2
}

metrics_tmp_path() {
  printf '%s.tmp' "$GFS_METRICS_OUTPUT_PATH"
}

ensure_dirs() {
  mkdir -p "$(dirname "$GFS_METRICS_OUTPUT_PATH")" "$GFS_HEALTH_STATE_DIR"
}

utc_now() {
  date -u +%s
}

resolve_cycle_date() {
  if [[ -n "$GFS_CYCLE_DATE" ]]; then
    printf '%s' "$GFS_CYCLE_DATE"
    return
  fi

  if [[ "$GFS_HEALTH_MODE" == "live" ]]; then
    date -u +%Y%m%d
  else
    printf '%s' "$DEFAULT_CYCLE_DATE"
  fi
}

resolve_cycle_hour() {
  if [[ -n "$GFS_CYCLE_HOUR" ]]; then
    printf '%02d' "$GFS_CYCLE_HOUR"
    return
  fi

  if [[ "$GFS_HEALTH_MODE" == "live" ]]; then
    local hour
    hour="$(date -u +%H)"
    printf '%02d' $((10#$hour / 6 * 6))
  else
    printf '00'
  fi
}

read_state_or_default() {
  local path="$1"
  local fallback="$2"

  if [[ -f "$path" ]]; then
    cat "$path"
  else
    printf '%s' "$fallback"
  fi
}

write_state() {
  local path="$1"
  local value="$2"
  printf '%s\n' "$value" > "$path"
}

write_metrics() {
  local up="$1"
  local latency="$2"
  local last_success="$3"
  local last_probe="$4"
  local failure_reason="$5"
  local tmp_path

  tmp_path="$(metrics_tmp_path)"
  cat > "$tmp_path" <<EOF
# HELP gfs_fetch_health_up 1 when the latest GFS fetch probe succeeded.
# TYPE gfs_fetch_health_up gauge
gfs_fetch_health_up ${up}
# HELP gfs_fetch_health_latency_seconds End-to-end latency of the latest GFS fetch probe.
# TYPE gfs_fetch_health_latency_seconds gauge
gfs_fetch_health_latency_seconds ${latency}
# HELP gfs_fetch_health_last_success_unixtime Unix timestamp of the last successful GFS fetch probe.
# TYPE gfs_fetch_health_last_success_unixtime gauge
gfs_fetch_health_last_success_unixtime ${last_success}
# HELP gfs_fetch_health_last_probe_unixtime Unix timestamp of the last attempted GFS fetch probe.
# TYPE gfs_fetch_health_last_probe_unixtime gauge
gfs_fetch_health_last_probe_unixtime ${last_probe}
# gfs_fetch_health_mode ${GFS_HEALTH_MODE}
# gfs_fetch_health_failure_reason ${failure_reason}
EOF
  mv "$tmp_path" "$GFS_METRICS_OUTPUT_PATH"
}

payload_size_bytes() {
  wc -c < "$1" | tr -d '[:space:]'
}

payload_prefix() {
  head -c 32 "$1" | tr '\r\n' ' ' | tr -dc '[:print:]'
}

payload_magic() {
  head -c 4 "$1"
}

validate_payload() {
  local body_file="$1"
  local content_type="$2"
  local size
  local magic
  local prefix

  size="$(payload_size_bytes "$body_file")"
  if (( size <= 1024 )); then
    log "GFS health check failed: payload too small (${size} bytes)"
    return 20
  fi

  magic="$(payload_magic "$body_file")"
  if [[ "$magic" != "GRIB" ]]; then
    prefix="$(payload_prefix "$body_file")"
    if [[ "$prefix" == "<html"* || "$prefix" == "<!DOCTYPE"* ]]; then
      log "GFS health check failed: HTML payload detected"
      return 21
    fi

    if [[ "$content_type" == text/html* || "$content_type" == application/json* ]]; then
      log "GFS health check failed: unexpected content type ${content_type}"
      return 22
    fi

    log "GFS health check failed: payload missing GRIB magic"
    return 23
  fi

  return 0
}

run_dry_run_probe() {
  local body_file="$1"
  cp "$GFS_HEALTH_DRY_RUN_FIXTURE" "$body_file"
  printf '0.001'
}

run_live_probe() {
  local body_file="$1"
  local cycle_date
  local cycle_hour
  local curl_output
  local http_code
  local latency
  local content_type
  local gfs_file

  cycle_date="$(resolve_cycle_date)"
  cycle_hour="$(resolve_cycle_hour)"
  gfs_file="gfs.t${cycle_hour}z.pgrb2.0p25.f${GFS_FORECAST_HOUR}"

  if ! curl_output="$(
    curl \
      --silent \
      --show-error \
      --location \
      --max-time "$GFS_TIMEOUT_SECONDS" \
      --output "$body_file" \
      --write-out $'http_code=%{http_code}\ntime_total=%{time_total}\ncontent_type=%{content_type}\n' \
      --get "$GFS_ENDPOINT" \
      --data-urlencode "file=${gfs_file}" \
      --data-urlencode "lev_2_m_above_ground=on" \
      --data-urlencode "lev_10_m_above_ground=on" \
      --data-urlencode "lev_surface=on" \
      --data-urlencode "var_TMP=on" \
      --data-urlencode "var_PRES=on" \
      --data-urlencode "var_RH=on" \
      --data-urlencode "var_UGRD=on" \
      --data-urlencode "var_VGRD=on" \
      --data-urlencode "subregion=" \
      --data-urlencode "leftlon=${GFS_LEFT_LON}" \
      --data-urlencode "rightlon=${GFS_RIGHT_LON}" \
      --data-urlencode "toplat=${GFS_TOP_LAT}" \
      --data-urlencode "bottomlat=${GFS_BOTTOM_LAT}" \
      --data-urlencode "dir=/gfs.${cycle_date}/${cycle_hour}/atmos"
  )"; then
    log "GFS health check failed: curl request could not complete"
    printf '__HTTP__:curl_failed:0'
    return 12
  fi

  http_code="$(printf '%s\n' "$curl_output" | awk -F= '/^http_code=/{print $2}')"
  latency="$(printf '%s\n' "$curl_output" | awk -F= '/^time_total=/{print $2}')"
  content_type="$(printf '%s\n' "$curl_output" | awk -F= '/^content_type=/{print $2}')"

  if [[ "$http_code" != "200" ]]; then
    log "GFS health check failed: HTTP ${http_code}"
    printf '__HTTP__:%s:%s' "$http_code" "$latency"
    return 10
  fi

  if validate_payload "$body_file" "$content_type"; then
    :
  else
    local validate_status=$?
    case "$validate_status" in
      20) printf '__PAYLOAD__:payload_too_small:%s' "$latency" ;;
      21) printf '__PAYLOAD__:html_payload:%s' "$latency" ;;
      22) printf '__PAYLOAD__:unexpected_content_type:%s' "$latency" ;;
      *) printf '__PAYLOAD__:bad_magic:%s' "$latency" ;;
    esac
    return 11
  fi

  printf '%s' "$latency"
}

probe_once() {
  local body_file
  local last_probe
  local last_success
  local latency="0"
  local failure_reason="none"
  local probe_result

  body_file="$(mktemp)"
  trap 'rm -f "$body_file"' RETURN
  last_probe="$(utc_now)"
  last_success="$(read_state_or_default "$STATE_LAST_SUCCESS_FILE" 0)"

  if [[ "$GFS_HEALTH_MODE" == "dry-run" ]]; then
    probe_result="$(run_dry_run_probe "$body_file")"
    latency="${probe_result}"

    if validate_payload "$body_file" "application/octet-stream"; then
      last_success="$last_probe"
      write_state "$STATE_LAST_SUCCESS_FILE" "$last_success"
      write_state "$STATE_LAST_REASON_FILE" "none"
      write_state "$STATE_LAST_MODE_FILE" "$GFS_HEALTH_MODE"
      write_metrics 1 "$latency" "$last_success" "$last_probe" "none"
      log "GFS health check OK mode=dry-run latency=${latency}s fixture=${GFS_HEALTH_DRY_RUN_FIXTURE}"
      return 0
    else
      local validate_status=$?
      case "$validate_status" in
        20) failure_reason="payload_too_small" ;;
        21) failure_reason="html_payload" ;;
        22) failure_reason="unexpected_content_type" ;;
        *) failure_reason="bad_magic" ;;
      esac
    fi
  else
    if probe_result="$(run_live_probe "$body_file")"; then
      latency="$probe_result"
      last_success="$last_probe"
      write_state "$STATE_LAST_SUCCESS_FILE" "$last_success"
      write_state "$STATE_LAST_REASON_FILE" "none"
      write_state "$STATE_LAST_MODE_FILE" "$GFS_HEALTH_MODE"
      write_metrics 1 "$latency" "$last_success" "$last_probe" "none"
      log "GFS health check OK mode=live latency=${latency}s endpoint=${GFS_ENDPOINT}"
      return 0
    fi

    case "$probe_result" in
      __HTTP__:*:*)
        failure_reason="${probe_result#__HTTP__:}"
        failure_reason="${failure_reason%%:*}"
        latency="${probe_result##*:}"
        ;;
      __PAYLOAD__:*:*)
        failure_reason="${probe_result#__PAYLOAD__:}"
        failure_reason="${failure_reason%%:*}"
        latency="${probe_result##*:}"
        ;;
      *)
        failure_reason="curl_failed"
        ;;
    esac
  fi

  write_state "$STATE_LAST_REASON_FILE" "$failure_reason"
  write_state "$STATE_LAST_MODE_FILE" "$GFS_HEALTH_MODE"
  write_metrics 0 "$latency" "$last_success" "$last_probe" "$failure_reason"
  log "GFS health check FAILED mode=${GFS_HEALTH_MODE} reason=${failure_reason} latency=${latency}s"
  return 1
}

main() {
  ensure_dirs

  while true; do
    if probe_once; then
      if [[ "$GFS_HEALTH_RUN_ONCE" == "1" ]]; then
        exit 0
      fi
    else
      if [[ "$GFS_HEALTH_RUN_ONCE" == "1" ]]; then
        exit 1
      fi
    fi

    sleep "$GFS_HEALTH_LOOP_INTERVAL_SECONDS"
  done
}

main "$@"
