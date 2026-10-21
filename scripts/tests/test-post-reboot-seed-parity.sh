#!/usr/bin/env bash
# Hermetic production-entrypoint tests for post-reboot node/seed parity.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_VERIFY="${REPO_ROOT}/testnet/scripts/post-reboot-verify.sh"
SOURCE_COMPOSE_INPUTS="${REPO_ROOT}/testnet/lib/compose-inputs.sh"
TMP_DIR="$(mktemp -d)"
FIXTURE_DIR="${TMP_DIR}/testnet"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '  ok    %s\n' "$*"
}

mkdir -p "${FIXTURE_DIR}/scripts" "${FIXTURE_DIR}/lib" "${TMP_DIR}/bin"
cp "${SOURCE_VERIFY}" "${FIXTURE_DIR}/scripts/post-reboot-verify.sh"
cp "${SOURCE_COMPOSE_INPUTS}" "${FIXTURE_DIR}/lib/compose-inputs.sh"

for compose_file in docker-compose.testnet.yml docker-compose.override.yml \
                    docker-compose.local-paths.yml docker-compose.cut.yml \
                    docker-compose.cut-miner.yml docker-compose.cut-genesis-seed.yml \
                    docker-compose.yubikey.n5.yml docker-compose.oracle-attester.yml \
                    docker-compose.oracle-attester-yubikey.n5.yml; do
  printf '%s\n' 'services: {}' > "${FIXTURE_DIR}/${compose_file}"
done
EXTRA_COMPOSE="${TMP_DIR}/deployment.yml"
printf '%s\n' 'services: {}' > "${EXTRA_COMPOSE}"
printf '%s\n' \
  'WRFCOIN_READER_TOKEN=reader-token' \
  'PROMETHEUS_ADMIN_PASSWORD=prom-password' \
  'COMPOSE_PROFILES=seed,oracle-reference' > "${FIXTURE_DIR}/.env"
printf '%s' 'reader-token' > "${FIXTURE_DIR}/prometheus-bearer-token"

cat > "${TMP_DIR}/bin/systemctl" <<'SH'
#!/usr/bin/env bash
[[ "$*" == 'is-active --quiet wrfcoin-testnet.service' ]]
SH
chmod +x "${TMP_DIR}/bin/systemctl"

cat > "${TMP_DIR}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == compose ]]; then
  printf '%q ' "$@" >> "${COMPOSE_LOG}"
  printf '\n' >> "${COMPOSE_LOG}"
  exit 0
fi
if [[ "${1:-}" == ps ]]; then
  if [[ "$*" == *'.Ports'* ]]; then
    printf '%s\n' \
      $'wrfcoin-testnet-node\t127.0.0.1:8556->8556/tcp, 0.0.0.0:9000->9000/tcp' \
      $'wrfcoin-testnet-seed\t127.0.0.1:8557->8556/tcp' \
      $'wrfcoin-testnet-prometheus\t127.0.0.1:9090->9090/tcp' \
      $'wrfcoin-testnet-alertmanager\t127.0.0.1:9093->9093/tcp' \
      $'wrfcoin-testnet-grafana\t127.0.0.1:3100->3000/tcp'
  else
    printf '%s\n' wrfcoin-testnet-node wrfcoin-testnet-seed
  fi
  # infra#918: DOCKER_PS_PAD=N appends N unrelated containers AFTER the real
  # ones. Past the 64 KiB pipe buffer, a `... | grep -q` reader exits on its
  # first match while the writer is still writing, which makes the SIGPIPE
  # path deterministic instead of load-dependent.
  if [[ -n "${DOCKER_PS_PAD:-}" ]]; then
    for ((i = 0; i < DOCKER_PS_PAD; i++)); do
      printf 'unrelated-container-%06d\t10.0.0.1:%d->80/tcp, padding-padding-padding-padding\n' "$i" "$((10000 + i % 50000))"
    done
  fi
  exit 0
fi
exit 2
SH
chmod +x "${TMP_DIR}/bin/docker"

cat > "${TMP_DIR}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# infra#1073: record argv so the suite can prove no credential reaches it, and
# accept credential headers only from stdin (-H @-).
printf '%s\n' "$*" >> "${CURL_LOG}.argv"
auth=''
url=''
while (( $# > 0 )); do
  case "$1" in
    -H)
      if [[ "$2" == '@-' ]]; then
        IFS= read -r auth || true
      fi
      shift 2
      ;;
    --connect-timeout|--max-time)
      shift 2
      ;;
    -fsS)
      shift
      ;;
    http://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\t%s\n' "${url}" "${auth}" >> "${CURL_LOG}"

case "${url}" in
  */network/info|*/chain/block/*|*/state/snapshot)
    if [[ "${AUTH_FAIL:-false}" == true || "${auth}" != 'Authorization: Bearer reader-token' ]]; then
      exit 22
    fi
    ;;
  http://127.0.0.1:9090/api/v1/*)
    # base64 of admin:prom-password
    if [[ "${auth}" != 'Authorization: Basic YWRtaW46cHJvbS1wYXNzd29yZA==' ]]; then
      exit 22
    fi
    ;;
esac

case "${url}" in
  http://127.0.0.1:8556/readyz|http://127.0.0.1:8557/readyz)
    printf '%s\n' '{"status":"ready"}'
    ;;
  http://127.0.0.1:8556/network/info)
    printf '%s\n' "${NODE_NETWORK_JSON}"
    ;;
  http://127.0.0.1:8557/network/info)
    count=0
    if [[ -n "${SEED_CALL_COUNT_FILE:-}" ]]; then
      [[ ! -f "${SEED_CALL_COUNT_FILE}" ]] || read -r count < "${SEED_CALL_COUNT_FILE}"
      count=$((count + 1))
      printf '%s\n' "${count}" > "${SEED_CALL_COUNT_FILE}"
    fi
    if [[ -n "${SEED_TRANSIENT_NETWORK_JSON:-}" && \
          "${count}" -le "${SEED_TRANSIENT_CALLS:-0}" ]]; then
      printf '%s\n' "${SEED_TRANSIENT_NETWORK_JSON}"
    else
      printf '%s\n' "${SEED_NETWORK_JSON}"
    fi
    ;;
  http://127.0.0.1:8556/chain/block/*)
    height="${url##*/}"
    printf '{"data":{"height":%s,"hash":"%s"}}\n' "${height}" "${NODE_BLOCK_HASH}"
    ;;
  http://127.0.0.1:8557/chain/block/*)
    height="${url##*/}"
    printf '{"data":{"height":%s,"hash":"%s"}}\n' "${height}" "${SEED_BLOCK_HASH}"
    ;;
  http://127.0.0.1:8556/state/snapshot)
    printf '{"height":%s,"state_root_hex":"%s","snapshot_root_hex":"%s","entry_count":12}\n' \
      "${NODE_HEIGHT}" "${NODE_STATE_ROOT}" "${NODE_SNAPSHOT_ROOT}"
    ;;
  http://127.0.0.1:8557/state/snapshot)
    printf '{"height":%s,"state_root_hex":"%s","snapshot_root_hex":"%s","entry_count":12}\n' \
      "${SEED_HEIGHT}" "${SEED_STATE_ROOT}" "${SEED_SNAPSHOT_ROOT}"
    ;;
  http://127.0.0.1:9090/api/v1/targets)
    printf '%s\n' '{"data":{"activeTargets":[]}}'
    ;;
  http://127.0.0.1:9090/api/v1/alerts)
    printf '%s\n' '{"data":{"alerts":[]}}'
    ;;
  http://127.0.0.1:9093/api/v2/alerts)
    printf '%s\n' '[]'
    ;;
  *)
    exit 3
    ;;
esac
SH
chmod +x "${TMP_DIR}/bin/curl"

CHAIN_ID='777'
NETWORK_ID='wrfcoin-testnet-v1'
GENESIS_HASH="$(printf 'a%.0s' {1..64})"
COMMON_HASH="$(printf 'b%.0s' {1..64})"
OTHER_HASH="$(printf 'c%.0s' {1..64})"
STATE_ROOT="$(printf 'd%.0s' {1..64})"
SNAPSHOT_ROOT="$(printf 'e%.0s' {1..64})"

network_json() {
  local height="$1" peers="$2" chain_id="${3:-${CHAIN_ID}}" genesis="${4:-${GENESIS_HASH}}"
  local sync_status="${5:-synced}"
  printf '{"chain_id":"%s","network_id":"%s","genesis_hash":"%s","peer_count":%s,"sync_status":"%s","chain_height":%s}' \
    "${chain_id}" "${NETWORK_ID}" "${genesis}" "${peers}" "${sync_status}" "${height}"
}

run_case() {
  local name="$1" expected_rc="$2" expected_text="$3"
  local node_network="$4" seed_network="$5"
  shift 5
  local output="${TMP_DIR}/${name}.out"
  : > "${TMP_DIR}/${name}.curl.log"
  : > "${TMP_DIR}/${name}.compose.log"

  set +e
  # Forwarded env assignments are test inputs to the local boot-verify double.
  # dynamic-payload-reviewed: seed-parity-case-env-forwarder
  env PATH="${TMP_DIR}/bin:${PATH}" \
    CURL_LOG="${TMP_DIR}/${name}.curl.log" \
    COMPOSE_LOG="${TMP_DIR}/${name}.compose.log" \
    SEED_CALL_COUNT_FILE="${TMP_DIR}/${name}.seed-calls" \
    NODE_NETWORK_JSON="${node_network}" \
    SEED_NETWORK_JSON="${seed_network}" \
    NODE_HEIGHT="${NODE_HEIGHT:-100}" \
    SEED_HEIGHT="${SEED_HEIGHT:-100}" \
    NODE_BLOCK_HASH="${NODE_BLOCK_HASH:-${COMMON_HASH}}" \
    SEED_BLOCK_HASH="${SEED_BLOCK_HASH:-${COMMON_HASH}}" \
    NODE_STATE_ROOT="${NODE_STATE_ROOT:-${STATE_ROOT}}" \
    SEED_STATE_ROOT="${SEED_STATE_ROOT:-${STATE_ROOT}}" \
    NODE_SNAPSHOT_ROOT="${NODE_SNAPSHOT_ROOT:-${SNAPSHOT_ROOT}}" \
    SEED_SNAPSHOT_ROOT="${SEED_SNAPSHOT_ROOT:-${SNAPSHOT_ROOT}}" \
    WRFCOIN_HSM_MODE=yubikey \
    WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}" \
    POST_REBOOT_VERIFY_TIMEOUT_SECS=0 \
    POST_REBOOT_VERIFY_INTERVAL_SECS=0 \
    POST_REBOOT_VERIFY_ONCE=true \
    POST_REBOOT_REORG_DEPTH=2 \
    POST_REBOOT_MAX_RECOVERY_LAG=5 \
    "$@" bash "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" > "${output}" 2>&1
  rc=$?
  set -e

  [[ "${rc}" -eq "${expected_rc}" ]] || {
    cat "${output}" >&2
    fail "${name}: expected rc ${expected_rc}, got ${rc}"
  }
  grep -q "${expected_text}" "${output}" || {
    cat "${output}" >&2
    fail "${name}: missing expected result ${expected_text}"
  }
  ok "${name}"
}

BASE_NODE="$(network_json 100 2)"
BASE_SEED="$(network_json 100 1)"
# infra#918, deterministic: `docker ps` output far past the pipe buffer, with
# every match in its first lines. A `printf | grep -q` check under pipefail
# gets EPIPE here on every run ("printf: write error: Broken pipe" -> a
# spurious NO-GO, rc 1). Checks must read the captured value without a pipe.
DOCKER_PS_PAD=4000 run_case large-docker-ps-output 0 'REBOOT OK: canonical node/seed parity' "${BASE_NODE}" "${BASE_SEED}"
if grep -q 'Broken pipe' "${TMP_DIR}/large-docker-ps-output.out"; then
  fail "large-docker-ps-output: a check still pipes into grep -q (Broken pipe)"
fi
ok "large docker ps output: no Broken pipe in any check"
: > "${TMP_DIR}/converged.curl.log.argv"
run_case converged 0 'REBOOT OK: canonical node/seed parity' "${BASE_NODE}" "${BASE_SEED}"

# infra#1073: the converged run authenticated every canonical and Prometheus
# read (the stub rejects a missing header), yet no credential reached argv.
grep -q '/state/snapshot' "${TMP_DIR}/converged.curl.log.argv" \
  || fail "argv capture saw no authenticated canonical read"
grep -q ':9090/api/v1/alerts' "${TMP_DIR}/converged.curl.log.argv" \
  || fail "argv capture saw no authenticated Prometheus read"
! grep -qE 'reader-token|prom-password|YWRtaW46cHJvbS1wYXNzd29yZA|Authorization' \
  "${TMP_DIR}/converged.curl.log.argv" \
  || fail "a credential header reached curl argv"
ok "Reader bearer and Prometheus Basic credentials travel on stdin, never argv"

NODE_HEIGHT=100 SEED_HEIGHT=98 run_case recovering 2 'SEED RECOVERING:' \
  "$(network_json 100 2)" "$(network_json 98 1)"

run_case wrong-chain 1 'chain_id mismatch' "${BASE_NODE}" "$(network_json 100 1 wrong-chain)"
run_case wrong-genesis 1 'genesis_hash mismatch' "${BASE_NODE}" \
  "$(network_json 100 1 "${CHAIN_ID}" "${OTHER_HASH}")"
run_case zero-peers 2 'SEED RECOVERING: seed peer_count=0' \
  "${BASE_NODE}" "$(network_json 100 0)"

SEED_BLOCK_HASH="${OTHER_HASH}" run_case block-divergence 1 'SEED DIVERGED:' \
  "${BASE_NODE}" "${BASE_SEED}"

run_case malformed 1 'canonical response is malformed' 'not-json' "${BASE_SEED}"
run_case ambiguous 1 'canonical response is malformed' \
  '{"chain_id":"777","chain_id":"777","network_id":"wrfcoin-testnet-v1","genesis_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peer_count":2,"sync_status":"synced","chain_height":100}' \
  "${BASE_SEED}"
run_case stale-sync 2 'SEED RECOVERING: node sync_status=catching_up' \
  "$(network_json 100 2 "${CHAIN_ID}" "${GENESIS_HASH}" catching_up)" "${BASE_SEED}"
run_case unauthorized 1 'authenticated canonical endpoint failed' \
  "${BASE_NODE}" "${BASE_SEED}" AUTH_FAIL=true

SEED_STATE_ROOT="${OTHER_HASH}" run_case state-root-divergence 1 'SEED DIVERGED:' \
  "${BASE_NODE}" "${BASE_SEED}"

run_retry_case() {
  local name="$1" expected_rc="$2" expected_text="$3"
  local transient_seed="$4" transient_calls="$5" timeout="$6"
  local minimum_calls="${7:-2}" output="${TMP_DIR}/${name}.out" count
  : > "${TMP_DIR}/${name}.curl.log"
  : > "${TMP_DIR}/${name}.compose.log"
  rm -f "${TMP_DIR}/${name}.seed-calls"

  set +e
  env PATH="${TMP_DIR}/bin:${PATH}" \
    CURL_LOG="${TMP_DIR}/${name}.curl.log" \
    COMPOSE_LOG="${TMP_DIR}/${name}.compose.log" \
    SEED_CALL_COUNT_FILE="${TMP_DIR}/${name}.seed-calls" \
    NODE_NETWORK_JSON="${BASE_NODE}" \
    SEED_NETWORK_JSON="${BASE_SEED}" \
    SEED_TRANSIENT_NETWORK_JSON="${transient_seed}" \
    SEED_TRANSIENT_CALLS="${transient_calls}" \
    AUTH_FAIL="${AUTH_FAIL:-false}" \
    NODE_HEIGHT=100 SEED_HEIGHT=100 \
    NODE_BLOCK_HASH="${COMMON_HASH}" SEED_BLOCK_HASH="${COMMON_HASH}" \
    NODE_STATE_ROOT="${STATE_ROOT}" SEED_STATE_ROOT="${STATE_ROOT}" \
    NODE_SNAPSHOT_ROOT="${SNAPSHOT_ROOT}" SEED_SNAPSHOT_ROOT="${SNAPSHOT_ROOT}" \
    WRFCOIN_HSM_MODE=yubikey \
    WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}" \
    POST_REBOOT_VERIFY_TIMEOUT_SECS="${timeout}" \
    POST_REBOOT_VERIFY_INTERVAL_SECS=1 \
    POST_REBOOT_VERIFY_ONCE=false \
    POST_REBOOT_REORG_DEPTH=2 \
    POST_REBOOT_MAX_RECOVERY_LAG=5 \
    bash "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" > "${output}" 2>&1
  rc=$?
  set -e

  [[ "${rc}" -eq "${expected_rc}" ]] || {
    cat "${output}" >&2
    fail "${name}: expected rc ${expected_rc}, got ${rc}"
  }
  grep -q "${expected_text}" "${output}" || {
    cat "${output}" >&2
    fail "${name}: missing expected result ${expected_text}"
  }
  count=0
  [[ ! -f "${TMP_DIR}/${name}.seed-calls" ]] \
    || count="$(< "${TMP_DIR}/${name}.seed-calls")"
  [[ "${count}" -ge "${minimum_calls}" ]] \
    || fail "${name}: expected at least ${minimum_calls} seed polls, got ${count}"
  printf '%s\n' "${count}" > "${TMP_DIR}/${name}.observed-count"
  ok "${name} (${count} authenticated seed polls)"
}

run_retry_case transient-recovers 0 'REBOOT OK: canonical node/seed parity' \
  "$(network_json 100 1 "${CHAIN_ID}" "${GENESIS_HASH}" catching_up)" 2 4
grep -q 'waiting: .*SEED RECOVERING: seed sync_status=catching_up' \
  "${TMP_DIR}/transient-recovers.out" \
  || fail "transient recovery did not traverse the retry loop"

run_retry_case never-recovers 1 'timed out after 2s' "$(network_json 100 0)" 999 2
grep -q 'waiting: .*SEED RECOVERING: seed peer_count=0' \
  "${TMP_DIR}/never-recovers.out" \
  || fail "never-recovers case did not retry RECOVERING state before timeout"
ok "one-shot RECOVERING rc=2 remains distinct from retry timeout rc=1"

run_retry_case terminal-wrong-chain 1 'chain_id mismatch' \
  "$(network_json 100 1 wrong-chain)" 999 4 1
[[ "$(< "${TMP_DIR}/terminal-wrong-chain.observed-count")" -eq 1 ]] \
  || fail "terminal wrong-chain response was retried"
! grep -qE 'waiting:|timed out' "${TMP_DIR}/terminal-wrong-chain.out" \
  || fail "terminal wrong-chain response entered the recovery loop"
ok "terminal identity mismatch remains fail-fast outside one-shot mode"

AUTH_FAIL=true run_retry_case terminal-unauthorized 1 \
  'authenticated canonical endpoint failed' "${BASE_SEED}" 0 4 0
! grep -qE 'waiting:|timed out' "${TMP_DIR}/terminal-unauthorized.out" \
  || fail "terminal unauthorized response entered the recovery loop"
ok "unauthorized canonical response remains fail-fast outside one-shot mode"

# Seed retired (infra#1057 Q4): no "seed" profile -> no seed container,
# readyz or parity is demanded, the skip is announced, and the OK line says
# plainly that there was no seed parity. The seed endpoint is never contacted.
run_case retired-converged 0 'REBOOT OK (NO SEED PARITY: seed retired)' "${BASE_NODE}" "${BASE_SEED}" \
  COMPOSE_PROFILES=oracle-reference
grep -q 'SEED PARITY: SKIP (seed profile not active' "${TMP_DIR}/retired-converged.out" \
  || fail "seed retired: the parity skip is not announced"
! grep -q ':8557' "${TMP_DIR}/retired-converged.curl.log" \
  || fail "seed retired: the seed endpoint was still contacted"
ok "seed retired: skip announced, seed endpoint never contacted"
run_case retired-seed-diverged-ignored 0 'REBOOT OK (NO SEED PARITY: seed retired)' "${BASE_NODE}" \
  "$(network_json 100 1 wrong-chain)" COMPOSE_PROFILES=oracle-reference
grep -q ':8557' "${TMP_DIR}/converged.curl.log" \
  || fail "positive control: the active-seed run did not contact :8557 (the retired check would be vacuous)"
ok "positive control: with the seed profile active the seed endpoint IS contacted"

grep -q -- '-f .*docker-compose.testnet.yml.*-f .*docker-compose.override.yml.*-f .*docker-compose.local-paths.yml.*-f .*docker-compose.cut.yml.*-f .*docker-compose.cut-miner.yml.*-f .*docker-compose.cut-genesis-seed.yml.*-f .*docker-compose.yubikey.n5.yml.*-f .*docker-compose.oracle-attester.yml.*-f .*docker-compose.oracle-attester-yubikey.n5.yml.*-f .*deployment.yml.*--profile seed.*--profile oracle-reference.*config --quiet' \
  "${TMP_DIR}/converged.compose.log" || fail "effective Compose order/profile custody drifted"
ok "shared Compose order and optional-oracle custody are preserved"

SETTLED_MUTANT="${FIXTURE_DIR}/scripts/post-reboot-settled-height.sh"
# shellcheck disable=SC2016 # Literal arithmetic source is the mutation anchor.
sed 's/settled_height=$((seed_height - POST_REBOOT_REORG_DEPTH))/settled_height=$((seed_height - POST_REBOOT_REORG_DEPTH + 1))/' \
  "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" > "${SETTLED_MUTANT}"
mv "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" "${FIXTURE_DIR}/scripts/post-reboot-canonical.sh"
mv "${SETTLED_MUTANT}" "${FIXTURE_DIR}/scripts/post-reboot-verify.sh"
SETTLED_MUTATION_OUT="${TMP_DIR}/settled-height-proof.out"
if (run_case settled-height-mutation 0 'REBOOT OK: canonical node/seed parity' \
  "${BASE_NODE}" "${BASE_SEED}") > "${SETTLED_MUTATION_OUT}" 2>&1; then
  fail "settled-height mutation survived the production-entrypoint test"
fi
grep -q 'expected rc 0, got 1' "${SETTLED_MUTATION_OUT}" \
  || fail "settled-height mutation did not produce the expected direct RED evidence"
mv "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" "${SETTLED_MUTANT}"
mv "${FIXTURE_DIR}/scripts/post-reboot-canonical.sh" "${FIXTURE_DIR}/scripts/post-reboot-verify.sh"
ok "settled-height cross-check mutation is REAL-RED"

MUTANT="${FIXTURE_DIR}/scripts/post-reboot-readyz-only.sh"
sed 's/^  check_canonical_seed_parity || return \$?$/  true # readyz-only mutation/' \
  "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" > "${MUTANT}"
mv "${FIXTURE_DIR}/scripts/post-reboot-verify.sh" "${FIXTURE_DIR}/scripts/post-reboot-canonical.sh"
mv "${MUTANT}" "${FIXTURE_DIR}/scripts/post-reboot-verify.sh"
MUTATION_OUT="${TMP_DIR}/readyz-only-proof.out"
if (SEED_BLOCK_HASH="${OTHER_HASH}" run_case readyz-only-mutation 1 'SEED DIVERGED:' \
  "${BASE_NODE}" "${BASE_SEED}") > "${MUTATION_OUT}" 2>&1; then
  fail "readyz-only mutation survived the production-entrypoint test"
fi
grep -q 'expected rc 1, got 0' "${MUTATION_OUT}" \
  || fail "readyz-only mutation did not produce the expected direct RED evidence"
ok "readyz-only mutation is REAL-RED"

printf 'PASS: post-reboot canonical seed parity production-entrypoint tests\n'
