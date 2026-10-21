#!/usr/bin/env bash
# boot-heal.sh must be able to cold-start the stack.
#
# Every fault this guards against was invisible on a running system and only
# appeared when the N5 came up from cold on 2026-08-06, taking the testnet down
# for ~40 minutes. A running stack cannot detect any of them, which is why these
# are static assertions on the script rather than a health check.
#
# What this canNOT check, stated plainly so a green run is not over-read: that a
# real cold boot succeeds. That needs a machine to reboot. These assertions catch
# the specific regressions that were measured, not the class.
#
# Run: bash scripts/tests/test-boot-heal-cold-start.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/testnet/boot-heal.sh"
COMPOSE_INPUTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/testnet/lib/compose-inputs.sh"
fails=0
assertions=0

check() {
  local name="$1" ; shift
  assertions=$((assertions + 1))
  if "$@"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    fails=$((fails + 1))
  fi
}

# ---------------------------------------------------------------------------
# 1. The advertised-address proof must not gate `compose up`.
#
# The guard dials our own P2P port and requires an answer. On a cold boot the
# thing that answers is the node the script has not started yet, so running it
# first is unsatisfiable: it passed on shutdown (node still up) and could never
# pass on boot. Measured 2026-08-06 — the stack never started.
# ---------------------------------------------------------------------------
guard_not_before_up() {
  # In the start path, the first `compose up -d` must appear before any
  # bare `guard_external_address` call.
  local up_line guard_line
  up_line=$(grep -n '^\s*compose up -d' "$SCRIPT" | head -1 | cut -d: -f1)
  guard_line=$(grep -n '^\s*guard_external_address$' "$SCRIPT" | head -1 | cut -d: -f1)
  [[ -z "$guard_line" ]] && return 0          # no bare pre-up call at all: good
  [[ -n "$up_line" ]] && (( up_line < guard_line ))
}
check "advertised-address proof does not gate compose up" guard_not_before_up

# ---------------------------------------------------------------------------
# 2. `--stop` must not run the guard.
#
# It passes there for the wrong reason (the node is still running), and a
# failure must never block a shutdown.
# ---------------------------------------------------------------------------
stop_path_has_no_guard() {
  ! awk '/--stop\)/,/;;/' "$SCRIPT" | grep -q 'guard_external_address'
}
check "--stop path does not run the guard" stop_path_has_no_guard

# ---------------------------------------------------------------------------
# 3. The cut overlays must be in the compose set.
#
# docker-compose.cut.yml carries the node's genesis pin; without it the node
# falls back to the binary's compiled-in TESTNET_GENESIS_HASH, which after a cut
# is the RETIRED genesis, and refuses to start (#2035).
#
# docker-compose.cut-miner.yml carries the producer's authorized payout address;
# without it every mine returns 500 and the chain stalls silently (#2290 §R2).
#
# docker-compose.cut-genesis-seed.yml is the same fault for the SEED. cut.yml
# pins only `wrfcoin-node`; an unpinned seed resolves its genesis from the
# binary's compiled-in TESTNET_GENESIS_HASH — the retired chain — and
# crash-loops. Measured on CT 101 2026-08-06: the seed had been restarting since
# the prior boot while the node ran fine, so the stack looked healthy from
# outside. The overlay existed in the repo the whole time; nothing listed it.
#
# All measured on cold boots. None of these failures resembles a missing overlay
# from the outside.
#
# The assertion reads the `for extra in ... ; do` list SPECIFICALLY, not the
# whole script. A bare `grep -q <overlay> "$SCRIPT"` is vacuous: these overlays
# are named in the prose above the list, so the grep matches even when the
# overlay has been removed from the list. Caught by running exactly that RED
# control against this file — it passed with the fix reverted.
# ---------------------------------------------------------------------------
compose_extras_list() {
  # Everything between `for extra in` and the terminating `; do`, comments
  # stripped, so only real list members can satisfy the check.
  awk '/^[[:space:]]*for extra in/,/do$/' "$COMPOSE_INPUTS" | sed 's/#.*//'
}

for overlay in docker-compose.cut.yml docker-compose.cut-miner.yml \
               docker-compose.cut-genesis-seed.yml; do
  # The single-quoted program is intentionally expanded by the nested shell.
  # shellcheck disable=SC2016
  check "compose set includes ${overlay}" \
    bash -c 'compose_extras_list() { awk "/^[[:space:]]*for extra in/,/do\$/" "$1" | sed "s/#.*//"; }; compose_extras_list "$1" | grep -q -- "$2"' _ "$COMPOSE_INPUTS" "${overlay}"
done

# ---------------------------------------------------------------------------
# 3b. The seed overlay must actually pin a genesis, not merely be listed.
#
# Naming the file in boot-heal.sh is worthless if the file stops setting
# WRFCOIN_GENESIS_HASH for wrfcoin-seed. An absent, empty, or ${VAR}-interpolated
# value all fall through to the compiled-in default — which IS the failure being
# guarded — so the pin must be a non-empty literal against the seed service.
# ---------------------------------------------------------------------------
SEED_OVERLAY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/testnet/docker-compose.cut-genesis-seed.yml"

seed_overlay_targets_the_seed() {
  [[ -f "$SEED_OVERLAY" ]] && grep -qE '^[[:space:]]*wrfcoin-seed:' "$SEED_OVERLAY"
}
check "seed overlay targets wrfcoin-seed" seed_overlay_targets_the_seed

seed_overlay_pins_a_literal() {
  [[ -f "$SEED_OVERLAY" ]] || return 1
  grep -qE "^[[:space:]]*WRFCOIN_GENESIS_HASH:[[:space:]]*'?(0x)?[0-9a-fA-F]{64}'?[[:space:]]*$" "$SEED_OVERLAY"
}
check "seed overlay pins a literal 64-hex genesis (not \${VAR})" seed_overlay_pins_a_literal

# ---------------------------------------------------------------------------
# 4. The guard must still run somewhere.
#
# Deleting it would make 1-2 pass trivially. It is a real check with a real
# purpose — a wrong advertised address makes remote peers fail SILENTLY — so it
# must survive, just later.
# ---------------------------------------------------------------------------
check "guard still runs after the stack is up" \
  grep -q 'guard_external_address_after_up' "$SCRIPT"

# ---------------------------------------------------------------------------
# 5. Boot must never build.
#
# `docker compose up` asks bake to prepare EVERY image in the file set, not just
# the services being started. On CT 101 that includes oracle-reference, whose
# build context does not exist — so a service that was not being started aborted
# the whole stack. Measured 2026-08-06.
# ---------------------------------------------------------------------------
boot_never_builds() {
  # No `compose up -d` anywhere without --no-build. Written as "every occurrence
  # carries the flag" rather than "no bare occurrences exist", so the helper's
  # own definition is not a false positive and a new bare call still fails.
  ! grep -E '^[[:space:]]*compose up -d' "$SCRIPT" | grep -qv -- '--no-build'
}
check "boot path never builds images" boot_never_builds
check "reconciliation carries --no-build" grep -q 'compose up -d --no-build' "$SCRIPT"

printf '\n'
if (( fails > 0 )); then
  printf 'FAIL: %d cold-start assertion(s) failed\n' "$fails"
  exit 1
fi
printf 'PASS: boot-heal.sh can cold-start (%d assertions)\n' "${assertions}"
