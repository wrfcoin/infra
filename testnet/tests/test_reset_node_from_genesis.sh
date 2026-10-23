#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/reset-node-from-genesis.sh
source "${SCRIPT_DIR}/../scripts/reset-node-from-genesis.sh"

PASS_COUNT=0
FAIL_COUNT=0
EVENTS=()
CANONICAL_MARKER="$(mktemp)"
trap 'rm -f "${CANONICAL_MARKER}"' EXIT

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
}

assert_success() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "${name}"
  else
    pass "${name}"
  fi
}

assert_no_node_mutation_after_guard_failure() {
  local name="$1"
  local rejected=0 event
  for event in "${EVENTS[@]}"; do
    if [[ "${event}" == guard:*:fail ]]; then
      rejected=1
      continue
    fi
    if [ "${rejected}" -eq 1 ] && [[ "${event}" == docker:start* || "${event}" == docker:restart* ]]; then
      fail "${name}"
      return
    fi
  done
  if [ "${rejected}" -eq 1 ]; then
    pass "${name}"
  else
    fail "${name} (no rejected guard event)"
  fi
}

valid_config() {
  printf '%s\n' '[
    "WRFCOIN_NETWORK_ID=testnet",
    "WRFCOIN_CHAIN_ID=777",
    "WRFCOIN_P2P_BOOTSTRAP=/ip4/100.64.0.1/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr"
  ]'
}

assert_success "canonical container config accepted" validate_container_env_json "$(valid_config)"
assert_failure "missing bootstrap rejected" validate_container_env_json \
  '["WRFCOIN_NETWORK_ID=testnet","WRFCOIN_CHAIN_ID=777"]'
assert_failure "wrong chain rejected" validate_container_env_json \
  '["WRFCOIN_NETWORK_ID=testnet","WRFCOIN_CHAIN_ID=778","WRFCOIN_P2P_BOOTSTRAP=/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr"]'
assert_failure "wrong bootstrap identity rejected" validate_container_env_json \
  '["WRFCOIN_NETWORK_ID=testnet","WRFCOIN_CHAIN_ID=777","WRFCOIN_P2P_BOOTSTRAP=/ip4/192.0.2.1/tcp/9000/p2p/wrong"]'

assert_failure "seed service cannot be selected" bash -c \
  'source "$1"; main --confirm --service wrfcoin-seed' _ \
  "${SCRIPT_DIR}/../scripts/reset-node-from-genesis.sh"

GUARD_CALLS=0
GUARD_FAIL_FROM=0

require_p2p_guard() {
  GUARD_CALLS=$((GUARD_CALLS + 1))
  if [ "${GUARD_FAIL_FROM}" -gt 0 ] && [ "${GUARD_CALLS}" -ge "${GUARD_FAIL_FROM}" ]; then
    EVENTS+=("guard:${GUARD_CALLS}:fail")
    return 1
  fi
  EVENTS+=("guard:${GUARD_CALLS}:pass")
}

preflight() {
  EVENTS+=("preflight")
  require_p2p_guard
}

read_node_info() {
  printf '{
    "network_id":"testnet",
    "chain_id":"777",
    "genesis_hash":"%s",
    "chain_height":42,
    "peer_count":1,
    "sync_status":"synced"
  }\n' "${CANONICAL_GENESIS_HASH}"
}

for operator_doc in \
  "${SCRIPT_DIR}/../JOIN_TESTNET.md" \
  "${SCRIPT_DIR}/../TESTNET_OPERATOR_GUIDE.md"; do
  if [[ ! -e "${operator_doc}" && "$(basename "${operator_doc}")" == TESTNET_OPERATOR_GUIDE.md ]]; then
    # Not shipped in the public tree; still FAILS below if the file exists but drifted.
    echo "  SKIP  $(basename "${operator_doc}") not present in this tree"
  elif grep -Fq "${CANONICAL_GENESIS_HASH}" "${operator_doc}"; then
    pass "$(basename "${operator_doc}") uses cut-pins genesis"
  else
    fail "$(basename "${operator_doc}") drifted from cut-pins genesis"
  fi
done

docker() {
  EVENTS+=("docker:$*")
}

archive_chain_state() {
  EVENTS+=("archive:wrfcoin.redb,equivocation_evidence.redb")
}

reserve_archive_directory() {
  printf '%s\n' test-reset-backup
}

restore_chain_state() {
  EVENTS+=("restore:wrfcoin.redb,equivocation_evidence.redb")
}

wait_for_health() {
  EVENTS+=("health")
}

wait_for_genesis_import() {
  EVENTS+=("import")
}

wait_for_canonical_identity() {
  : >"${CANONICAL_MARKER}"
  read_node_info
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=0
rm -f "${CANONICAL_MARKER}"
assert_success "successful reset orchestration" run_reset
event_log="$(printf '%s\n' "${EVENTS[@]}")"
for expected in \
  "preflight" \
  "guard:1:pass" \
  "docker:stop wrfcoin-testnet-node" \
  "archive:wrfcoin.redb,equivocation_evidence.redb" \
  "guard:2:pass" \
  "docker:start wrfcoin-testnet-node" \
  "import" \
  "guard:3:pass" \
  "docker:restart wrfcoin-testnet-node"; do
  if grep -Fxq "${expected}" <<<"${event_log}"; then
    pass "success path: ${expected}"
  else
    fail "success path missing: ${expected}"
  fi
done
if [ -f "${CANONICAL_MARKER}" ]; then
  pass "success path verifies canonical identity after restart"
else
  fail "success path did not verify canonical identity"
fi
if grep -q '^restore:' <<<"${event_log}"; then
  fail "success path must not restore rollback state"
else
  pass "success path retains rollback without restoring it"
fi

# Each failure starts with a successful preflight guard, then rejects the
# exact guard immediately before one distinct node start/restart path. The
# failure mode is persistent so rollback also leaves the node stopped.
wait_for_genesis_import() {
  EVENTS+=("import-timeout")
  return 1
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=3
assert_failure "rollback start guard rejection fails reset" run_reset
assert_no_node_mutation_after_guard_failure \
  "rollback start guard rejection prevents docker start"
if grep -Fxq "guard:1:pass" <<<"$(printf '%s\n' "${EVENTS[@]}")"; then
  pass "rollback start rejection had a successful preflight guard"
else
  fail "rollback start rejection missing successful preflight guard"
fi

reserve_archive_directory() {
  EVENTS+=("reserve-failure")
  return 1
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=2
assert_failure "archive-recovery start guard rejection fails reset" run_reset
assert_no_node_mutation_after_guard_failure \
  "archive-recovery start guard rejection prevents docker start"
if grep -Fxq "guard:1:pass" <<<"$(printf '%s\n' "${EVENTS[@]}")"; then
  pass "archive-recovery rejection had a successful preflight guard"
else
  fail "archive-recovery rejection missing successful preflight guard"
fi

reserve_archive_directory() {
  printf '%s\n' test-reset-backup
}
archive_chain_state() {
  EVENTS+=("archive:wrfcoin.redb,equivocation_evidence.redb")
}
wait_for_genesis_import() {
  EVENTS+=("import")
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=2
assert_failure "empty-chain start guard rejection fails reset" run_reset
assert_no_node_mutation_after_guard_failure \
  "empty-chain start guard rejection prevents docker start"
if grep -Fxq "guard:1:pass" <<<"$(printf '%s\n' "${EVENTS[@]}")"; then
  pass "empty-chain rejection had a successful preflight guard"
else
  fail "empty-chain rejection missing successful preflight guard"
fi

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=3
assert_failure "post-genesis restart guard rejection fails reset" run_reset
assert_no_node_mutation_after_guard_failure \
  "post-genesis restart guard rejection prevents node mutation"
if grep -Fxq "guard:1:pass" <<<"$(printf '%s\n' "${EVENTS[@]}")"; then
  pass "post-genesis rejection had a successful preflight guard"
else
  fail "post-genesis rejection missing successful preflight guard"
fi

wait_for_genesis_import() {
  EVENTS+=("import-timeout")
  return 1
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=0
assert_failure "sync timeout fails reset" run_reset
event_log="$(printf '%s\n' "${EVENTS[@]}")"
if grep -Fxq "restore:wrfcoin.redb,equivocation_evidence.redb" <<<"${event_log}"; then
  pass "sync timeout restores both chain-coupled databases"
else
  fail "sync timeout did not restore chain state"
fi
if grep -Fxq "docker:start wrfcoin-testnet-node" <<<"${event_log}"; then
  pass "rollback restarts the original node"
else
  fail "rollback did not restart the original node"
fi

archive_chain_state() {
  EVENTS+=("archive-partial-failure")
  return 1
}

EVENTS=()
GUARD_CALLS=0
GUARD_FAIL_FROM=0
assert_failure "partial archive failure fails reset" run_reset
event_log="$(printf '%s\n' "${EVENTS[@]}")"
if grep -Fxq "restore:wrfcoin.redb,equivocation_evidence.redb" <<<"${event_log}"; then
  pass "partial archive failure invokes rollback before restarting"
else
  fail "partial archive failure did not invoke rollback"
fi

if grep -Eq 'peer_identity\.key|/app/data/hsm' \
  "${SCRIPT_DIR}/../scripts/reset-node-from-genesis.sh"; then
  fail "reset script must not move or delete peer identity/HSM material"
else
  pass "reset scope excludes peer identity and HSM material"
fi

assert_failure "bad genesis identity fails closed" bash -c '
  source "$1"
  read_node_info() {
    printf "%s\\n" "{\\\"network_id\\\":\\\"testnet\\\",\\\"chain_id\\\":\\\"777\\\",\\\"genesis_hash\\\":\\\"0xnot-canonical\\\",\\\"chain_height\\\":42,\\\"peer_count\\\":1}"
  }
  RESET_TIMEOUT_SECS=1
  wait_for_canonical_identity
' _ "${SCRIPT_DIR}/../scripts/reset-node-from-genesis.sh"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  printf '\nFailed %d of %d assertions\n' "${FAIL_COUNT}" "$((PASS_COUNT + FAIL_COUNT))"
  exit 1
fi
printf '\nPassed %d assertions\n' "${PASS_COUNT}"
