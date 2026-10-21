#!/usr/bin/env bash
#
# #2502 — every chain node in the cut compose must set
# WRFCOIN_REQUIRE_PRODUCER_AUTH=1.
#
# WHY THIS GUARD EXISTS
#
# Block-producer authority is enforced iff the chain seeds a producer set at
# genesis. `launch_api` resolves that set from WRFCOIN_NETWORK_ID, and
# WRFCOIN_NETWORK_ID is a *selector*, not a boolean: `mainnet`, `dev` and
# friends are all legitimate values, so a typo like `testnett` is
# indistinguishable from a real third network. It lands in the branch that seeds
# NO producer set, and the chain comes up looking authenticated while enforcing
# nothing. core4's `genesis_producers.rs` states plainly that there is no fix for
# this in code:
#
#     "There is no local fix; the mitigation is WRFCOIN_REQUIRE_PRODUCER_AUTH=1
#      ... This is precisely why the cut compose sets it, and why it must not be
#      treated as belt-and-braces."
#
# The flag turns a resolved-empty producer set into a hard startup abort, and it
# parses FALLIBLY — unlike the WRFCOIN_ENABLE_* flags, a typo in this one aborts
# rather than silently disabling the guard, because its polarity is the opposite
# (off = a disabled security protection).
#
# WHY IT IS A SCRIPT AND NOT A COMMENT
#
# Three core4 runbooks already called this flag mandatory for the cut
# (GENESIS_CUT_RUNBOOK.md, AUTH_LIVE_FAILURE_PLAYBOOK.md,
# PRODUCER_SIGN_WIRING_2290.md) while it was set in no compose file anywhere in
# this repo. "Documented as mandatory" is not "set". This script is the
# difference, and it is why fixing the compose once would not have been enough.
#
# Usage:  scripts/check-producer-auth-required.sh [compose-file]
#         scripts/check-producer-auth-required.sh --self-test

set -euo pipefail

COMPOSE="${1:-testnet/docker-compose.testnet.yml}"

# Services that run the `launch_api` binary and therefore resolve a genesis
# producer set. The faucet also sets WRFCOIN_NETWORK_ID but is not a chain node:
# it seeds no genesis and has no producer set to lose.
CHAIN_NODES=("wrfcoin-node" "wrfcoin-seed")

check() {
  local file="$1"
  python3 - "$file" "${CHAIN_NODES[@]}" <<'PY'
import sys, yaml
path, nodes = sys.argv[1], sys.argv[2:]
try:
    doc = yaml.safe_load(open(path))
except Exception as e:
    print(f"ERROR: {path} is not parseable YAML: {e}", file=sys.stderr)
    sys.exit(1)

services = (doc or {}).get("services") or {}
missing, wrong, absent = [], [], []

for name in nodes:
    svc = services.get(name)
    if svc is None:
        # Fail closed: a renamed or removed chain node must break this guard
        # loudly rather than silently reducing what it covers to nothing.
        absent.append(name)
        continue
    env = svc.get("environment") or {}
    if isinstance(env, list):  # `- KEY=value` form
        env = dict(
            item.split("=", 1) for item in env if isinstance(item, str) and "=" in item
        )
    val = env.get("WRFCOIN_REQUIRE_PRODUCER_AUTH")
    if val is None:
        missing.append(name)
    elif str(val).strip() != "1":
        wrong.append((name, val))

if absent:
    print(
        f"ERROR: {path}: expected chain node service(s) not found: {', '.join(absent)}.\n"
        "       If a node was renamed, update CHAIN_NODES in this script — an\n"
        "       unrecognised name silently shrinks this guard's coverage.",
        file=sys.stderr,
    )
if missing:
    print(
        f"ERROR: {path}: chain node(s) {', '.join(missing)} do not set\n"
        "       WRFCOIN_REQUIRE_PRODUCER_AUTH.\n"
        "       Without it, a mistyped or missing WRFCOIN_NETWORK_ID seeds NO\n"
        "       producer set and the chain starts UNENFORCED with nothing to say\n"
        "       so. Add:  WRFCOIN_REQUIRE_PRODUCER_AUTH: \"1\"   (#2502)",
        file=sys.stderr,
    )
for name, val in wrong:
    print(
        f"ERROR: {path}: {name} sets WRFCOIN_REQUIRE_PRODUCER_AUTH={val!r}, expected \"1\".",
        file=sys.stderr,
    )

if absent or missing or wrong:
    sys.exit(1)
print(f"ok: every chain node in {path} requires producer auth ({', '.join(nodes)})")
PY
}

self_test() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN

  # A compose that satisfies the rule must PASS.
  cat >"${tmp}/good.yml" <<'YML'
services:
  wrfcoin-node:
    environment:
      WRFCOIN_NETWORK_ID: testnet
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "1"
  wrfcoin-seed:
    environment:
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "1"
YML
  check "${tmp}/good.yml" >/dev/null || { echo "self-test FAILED: good fixture rejected" >&2; exit 1; }

  # Each failure mode must be REJECTED. A guard that cannot fail is not a guard.
  cat >"${tmp}/missing.yml" <<'YML'
services:
  wrfcoin-node:
    environment:
      WRFCOIN_NETWORK_ID: testnet
  wrfcoin-seed:
    environment:
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "1"
YML
  if check "${tmp}/missing.yml" >/dev/null 2>&1; then
    echo "self-test FAILED: a node missing the flag was accepted" >&2; exit 1
  fi

  cat >"${tmp}/wrong.yml" <<'YML'
services:
  wrfcoin-node:
    environment:
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "0"
  wrfcoin-seed:
    environment:
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "1"
YML
  if check "${tmp}/wrong.yml" >/dev/null 2>&1; then
    echo "self-test FAILED: WRFCOIN_REQUIRE_PRODUCER_AUTH=0 was accepted" >&2; exit 1
  fi

  cat >"${tmp}/renamed.yml" <<'YML'
services:
  wrfcoin-node-renamed:
    environment:
      WRFCOIN_REQUIRE_PRODUCER_AUTH: "1"
YML
  if check "${tmp}/renamed.yml" >/dev/null 2>&1; then
    echo "self-test FAILED: a renamed chain node silently passed" >&2; exit 1
  fi

  # The `- KEY=value` list form must be understood too, or a compose written in
  # that style would pass while setting nothing.
  cat >"${tmp}/listform.yml" <<'YML'
services:
  wrfcoin-node:
    environment:
      - WRFCOIN_REQUIRE_PRODUCER_AUTH=1
  wrfcoin-seed:
    environment:
      - WRFCOIN_NETWORK_ID=testnet
YML
  if check "${tmp}/listform.yml" >/dev/null 2>&1; then
    echo "self-test FAILED: list-form env with a missing flag was accepted" >&2; exit 1
  fi

  echo "check-producer-auth-required.sh self-test passed (5 fixtures)"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

check "${COMPOSE}"
