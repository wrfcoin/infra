#!/usr/bin/env bash
# Focused proof checks for infra#117 public availability uptime.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/edge/probe_public_uptime.sh"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.testnet.yml"
RENDER_HELPER="${SCRIPT_DIR}/tests/render-testnet-compose.sh"
SERVICE_FILE="${SCRIPT_DIR}/systemd/wrfcoin-testnet-public-uptime-probe.service"
TIMER_FILE="${SCRIPT_DIR}/systemd/wrfcoin-testnet-public-uptime-probe.timer"
STATUS_SCHEMA="${SCRIPT_DIR}/edge/status.schema.json"

assert_file_contains() {
  local file="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    printf 'FAIL: expected %s to contain: %s\n' "$file" "$text" >&2
    return 1
  fi
}

backend_restart_policy() {
  local file="$1"
  awk '
    $0 ~ /^  wrfcoin-backend:/ { in_backend = 1; next }
    in_backend && /^  [^ ]/ { in_backend = 0 }
    in_backend && /^    restart:/ {
      sub(/^    restart:[[:space:]]*/, "", $0)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      print $0
      exit
    }
  ' "$file"
}

assert_backend_restart_policy() {
  local file="$1"
  local expected="$2"
  local policy

  policy="$(backend_restart_policy "$file")"
  if [[ "$policy" != "$expected" ]]; then
    printf 'FAIL: %s restart policy is %s, expected %s\n' "$file" "${policy:-<missing>}" "$expected" >&2
    return 1
  fi
}

assert_not_equal_to() {
  local file="$1"
  local expected="$2"
  local value
  value="$(backend_restart_policy "$file")"
  if [[ "$value" == "$expected" ]]; then
    printf 'FAIL: %s unexpectedly kept malformed backend restart policy %s\n' "$file" "$expected" >&2
    return 1
  fi
}

assert_file_mode() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(stat -c '%a' "$file" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    printf 'FAIL: %s mode is %s, expected %s\n' "$file" "$actual" "$expected" >&2
    return 1
  fi
}

run_source_and_atomicity_controls() {
  local workdir=""
  local original_path=""
  local status=0
  local fake_bin=""
  local pre_hash=""
  local post_hash=""
  local fake_output=""
  local target_file=""
  local target_dir=""
  local leaked_temp=""

  if ! bash -c "source \"${PROBE_SCRIPT}\"; :"; then
    printf 'FAIL: probe script failed when sourced (entrypoint guard may be missing)\n' >&2
    return 1
  fi

  # Shellcheck requires explicit sourcing guard in the script under test.
  # shellcheck disable=SC1090
  source "$PROBE_SCRIPT"

  workdir="$(mktemp -d)"
  target_file="${workdir}/state.json"
  printf '%s' '{ "existing": true }' > "$target_file"

  # shellcheck disable=SC2034
  BASE_URL="https://probe-testnet.local"
  export BASE_URL ROOT_CODE NONCE_CODE PROTECTED_CODE FORBIDDEN_CODE FAILURE_THRESHOLD
  BASE_URL="https://probe-testnet.local"
  ROOT_CODE="200"
  NONCE_CODE="200"
  PROTECTED_CODE="401"
  FORBIDDEN_CODE="404"
  FAILURE_THRESHOLD=18

  if ! write_atomic_json "$target_file" "20260817T000000Z" "PASS" "1"; then
    printf 'FAIL: write_atomic_json failed for same-device happy path\n' >&2
    status=1
  else
    if ! jq -e '.timestamp_utc == "20260817T000000Z" and .status == "PASS" and .consecutive_failures == 1' "$target_file" >/dev/null; then
      printf 'FAIL: write_atomic_json happy-path receipt is not valid JSON\n' >&2
      status=1
    fi
    if ! assert_file_mode "$target_file" "600"; then
      status=1
    fi
  fi

  printf '%s\n' '{"guarded":"yes"}' > "$target_file"
  pre_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
  original_path="$PATH"
  fake_bin="$(mktemp -d)"
  cat >"${fake_bin}/mv" <<'EOF'
#!/usr/bin/env bash
echo "simulated mv interruption" >&2
exit 11
EOF
  chmod +x "${fake_bin}/mv"
  PATH="${fake_bin}:$PATH"
  if write_atomic_json "${target_file}" "20260817T000001Z" "FAIL" "2" > /tmp/wrfcoin-uptime-mv-stdout 2> /tmp/wrfcoin-uptime-mv-stderr; then
    printf 'FAIL: write_atomic_json succeeded despite simulated mv failure\n' >&2
    status=1
  else
    post_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
    if [[ "$post_hash" != "$pre_hash" ]]; then
      printf 'FAIL: write_atomic_json corrupted target after simulated mv interruption\n' >&2
      status=1
    fi
  fi
  rm -f /tmp/wrfcoin-uptime-mv-stdout /tmp/wrfcoin-uptime-mv-stderr
  PATH="$original_path"
  rm -rf "$fake_bin"

  target_dir="${workdir}/target"
  mkdir -p "$target_dir"
  target_file="${target_dir}/state.json"
  printf '%s\n' '{"keep":"me"}' > "$target_file"
  pre_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
  fake_bin="$(mktemp -d)"
  cat >"${fake_bin}/mktemp" <<'EOF'
#!/usr/bin/env bash
tmp="/tmp/wrfcoin-uptime-crossfs-${RANDOM}-${RANDOM}"
touch "$tmp"
printf '%s\n' "$tmp"
EOF
  chmod +x "${fake_bin}/mktemp"
  cat >"${fake_bin}/stat" <<'EOF'
#!/usr/bin/env bash
path="${@: -1}"
if [[ "$path" == "$FAKE_TARGET_DIR" ]]; then
  echo "200"
  exit 0
fi
if [[ "$path" == /tmp/wrfcoin-uptime-crossfs-* ]]; then
  echo "201"
  exit 0
fi
/usr/bin/stat "$@"
EOF
  chmod +x "${fake_bin}/stat"
  FAKE_TARGET_DIR="$target_dir"
  PATH="${fake_bin}:$PATH"
  FAKE_TARGET_DIR="$target_dir"
  export FAKE_TARGET_DIR
  if fake_output="$(write_atomic_json "${target_file}" "20260817T000002Z" "FAIL" "3" 2>&1)"; then
    printf 'FAIL: write_atomic_json succeeded despite cross-filesystem temp-device mismatch\n' >&2
    status=1
  elif ! grep -Fq "wrong filesystem" <<<"$fake_output"; then
    printf 'FAIL: cross-filesystem mismatch did not emit expected failure mode\n' >&2
    status=1
  fi
  unset FAKE_TARGET_DIR
  PATH="$original_path"
  rm -rf "$fake_bin"

  original_path="$PATH"
  fake_bin="$(mktemp -d)"
  cat >"${fake_bin}/cat" <<'EOF'
#!/usr/bin/env bash
echo "simulated cat failure" >&2
exit 13
EOF
  chmod +x "${fake_bin}/cat"
  PATH="${fake_bin}:$PATH"
  printf '%s\n' '{"guarded":"no"}' > "$target_file"
  pre_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
  if write_atomic_json "${target_file}" "20260817T000003Z" "FAIL" "4" > /tmp/wrfcoin-uptime-cat-stdout 2> /tmp/wrfcoin-uptime-cat-stderr; then
    printf 'FAIL: write_atomic_json succeeded despite simulated cat failure\n' >&2
    status=1
  else
    post_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
    if [[ "$post_hash" != "$pre_hash" ]]; then
      printf 'FAIL: write_atomic_json altered target after simulated cat failure\n' >&2
      status=1
    fi
  fi
  rm -f /tmp/wrfcoin-uptime-cat-stdout /tmp/wrfcoin-uptime-cat-stderr
  PATH="$original_path"
  rm -rf "$fake_bin"

  target_file="${workdir}/state.json"
  printf '%s\n' '{"guarded":"maybe"}' > "$target_file"
  pre_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
  original_path="$PATH"
  fake_bin="$(mktemp -d)"
  cat >"${fake_bin}/chmod" <<'EOF'
#!/usr/bin/env bash
echo "simulated chmod failure" >&2
exit 13
EOF
  chmod +x "${fake_bin}/chmod"
  PATH="${fake_bin}:$PATH"
  if write_atomic_json "${target_file}" "20260817T000004Z" "FAIL" "5" > /tmp/wrfcoin-uptime-chmod-stdout 2> /tmp/wrfcoin-uptime-chmod-stderr; then
    printf 'FAIL: write_atomic_json succeeded despite simulated chmod failure\n' >&2
    status=1
  else
    post_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"
    if [[ "$post_hash" != "$pre_hash" ]]; then
      printf 'FAIL: write_atomic_json altered target after simulated chmod failure\n' >&2
      status=1
    fi
  fi
  rm -f /tmp/wrfcoin-uptime-chmod-stdout /tmp/wrfcoin-uptime-chmod-stderr
  PATH="$original_path"
  rm -rf "$fake_bin"

  leaked_temp="$(find "$workdir" -type f -name '.*.tmp.*' -print -quit)"
  if [[ -n "$leaked_temp" ]]; then
    printf 'FAIL: write_atomic_json left a temp file after simulated failure: %s\n' "$leaked_temp" >&2
    status=1
  fi

  rm -rf "$workdir"
  if (( status != 0 )); then
    return 1
  fi
}

run_service_deadline_controls() {
  local mutated_service=""
  local deadline=""

  deadline="$(sed -n 's/^TimeoutStartSec=//p' "$SERVICE_FILE")"
  if [[ "$deadline" != "120" ]]; then
    printf 'FAIL: service deadline is %s, expected exact 120\n' "${deadline:-<missing>}" >&2
    return 1
  fi

  mutated_service="$(mktemp)"
  sed 's/^TimeoutStartSec=.*/TimeoutStartSec=infinity/' "$SERVICE_FILE" > "$mutated_service"
  deadline="$(sed -n 's/^TimeoutStartSec=//p' "$mutated_service")"
  rm -f "$mutated_service"
  if [[ "$deadline" == "120" ]]; then
    printf 'FAIL: infinity mutation was not load-bearing\n' >&2
    return 1
  fi
  if [[ "$deadline" != "infinity" ]]; then
    printf 'FAIL: timeout mutation produced unexpected value %s\n' "$deadline" >&2
    return 1
  fi
}

run_published_status_controls() {
  local workdir
  local rendered
  workdir="$(mktemp -d)"
  # shellcheck disable=SC1090
  source "$PROBE_SCRIPT"
  PUBLISH_DIR="${workdir}/public"
  NONCE_EXPECTED_CHAIN_ID="777"
  export PUBLISH_DIR NONCE_EXPECTED_CHAIN_ID

  write_published_status "20260920T220000Z" "PASS" "0"
  rendered="${PUBLISH_DIR}/status.json"
  if ! jq -e '
    keys == ["chain_id", "checked_at", "consecutive_failures", "status"] and
    .status == "PASS" and .checked_at == "20260920T220000Z" and
    .consecutive_failures == 0 and .chain_id == "777"
  ' "$rendered" >/dev/null; then
    printf 'FAIL: published status shape is not the redacted contract\n' >&2
    rm -rf "$workdir"
    return 1
  fi
  if ! python3 - "$STATUS_SCHEMA" "$rendered" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
with open(sys.argv[2], encoding="utf-8") as status_file:
    status = json.load(status_file)
assert set(status) == set(schema["required"])
for key, rule in schema["properties"].items():
    value = status[key]
    if rule["type"] == "string":
        assert isinstance(value, str)
    elif rule["type"] == "integer":
        assert isinstance(value, int) and not isinstance(value, bool)
    if "enum" in rule:
        assert value in rule["enum"]
    if "minimum" in rule:
        assert value >= rule["minimum"]
    if "pattern" in rule:
        assert re.fullmatch(rule["pattern"], value)
PY
  then
    printf 'FAIL: published status does not validate against status.schema.json\n' >&2
    rm -rf "$workdir"
    return 1
  fi
  if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}|https?://|receipt|hostname|base_url|checks' "$rendered"; then
    printf 'FAIL: published status leaked an IP, host, URL, checks, or receipt path\n' >&2
    rm -rf "$workdir"
    return 1
  fi
  if [[ "$(stat -c '%a' "$rendered")" != "644" ]]; then
    printf 'FAIL: published status is not world-readable through the read-only edge mount\n' >&2
    rm -rf "$workdir"
    return 1
  fi
  rm -rf "$workdir"
}

run_runtime_ceiling_controls() {
  local run_dir=""
  run_dir="$(mktemp -d)"
  mkdir -p "$run_dir/state" "$run_dir/receipts"

  if WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN='probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_URI='https://probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID=777 bash "$PROBE_SCRIPT" \
    --base-url https://probe-testnet.local \
    --state-dir "$run_dir/state" \
    --receipt-dir "$run_dir/receipts" \
    --timeout 7 \
    --request-retries 3 \
    --retry-delay 1 \
    --failure-threshold 18 \
    --allow-http > /tmp/wrfcoin-uptime-timeout-over.out 2>&1; then
    printf 'FAIL: over-ceiling timeout config unexpectedly passed full probe execution\n' >&2
    cat /tmp/wrfcoin-uptime-timeout-over.out
    rm -rf "$run_dir"
    return 1
  fi
  if ! grep -Fq "must be <= 6, got 7" /tmp/wrfcoin-uptime-timeout-over.out; then
    printf 'FAIL: timeout over-ceiling did not emit expected hard-limit diagnostic\n' >&2
    cat /tmp/wrfcoin-uptime-timeout-over.out
    rm -rf "$run_dir"
    return 1
  fi
  rm -f /tmp/wrfcoin-uptime-timeout-over.out

  if WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN='probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_URI='https://probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID=777 bash "$PROBE_SCRIPT" \
    --base-url https://probe-testnet.local \
    --state-dir "$run_dir/state" \
    --receipt-dir "$run_dir/receipts" \
    --timeout 6 \
    --request-retries 4 \
    --retry-delay 1 \
    --failure-threshold 18 \
    > /tmp/wrfcoin-uptime-retries-over.out 2>&1; then
    printf 'FAIL: over-ceiling retries config unexpectedly passed full probe execution\n' >&2
    cat /tmp/wrfcoin-uptime-retries-over.out
    rm -rf "$run_dir"
    return 1
  fi
  if ! grep -Fq "must be <= 3, got 4" /tmp/wrfcoin-uptime-retries-over.out; then
    printf 'FAIL: retries over-ceiling did not emit expected hard-limit diagnostic\n' >&2
    cat /tmp/wrfcoin-uptime-retries-over.out
    rm -rf "$run_dir"
    return 1
  fi
  rm -f /tmp/wrfcoin-uptime-retries-over.out

  if WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN='probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_URI='https://probe-testnet.local' WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID=777 bash "$PROBE_SCRIPT" \
    --base-url https://probe-testnet.local \
    --state-dir "$run_dir/state" \
    --receipt-dir "$run_dir/receipts" \
    --timeout 6 \
    --request-retries 3 \
    --retry-delay 2 \
    --failure-threshold 18 \
    > /tmp/wrfcoin-uptime-delay-over.out 2>&1; then
    printf 'FAIL: over-ceiling delay config unexpectedly passed full probe execution\n' >&2
    cat /tmp/wrfcoin-uptime-delay-over.out
    rm -rf "$run_dir"
    return 1
  fi
  if ! grep -Fq "must be <= 1, got 2" /tmp/wrfcoin-uptime-delay-over.out; then
    printf 'FAIL: delay over-ceiling did not emit expected hard-limit diagnostic\n' >&2
    cat /tmp/wrfcoin-uptime-delay-over.out
    rm -rf "$run_dir"
    return 1
  fi
  rm -f /tmp/wrfcoin-uptime-delay-over.out

  rm -rf "$run_dir"
}

run_receipt_contract_controls() {
  local workdir=""
  local receipt_dir=""
  local receipt_file=""
  local bad_receipt_file=""
  local live_script=""

  workdir="$(mktemp -d)"
  receipt_dir="${workdir}/receipts"
  mkdir -p "$receipt_dir"
  BASE_URL="https://probe-testnet.local"
  STATE_DIR="${workdir}/state"
  RECEIPT_DIR="$receipt_dir"
  FAILURE_THRESHOLD=18
  export STATE_DIR RECEIPT_DIR

  # shellcheck disable=SC1090
  source "$PROBE_SCRIPT"

  ROOT_CODE="200"
  NONCE_CODE="200"
  PROTECTED_CODE="401"
  FORBIDDEN_CODE="404"

  write_probe_state "20260817T000000Z" "PASS" "1"
  receipt_file="${receipt_dir}/uptime-receipt-20260817T000000Z.json"
  if ! jq -e '.checks.root.code == "200" and .checks.nonce.code == "200" and .checks.protected.code == "401" and .checks.forbidden.code == "404" and
    (.checks.root.code|type=="string") and (.checks.nonce.code|type=="string") and (.checks.protected.code|type=="string") and (.checks.forbidden.code|type=="string")' "$receipt_file" >/dev/null; then
    printf 'FAIL: production write_atomic_json/write_probe_state did not emit exact JSON-string contract\n' >&2
    rm -rf "$workdir"
    return 1
  fi

  live_script="$(mktemp)"
  # shellcheck disable=SC2016
  sed 's/"code": "${ROOT_CODE}"/"code": "999"/' "$PROBE_SCRIPT" > "$live_script"
  # shellcheck disable=SC1090
  source "$live_script"

  ROOT_CODE="200"
  NONCE_CODE="200"
  PROTECTED_CODE="401"
  FORBIDDEN_CODE="404"
  write_probe_state "20260817T000001Z" "PASS" "2"
  bad_receipt_file="${receipt_dir}/uptime-receipt-20260817T000001Z.json"
  if jq -e '.checks.root.code == "200" and .checks.nonce.code == "200" and .checks.protected.code == "401" and .checks.forbidden.code == "404" and
    (.checks.root.code|type=="string") and (.checks.nonce.code|type=="string") and (.checks.protected.code|type=="string") and (.checks.forbidden.code|type=="string")' "$bad_receipt_file" >/dev/null 2>&1; then
    printf 'FAIL: production write_atomic_json/write_probe_state failed to reject mutated root code\n' >&2
    rm -rf "$workdir"
    return 1
  fi

  rm -f "$live_script"
  rm -rf "$workdir"
}

if ! bash "$PROBE_SCRIPT" --self-test >/tmp/probe_public_uptime_self_test.out; then
  printf 'FAIL: probe self-test/mutation controls failed\n' >&2
  cat /tmp/probe_public_uptime_self_test.out >&2 || true
  exit 1
fi
rm -f /tmp/probe_public_uptime_self_test.out

assert_backend_restart_policy "$COMPOSE_FILE" "unless-stopped"

MUTATED_COMPOSE="$(mktemp)"
RENDERED_COMPOSE="$(mktemp)"
trap 'rm -f "$MUTATED_COMPOSE" "$RENDERED_COMPOSE"' EXIT
awk '
  $0 ~ /^  wrfcoin-backend:/ { in_backend = 1; print; next }
  in_backend && /^  [^ ]/ { in_backend = 0 }
  in_backend && /^    restart:/ { sub(/^    restart:[[:space:]]*.*/, "    restart: on-failure:5", $0); print; next }
  { print }
' "$COMPOSE_FILE" > "$MUTATED_COMPOSE"

assert_not_equal_to "$MUTATED_COMPOSE" "unless-stopped"

if ! (
  export POSTGRES_PASSWORD=ci
  export REDIS_PASSWORD=ci
  export JWT_SECRET=ci
  export OAUTH_STATE_SECRET=ci
  export RPC_API_KEY=ci
  export ADMIN_TOKEN=ci
  export N8N_WEBHOOK_SECRET=ci
  export WRFCOIN_OPERATOR_TOKEN=ci
  export WRFCOIN_CONTRIBUTOR_TOKEN=contributor-ci
  export GRAFANA_ADMIN_PASSWORD=ci
  cd "$SCRIPT_DIR"
  export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
  export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000
  bash "$RENDER_HELPER" -f docker-compose.testnet.yml config
) > "$RENDERED_COMPOSE"; then
  printf 'FAIL: render of docker-compose.testnet.yml did not produce valid config\n' >&2
  exit 1
fi

assert_backend_restart_policy "$RENDERED_COMPOSE" "unless-stopped"
assert_file_contains "$SERVICE_FILE" "WRFCOIN_TESTNET_PUBLIC_HOST is required in /etc/wrfcoin-testnet-uptime.conf"
assert_file_contains "$SERVICE_FILE" "WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN is required in /etc/wrfcoin-testnet-uptime.conf"
assert_file_contains "$SERVICE_FILE" "Environment=WRFCOIN_TESTNET_NONCE_EXPECTED_ORIGIN="
assert_file_contains "$SERVICE_FILE" "Environment=WRFCOIN_TESTNET_NONCE_EXPECTED_URI="
assert_file_contains "$SERVICE_FILE" "Environment=WRFCOIN_TESTNET_NONCE_EXPECTED_CHAIN_ID="
assert_file_contains "$SERVICE_FILE" "Environment=PUBLISH_DIR=/var/lib/wrfcoin-testnet-uptime/public"
assert_file_contains "$SERVICE_FILE" "TimeoutStartSec="
assert_file_contains "$SERVICE_FILE" "TimeoutStartSec=120"
assert_file_contains "$SERVICE_FILE" "for name in REQUEST_TIMEOUT REQUEST_RETRIES RETRY_DELAY FAILURE_THRESHOLD"
# systemd $$ must remain literal for Bash expansion.
# shellcheck disable=SC2016
assert_file_contains "$SERVICE_FILE" 'value="$${!name}"'
# systemd $$ must remain literal for Bash expansion.
# shellcheck disable=SC2016
assert_file_contains "$SERVICE_FILE" 'echo "FAIL: $${name} must be a positive integer: $${value}"'
assert_file_contains "$SERVICE_FILE" "Environment=REQUEST_RETRIES=3"
assert_file_contains "$SERVICE_FILE" "Environment=RETRY_DELAY=1"
assert_file_contains "$SERVICE_FILE" "if ! command -v jq >/dev/null 2>&1; then"
assert_file_contains "$SERVICE_FILE" "WRFCOIN_TESTNET_UPTIME_SCRIPT"
assert_file_contains "$SERVICE_FILE" "ExecStart=/usr/bin/bash -eu -c"
assert_file_contains "$TIMER_FILE" "OnUnitInactiveSec=10m"
assert_file_contains "$TIMER_FILE" "Persistent=true"
assert_file_contains "$PROBE_SCRIPT" "REQUEST_TIMEOUT_MAX="
assert_file_contains "$PROBE_SCRIPT" "REQUEST_RETRIES_MAX="
assert_file_contains "$PROBE_SCRIPT" "RETRY_DELAY_MAX="
assert_file_contains "$PROBE_SCRIPT" "PROBE_RUNTIME_MAX_SECONDS=\"\${PROBE_RUNTIME_MAX_SECONDS:-110}\""
assert_file_contains "$PROBE_SCRIPT" "four_route_runtime_budget"
assert_file_contains "$PROBE_SCRIPT" "max_four_route_runtime_budget"
assert_file_contains "$PROBE_SCRIPT" "if (( four_route_runtime_budget >= PROBE_RUNTIME_MAX_SECONDS )); then"
assert_file_contains "$PROBE_SCRIPT" "require_bounded_positive_integer REQUEST_TIMEOUT"
assert_file_contains "$PROBE_SCRIPT" "mktemp -p \"\$target_dir\""
assert_file_contains "$PROBE_SCRIPT" "nonce-domain-suffix"
assert_file_contains "$PROBE_SCRIPT" "nonce-uri-suffix"
assert_file_contains "$PROBE_SCRIPT" "nonce-chain-7770"
assert_file_contains "$PROBE_SCRIPT" "jq -r '.data.message // empty'"
assert_file_contains "$PROBE_SCRIPT" "expected_uri=\"https://probe-testnet.local\""
assert_file_contains "$PROBE_SCRIPT" "expected_prefix=' wants you to sign in with your Ethereum account:'"
assert_file_contains "$PROBE_SCRIPT" "siwe_first_line=\"\$(printf '%s' \"\$parsed_message\" | awk 'NR == 1 { print; exit }')\""
assert_file_contains "$PROBE_SCRIPT" "if (( max_four_route_runtime_budget >= PROBE_RUNTIME_MAX_SECONDS )); then"

if ! run_source_and_atomicity_controls; then
  exit 1
fi

if ! run_service_deadline_controls; then
  exit 1
fi

if ! run_runtime_ceiling_controls; then
  exit 1
fi

if ! run_receipt_contract_controls; then
  exit 1
fi

if ! run_published_status_controls; then
  exit 1
fi

echo "PASS: infra#117 public uptime checks passed"
