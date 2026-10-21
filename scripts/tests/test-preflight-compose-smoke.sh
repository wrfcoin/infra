#!/usr/bin/env bash
# Boot-smoke contract (backend#910 finding 3): the repo's only "compose smoke"
# validated rendered YAML without ever starting a container. These assertions
# pin the properties that make testnet/preflight-compose-smoke.sh a REAL and
# SAFE boot smoke:
#
#   - it actually runs `compose up` (not `config`), waits on container
#     health, and probes a live endpoint;
#   - it is isolated: own project name, an overlay that resets the base
#     file's fixed container_names and published ports and disables
#     restarts, and a teardown that removes only the smoke project;
#   - the old static script no longer claims to be a smoke test.
#
# What this canNOT check, stated plainly: an actual boot on this machine
# (needs Docker + the operator .env). Executed evidence lives with the deploy
# runbook; RED controls (unknown service RC=1; crashed service stays visible
# as 'exited') were run on the workstation 2026-08-16.
#
# Run: bash scripts/tests/test-preflight-compose-smoke.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SMOKE="${REPO}/testnet/preflight-compose-smoke.sh"
OVERLAY="${REPO}/testnet/docker-compose.smoke.yml"
STATIC="${REPO}/scripts/test-compose-smoke.sh"
FAKE_DOCKER="${REPO}/scripts/tests/fixtures/fake-docker-compose-smoke.sh"

fails=0
assertions=0
check() {
  local name="$1" ; shift
  assertions=$((assertions + 1))
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: preflight-compose-smoke-check-forwards-argv
  if "$@"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    fails=$((fails + 1))
  fi
}

echo "== the smoke actually boots, waits, probes =="

check "runs compose up -d (a boot, not a render)" \
  grep -q -- "compose up -d --no-build --no-deps" "${SMOKE}"

check "waits on container State.Health, not on hope" \
  bash -c "grep -q 'State.Health' '${SMOKE}' && grep -q 'deadline' '${SMOKE}'"

check "probes /health from inside the network" \
  bash -c "grep -q 'docker exec' '${SMOKE}' && grep -q '/health' '${SMOKE}'"

check "503 passes ONLY with the exact Core4-down health contract" \
  bash -c "grep -q 'data.status == \"unhealthy\"' '${SMOKE}' && grep -q 'dependencies.core4.status == \"down\"' '${SMOKE}'"

echo "== isolation: safe next to a live stack =="

check "own project name on every compose call" \
  bash -c "grep -q -- '-p \"\${SMOKE_PROJECT}\"' '${SMOKE}'"

check "teardown is down -v inside a trap" \
  bash -c "grep -q 'trap cleanup EXIT' '${SMOKE}' && grep -A2 'cleanup()' '${SMOKE}' | grep -q 'down -v'"

check "pre-existing project resources are rejected before cleanup is armed" \
  bash -c "grep -n 'existing_resources=' '${SMOKE}' | cut -d: -f1 | { read guard; grep -n 'trap cleanup EXIT' '${SMOKE}' | cut -d: -f1 | { read trap_line; test \"\${guard}\" -lt \"\${trap_line}\"; }; }"

overlay_resets_all_three() {
  for svc in postgres redis wrfcoin-backend; do
    grep -q "^  ${svc}:" "${OVERLAY}" || return 1
  done
  # anchored to the 4-space service body so the explanatory header comments
  # cannot satisfy the count
  [ "$(grep -c '^    container_name: !reset' "${OVERLAY}")" -eq 3 ] \
    && [ "$(grep -c '^    ports: !reset' "${OVERLAY}")" -eq 3 ] \
    && [ "$(grep -c '^    restart: !override' "${OVERLAY}")" -eq 3 ]
}
check "overlay resets container_name + ports + restart for all smoke services" overlay_resets_all_three

check "smoke composes the isolation overlay" \
  grep -q "docker-compose.smoke.yml" "${SMOKE}"

check "backend overlay removes node/migration dependencies and disables curl-f health" \
  bash -c "grep -A20 '^  wrfcoin-backend:' '${OVERLAY}' | grep -q 'depends_on: !override' && grep -A20 '^  wrfcoin-backend:' '${OVERLAY}' | grep -q 'disable: true'"

echo "== effective rendered dependency closure =="

render_smoke_config() {
  env \
    ADMIN_TOKEN=test-render-only \
    FAUCET_API_TOKEN=test-render-only \
    GRAFANA_ADMIN_PASSWORD=test-render-only \
    JWT_SECRET=test-render-only \
    N8N_WEBHOOK_SECRET=test-render-only \
    OAUTH_STATE_SECRET=test-render-only \
    POSTGRES_PASSWORD=test-render-only \
    REDIS_PASSWORD=test-render-only \
    RPC_API_KEY=test-render-only \
    WRFCOIN_OPERATOR_TOKEN=test-render-only \
    WRFCOIN_CONTRIBUTOR_TOKEN=contributor-test-render-only \
    WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/127.0.0.1/tcp/9000 \
    bash "${REPO}/testnet/tests/render-testnet-compose.sh" \
      -f "${REPO}/testnet/docker-compose.testnet.yml" \
      -f "${REPO}/testnet/docker-compose.override.yml" \
      -f "${OVERLAY}" \
      config --format json 2>/dev/null
}

RENDERED="$(render_smoke_config)"
check "rendered backend depends only on postgres and redis" \
  bash -c "printf '%s' \"\$1\" | jq -e '.services[\"wrfcoin-backend\"].depends_on | keys | sort == [\"postgres\",\"redis\"]' >/dev/null" _ "${RENDERED}"

check "rendered backend has no fixed name, host ports, restart, or inherited healthcheck" \
  bash -c "printf '%s' \"\$1\" | jq -e '.services[\"wrfcoin-backend\"] | ((.container_name? // null) == null) and ((.ports? // []) == []) and .restart == \"no\" and .healthcheck.disable == true' >/dev/null" _ "${RENDERED}"

echo "== hostile fake-Docker execution controls =="

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
ln -s "${FAKE_DOCKER}" "${TMP}/docker"
: > "${TMP}/smoke.env"

run_fake() {
  local mode="$1" project="$2"
  local log="${TMP}/${mode}.log"
  local state="${TMP}/${mode}.state"
  shift 2
  : > "${log}"
  rm -f "${state}"
  env \
    PATH="${TMP}:${PATH}" \
    FAKE_DOCKER_LOG="${log}" \
    FAKE_DOCKER_MODE="${mode}" \
    FAKE_DOCKER_STATE="${state}" \
    SMOKE_PROJECT="${project}" \
    SMOKE_ENV_FILE="${TMP}/smoke.env" \
    SMOKE_TIMEOUT_SECS=1 \
    SMOKE_PROBE_INTERVAL_SECS=0 \
    bash "${SMOKE}" "$@"
}

collision_fails_without_down() {
  if run_fake collision smoke-collision postgres >/dev/null 2>&1; then
    return 1
  fi
  ! grep -q 'compose .* down ' "${TMP}/collision.log"
}
check "project collision fails before any compose down" collision_fails_without_down

expected_503_passes_once_and_uses_no_deps() {
  run_fake expected-503 smoke-expected-503 postgres redis wrfcoin-backend >/dev/null 2>&1 || return 1
  grep -q 'compose .* up -d --no-build --no-deps postgres redis wrfcoin-backend' "${TMP}/expected-503.log" \
    && [ "$(grep -c '^exec ' "${TMP}/expected-503.log")" -eq 1 ]
}
check "one exact 503 response passes with explicit --no-deps services" expected_503_passes_once_and_uses_no_deps

startup_race_retries_then_passes() {
  run_fake startup-race smoke-startup-race postgres redis wrfcoin-backend >/dev/null 2>&1 || return 1
  [ "$(grep -c '^exec ' "${TMP}/startup-race.log")" -eq 2 ]
}
check "status-masked HTTP 000 is retried until the exact 503 contract answers" startup_race_retries_then_passes

bad_503_fails() {
  ! run_fake bad-503 smoke-bad-503 postgres redis wrfcoin-backend >/dev/null 2>&1
}
check "malformed 503 body fails closed" bad_503_fails

# backend#1234: /health detail is operator/reader-only. Run the smoke's real
# in-container probe script against the captured post-#1234 bodies.
FAKE_CURL_DIR="${TMP}/fake-curl"
mkdir -p "${FAKE_CURL_DIR}"
ln -s "${REPO}/scripts/tests/fixtures/fake-curl-backend-1234.sh" "${FAKE_CURL_DIR}/curl"
# run_real_exec [VAR=value ...]: a subshell so the token variables never leak
# between cases (run_fake is a function, so `env` cannot wrap it).
run_real_exec() {
  (
    unset WRFCOIN_READER_TOKEN WRFCOIN_OPERATOR_TOKEN
    export FAKE_CURL_DIR FAKE_BACKEND_TOKEN=reader-token-1234 FAKE_CURL_ARGV_LOG="${TMP}/fake-curl-argv.log"
    export FAKE_BACKEND_FIXTURES="${REPO}/testnet/tests/fixtures/backend-1234-health"
    local assignment
    # shellcheck disable=SC2163 # each argument is a NAME=value assignment
    for assignment in "$@"; do export "${assignment}"; done
    run_fake real-exec smoke-real-exec postgres redis wrfcoin-backend > "${TMP}/real-exec.out" 2>&1
  )
}
authenticated_probe_passes() {
  run_real_exec WRFCOIN_READER_TOKEN=reader-token-1234 &&
    run_real_exec WRFCOIN_OPERATOR_TOKEN=reader-token-1234
}
check "in-container probe authenticates (reader token, operator fallback) and meets the 503 contract" authenticated_probe_passes

# infra#1066 round 13: the token must travel on stdin, never in curl's argv.
token_never_in_argv() {
  local source
  for source in WRFCOIN_READER_TOKEN WRFCOIN_OPERATOR_TOKEN; do
    : > "${TMP}/fake-curl-argv.log"
    run_real_exec "${source}=reader-token-1234" || return 1
    [ -s "${TMP}/fake-curl-argv.log" ] || return 1
    ! grep -qF reader-token-1234 "${TMP}/fake-curl-argv.log" || return 1
  done
}
check "in-container probe keeps the token out of curl argv (reader and operator fallback)" token_never_in_argv

anonymous_probe_fails_closed() {
  local case_args
  for case_args in "" "WRFCOIN_READER_TOKEN=wrong-token"; do
    # shellcheck disable=SC2086 # empty case = no assignment
    if run_real_exec ${case_args}; then return 1; fi
    # It must fail on the contract, not on plumbing.
    grep -q 'without the expected Core4-down contract' "${TMP}/real-exec.out" || return 1
  done
}
check "without a valid bearer the minimal anonymous body FAILS the contract (not downgraded)" anonymous_probe_fails_closed

unexpected_service_fails() {
  ! run_fake unexpected-service smoke-unexpected postgres redis wrfcoin-backend >/dev/null 2>&1
}
check "unexpected project service fails the runtime closure fence" unexpected_service_fails

live_project_fails_without_docker() {
  local log="${TMP}/live-project.log"
  : > "${log}"
  if env PATH="${TMP}:${PATH}" FAKE_DOCKER_LOG="${log}" FAKE_DOCKER_MODE=healthy \
    SMOKE_PROJECT=wrfcoin-testnet SMOKE_ENV_FILE="${TMP}/smoke.env" \
    bash "${SMOKE}" postgres >/dev/null 2>&1; then
    return 1
  fi
  [ ! -s "${log}" ]
}
check "deployment project name is rejected before Docker is called" live_project_fails_without_docker

echo "== the misnomer is retired =="

check "static script names itself STATIC and points at the real smoke" \
  bash -c "head -8 '${STATIC}' | grep -q 'STATIC' && head -8 '${STATIC}' | grep -q 'preflight-compose-smoke.sh'"

echo ""
echo "${assertions} assertions, ${fails} failures"
[ "${fails}" -eq 0 ]
