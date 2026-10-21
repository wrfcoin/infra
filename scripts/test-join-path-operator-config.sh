#!/usr/bin/env bash
#
# test-join-path-operator-config.sh — infra#762
#
# Runs the ONE documented join command against the configuration an OPERATOR
# actually has, with nothing injected.
#
# WHY THIS EXISTS
# ---------------
# #762 blocked every new peer: `join-testnet-sync-node.sh:201` exited 1 at
# Compose interpolation, before any build, because a `${VAR:?}` guard on
# `wrfcoin-seed` — a service that command neither starts nor renders — made the
# seed's advertise address a precondition of the whole file set. `profiles:`
# does not scope interpolation.
#
# It survived because SIX places inject a value the operator does not have:
#
#   .github/workflows/ci-self-hosted.yml
#   .github/workflows/testnet-docker-validate.yml            (x2 steps)
#   testnet/tests/render-testnet-compose.sh                  (exports BOTH addrs)
#   scripts/test-compose-smoke.sh
#   scripts/test-deploy-hygiene-tools.sh
#   scripts/test-faucet-base-profile-smoke.sh
#   scripts/test-hsm-pin-render-guard.sh
#
# render-testnet-compose.sh even says "Production Compose remains fail-closed
# with its `:?` guards" — true, and the reason nobody noticed: the guards were
# fail-closed on the WRONG COMMAND. Every harness validated a configuration no
# operator has.
#
# So this script deliberately does NOT use render-testnet-compose.sh, and
# REFUSES TO RUN if either address is present in its environment. A gate that
# passes only because the harness supplies what the operator lacks is not a gate.
#
# Probe: `docker compose config` rather than `up`. The defect is at
# interpolation, which `config` performs over the identical file set — measured
# identical exit status and identical error for `config`, `config <service>`,
# and `up --dry-run`. `config` needs no daemon and pulls nothing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_BASE="docker-compose.testnet.yml"
COMPOSE_OVERRIDE="docker-compose.override.yml"
FAILED=0

fail() { echo "FAIL: $*" >&2; FAILED=1; }
pass() { echo "  ok — $*"; }

# ---------------------------------------------------------------------------
# 0. The gate must not be vacuous. Refuse to run in an injected environment.
# ---------------------------------------------------------------------------
echo "== 0. anti-injection self-check =="
for var in WRFCOIN_P2P_EXTERNAL_ADDR WRFCOIN_SEED_P2P_EXTERNAL_ADDR; do
  if [ -n "${!var:-}" ]; then
    echo "FAIL: ${var} is set in this environment." >&2
    echo "      This check exists precisely to run WITHOUT it. Whatever set it has" >&2
    echo "      made this gate vacuous — that is #762's root cause, not a config" >&2
    echo "      convenience. Remove it from the caller rather than from here." >&2
    exit 1
  fi
done
pass "neither advertise address is injected"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp -a "${REPO_ROOT}/testnet" "${WORK}/testnet"
cd "${WORK}/testnet"
export WRFCOIN_ROOT="${REPO_ROOT}/.."

set_env() {
  local k="${1%%=*}"
  if grep -q "^${k}=" .env 2>/dev/null; then
    sed -i "s|^${k}=.*|$1|" .env
  else
    printf '%s\n' "$1" >> .env
  fi
}

# The values join-testnet-sync-node.sh writes itself (script lines 172-186).
apply_join_script_env() {
  set_env "BOOTSTRAP_PEERS=/ip4/100.64.0.1/tcp/9000"
  set_env "WRFCOIN_NETWORK_ID=testnet"
  set_env "WRFCOIN_CHAIN_ID=777"
  set_env "WRFCOIN_GENESIS_HASH=a3301def68ac695636e90d7a66f83e6144a74da0ed5f234a298b73906a437658"
  set_env "ALLOW_UNENCRYPTED_STORAGE=true"
  set_env "WRFCOIN_SYNC_ONLY=1"
  set_env "WRFCOIN_HSM_PIN="
  # The joiner's OWN advertise address. The script derives this from
  # `tailscale ip -4`; a documentation-only RFC 5737 stand-in is used here
  # because this gate must not depend on a tailnet. It is the NODE's address —
  # the one the documented command genuinely needs — not the seed's.
  set_env "WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000"
}

documented_command() {
  # Exactly join-testnet-sync-node.sh:201's file set. Exit status read
  # directly into a variable — never through a pipe.
  # This render is deliberately NOT the canonical helper: the helper forces the
  # RFC 5737 advertise addresses, which would hide the very thing checked here
  # (that the join path needs no injected seed address, #762).
  # raw-render-reviewed: join-path-unforced-render
  docker compose -f "${COMPOSE_BASE}" -f "${COMPOSE_OVERRIDE}" config > /dev/null 2> /tmp/jp.err
}

# ---------------------------------------------------------------------------
# 1. Starting point A — `.env` from setup-env.sh, which is what the join
#    script itself runs on first use (join-testnet-sync-node.sh:155-158).
# ---------------------------------------------------------------------------
echo "== 1. operator path A: setup-env.sh =="
rm -f .env
WRFCOIN_TESTNET_RUNTIME_IMAGE='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  bash setup-env.sh > /dev/null 2>&1 || { fail "setup-env.sh did not complete"; exit 1; }
apply_join_script_env
if documented_command; then
  rc=0
else
  rc=$?
fi
if [ "${rc}" -eq 0 ]; then
  pass "documented command interpolates clean (exit 0)"
else
  fail "documented command exited ${rc} from a clean setup-env.sh checkout"
  sed 's/^/      /' /tmp/jp.err | head -3 >&2
fi

# ---------------------------------------------------------------------------
# 2. Starting point B — operator copies the documented example env.
#    Only the two secrets an operator must obviously fill are supplied.
# ---------------------------------------------------------------------------
echo "== 2. operator path B: .env.testnet.example =="
rm -f .env
cp .env.testnet.example .env
apply_join_script_env
set_env "WRFCOIN_OPERATOR_TOKEN=operator-fills-this-in"
set_env "POSTGRES_PASSWORD=operator-fills-this-in"
if documented_command; then
  rc=0
else
  rc=$?
fi
if [ "${rc}" -eq 0 ]; then
  pass "documented command interpolates clean (exit 0)"
else
  fail "documented command exited ${rc} from the documented example env"
  sed 's/^/      /' /tmp/jp.err | head -3 >&2
fi

# ---------------------------------------------------------------------------
# 3. The fix must not have been achieved by weakening the seed.
#    Static assertions, so a revert is caught even if step 1-2 still pass.
# ---------------------------------------------------------------------------
echo "== 3. the seed guard must still be strict at seed startup =="
SEED_BLOCK="$(awk '/^  wrfcoin-seed:/{f=1} f&&/^  [a-z]/&&!/^  wrfcoin-seed:/{exit} f' "${COMPOSE_BASE}")"

if grep -q 'WRFCOIN_P2P_EXTERNAL_ADDR: \${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:?' <<<"${SEED_BLOCK}"; then
  fail "the seed re-introduced a ':?' interpolation guard — that is #762"
else
  pass "seed does not gate interpolation on its advertise address"
fi

if grep -q 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR is unset or empty' <<<"${SEED_BLOCK}"; then
  pass "seed still refuses to start without an advertise address"
else
  fail "the seed's startup guard is gone — an unset address would now fail OPEN,"
  fail "  because p2p/src/config.rs resolves it with .ok() and starts anyway"
fi

# The NODE's guard is correct and must survive: the node IS the target of the
# documented command, and the join script supplies its value.
NODE_BLOCK="$(awk '/^  wrfcoin-node:/{f=1} f&&/^  [a-z]/&&!/^  wrfcoin-node:/{exit} f' "${COMPOSE_BASE}")"
if grep -q 'WRFCOIN_P2P_EXTERNAL_ADDR: \${WRFCOIN_P2P_EXTERNAL_ADDR:?' <<<"${NODE_BLOCK}"; then
  pass "node keeps its own ':?' guard"
else
  fail "the node's ':?' guard was removed — #762 must not be 'fixed' by loosening it"
fi

echo
if [ "${FAILED}" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS — the documented join command works from both documented"
echo "        starting points with no injected advertise address."
