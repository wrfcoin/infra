#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=testnet/lib/compose-inputs.sh
source "${SCRIPT_DIR}/lib/compose-inputs.sh"
wrfcoin_init_compose_inputs "${SCRIPT_DIR}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
TMP_FILES=()
SEMANTIC_VALIDATOR="${SCRIPT_DIR}/scripts/validate-health-payload.py"

cleanup() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "${f:-}" ] && [ -e "$f" ] && rm -f "$f"
  done
}
trap cleanup EXIT

have() {
  command -v "$1" >/dev/null 2>&1
}

compose_runner() {
  if have docker && docker compose version >/dev/null 2>&1; then
    wrfcoin_compose "$@"
    return
  fi
  return 127
}

check_oracle_reference() {
  local services service count=0 total=0

  if ! services="$(compose_runner config --services 2>/dev/null)"; then
    mark_fail "Oracle reference: effective Compose configuration could not be rendered"
    return 0
  fi
  while IFS= read -r service; do
    [[ -n "${service}" ]] || continue
    total=$((total + 1))
    if [[ ! "${service}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      mark_fail "Oracle reference: effective Compose service inventory is malformed"
      return 0
    fi
    [[ "${service}" == "oracle-reference" ]] && count=$((count + 1))
  done <<< "${services}"

  if (( total == 0 )); then
    mark_fail "Oracle reference: effective Compose service inventory is empty"
  elif (( count == 0 )); then
    mark_pass "Oracle reference: not configured; optional check skipped"
  elif (( count == 1 )); then
    probe_compose_health "oracle-reference" "Oracle reference" "oracle-reference service not healthy"
  else
    mark_fail "Oracle reference: effective Compose service inventory is ambiguous"
  fi
}

# infra#972: REFERENCE_SHADOW=1 makes wrfcoin-backend call the oracle-reference
# sidecar after every reveal. Shadow scoring is advisory only: it runs after the
# core4 reveal and local finalization, fails open, and never changes a reward.
# Enabled without the sidecar it can only fail, so that is RED with a named
# reason. Enabled with it is a WARN: the scorer's tiering is not yet at consensus
# parity (oracle-reference#9, backend#1169), so its scores are not comparable to
# consensus until both land. Reads the EFFECTIVE render, not a .env line.
check_reference_shadow() {
  local rendered verdict
  if ! rendered="$(compose_runner config --format json 2>/dev/null)"; then
    mark_fail "Reference shadow: effective Compose configuration could not be rendered"
    return 0
  fi
  if ! verdict="$(python3 -c '
import json, sys
services = json.loads(sys.stdin.read()).get("services") or {}
backend = services.get("wrfcoin-backend")
if backend is None:
    print("no-backend")
elif str((backend.get("environment") or {}).get("REFERENCE_SHADOW", "")) != "1":
    print("off")
else:
    print("on-with-sidecar" if "oracle-reference" in services else "on-without-sidecar")
' <<< "${rendered}" 2>/dev/null)"; then
    mark_fail "Reference shadow: effective Compose configuration is not valid JSON"
    return 0
  fi
  case "${verdict}" in
    off) mark_pass "Reference shadow: off (default; REFERENCE_SHADOW is not 1)" ;;
    no-backend) mark_pass "Reference shadow: wrfcoin-backend not in the effective set; check skipped" ;;
    on-without-sidecar)
      mark_fail "Reference shadow: REFERENCE_SHADOW=1 on wrfcoin-backend but oracle-reference is not in the effective Compose set (use --profile oracle-reference with docker-compose.reference-shadow.yml)" ;;
    on-with-sidecar)
      mark_warn "Reference shadow: ON, advisory only with zero reward effect; the scorer is NOT at consensus parity yet (oracle-reference#9, backend#1169), so its scores are not comparable to consensus" ;;
    *) mark_fail "Reference shadow: unexpected verdict '${verdict}'" ;;
  esac
}

status_line() {
  local level="$1"
  shift
  printf '%-5s %s\n' "$level" "$*"
}

mark_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  status_line PASS "$*"
}

mark_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  status_line WARN "$*"
}

mark_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  status_line FAIL "$*"
}

short_body() {
  tr '\n' ' ' < "$1" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | cut -c1-180
}

probe_reachability() {
  local label="$1"
  local url="$2"
  local hint="$3"
  local auth_ok="${4:-false}"
  local tmp http_code body

  if ! have curl; then
    mark_warn "${label}: curl is not installed; cannot probe ${url} (${hint})"
    return 0
  fi

  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  http_code="$(curl -sS --connect-timeout 3 --max-time 5 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  body="$(short_body "$tmp" 2>/dev/null || true)"

  if [ "$http_code" = "200" ]; then
    if [ -n "$body" ]; then
      mark_warn "${label}: REACHABILITY_ONLY HTTP 200 (${body})"
    else
      mark_warn "${label}: REACHABILITY_ONLY HTTP 200"
    fi
  elif [ "$http_code" = "401" ] && [ "$auth_ok" = "auth_ok" ]; then
    mark_warn "${label}: REACHABILITY_ONLY HTTP 401 (auth required; service is responding)"
  elif [ -n "$http_code" ] && [ "$http_code" != "000" ]; then
    mark_fail "${label}: HTTP ${http_code} (${hint})"
  else
    mark_fail "${label}: unreachable (${hint})"
  fi
}

# backend#1234: backend/governance /health returns dependency detail only to
# an operator or reader bearer; anonymous callers get {status, timestamp}.
# Prefer the read-only reader token, fall back to the operator token, from the
# process environment or the stack's testnet/.env.
health_bearer_token() {
  local key value
  for key in WRFCOIN_READER_TOKEN WRFCOIN_OPERATOR_TOKEN; do
    value="${!key:-}"
    [[ -n "${value}" ]] || value="$(wrfcoin_compose_env_value "${SCRIPT_DIR}" "${key}")"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
  done
  return 1
}

probe_semantic_http() {
  local label="$1" url="$2" contract="$3"
  local tmp http_code body validation token
  if ! have curl; then
    mark_fail "${label}: curl is not installed; semantic health is unverified"
    return 0
  fi
  if [[ ! -x "$SEMANTIC_VALIDATOR" ]]; then
    mark_fail "${label}: semantic validator is missing"
    return 0
  fi
  if ! token="$(health_bearer_token)"; then
    mark_fail "${label}: no WRFCOIN_READER_TOKEN or WRFCOIN_OPERATOR_TOKEN (env or testnet/.env); dependency health is unverified"
    return 0
  fi
  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  # The header travels on stdin (-H @-) so the token never appears in argv.
  http_code="$(printf 'Authorization: Bearer %s\n' "${token}" |
    curl -sS --connect-timeout 3 --max-time 5 -H @- -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  body="$(short_body "$tmp" 2>/dev/null || true)"
  if [[ "$http_code" != 200 ]]; then
    mark_fail "${label}: HTTP ${http_code:-000}; semantic health unavailable"
    return 0
  fi
  if validation="$(python3 "$SEMANTIC_VALIDATOR" --contract "$contract" "$tmp" 2>&1)"; then
    mark_pass "${label}: ${validation}"
  else
    mark_fail "${label}: HTTP 200 but semantic contract failed (${validation}; body=${body:-<empty>})"
  fi
}

probe_compose_health() {
  local service="$1"
  local label="$2"
  local hint="$3"
  local container_ids container expected_hash hash_lines metadata
  local inspected_id service_label oneoff state health actual_hash
  local extra
  local -a containers=()

  if ! have docker; then
    mark_warn "${label}: docker is not installed; cannot inspect (${hint})"
    return 0
  fi
  if ! hash_lines="$(compose_runner config --hash="$service" 2>/dev/null)"; then
    mark_fail "${label}: effective Compose config hash is unavailable (${hint})"
    return 0
  fi
  expected_hash="$(awk -v service="$service" '
    NF > 0 { lines++ }
    NF == 2 && $1 == service && $2 ~ /^[0-9a-f]{64}$/ { count++; hash=$2 }
    END { if (lines == 1 && count == 1) print hash; else exit 1 }
  ' <<< "${hash_lines}" 2>/dev/null || true)"
  if [[ -z "${expected_hash}" ]]; then
    mark_fail "${label}: effective Compose config hash is malformed or ambiguous (${hint})"
    return 0
  fi

  if ! container_ids="$(compose_runner ps -q "$service" 2>/dev/null)"; then
    mark_fail "${label}: container lookup failed (${hint})"
    return 0
  fi
  mapfile -t containers < <(printf '%s\n' "${container_ids}" | sed '/^$/d')
  if (( ${#containers[@]} == 0 )); then
    mark_fail "${label}: container is not running (${hint})"
    return 0
  fi
  if (( ${#containers[@]} != 1 )) || [[ ! "${containers[0]}" =~ ^[0-9a-f]{12,64}$ ]]; then
    mark_fail "${label}: container lookup is malformed or ambiguous (${hint})"
    return 0
  fi
  container="${containers[0]}"
  if ! metadata="$(docker inspect --format '{{.Id}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.oneoff"}}{{"\t"}}{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}{{"\t"}}{{index .Config.Labels "com.docker.compose.config-hash"}}' "$container" 2>/dev/null)"; then
    mark_fail "${label}: container inspection failed (${hint})"
    return 0
  fi
  IFS=$'\t' read -r inspected_id service_label oneoff state health actual_hash extra <<< "${metadata}"
  if [[ -n "${extra:-}" || "${inspected_id}" != "${container}" \
     || "${service_label}" != "${service}" || "${oneoff}" != "False" \
     || "${state}" != "running" || ! "${actual_hash}" =~ ^[0-9a-f]{64}$ ]]; then
    mark_fail "${label}: container metadata is invalid (${hint})"
  elif [[ "${actual_hash}" != "${expected_hash}" ]]; then
    mark_fail "${label}: container config hash does not match effective Compose configuration (${hint})"
  elif [[ "${health}" == "healthy" ]]; then
    mark_pass "${label}: container is running, healthy, and matches effective Compose configuration"
  else
    mark_fail "${label}: container health is ${health:-unavailable} (${hint})"
  fi
}

extract_peer_count() {
  local payload="$1"

  if have jq; then
    printf '%s' "$payload" | jq -r '
      if (.connected_peers? | type) == "array" then
        .connected_peers | length
      elif (.connected_peers? | type) == "number" then
        .connected_peers
      elif (.peer_count? | type) == "number" then
        .peer_count
      else
        empty
      end
    ' 2>/dev/null || true
    return 0
  fi

  if printf '%s' "$payload" | grep -Eq '"peer_count"[[:space:]]*:[[:space:]]*[0-9]+'; then
    printf '%s' "$payload" | sed -nE 's/.*"peer_count"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n1
    return 0
  fi

  if printf '%s' "$payload" | grep -Eq '"connected_peers"[[:space:]]*:[[:space:]]*0'; then
    printf '0'
    return 0
  fi

  if printf '%s' "$payload" | grep -Eq '"connected_peers"[[:space:]]*:[[:space:]]*\[\s*\]'; then
    printf '0'
    return 0
  fi
}

extract_chain_height() {
  local payload="$1"

  if have jq; then
    printf '%s' "$payload" | jq -r '
      if (.data?.height? | type) == "number" then
        .data.height
      elif (.height? | type) == "number" then
        .height
      else
        empty
      end
    ' 2>/dev/null || true
    return 0
  fi

  if printf '%s' "$payload" | grep -Eq '"height"[[:space:]]*:[[:space:]]*[0-9]+'; then
    printf '%s' "$payload" | sed -nE 's/.*"height"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' | head -n1
  fi
}

check_node_api() {
  local url="http://localhost:8556/blockchain"
  local tmp http_code payload height

  if ! have curl; then
    mark_warn "Node API: curl is not installed; cannot inspect ${url}"
    return 0
  fi

  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  http_code="$(curl -sS --connect-timeout 3 --max-time 5 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  payload="$(cat "$tmp" 2>/dev/null || true)"
  height="$(extract_chain_height "$payload")"

  if [ "$http_code" != "200" ]; then
    mark_fail "Node API: blockchain endpoint unreachable (HTTP ${http_code:-000})"
    return 0
  fi

  if [ -n "${height:-}" ]; then
    mark_pass "Node API: serving blockchain state at height ${height}"
  elif [ -n "$payload" ]; then
    mark_pass "Node API: HTTP 200 (${payload:0:120})"
  else
    mark_pass "Node API: HTTP 200"
  fi
}

check_node_readiness() {
  local url="http://localhost:8556/readyz"
  local tmp http_code body

  if ! have curl; then
    mark_warn "Node readiness: curl is not installed; cannot inspect ${url}"
    return 0
  fi

  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  http_code="$(curl -sS --connect-timeout 3 --max-time 5 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  body="$(short_body "$tmp" 2>/dev/null || true)"

  if [ "$http_code" = "200" ]; then
    mark_pass "Node readiness: HTTP 200 (${body:-ready})"
  elif [ "$http_code" = "503" ]; then
    mark_warn "Node readiness: HTTP 503 (${body:-not ready}; node may still be replaying or waiting on fresh blocks)"
  else
    mark_fail "Node readiness: unreachable (HTTP ${http_code:-000})"
  fi
}

check_node_peers() {
  local url="http://localhost:8556/network/info"
  local tmp http_code payload peers

  if ! have curl; then
    mark_warn "Node peers: curl is not installed; cannot inspect ${url}"
    return 0
  fi

  tmp="$(mktemp)"
  TMP_FILES+=("$tmp")
  http_code="$(curl -sS --connect-timeout 3 --max-time 5 -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || true)"
  payload="$(cat "$tmp" 2>/dev/null || true)"
  peers="$(extract_peer_count "$payload")"

  if [ "$http_code" != "200" ]; then
    mark_fail "Node peers: network/info unreachable (HTTP ${http_code:-000})"
    return 0
  fi

  if [ -n "${peers:-}" ]; then
    if [ "$peers" -gt 0 ] 2>/dev/null; then
      mark_pass "Node peers: ${peers} connected"
    else
      mark_warn "Node peers: 0 connected peers; check BOOTSTRAP_PEERS, seed nodes, and TCP 9000 reachability"
    fi
  else
    if [ -n "$payload" ]; then
      mark_warn "Node peers: HTTP 200 but peer count could not be parsed (${payload:0:120})"
    else
      mark_warn "Node peers: HTTP 200 but empty response body"
    fi
  fi
}

check_listener() {
  local port="$1"
  local label="$2"
  local lines

  if ! have ss; then
    mark_warn "${label}: ss is not installed; cannot verify local listener on :${port}"
    return 0
  fi

  lines="$(ss -H -ltn "( sport = :${port} )" 2>/dev/null || true)"
  if [ -n "$lines" ]; then
    mark_pass "${label}: listening on :${port}"
    printf '%s\n' "$lines" | sed 's/^/      /'
  else
    mark_warn "${label}: no local listener detected on :${port}"
  fi
}

show_compose_status() {
  local ps_json

  if ! have docker; then
    mark_warn "Docker Compose: docker is not installed; skipping compose status"
    return 0
  fi

  if ! compose_runner version >/dev/null 2>&1; then
    mark_warn "Docker Compose: unavailable; skipping compose status"
    return 0
  fi

  printf '\n== Docker Compose Status ==\n'
  if have jq; then
    ps_json="$(mktemp)"
    TMP_FILES+=("$ps_json")
    if compose_runner ps --format json >"$ps_json" 2>/dev/null; then
    while IFS=$'\t' read -r name state health; do
      [ -n "$name" ] || continue
      printf '%-5s %-32s state=%s health=%s\n' INFO "$name" "${state:-unknown}" "${health:-n/a}"
      done < <(jq -r '.[] | [ .Name, (.State // "unknown"), (.Health // "n/a") ] | @tsv' "$ps_json" 2>/dev/null || true)
    else
      compose_runner ps || true
    fi
  else
    compose_runner ps || true
  fi
}

main() {
  printf '== WRFCoin Testnet Health Summary ==\n'
  printf 'Compose files:\n'
  printf '  - %s\n' "${COMPOSE_FILES[@]}"
  printf '\n'

  show_compose_status

  printf '\n== Service Checks ==\n'
  check_node_api
  check_node_readiness
  check_node_peers
  check_listener 9000 "Node P2P"
  probe_semantic_http "Backend dependency health" "http://localhost:4001/health" "backend"
  probe_semantic_http "Governance dependency health" "http://localhost:8000/health" "governance"
  probe_reachability "IoT reachability" "http://localhost:3002/health" "IoT liveness unavailable"
  probe_reachability "Weather earnings reachability" "http://localhost:8001/health" "weather earnings liveness unavailable"
  probe_reachability "Frontend reachability" "http://localhost:5000/health" "frontend liveness unavailable"
  # ORACLE_REFERENCE_CHECK_BEGIN
  check_oracle_reference
  # ORACLE_REFERENCE_CHECK_END
  # REFERENCE_SHADOW_CHECK_BEGIN
  check_reference_shadow
  # REFERENCE_SHADOW_CHECK_END
  probe_reachability "Prometheus reachability" "http://localhost:9090/-/healthy" "Prometheus liveness unavailable" "auth_ok"
  probe_reachability "Grafana reachability" "http://localhost:3100/api/health" "Grafana liveness unavailable"
  probe_reachability "Alertmanager reachability" "http://localhost:9093/-/healthy" "Alertmanager liveness unavailable"

  printf '\n== Summary ==\n'
  printf 'PASS: %d  WARN: %d  FAIL: %d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

case "${1:-}" in
  --probe-service)
    [[ $# -eq 4 ]] || { echo "usage: $0 --probe-service CONTRACT URL LABEL" >&2; exit 2; }
    probe_semantic_http "$4" "$3" "$2"
    [[ "$FAIL_COUNT" -eq 0 ]]
    ;;
  --print-compose-files)
    wrfcoin_print_compose_files
    ;;
  --print-compose-profiles)
    wrfcoin_print_compose_profiles
    ;;
  *)
    main "$@"
    ;;
esac
