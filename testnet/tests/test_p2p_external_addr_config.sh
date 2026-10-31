#!/usr/bin/env bash
# Focused non-live tests for the reference-node advertised-address guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="${SCRIPT_DIR}/check-p2p-external-addr.sh"

expect_pass() {
  if ! WRFCOIN_P2P_GUARD_TEST_MODE=1 "$CHECKER" --test-only --require --validate-only "$1" >/dev/null; then
    echo "FAIL: expected validation success for $1" >&2
    exit 1
  fi
}

expect_fail() {
  if WRFCOIN_P2P_GUARD_TEST_MODE=1 "$CHECKER" --test-only --require --validate-only "$1" >/dev/null 2>&1; then
    echo "FAIL: expected validation failure for $1" >&2
    exit 1
  fi
}

expect_pass "/ip4/198.51.100.7/tcp/9000"
expect_pass "/dns4/bootstrap.example.invalid/tcp/9000"
expect_fail "/ip4/192.0.2.2/tcp/9000"
expect_fail "/ip4/127.0.0.1;echo INJECTED/tcp/9000"
expect_fail "/ip4/198.51.100.7/tcp/not-a-port"
expect_fail "/ip4/999.999.999.999/tcp/9000"
expect_fail "/ip4/192.168.1/tcp/9000"
expect_fail "/ip6/::::/tcp/9000"
expect_fail "/ip6/not-an-ip/tcp/9000"
expect_fail "/dns4/host_name/tcp/9000"
expect_fail "/ip4/198.51.100.7/tcp/0"
expect_fail "/ip4/198.51.100.7/tcp/65536"

if env -u WRFCOIN_P2P_EXTERNAL_ADDR WRFCOIN_P2P_GUARD_TEST_MODE=1 "$CHECKER" --test-only --require --validate-only >/dev/null 2>&1; then
  echo "FAIL: unset advertised address must fail closed" >&2
  exit 1
fi

if "$CHECKER" --require --validate-only "/ip4/198.51.100.7/tcp/9000" >/dev/null 2>&1; then
  echo "FAIL: syntax-only mode must not be selectable without the explicit test-only gate" >&2
  exit 1
fi

missing_tool_dir="$(mktemp -d)"
trap 'rm -rf "$missing_tool_dir"' EXIT
ln -s "$(command -v bash)" "${missing_tool_dir}/bash"
ln -s "$(command -v python3)" "${missing_tool_dir}/python3"
ln -s "$(command -v cut)" "${missing_tool_dir}/cut"
missing_tool_output="$(PATH="${missing_tool_dir}" "$CHECKER" --require "/ip4/127.0.0.1/tcp/1" 2>&1 || true)"
if /usr/bin/grep -Fq 'runtime reachability proof tool is unavailable: timeout' <<<"${missing_tool_output}"; then
  :
else
  echo "FAIL: missing runtime proof tool must fail closed" >&2
  exit 1
fi

assert_contains() {
  local file="$1" text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    echo "FAIL: ${file} does not contain required guard: ${text}" >&2
    exit 1
  fi
}

assert_workflow_step_has_fixture() {
  local workflow="$1" step_name="$2" fixture="$3"
  if ! awk -v step_name="$step_name" -v fixture="$fixture" '
    $0 == "      - name: " step_name { in_step = 1; next }
    in_step && /^      - name:/ { exit }
    in_step && index($0, fixture) { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$workflow"; then
    echo "FAIL: workflow Compose render step ${step_name} omits ${fixture}" >&2
    exit 1
  fi
}

expect_render_inventory_mutation_rejected() {
  local label="$1" suffix="$2"
  shift 2
  local mutated
  mutated="$(mktemp --suffix="$suffix")"
  compose_binary=docker
  trap 'rm -f "$mutated"' RETURN
  printf '%s\n' "$@" > "$mutated"
  if WRFCOIN_RENDER_DISCOVERY_EXTRA="$mutated" python3 "$RENDER_INVENTORY" >/dev/null 2>&1; then
    echo "FAIL: inventory accepted ${label} mutation" >&2
    exit 1
  fi
  echo "Compose render inventory ${label} mutation: RED as expected"
  rm -f "$mutated"
  trap - RETURN
}

expect_render_inventory_mutation_accepted() {
  local label="$1" suffix="$2"
  shift 2
  local mutated
  mutated="$(mktemp --suffix="$suffix")"
  trap 'rm -f "$mutated"' RETURN
  printf '%s\n' "$@" > "$mutated"
  if ! WRFCOIN_RENDER_DISCOVERY_EXTRA="$mutated" python3 "$RENDER_INVENTORY" >/dev/null 2>&1; then
    echo "FAIL: inventory rejected ${label} control" >&2
    exit 1
  fi
  echo "Compose render inventory ${label} control: GREEN as expected"
  rm -f "$mutated"
  trap - RETURN
}

# expect_seed_runtime_guard: the seed-address guard is enforced at SEED START.
# 1. A --profile seed render with ONLY the seed address omitted must succeed
#    (the node's address is still required at render time).
# 2. The RENDERED seed entrypoint is executed: with the address empty it must
#    exit 1 with the FATAL line and never reach the real entrypoint; with a
#    value it must hand over to the entrypoint.
# 3. Negative control: the same script with its `exit 1` removed must reach the
#    entrypoint when the address is empty (so step 2 can tell the difference).
expect_seed_runtime_guard() {
  local work rendered script stub out rc
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  rendered="${work}/rendered.json"
  # This unforced seed render tests the seed's runtime guard, not fixture injection.
  # raw-render-reviewed: seed-runtime-guard-unforced-render
  if ! env -i "PATH=${PATH}" "HOME=${HOME:-/tmp}" POSTGRES_PASSWORD=ci REDIS_PASSWORD=ci JWT_SECRET=ci \
      GRAFANA_ADMIN_PASSWORD=ci OAUTH_STATE_SECRET=ci RPC_API_KEY=ci ADMIN_TOKEN=ci N8N_WEBHOOK_SECRET=ci \
      WRFCOIN_OPERATOR_TOKEN=ci WRFCOIN_CONTRIBUTOR_TOKEN=contributor-ci WRFCOIN_HSM_PIN=ci WRFCOIN_HSM_SO_PIN=ci \
      WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000 \
      docker compose --profile seed -f "$COMPOSE" config --format json > "$rendered" 2>"${work}/render.err"; then
    echo "FAIL: a --profile seed render with only WRFCOIN_SEED_P2P_EXTERNAL_ADDR omitted must succeed (runtime guard, #762)" >&2
    sed -n '1,5p' "${work}/render.err" >&2
    exit 1
  fi
  script="${work}/seed-entry.sh"
  stub="${work}/hsm-entrypoint.sh"
  printf '#!/bin/sh\necho REACHED_REAL_ENTRYPOINT\n' > "$stub"; chmod +x "$stub"
  python3 - "$rendered" "$script" "$stub" <<'PY'
import json, sys
svc = json.load(open(sys.argv[1]))["services"]["wrfcoin-seed"]
ep = svc["entrypoint"]
assert ep[:2] == ["/bin/sh", "-ec"], ep[:2]
# `docker compose config` keeps Compose's `$$` escape in its output; the
# container receives it unescaped. Undo it, or `$$` would be the shell's PID.
body = ep[2].replace("$$", "$")
assert "/usr/local/bin/hsm-entrypoint.sh" in body, "rendered seed entrypoint no longer execs hsm-entrypoint.sh"
open(sys.argv[2], "w").write(body.replace("/usr/local/bin/hsm-entrypoint.sh", sys.argv[3]))
PY
  run_seed_entry() { # run_seed_entry <script> <addr>: prints output, returns the script's rc
    env -i "PATH=${PATH}" "WRFCOIN_P2P_EXTERNAL_ADDR=$2" /bin/sh -ec "$(cat "$1")" -- 2>&1
  }
  rc=0; out="$(run_seed_entry "$script" "")" || rc=$?
  if [ "$rc" -ne 1 ] || ! grep -q 'FATAL: WRFCOIN_SEED_P2P_EXTERNAL_ADDR is unset or empty' <<<"$out" \
     || grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
    echo "FAIL: rendered seed entrypoint did not refuse an empty WRFCOIN_P2P_EXTERNAL_ADDR (rc=${rc})" >&2
    exit 1
  fi
  rc=0; out="$(run_seed_entry "$script" "/ip4/203.0.113.9/tcp/9001")" || rc=$?
  if [ "$rc" -ne 0 ] || ! grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
    echo "FAIL: rendered seed entrypoint did not hand over with a valid address (rc=${rc})" >&2
    exit 1
  fi
  grep -v '^[[:space:]]*exit 1$' "$script" > "${work}/weakened.sh"
  rc=0; out="$(run_seed_entry "${work}/weakened.sh" "")" || rc=$?
  if ! grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
    echo "FAIL: negative control: the guard without 'exit 1' still did not reach the entrypoint; the check cannot discriminate" >&2
    exit 1
  fi
  echo "Seed runtime P2P guard: refuses empty, hands over when set; weakened guard is RED as expected"
  rm -rf "$work"
  trap - RETURN
}

# expect_node_runtime_guard: the node's advertise-address guard is enforced at
# NODE START and scoped by role (join path, 2026-10-31).
# 1. A render with the node address omitted must succeed: the documented join
#    command for an outbound-only sync node must not need an address.
# 2. The RENDERED node entrypoint is executed:
#      empty + not sync-only            -> exit 1, FATAL, never the real entrypoint
#      empty + sync-only + service id   -> exit 1 (a serving role must advertise)
#      empty + sync-only                -> hands over (outbound-only sync node)
#      set (any role)                   -> hands over
# 3. Negative control: the same script with its `exit 1` removed must reach the
#    entrypoint for a non-sync-only node (so step 2 can tell the difference).
expect_node_runtime_guard() {
  local work rendered script stub out rc
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  rendered="${work}/rendered.json"
  # This unforced render tests the node's runtime guard, not fixture injection.
  # raw-render-reviewed: node-runtime-guard-unforced-render
  if ! env -i "PATH=${PATH}" "HOME=${HOME:-/tmp}" POSTGRES_PASSWORD=ci REDIS_PASSWORD=ci JWT_SECRET=ci \
      GRAFANA_ADMIN_PASSWORD=ci OAUTH_STATE_SECRET=ci RPC_API_KEY=ci ADMIN_TOKEN=ci N8N_WEBHOOK_SECRET=ci \
      WRFCOIN_OPERATOR_TOKEN=ci WRFCOIN_CONTRIBUTOR_TOKEN=contributor-ci WRFCOIN_HSM_PIN=ci WRFCOIN_HSM_SO_PIN=ci \
      docker compose -f "$COMPOSE" config --format json > "$rendered" 2>"${work}/render.err"; then
    echo "FAIL: a render with WRFCOIN_P2P_EXTERNAL_ADDR omitted must succeed (node runtime guard)" >&2
    sed -n '1,5p' "${work}/render.err" >&2
    exit 1
  fi
  script="${work}/node-entry.sh"
  stub="${work}/hsm-entrypoint.sh"
  printf '#!/bin/sh\necho REACHED_REAL_ENTRYPOINT\n' > "$stub"; chmod +x "$stub"
  python3 - "$rendered" "$script" "$stub" <<'PY2'
import json, sys
svc = json.load(open(sys.argv[1]))["services"]["wrfcoin-node"]
ep = svc["entrypoint"]
assert ep[:2] == ["/bin/sh", "-ec"], ep[:2]
assert ep[3:] == ["--"], ep[3:]
body = ep[2].replace("$$", "$")
assert "/usr/local/bin/hsm-entrypoint.sh" in body, "rendered node entrypoint no longer execs hsm-entrypoint.sh"
open(sys.argv[2], "w").write(body.replace("/usr/local/bin/hsm-entrypoint.sh", sys.argv[3]))
PY2
  run_node_entry() { # run_node_entry <script> <addr> <sync_only> <service_id>
    env -i "PATH=${PATH}" "WRFCOIN_P2P_EXTERNAL_ADDR=$2" "WRFCOIN_SYNC_ONLY=$3" "WRFCOIN_SERVICE_ID=$4" \
      /bin/sh -ec "$(cat "$1")" -- 2>&1
  }
  refuses() { # refuses <label> <addr> <sync_only> <service_id>
    rc=0; out="$(run_node_entry "$script" "$2" "$3" "$4")" || rc=$?
    if [ "$rc" -ne 1 ] || ! grep -q 'FATAL: WRFCOIN_P2P_EXTERNAL_ADDR is unset or empty' <<<"$out" \
       || grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
      echo "FAIL: rendered node entrypoint did not refuse: $1 (rc=${rc})" >&2
      exit 1
    fi
  }
  hands_over() { # hands_over <label> <addr> <sync_only> <service_id>
    rc=0; out="$(run_node_entry "$script" "$2" "$3" "$4")" || rc=$?
    if [ "$rc" -ne 0 ] || ! grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
      echo "FAIL: rendered node entrypoint did not hand over: $1 (rc=${rc})" >&2
      exit 1
    fi
  }
  refuses "empty address on a producer/reference node" "" 0 ""
  refuses "empty address on a sync-only SERVING node" "" 1 "node-ws"
  hands_over "empty address on a plain sync-only node (outbound-only)" "" 1 ""
  grep -q 'outbound connections only' <<<"$out" || { echo "FAIL: outbound-only start is not announced" >&2; exit 1; }
  hands_over "producer with an address" "/ip4/203.0.113.9/tcp/9000" 0 ""
  hands_over "serving node with an address" "/ip4/203.0.113.9/tcp/9000" 1 "node-ws"
  grep -v '^[[:space:]]*exit 1$' "$script" > "${work}/weakened.sh"
  rc=0; out="$(run_node_entry "${work}/weakened.sh" "" 0 "")" || rc=$?
  if ! grep -q REACHED_REAL_ENTRYPOINT <<<"$out"; then
    echo "FAIL: negative control: the node guard without 'exit 1' still did not reach the entrypoint; the check cannot discriminate" >&2
    exit 1
  fi
  echo "Node runtime P2P guard: refuses empty for producer/serving roles, allows outbound-only sync; weakened guard is RED as expected"
  rm -rf "$work"
  trap - RETURN
}

# expect_executed_render_rejected <label> <snippet lines...>: codex round 62.
# ARGV-PROVEN: the snippet is first EXECUTED by bash against a docker shim that
# records its argv, and must really call `compose -f
# testnet/docker-compose.testnet.yml config` (so the case is a genuine render,
# not a strawman). Only then must the inventory reject it.
expect_executed_render_rejected() {
  local label="$1"; shift
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  mkdir -p "${work}/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/argv"\nprintf "{}\\n"\n' "$work" > "${work}/bin/docker"
  chmod +x "${work}/bin/docker"
  # docker-compose (the v1 binary) records the same argv as `docker compose` (infra#1107).
  printf '#!/bin/sh\nprintf "compose %%s\\n" "$*" >> "%s/argv"\nprintf "{}\\n"\n' "$work" > "${work}/bin/docker-compose"
  chmod +x "${work}/bin/docker-compose"
  printf '%s\n' "$@" > "${work}/snippet.sh"
  ( cd "$work" && PATH="${work}/bin:${PATH}" bash "${work}/snippet.sh" >/dev/null 2>&1 ) || true
  if ! grep -qx 'compose -f testnet/docker-compose.testnet.yml config' "${work}/argv" 2>/dev/null; then
    echo "FAIL: ${label}: the snippet did not actually execute the render (argv: $(cat "${work}/argv" 2>/dev/null))" >&2
    exit 1
  fi
  if WRFCOIN_RENDER_DISCOVERY_EXTRA="${work}/snippet.sh" python3 "$RENDER_INVENTORY" >/dev/null 2>&1; then
    echo "FAIL: inventory accepted ${label}, which EXECUTES a raw render (argv-proven)" >&2
    exit 1
  fi
  echo "Compose render inventory ${label}: executes a render (argv-proven) and is RED as expected"
  rm -rf "$work"
  trap - RETURN
}

# expect_unexecuted_data_accepted <label> <snippet lines...>: the mirror image.
# The snippet runs WITHOUT calling docker (argv log empty), and the inventory
# must accept it: data is not a render.
expect_unexecuted_data_accepted() {
  local label="$1"; shift
  local work
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  mkdir -p "${work}/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/argv"\n' "$work" > "${work}/bin/docker"
  chmod +x "${work}/bin/docker"
  printf '%s\n' "$@" > "${work}/snippet.sh"
  ( cd "$work" && PATH="${work}/bin:${PATH}" bash "${work}/snippet.sh" >/dev/null 2>&1 ) || true
  if [ -s "${work}/argv" ]; then
    echo "FAIL: ${label}: the data control executed docker: $(cat "${work}/argv")" >&2
    exit 1
  fi
  if ! WRFCOIN_RENDER_DISCOVERY_EXTRA="${work}/snippet.sh" python3 "$RENDER_INVENTORY" >/dev/null 2>&1; then
    echo "FAIL: inventory rejected ${label}, which never executes docker (argv-proven)" >&2
    exit 1
  fi
  echo "Compose render inventory ${label}: executes nothing (argv-proven) and is GREEN as expected"
  rm -rf "$work"
  trap - RETURN
}

COMPOSE="${SCRIPT_DIR}/docker-compose.testnet.yml"
RENDER_INVENTORY="${SCRIPT_DIR}/tests/check-compose-render-inventory.py"
RENDER_HELPER="${SCRIPT_DIR}/tests/render-testnet-compose.sh"
COMPOSE_WORKFLOW="${SCRIPT_DIR}/../.github/workflows/testnet-docker-validate.yml"
SELF_HOSTED_WORKFLOW="${SCRIPT_DIR}/../.github/workflows/ci-self-hosted.yml"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap.sh"
SYNC_JOIN="${SCRIPT_DIR}/join-testnet-sync-node.sh"
BOOT_HEAL="${SCRIPT_DIR}/boot-heal.sh"
RESET="${SCRIPT_DIR}/scripts/reset-node-from-genesis.sh"
EXPOSE_LAN="${SCRIPT_DIR}/expose-lan.sh"
RESTORE_DRILL="${SCRIPT_DIR}/scripts/backup-restore-verification.sh"
PITR_RESTORE="${SCRIPT_DIR}/scripts/pg-restore-pitr.sh"
SMOKE_FULL="${SCRIPT_DIR}/scripts/smoke-full.sh"
SUSTAINED_TEST="${SCRIPT_DIR}/scripts/sustained-operation-test.sh"
# The node's guard is a role-scoped RUNTIME guard, not an interpolation-time
# `:?`: a plain sync-only node may run outbound-only. Exercised for real below
# (expect_node_runtime_guard).
assert_contains "$COMPOSE" "WRFCOIN_P2P_EXTERNAL_ADDR: \${WRFCOIN_P2P_EXTERNAL_ADDR:-}"
assert_contains "$COMPOSE" 'echo "FATAL: WRFCOIN_P2P_EXTERNAL_ADDR is unset or empty on a non-sync-only node." >&2'
# The seed's guard is a RUNTIME guard, not an interpolation-time `:?`
# (infra#762, b58d27b): a `:?` there made every render fail, including the
# documented join path that never starts the seed. The variable passes through
# with `:-`, and the seed's entrypoint refuses to start without it. It is
# exercised for real below (expect_seed_runtime_guard).
assert_contains "$COMPOSE" "WRFCOIN_P2P_EXTERNAL_ADDR: \${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:-}"
assert_contains "$COMPOSE" 'if [ -z "$${WRFCOIN_P2P_EXTERNAL_ADDR:-}" ]; then'
assert_contains "$COMPOSE" 'echo "FATAL: WRFCOIN_SEED_P2P_EXTERNAL_ADDR is unset or empty." >&2'
# A CI render needs a syntactically valid value, but must not relax the
# production Compose interpolation above. RFC 5737 makes this non-routable
# fixture unambiguously documentation-only.
assert_contains "$COMPOSE_WORKFLOW" 'WRFCOIN_P2P_EXTERNAL_ADDR: /ip4/198.51.100.7/tcp/9000'
assert_contains "$COMPOSE_WORKFLOW" 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR: /ip4/203.0.113.9/tcp/9000'
# Both workflow steps execute positive Compose renders. Keep the fixtures scoped
# to each render step rather than allowing a fixture in one step to mask a later
# PIN-free render that still fails interpolation.
# Complete positive-render inventory: every workflow/script/test callsite that
# renders this Compose file, including all-profiles and seed-profile renders.
assert_workflow_step_has_fixture "$COMPOSE_WORKFLOW" 'Validate testnet compose' 'WRFCOIN_P2P_EXTERNAL_ADDR: /ip4/198.51.100.7/tcp/9000'
assert_workflow_step_has_fixture "$COMPOSE_WORKFLOW" 'Validate testnet compose' 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR: /ip4/203.0.113.9/tcp/9000'
assert_workflow_step_has_fixture "$COMPOSE_WORKFLOW" 'Verify PIN-free renders remain runtime fail-closed' 'WRFCOIN_P2P_EXTERNAL_ADDR: /ip4/198.51.100.7/tcp/9000'
assert_workflow_step_has_fixture "$COMPOSE_WORKFLOW" 'Verify PIN-free renders remain runtime fail-closed' 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR: /ip4/203.0.113.9/tcp/9000'
assert_workflow_step_has_fixture "$SELF_HOSTED_WORKFLOW" 'Validate testnet compose' 'WRFCOIN_P2P_EXTERNAL_ADDR: /ip4/198.51.100.7/tcp/9000'
assert_workflow_step_has_fixture "$SELF_HOSTED_WORKFLOW" 'Validate testnet compose' 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR: /ip4/203.0.113.9/tcp/9000'
assert_contains "${SCRIPT_DIR}/../scripts/test-faucet-base-profile-smoke.sh" 'export WRFCOIN_P2P_EXTERNAL_ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-/ip4/198.51.100.7/tcp/9000}"'
assert_contains "${SCRIPT_DIR}/../scripts/test-faucet-base-profile-smoke.sh" 'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR="${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:-/ip4/203.0.113.9/tcp/9000}"'
assert_contains "${SCRIPT_DIR}/../scripts/test-hsm-pin-render-guard.sh" 'export WRFCOIN_P2P_EXTERNAL_ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-/ip4/198.51.100.7/tcp/9000}"'
assert_contains "${SCRIPT_DIR}/../scripts/test-hsm-pin-render-guard.sh" 'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR="${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:-/ip4/203.0.113.9/tcp/9000}"'
assert_contains "${SCRIPT_DIR}/../scripts/test-deploy-hygiene-tools.sh" 'WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000'
assert_contains "${SCRIPT_DIR}/../scripts/test-deploy-hygiene-tools.sh" 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000'
assert_contains "$RENDER_HELPER" 'export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000'
assert_contains "$RENDER_HELPER" 'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000'
assert_contains "${SCRIPT_DIR}/../scripts/tests/test-route-ledger.sh" 'render-testnet-compose.sh'
assert_contains "${SCRIPT_DIR}/../scripts/test-compose-smoke.sh" 'export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000'
assert_contains "${SCRIPT_DIR}/../scripts/test-compose-smoke.sh" 'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000'
compose_binary=do""cker
literal_dollar='$'
expect_render_inventory_mutation_rejected variable-executable .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'DOCKER=docker' \
  "${literal_dollar}DOCKER compose --profile seed -f \"${literal_dollar}COMPOSE_FILE\" config"
expect_render_inventory_mutation_rejected variable-reassigned-empty .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'DOCKER=docker' \
  'DOCKER=' \
  "${literal_dollar}DOCKER compose --profile seed -f \"${literal_dollar}COMPOSE_FILE\" config"
expect_render_inventory_mutation_rejected quoted-executable .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '"docker" compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected echo-command-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '$(echo docker) compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected command-v-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '$(command -v docker) compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected command-v-substitution-quoted .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '"$(command -v docker)" compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected arbitrary-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '$(resolve_executable docker) compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected nested-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '$(printf "%s" "$(command -v docker)") compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected nested-substitution-quoted .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '"$(printf "%s" "$(command -v docker)")" compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_accepted unrelated-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'resolved="$(command -v docker)"' \
  'printf "%s\\n" "$resolved"'
expect_render_inventory_mutation_accepted shell-printf-quoted-data .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "printf '%s\\n' 'docker compose -f testnet/docker-compose.testnet.yml config'" \
  'printf "%s\\n" "docker compose -f testnet/docker-compose.testnet.yml config"' \
  '# docker compose -f testnet/docker-compose.testnet.yml config'
expect_render_inventory_mutation_accepted yaml-printf-quoted-data .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  "      - run: printf '%s\\n' 'docker compose -f testnet/docker-compose.testnet.yml config'"
expect_render_inventory_mutation_rejected multiple-segment-quoted-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'printf "%s\\n" "docker compose -f testnet/docker-compose.testnet.yml config"; "$(printf "%s" "$(command -v docker)")" compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected sh-c-payload .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "sh -c 'docker compose -f testnet/docker-compose.testnet.yml config'"
expect_render_inventory_mutation_rejected bash-c-payload .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "bash -c 'docker compose -f testnet/docker-compose.testnet.yml config'"
expect_render_inventory_mutation_rejected sudo-delegated-render .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'sudo docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected printf-executed-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'printf "%s" "$(docker compose -f "$COMPOSE_FILE" config)"'
expect_render_inventory_mutation_rejected delegated-options-and-assignments .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'env TRACE=1 timeout --signal=TERM 10 nice -n 5 nohup sudo -u root docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected unsupported-shell-payload .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "sh --unsupported 'docker compose -f testnet/docker-compose.testnet.yml config'"
expect_render_inventory_mutation_rejected recursion-depth-limit .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'printf "%s" "$(echo $(echo $(echo $(echo $(echo $(echo $(echo $(echo $(docker compose -f "$COMPOSE_FILE" config)))))))))"'
expect_render_inventory_mutation_rejected process-substitution-input .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat <(docker compose -f "$COMPOSE_FILE" config)'
expect_render_inventory_mutation_rejected process-substitution-output .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat >(docker compose -f "$COMPOSE_FILE" config)'
expect_render_inventory_mutation_rejected process-substitution-nested .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat <(printf "%s" "$(docker compose -f "$COMPOSE_FILE" config)")'
expect_render_inventory_mutation_rejected process-substitution-wrapper-pipeline .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'printf "%s\\n" x | cat <(docker compose -f testnet/docker-compose.testnet.yml config)'
expect_render_inventory_mutation_rejected process-substitution-yaml .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: cat <(docker compose -f testnet/docker-compose.testnet.yml config)'
expect_render_inventory_mutation_rejected process-substitution-malformed .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat <(docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected process-substitution-depth-limit .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat <(<(<(<(<(<(<(<(docker compose -f "$COMPOSE_FILE" config))))))))'
process_substitution_token_suffix="$(printf ' token%.0s' {1..257})"
expect_render_inventory_mutation_rejected process-substitution-token-limit .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "cat <(docker compose -f \"\$COMPOSE_FILE\" config${process_substitution_token_suffix})"
expect_render_inventory_mutation_accepted process-substitution-literal-data .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'printf "%s\\n" "\<(docker compose -f testnet/docker-compose.testnet.yml config)"' \
  '# \>(docker compose -f testnet/docker-compose.testnet.yml config)'
expect_render_inventory_mutation_accepted process-substitution-yaml-literal-data .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: printf "%s\\n" "\<(docker compose -f testnet/docker-compose.testnet.yml config)"'
expect_render_inventory_mutation_rejected backtick-command-v .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '`command -v docker` compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected backtick-echo-quoted .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '"`echo docker`" compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected backtick-command-v-unquoted .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '`command -v docker` compose --profile seed -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected fixture-cleared .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000' \
  'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000' \
  'WRFCOIN_P2P_EXTERNAL_ADDR=""' \
  'unset WRFCOIN_SEED_P2P_EXTERNAL_ADDR' \
  '# positive-compose-render: mutation-fixture-cleared' \
  "${compose_binary} compose --profile seed -f \"\$COMPOSE_FILE\" config >/dev/null"
expect_render_inventory_mutation_rejected shell-wrapper .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000' \
  'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000' \
  'seed_render() {' \
  "  ${compose_binary} compose \"\$@\"" \
  '}' \
  "seed_render --profile seed -f \"\$COMPOSE_FILE\" config >/dev/null"
expect_render_inventory_mutation_rejected variable-name-parens-wrapper .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'DOCKER=docker' \
  'seed_render() {' \
  "  ${literal_dollar}DOCKER compose \"${literal_dollar}@\"" \
  '}' \
  "seed_render --profile seed -f \"${literal_dollar}COMPOSE_FILE\" config"
expect_render_inventory_mutation_rejected variable-bare-wrapper .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'DOCKER=docker' \
  'seed_render {' \
  "  ${literal_dollar}DOCKER compose \"${literal_dollar}@\"" \
  '}' \
  "seed_render --profile seed -f \"${literal_dollar}COMPOSE_FILE\" config"
expect_render_inventory_mutation_rejected function-keyword-wrapper .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'function seed_render {' \
  "  ${compose_binary} compose \"\$@\"" \
  '}' \
  "seed_render --profile seed -f \"\$COMPOSE_FILE\" config >/dev/null"
expect_render_inventory_mutation_rejected bare-name-wrapper .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'seed_render {' \
  "  ${compose_binary} compose \"\$@\"" \
  '}' \
  "seed_render --profile seed -f \"\$COMPOSE_FILE\" config >/dev/null"
expect_render_inventory_mutation_rejected yaml-inline .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  "      - run: ${compose_binary} compose --profile seed -f testnet/docker-compose.testnet.yml config"
expect_render_inventory_mutation_rejected yaml-variable-inline .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: $DOCKER compose --profile seed -f testnet/docker-compose.testnet.yml config'
expect_render_inventory_mutation_rejected yaml-literal .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: |' \
  "          ${compose_binary} compose --profile seed -f testnet/docker-compose.testnet.yml config"
expect_render_inventory_mutation_rejected yaml-variable-literal .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: |' \
  '          ${DOCKER} compose --profile seed -f testnet/docker-compose.testnet.yml config'
expect_render_inventory_mutation_rejected yaml-folded .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - name: folded render' \
  '        env:' \
  '          WRFCOIN_P2P_EXTERNAL_ADDR: /ip4/198.51.100.7/tcp/9000' \
  '          WRFCOIN_SEED_P2P_EXTERNAL_ADDR: /ip4/203.0.113.9/tcp/9000' \
  '        run: >' \
  "          ${compose_binary} compose" \
  '          --profile seed' \
  '          -f testnet/docker-compose.testnet.yml' \
  '          config'
expect_render_inventory_mutation_rejected yaml-variable-folded .yaml \
  'jobs:' \
  '  scan:' \
  '    steps:' \
  '      - run: >' \
  '          $DOCKER compose --profile seed -f testnet/docker-compose.testnet.yml config'
expect_render_inventory_mutation_rejected alias-eval-command-substitution .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'alias d=docker' \
  'd compose -f "$COMPOSE_FILE" config' \
  'eval "$DOCKER compose -f $COMPOSE_FILE config"' \
  '$(printf docker) compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected malformed-yaml .yaml \
  'jobs: [' \
  "run: ${compose_binary} compose --profile seed -f testnet/docker-compose.testnet.yml config"
expect_render_inventory_mutation_rejected duplicate-id .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000' \
  'export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000' \
  '# positive-compose-render: mutation-duplicate-id' \
  "${compose_binary} compose -f \"\$COMPOSE_FILE\" config >/dev/null" \
  '# positive-compose-render: mutation-duplicate-id' \
  "${compose_binary} compose --profile seed -f \"\$COMPOSE_FILE\" config >/dev/null"
# Nested quoting (a $() inside double quotes opens a fresh quoting context).
# The flat scanner cut such commands mid-string: it flagged harmless multi-line
# arguments and could lose the real invocation. These pin both directions.
expect_render_inventory_mutation_rejected nested-dq-substitution-dynamic .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'out="$("$DOCKER" compose -f "$COMPOSE_FILE" config --format json)"'
expect_render_inventory_mutation_rejected nested-dq-substitution-multiline-dynamic .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'out="$(f "a' \
  'b" && "$DOCKER" compose -f "$COMPOSE_FILE" config)"'
expect_render_inventory_mutation_rejected nested-dq-substitution-raw .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'out="$(docker compose -f "$COMPOSE_FILE" config --format json)"'
expect_render_inventory_mutation_accepted nested-dq-substitution-multiline-data .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'file="$(override node "  wrfcoin-node:' \
  '    image: fixture' \
  '    build: !reset null")"'
expect_render_inventory_mutation_accepted compose-reset-override-tags .yml \
  'services:' \
  '  wrfcoin-node:' \
  '    build: !reset null' \
  '    ports: !override ["127.0.0.1:8556:8556"]'
expect_render_inventory_mutation_rejected unknown-yaml-tag .yml \
  'services:' \
  '  wrfcoin-node:' \
  '    build: !evil null'
expect_render_inventory_mutation_rejected malformed-yaml-unclosed-flow .yml \
  'services:' \
  '  wrfcoin-node: [unclosed'
# codex round 62, all argv-proven. (1) heredocs that EXECUTE,
# (2) eval / sh -c of an unresolved payload, (3) a quoted `)` inside $().
expect_executed_render_rejected heredoc-bash-stdin-raw \
  "bash <<'EOF'" \
  'docker compose -f testnet/docker-compose.testnet.yml config' \
  'EOF'
expect_executed_render_rejected heredoc-dash-strip-tabs-raw \
  "sh <<-'EOF'" \
  $'\tdocker compose -f testnet/docker-compose.testnet.yml config' \
  $'\tEOF'
expect_executed_render_rejected heredoc-inside-substitution-raw \
  "out=\"\$(bash <<'EOF'" \
  'docker compose -f testnet/docker-compose.testnet.yml config' \
  'EOF' \
  ')"'
expect_executed_render_rejected heredoc-unquoted-substitution \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'cat <<EOF >/dev/null' \
  '$(docker compose -f "$COMPOSE_FILE" config)' \
  'EOF'
expect_executed_render_rejected heredoc-unquoted-apostrophe-substitution \
  'cat <<EOF >/dev/null' \
  "it's \$(docker compose -f testnet/docker-compose.testnet.yml config)" \
  'EOF'
expect_executed_render_rejected eval-variable-payload \
  "cmd='docker compose -f testnet/docker-compose.testnet.yml config'" \
  'eval "$cmd"'
expect_executed_render_rejected sh-c-variable-payload \
  "cmd='docker compose -f testnet/docker-compose.testnet.yml config'" \
  'bash -c "$cmd"'
expect_executed_render_rejected quoted-paren-in-substitution \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "x=\"\$(printf '%s' ')'; docker compose -f \"\$COMPOSE_FILE\" config)\""
expect_unexecuted_data_accepted heredoc-quoted-data \
  "cat <<'EOF' >/dev/null" \
  'docker compose -f testnet/docker-compose.testnet.yml config' \
  '$(docker compose -f testnet/docker-compose.testnet.yml config)' \
  'EOF'
expect_unexecuted_data_accepted heredoc-unquoted-escaped-substitution \
  'cat <<EOF >/dev/null' \
  "it's \\\$(docker compose -f testnet/docker-compose.testnet.yml config) and \${HOME}" \
  'EOF'
expect_unexecuted_data_accepted heredoc-bash-stdin-no-render \
  "bash <<'EOF'" \
  'echo testnet/docker-compose.testnet.yml' \
  'EOF'
# Fail closed by default: an unresolvable payload is RED even when benign,
# unless a human marked that exact site with a unique reviewed id.
expect_render_inventory_mutation_rejected unmarked-unresolved-payload .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "cmd='true'" \
  'bash -c "$cmd"'
expect_render_inventory_mutation_accepted reviewed-unresolved-payload .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "cmd='true'" \
  '# dynamic-payload-reviewed: inventory-control-reviewed-payload' \
  'bash -c "$cmd"'
# infra#1107: a reviewed marker is BOUND to exactly the next command (only
# blank/comment lines between) and clears exactly one dynamic invocation.
expect_executed_render_rejected marker-does-not-reach-past-a-command \
  '# dynamic-payload-reviewed: inventory-control-unrelated-review' \
  'eval "$REVIEWED_BENIGN_CMD"' \
  'cmd="docker compose -f testnet/docker-compose.testnet.yml config"; eval "$cmd"'
expect_executed_render_rejected marker-clears-only-one-command \
  "a='true'; b='docker compose -f testnet/docker-compose.testnet.yml config'" \
  '# dynamic-payload-reviewed: inventory-control-one-marker-two-commands' \
  'eval "$a"; eval "$b"'
expect_render_inventory_mutation_rejected marker-separated-by-a-command .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "cmd='true'" \
  '# dynamic-payload-reviewed: inventory-control-separated-marker' \
  'echo unrelated' \
  'bash -c "$cmd"'
expect_unexecuted_data_accepted marker-bound-through-comments-and-blanks \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "cmd='true'" \
  '# dynamic-payload-reviewed: inventory-control-bound-through-comments' \
  '# (the reason for the review goes here)' \
  '' \
  'bash -c "$cmd"'
expect_unexecuted_data_accepted eval-literal-no-render \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "eval 'true'"
# infra#1118: an apostrophe in a comment opens no quote, so it can no longer
# swallow every later command (which hid raw renders behind a "#" command).
expect_render_inventory_mutation_rejected comment-apostrophe-does-not-hide-render .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "# the gate's own fixtures" \
  'docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected trailing-comment-apostrophe-does-not-hide-render .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "echo ok # it's fine" \
  'docker compose -f "$COMPOSE_FILE" config'
# A quote still open at EOF swallowed the rest of the file: fail closed.
expect_render_inventory_mutation_rejected unterminated-quote-at-eof-fails-closed .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "echo 'never closed" \
  'docker compose -f "$COMPOSE_FILE" config'
# `#` inside a word or a quote is not a comment.
expect_render_inventory_mutation_rejected hash-inside-word-is-not-a-comment .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "echo a#b 'x' \"#\" ; docker compose -f \"\$COMPOSE_FILE\" config"
# infra#1107: wrapper shapes that reach a raw render without a literal
# `docker compose` prefix are detected or fail closed; data controls stay GREEN.
expect_executed_render_rejected wrapper-docker-compose-v1 \
  'docker-compose -f testnet/docker-compose.testnet.yml config'
expect_executed_render_rejected wrapper-xargs \
  "printf 'testnet/docker-compose.testnet.yml\\n' | xargs -I{} docker compose -f {} config"
expect_executed_render_rejected wrapper-array-expansion \
  'args=(docker compose -f testnet/docker-compose.testnet.yml config)' \
  '"${args[@]}"'
expect_executed_render_rejected wrapper-find-exec \
  'find . -maxdepth 0 -exec docker compose -f testnet/docker-compose.testnet.yml config \;'
expect_executed_render_rejected wrapper-function-forwarding-args \
  'r() { "$@"; }' \
  'r docker compose -f testnet/docker-compose.testnet.yml config'
expect_executed_render_rejected wrapper-python-heredoc \
  "python3 - <<'PY'" \
  'import subprocess; subprocess.run(["docker", "compose", "-f", "testnet/docker-compose.testnet.yml", "config"])' \
  'PY'
# A marker-looking line inside a multi-line quoted string is DATA, never a comment,
# so it must not clear anything (infra#1140 review).
expect_executed_render_rejected raw-marker-inside-quoted-string-is-data \
  "printf '%s\\n' 'data" \
  "# raw-render-reviewed: quoted-string-spoof'" \
  'docker compose -f testnet/docker-compose.testnet.yml config'
expect_executed_render_rejected dynamic-marker-inside-quoted-string-is-data \
  'cmd="docker compose -f testnet/docker-compose.testnet.yml config"' \
  "printf '%s\\n' 'data" \
  "# dynamic-payload-reviewed: quoted-string-spoof'" \
  'eval "$cmd"'
# infra#1140 review: a heredoc delimiter or body that spells like a marker is not a comment.
expect_executed_render_rejected raw-marker-as-heredoc-delimiter-is-data \
  "cat <<'# raw-render-reviewed: heredoc-delimiter-spoof'" \
  'data' \
  '# raw-render-reviewed: heredoc-delimiter-spoof' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
expect_executed_render_rejected raw-marker-inside-heredoc-body-is-data \
  'cat <<EOF' \
  '# raw-render-reviewed: heredoc-body-spoof' \
  'EOF' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
# Several heredocs on one command: bash consumes the bodies in order, so the SECOND
# terminator is still data (infra#1140 second review).
expect_executed_render_rejected raw-marker-as-second-heredoc-delimiter-is-data \
  "cat <<EOF <<'# raw-render-reviewed: second-delimiter'" \
  'first body' \
  'EOF' \
  'second body' \
  '# raw-render-reviewed: second-delimiter' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
expect_render_inventory_mutation_accepted genuine-marker-after-two-heredocs .sh \
  'cat <<EOF <<EOG' \
  'first' \
  'EOF' \
  'second' \
  'EOG' \
  '# raw-render-reviewed: genuine-after-two-heredocs' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
# An unsupported delimiter (`<<$(cmd)`) fails closed: no marker after it is honoured
# (inventory-level control; the delimiter form is not one the snippet can portably execute).
expect_render_inventory_mutation_rejected raw-marker-after-unsupported-heredoc-fails-closed .sh \
  'cat <<$(echo EOF)' \
  'data' \
  'EOF' \
  '# raw-render-reviewed: after-unsupported-heredoc' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
# ... while a genuine marker after an ordinary heredoc still clears exactly its command.
expect_render_inventory_mutation_accepted genuine-marker-after-heredoc .sh \
  'cat <<EOF' \
  'data # not a marker' \
  'EOF' \
  '# raw-render-reviewed: genuine-after-heredoc' \
  'docker compose -f testnet/docker-compose.testnet.yml config'
expect_unexecuted_data_accepted wrapper-python-heredoc-without-docker \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  "python3 - <<'PY'" \
  'print("no container tooling here")' \
  'PY'
expect_unexecuted_data_accepted wrapper-find-without-docker \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'find . -maxdepth 0 -name x'
expect_render_inventory_mutation_accepted wrapper-reviewed-argv-forwarder .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  'r() {' \
  '  # dynamic-payload-reviewed: inventory-control-argv-forwarder' \
  '  "$@"' \
  '}'
# raw-render-reviewed: bound to the next command, single use.
expect_render_inventory_mutation_accepted reviewed-raw-render .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '# raw-render-reviewed: inventory-control-reviewed-raw' \
  'docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected raw-marker-separated-by-a-command .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '# raw-render-reviewed: inventory-control-raw-separated' \
  'echo unrelated' \
  'docker compose -f "$COMPOSE_FILE" config'
expect_render_inventory_mutation_rejected raw-marker-clears-only-one-render .sh \
  'COMPOSE_FILE="testnet/docker-compose.testnet.yml"' \
  '# raw-render-reviewed: inventory-control-raw-two' \
  'docker compose -f "$COMPOSE_FILE" config; docker compose -f "$COMPOSE_FILE" config'
python3 "$RENDER_INVENTORY"
expect_node_runtime_guard
expect_seed_runtime_guard
assert_contains "$BOOTSTRAP" 'post_start_p2p_validation'
assert_contains "$BOOTSTRAP" 'run_p2p_config_validation'
assert_contains "$SYNC_JOIN" 'Preserving operator-supplied WRFCOIN_P2P_EXTERNAL_ADDR.'
# The join's own-address dial must run AFTER the node is started: before
# `compose up` nothing listens there, so a pre-start dial aborted every fresh
# join (2026-10-31 newcomer dry run).
dial_line=$(grep -n 'check-p2p-external-addr.sh" "\${WRFCOIN_P2P_EXTERNAL_ADDR}"' "$SYNC_JOIN" | head -1 | cut -d: -f1)
up_line=$(grep -n 'up -d --build postgres redis wrfcoin-node' "$SYNC_JOIN" | head -1 | cut -d: -f1)
if [ -z "$dial_line" ] || [ -z "$up_line" ] || [ "$dial_line" -le "$up_line" ]; then
  echo "FAIL: sync-node advertised-address dial must come after the node is started" >&2
  exit 1
fi
assert_contains "$BOOT_HEAL" 'guard_external_address'
assert_contains "$BOOT_HEAL" 'compose up -d --no-build --force-recreate'
assert_contains "$RESET" 'require_p2p_guard'
assert_contains "$EXPOSE_LAN" "\"\${P2P_GUARD}\" --env-file \"\${DIR}/.env\" --require"
assert_contains "$RESTORE_DRILL" 'guard_external_address'
assert_contains "$PITR_RESTORE" 'guard_external_address'
assert_contains "$SMOKE_FULL" 'guard_external_address'
assert_contains "$SUSTAINED_TEST" "\"\${P2P_GUARD}\" --env-file \"\${TESTNET_ENV_FILE}\" --require"

operator_line=$(grep -n 'operator_external_addr=' "$SYNC_JOIN" | head -1 | cut -d: -f1)
auto_detect_line=$(grep -n "set_env WRFCOIN_P2P_EXTERNAL_ADDR \"/ip4/\${TS_IP}" "$SYNC_JOIN" | head -1 | cut -d: -f1)
if [ -z "$operator_line" ] || [ -z "$auto_detect_line" ] || [ "$operator_line" -ge "$auto_detect_line" ]; then
  echo "FAIL: sync-node operator precedence must be evaluated before auto-detection" >&2
  exit 1
fi

echo "P2P advertised-address config tests: PASS"
