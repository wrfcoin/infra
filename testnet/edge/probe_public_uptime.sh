#!/usr/bin/env bash
# =============================================================================
# CT102 public availability probe (infra#117)
# =============================================================================
# Bounded CT102-facing public-availability probe.
# This is not an off-network exposure proof; it is an application-level
# availability gate for the public domain.

set -euo pipefail

BASE_URL="${BASE_URL:-}"
HOST="${HOST:-}"
STATE_DIR="${STATE_DIR:-}"
RECEIPT_DIR="${RECEIPT_DIR:-}"
PUBLISH_DIR="${PUBLISH_DIR:-}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-6}"
REQUEST_RETRIES="${REQUEST_RETRIES:-3}"
RETRY_DELAY="${RETRY_DELAY:-1}"
FAILURE_THRESHOLD="${FAILURE_THRESHOLD:-18}"
REQUEST_TIMEOUT_MAX="${REQUEST_TIMEOUT_MAX:-6}"
REQUEST_RETRIES_MAX="${REQUEST_RETRIES_MAX:-3}"
RETRY_DELAY_MAX="${RETRY_DELAY_MAX:-1}"
PROBE_RUNTIME_MAX_SECONDS="${PROBE_RUNTIME_MAX_SECONDS:-110}"
ALLOW_HTTP="${ALLOW_HTTP:-0}"
SELF_TEST="${SELF_TEST:-0}"

NONCE_DUMMY_ADDRESS="0x0000000000000000000000000000000000000000"
NONCE_PATH="/api/auth/nonce/${NONCE_DUMMY_ADDRESS}"
PROTECTED_PATH="/api/weather/stations/NO-SUCH-STATION/reward-progress"
FORBIDDEN_PATH="/api/health"
NONCE_EXPECTED_ORIGIN="${WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN:-}"
NONCE_EXPECTED_URI="${WRFCOIN_TESTNET_NONCE_EXPECTED_URI:-}"
NONCE_EXPECTED_CHAIN_ID="${WRFCOIN_CHAIN_ID:-${WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID:-}}"

REQUEST_CODE=""
REQUEST_BODY=""

ROOT_CODE=""
NONCE_CODE=""
PROTECTED_CODE=""
FORBIDDEN_CODE=""

USAGE="$(cat <<'USAGE'
Usage:
  probe_public_uptime.sh --base-url <url> [options]
  probe_public_uptime.sh --host <host> [options]
  probe_public_uptime.sh --self-test

Options:
  --base-url <url>             Full public URL to probe.
  --host <host>                Hostname to probe, defaults to https://<host>.
  --state-dir <path>           Directory for atomic failure state/receipts.
  --receipt-dir <path>         Directory for atomic timestamped receipts.
  --publish-dir <path>         Directory for redacted public status.json.
  --timeout <secs>             Per-request timeout (default: 6).
  --request-retries <n>        Retry loop bound for each request (default: 3).
  --retry-delay <secs>         Sleep between bounded retries (default: 1).
  --failure-threshold <n>      Nonzero terminal state threshold (default: 18).
  --allow-http                 Permit http:// URLs for self-test/harnesses.
  --self-test                  Run built-in mutation and contract controls.
USAGE
)"

normalize_url() {
  local input="$1"
  if [[ -z "$input" ]]; then
    echo ""
    return 0
  fi
  if [[ "$input" == *"://"* ]]; then
    echo "$input"
  else
    echo "https://$input"
  fi
}

parse_cli() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --base-url) BASE_URL="$2"; shift 2 ;;
      --host) HOST="$2"; shift 2 ;;
      --state-dir) STATE_DIR="$2"; shift 2 ;;
      --receipt-dir) RECEIPT_DIR="$2"; shift 2 ;;
      --publish-dir) PUBLISH_DIR="$2"; shift 2 ;;
      --timeout) REQUEST_TIMEOUT="$2"; shift 2 ;;
      --request-retries) REQUEST_RETRIES="$2"; shift 2 ;;
      --retry-delay) RETRY_DELAY="$2"; shift 2 ;;
      --failure-threshold) FAILURE_THRESHOLD="$2"; shift 2 ;;
      --allow-http) ALLOW_HTTP=1; shift ;;
      --self-test) SELF_TEST=1; shift ;;
      --help|-h)
        printf '%s\n' "$USAGE"
        exit 0
        ;;
      *)
        printf 'FAIL: unknown argument: %s\n' "$1" >&2
        printf '%s\n' "$USAGE" >&2
        exit 2
        ;;
    esac
  done

  if [[ "$SELF_TEST" == "1" ]]; then
    BASE_URL="${BASE_URL:-https://probe-testnet.local}"
  elif [[ -n "$HOST" ]]; then
    BASE_URL="$(normalize_url "$HOST")"
  elif [[ -n "$BASE_URL" ]]; then
    BASE_URL="$(normalize_url "$BASE_URL")"
  else
    printf 'FAIL: --base-url or --host is required when not running --self-test\n' >&2
    exit 2
  fi
}

require_positive_integer() {
  local name="$1"
  local value="${!name}"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL: --%s must be a positive integer, got %s\n' "${name//_/ -}" "$value" >&2
    exit 2
  fi
}

require_bounded_positive_integer() {
  local name="$1"
  local max="$2"
  local value="${!name}"

  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL: --%s must be a positive integer, got %s\n' "${name//_/ -}" "$value" >&2
    exit 2
  fi
  if (( value > max )); then
    printf 'FAIL: --%s must be <= %s, got %s\n' "${name//_/ -}" "$max" "$value" >&2
    exit 2
  fi
}

validate_configuration() {
  if [[ "$SELF_TEST" == "1" ]]; then
    return 0
  fi

  require_bounded_positive_integer REQUEST_TIMEOUT "$REQUEST_TIMEOUT_MAX"
  require_bounded_positive_integer REQUEST_RETRIES "$REQUEST_RETRIES_MAX"
  require_bounded_positive_integer RETRY_DELAY "$RETRY_DELAY_MAX"
  require_positive_integer FAILURE_THRESHOLD
  local route_runtime_budget=0
  local four_route_runtime_budget=0
  local max_route_runtime_budget=0
  local max_four_route_runtime_budget=0

  route_runtime_budget=$((REQUEST_TIMEOUT * REQUEST_RETRIES + RETRY_DELAY * REQUEST_RETRIES * (REQUEST_RETRIES + 1) / 2))
  four_route_runtime_budget=$((route_runtime_budget * 4))
  max_route_runtime_budget=$((REQUEST_TIMEOUT_MAX * REQUEST_RETRIES_MAX + RETRY_DELAY_MAX * REQUEST_RETRIES_MAX * (REQUEST_RETRIES_MAX + 1) / 2))
  max_four_route_runtime_budget=$((max_route_runtime_budget * 4))
  if (( four_route_runtime_budget >= PROBE_RUNTIME_MAX_SECONDS )); then
    printf 'FAIL: bounded runtime exceeds runtime cap %d: timeout=%s retries=%s delay=%s\n' \
      "$PROBE_RUNTIME_MAX_SECONDS" "$REQUEST_TIMEOUT" "$REQUEST_RETRIES" "$RETRY_DELAY" >&2
    exit 2
  fi
  if (( max_four_route_runtime_budget >= PROBE_RUNTIME_MAX_SECONDS )); then
    printf 'FAIL: ceiling configuration can exceed cap %d (%s, %s, %s)\n' \
      "$PROBE_RUNTIME_MAX_SECONDS" \
      "$REQUEST_TIMEOUT_MAX" "$REQUEST_RETRIES_MAX" "$RETRY_DELAY_MAX" >&2
    exit 2
  fi

  if [[ "$BASE_URL" != https://* && "$BASE_URL" != http://* ]]; then
    printf 'FAIL: --base-url/--host must include scheme: %s\n' "$BASE_URL" >&2
    exit 2
  fi
  if [[ "$BASE_URL" == http://* && "$ALLOW_HTTP" != "1" ]]; then
    printf 'FAIL: http:// rejected by default; use --allow-http only for test harnesses\n' >&2
    exit 2
  fi
  if [[ -z "${STATE_DIR}" ]]; then
    STATE_DIR="/var/lib/wrfcoin-testnet-uptime"
  fi
  if [[ -z "${RECEIPT_DIR}" ]]; then
    RECEIPT_DIR="${STATE_DIR}/receipts"
  fi
  if [[ -z "$NONCE_EXPECTED_ORIGIN" ]]; then
    printf 'FAIL: WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN is required\n' >&2
    exit 2
  fi
  if [[ -z "$NONCE_EXPECTED_URI" ]]; then
    printf 'FAIL: WRFCOIN_TESTNET_NONCE_EXPECTED_URI is required\n' >&2
    exit 2
  fi
  if ! [[ "$NONCE_EXPECTED_CHAIN_ID" =~ ^[1-9][0-9]*$ ]]; then
    printf 'FAIL: WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID must be a positive integer, got %s\n' \
      "$NONCE_EXPECTED_CHAIN_ID" >&2
    exit 2
  fi
  command -v curl >/dev/null 2>&1 || {
    printf 'FAIL: required command missing: curl\n' >&2
    exit 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'FAIL: required command missing: jq\n' >&2
    exit 2
  }
}

is_transient_code() {
  case "$1" in
    000|408|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

request_once() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local request_url="${BASE_URL}${path}"
  local response=""

  REQUEST_BODY=""
  REQUEST_CODE=""

  if [[ "$SELF_TEST" == "1" ]]; then
    case "${method} ${path}" in
      "GET /")
        REQUEST_CODE="${SELF_TEST_ROOT_CODE}"
        REQUEST_BODY="${SELF_TEST_ROOT_BODY}"
        ;;
      "GET ${NONCE_PATH}")
        REQUEST_CODE="${SELF_TEST_NONCE_CODE}"
        REQUEST_BODY="${SELF_TEST_NONCE_BODY}"
        ;;
      "GET ${PROTECTED_PATH}")
        REQUEST_CODE="${SELF_TEST_PROTECTED_CODE}"
        REQUEST_BODY="${SELF_TEST_PROTECTED_BODY}"
        ;;
      "GET ${FORBIDDEN_PATH}")
        REQUEST_CODE="${SELF_TEST_FORBIDDEN_CODE}"
        REQUEST_BODY="${SELF_TEST_FORBIDDEN_BODY}"
        ;;
      *)
        REQUEST_CODE="404"
        REQUEST_BODY="not-found"
        ;;
    esac
    return 0
  fi

  if [[ -n "$payload" ]]; then
    response="$(curl --max-time "${REQUEST_TIMEOUT}" --connect-timeout "${REQUEST_TIMEOUT}" \
      -sS -X "$method" -H 'Content-Type: application/json' -d "$payload" \
      "$request_url" -w $'\n%{http_code}' 2>/dev/null || true)"
  else
    response="$(curl --max-time "${REQUEST_TIMEOUT}" --connect-timeout "${REQUEST_TIMEOUT}" \
      -sS -X "$method" "$request_url" -w $'\n%{http_code}' 2>/dev/null || true)"
  fi

  if [[ -z "$response" ]]; then
    REQUEST_CODE="000"
    REQUEST_BODY=""
    return 0
  fi

  REQUEST_CODE="$(printf '%s' "$response" | tail -n 1)"
  REQUEST_BODY="$(printf '%s' "$response" | sed '$d')"
}

request_until_expected_code() {
  local method="$1"
  local path="$2"
  local expected="$3"
  local payload="${4:-}"
  local attempt=1

  while (( attempt <= REQUEST_RETRIES )); do
    request_once "$method" "$path" "$payload"
    if [[ "$REQUEST_CODE" == "$expected" ]]; then
      return 0
    fi
    if ! is_transient_code "$REQUEST_CODE"; then
      return 1
    fi
    sleep "$((RETRY_DELAY * attempt))"
    attempt=$((attempt + 1))
  done
  return 1
}

assert_nonempty() {
  local value="$1"
  local label="$2"
  if [[ -n "$value" ]]; then
    return 0
  fi
  printf 'FAIL: %s is empty\n' "$label" >&2
  return 1
}

assert_siwe_contract() {
  local body="$1"
  local expected_origin="$2"
  local expected_uri="$3"
  local expected_chain_id="$4"
  local parsed_message
  local siwe_first_line
  local actual_origin
  local actual_uri
  local actual_chain_id
  local expected_prefix=' wants you to sign in with your Ethereum account:'

  parsed_message="$(printf '%s' "$body" | jq -r '.data.message // empty' 2>/dev/null || true)"
  if [[ -z "$parsed_message" ]]; then
    printf 'FAIL: nonce body missing SIWE message envelope\n' >&2
    return 1
  fi

  siwe_first_line="$(printf '%s' "$parsed_message" | awk 'NR == 1 { print; exit }')"
  if [[ "$siwe_first_line" != *"${expected_prefix}" ]]; then
    printf 'FAIL: nonce body missing SIWE domain line: got %s\n' "$siwe_first_line" >&2
    return 1
  fi
  actual_origin="${siwe_first_line%"${expected_prefix}"}"
  actual_uri="$(printf '%s' "$parsed_message" | awk '/^URI: / {sub(/^URI: /, ""); print; exit}')"
  actual_chain_id="$(printf '%s' "$parsed_message" | awk '/^Chain ID: / {sub(/^Chain ID: /, ""); print; exit}')"

  actual_uri="${actual_uri%%\"*}"
  actual_chain_id="${actual_chain_id%%\"*}"
  if [[ -z "$actual_origin" ]]; then
    printf 'FAIL: nonce body missing SIWE domain\n' >&2
    return 1
  fi
  if [[ "$actual_origin" != "$expected_origin" ]]; then
    printf 'FAIL: nonce body SIWE origin mismatch: expected %s, got %s\n' \
      "$expected_origin" "$actual_origin" >&2
    return 1
  fi
  if [[ -z "$actual_uri" ]]; then
    printf 'FAIL: nonce body missing SIWE URI\n' >&2
    return 1
  fi
  if [[ "$actual_uri" != "$expected_uri" ]]; then
    printf 'FAIL: nonce body SIWE URI mismatch: expected %s, got %s\n' \
      "$expected_uri" "$actual_uri" >&2
    return 1
  fi
  if [[ -z "$actual_chain_id" || "$actual_chain_id" != "$expected_chain_id" ]]; then
    printf 'FAIL: nonce body SIWE chain id mismatch: expected %s, got %s\n' \
      "$expected_chain_id" "$actual_chain_id" >&2
    return 1
  fi
  return 0
}

run_probe_checks() {
  local expected_origin="$1"
  local expected_uri="$2"
  local expected_chain_id="$3"
  local failures=0

  if request_until_expected_code "GET" "/" "200"; then
    ROOT_CODE="$REQUEST_CODE"
  else
    printf 'FAIL: root GET / expected 200, got %s\n' "$REQUEST_CODE" >&2
    failures=$((failures + 1))
  fi

  if request_until_expected_code "GET" "$NONCE_PATH" "200"; then
    NONCE_CODE="$REQUEST_CODE"
    if ! assert_nonempty "$REQUEST_BODY" "nonce payload"; then
      failures=$((failures + 1))
    elif ! assert_siwe_contract "$REQUEST_BODY" "$expected_origin" "$expected_uri" "$expected_chain_id"; then
      failures=$((failures + 1))
    fi
  else
    printf 'FAIL: nonce path expected 200, got %s\n' "$REQUEST_CODE" >&2
    failures=$((failures + 1))
  fi

  if request_until_expected_code "GET" "$PROTECTED_PATH" "401"; then
    PROTECTED_CODE="$REQUEST_CODE"
  else
    printf 'FAIL: protected route %s expected 401, got %s\n' "$PROTECTED_PATH" "$REQUEST_CODE" >&2
    failures=$((failures + 1))
  fi

  if request_until_expected_code "GET" "$FORBIDDEN_PATH" "404"; then
    FORBIDDEN_CODE="$REQUEST_CODE"
  else
    printf 'FAIL: forbidden route %s expected 404, got %s\n' "$FORBIDDEN_PATH" "$REQUEST_CODE" >&2
    failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    printf 'FAIL: public availability checks failed (%d)\n' "$failures" >&2
    return 1
  fi
  printf 'PASS: public availability checks passed\n'
  return 0
}

write_atomic_json() {
  local target="$1"
  local stamp="$2"
  local status="$3"
  local consecutive="$4"
  local target_dir=""
  local target_file=""
  local tmp=""
  local tmp_device=""
  local target_device=""

  target_dir="$(dirname -- "$target")"
  target_file="$(basename -- "$target")"
  tmp="$(mktemp -p "$target_dir" ".${target_file}.tmp.XXXXXXXX")"
  tmp_device="$(stat -c '%d' "$tmp" 2>/dev/null || true)"
  target_device="$(stat -c '%d' "$target_dir" 2>/dev/null || true)"
  if [[ -z "$tmp_device" || -z "$target_device" ]]; then
    printf 'FAIL: unable to compare temporary and target filesystem device ids\n' >&2
    rm -f "$tmp"
    return 2
  fi
  if [[ "$tmp_device" != "$target_device" ]]; then
    printf 'FAIL: atomic temp file on wrong filesystem %s, expected %s\n' "$tmp_device" "$target_device" >&2
    rm -f "$tmp"
    return 2
  fi

  trap 'rm -f "${tmp-}"' RETURN

  if ! cat > "$tmp" <<EOF
{
  "timestamp_utc": "$stamp",
  "status": "$status",
  "consecutive_failures": $consecutive,
  "failure_threshold": $FAILURE_THRESHOLD,
  "base_url": "$BASE_URL",
  "checks": {
    "root": {"path": "/", "code": "${ROOT_CODE}"},
    "nonce": {"path": "${NONCE_PATH}", "code": "${NONCE_CODE}"},
    "protected": {"path": "${PROTECTED_PATH}", "code": "${PROTECTED_CODE}"},
    "forbidden": {"path": "${FORBIDDEN_PATH}", "code": "${FORBIDDEN_CODE}"}
  }
}
EOF
  then
    printf 'FAIL: failed to build atomic JSON for %s\n' "$target" >&2
    return 2
  fi
  if ! chmod 0600 "$tmp"; then
    printf 'FAIL: failed to set mode on temporary atomic file %s\n' "$tmp" >&2
    return 2
  fi
  if ! mv "$tmp" "$target"; then
    printf 'FAIL: failed to commit atomic write from %s to %s\n' "$tmp" "$target" >&2
    return 2
  fi
  trap - RETURN
  rm -f "$tmp"
}

load_failure_state() {
  local state_file="$1"
  local count=0
  if [[ -f "$state_file" ]]; then
    count="$(sed -n 's/.*\"consecutive_failures\"[[:space:]]*:[[:space:]]*\\([0-9]\\+\\).*/\\1/p' "$state_file" | head -n1 || true)"
  fi
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$count"
  else
    printf '0\n'
  fi
}

write_probe_state() {
  local stamp="$1"
  local status="$2"
  local consecutive="$3"
  local state_file="${STATE_DIR}/state.json"
  local receipt_file="${RECEIPT_DIR}/uptime-receipt-${stamp}.json"

  mkdir -p "$STATE_DIR" "$RECEIPT_DIR"
  write_atomic_json "$state_file" "$stamp" "$status" "$consecutive"
  write_atomic_json "$receipt_file" "$stamp" "$status" "$consecutive"
  if [[ -n "$PUBLISH_DIR" ]]; then
    write_published_status "$stamp" "$status" "$consecutive"
  fi
}

write_published_status() {
  local stamp="$1"
  local status="$2"
  local consecutive="$3"
  local target="${PUBLISH_DIR}/status.json"
  local tmp=""
  local tmp_device=""
  local target_device=""

  mkdir -p "$PUBLISH_DIR"
  tmp="$(mktemp "${PUBLISH_DIR}/.status.json.tmp.XXXXXX")"
  target_device="$(stat -c '%d' "$PUBLISH_DIR")"
  tmp_device="$(stat -c '%d' "$tmp")"
  if [[ "$tmp_device" != "$target_device" ]]; then
    rm -f "$tmp"
    printf 'FAIL: public status temp file is on the wrong filesystem\n' >&2
    return 2
  fi
  trap 'rm -f "${tmp-}"' RETURN
  jq -n \
    --arg status "$status" \
    --arg checked_at "$stamp" \
    --argjson consecutive_failures "$consecutive" \
    --arg chain_id "$NONCE_EXPECTED_CHAIN_ID" \
    '{status:$status, checked_at:$checked_at, consecutive_failures:$consecutive_failures, chain_id:$chain_id}' \
    >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$target"
  trap - RETURN
}

set_self_test_profile() {
  local mode="$1"
  local expected_origin="$2"
  local expected_uri="$3"
  local expected_chain_id="$4"
  local nonce_origin="$expected_origin"
  local nonce_uri="$expected_uri"
  local nonce_chain_id="$expected_chain_id"
  local base_msg=""
  local build_fixture=1

  SELF_TEST_ROOT_CODE=200
  SELF_TEST_ROOT_BODY="<html><body>ok</body></html>"
  SELF_TEST_NONCE_CODE=200
  SELF_TEST_NONCE_BODY="$base_msg"
  SELF_TEST_PROTECTED_CODE=401
  SELF_TEST_PROTECTED_BODY='{}'
  SELF_TEST_FORBIDDEN_CODE=404
  SELF_TEST_FORBIDDEN_BODY='not-found'

  case "$mode" in
    root-502)
      SELF_TEST_ROOT_CODE=502
      SELF_TEST_ROOT_BODY='gateway error'
      ;;
    nonce-502)
      SELF_TEST_NONCE_CODE=502
      SELF_TEST_NONCE_BODY='gateway error'
      build_fixture=0
      ;;
    nonce-empty)
      SELF_TEST_NONCE_BODY=''
      build_fixture=0
      ;;
    nonce-wrong-domain)
      nonce_origin="wrong.example.net"
      ;;
    nonce-domain-suffix)
      nonce_origin="${expected_origin}.example.net"
      ;;
    nonce-uri-suffix)
      nonce_uri="${expected_uri}/example.net"
      ;;
    nonce-chain-7770)
      nonce_chain_id="7770"
      ;;
    protected-200)
      SELF_TEST_PROTECTED_CODE=200
      ;;
    forbidden-200)
      SELF_TEST_FORBIDDEN_CODE=200
      ;;
  esac

  if (( build_fixture == 1 )); then
    base_msg="$(jq -cn \
      --arg top_message 'Wallet login challenge generated' \
      --arg message_address "${NONCE_DUMMY_ADDRESS}" \
      --arg siwe_origin "$nonce_origin" \
      --arg siwe_uri "$nonce_uri" \
      --arg siwe_chain_id "$nonce_chain_id" \
      '{
        message: $top_message,
        data: {
          message: (
            $siwe_origin + " wants you to sign in with your Ethereum account:\n\n" +
            "I agree to authenticate this request.\n\n" +
            "URI: " + $siwe_uri + "\n" +
            "Chain ID: " + $siwe_chain_id
          ),
          address: $message_address
        }
      }')"

    if [[ -z "$base_msg" ]]; then
      printf 'FAIL: unable to build self-test nonce fixture\n' >&2
      exit 2
    fi
    SELF_TEST_NONCE_BODY="$base_msg"
  fi
}

run_self_test() {
  local failures=0
  local expected
  local case_name
  local expected_origin="probe-testnet.local"
  local expected_uri="https://probe-testnet.local"
  local expected_chain_id="${WRFCOIN_CHAIN_ID:-777}"
  local rows=(
    "happy:1"
    "root-502:0"
    "nonce-502:0"
    "nonce-empty:0"
    "nonce-wrong-domain:0"
    "nonce-domain-suffix:0"
    "nonce-uri-suffix:0"
    "nonce-chain-7770:0"
    "protected-200:0"
    "forbidden-200:0"
  )

  for row in "${rows[@]}"; do
    case_name="${row%%:*}"
    expected="${row##*:}"
    set_self_test_profile "$case_name" "$expected_origin" "$expected_uri" "$expected_chain_id"
    if run_probe_checks "$expected_origin" "$expected_uri" "$expected_chain_id"; then
      if [[ "$expected" != "1" ]]; then
        failures=$((failures + 1))
      fi
    else
      if [[ "$expected" == "1" ]]; then
        failures=$((failures + 1))
      fi
    fi
  done

  if (( failures > 0 )); then
    printf 'FAIL: probe self-test controls failed\n' >&2
    return 1
  fi
  printf 'PASS: probe self-test controls passed\n'
  return 0
}

main() {
  parse_cli "$@"
  validate_configuration

  if [[ "$SELF_TEST" == "1" ]]; then
    if ! run_self_test; then
      return 1
    fi
    return 0
  fi

  local expected_origin expected_uri expected_chain_id previous_failures now consecutive status_code
  expected_origin="$NONCE_EXPECTED_ORIGIN"
  expected_uri="$NONCE_EXPECTED_URI"
  expected_chain_id="$NONCE_EXPECTED_CHAIN_ID"

  if run_probe_checks "$expected_origin" "$expected_uri" "$expected_chain_id"; then
    status_code="PASS"
    consecutive=0
  else
    status_code="FAIL"
    previous_failures="$(load_failure_state "${STATE_DIR}/state.json")"
    consecutive=$((previous_failures + 1))
  fi

  now="$(date -u +%Y%m%dT%H%M%SZ)"
  write_probe_state "$now" "$status_code" "$consecutive"

  if [[ "$status_code" == "PASS" ]]; then
    printf 'PASS: probe observed successful public availability check\n'
    return 0
  fi

  if (( consecutive >= FAILURE_THRESHOLD )); then
    printf 'FAIL: consecutive public availability failures=%d reached threshold=%d\n' \
      "$consecutive" "$FAILURE_THRESHOLD" >&2
    return 2
  fi

  printf 'WARN: public availability check failing, consecutive=%d (threshold=%d)\n' \
    "$consecutive" "$FAILURE_THRESHOLD" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
