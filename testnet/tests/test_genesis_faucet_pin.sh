#!/usr/bin/env bash
# core4#3361 option B: a testnet cut must never again start a chain with no
# genesis faucet recipient. check-env-completeness.sh --cut refuses the cutting
# host; without --cut (every follower, every day) it only ever WARNs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# CHECK_SCRIPT lets the RED-first proof point this suite at a pre-change copy.
CHECK="${CHECK_SCRIPT:-$REPO_ROOT/testnet/check-env-completeness.sh}"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/genesis-faucet-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

ADDR="0xf72059c3b4a6d3c431920c3cf3e40dbf68a6b5d3"
ADDR_UPPER="0xF72059C3B4A6D3C431920C3CF3E40DBF68A6B5D3"
OTHER="0x1111111111111111111111111111111111111111"
ZERO="0x0000000000000000000000000000000000000000"

# Synthetic fixtures, except the real_pins_* cases at the end, which copy the
# committed testnet/cut-pins.env (never a real .env).
# The gate reads what wrfcoin-node RECEIVES from `docker compose config`, so an
# exported value in this shell would leak into every render: clear it.
unset WRFCOIN_GENESIS_FAUCET_ADDRESS
GENESIS=1111111111111111111111111111111111111111111111111111111111111111
node() { printf 'services:\n  wrfcoin-node:\n    image: busybox\n%s' "${1:-}"; }
node >"$ROOT/no-forward.yml"
# shellcheck disable=SC2016 # literal compose interpolations, not shell ones
node '    environment:
      WRFCOIN_GENESIS_FAUCET_ADDRESS: ${WRFCOIN_GENESIS_FAUCET_ADDRESS:-}
' >"$ROOT/forward.yml"
# The reviewer's three false PASSes (infra#1122 P1):
#  1. a wrong literal on wrfcoin-node while .env equals the pin
node "    environment:
      WRFCOIN_GENESIS_FAUCET_ADDRESS: '$OTHER'
" >"$ROOT/literal-wrong.yml"
#  2. forwarded only to another service
# shellcheck disable=SC2016
node '  wrfcoin-seed:
    image: busybox
    environment:
      WRFCOIN_GENESIS_FAUCET_ADDRESS: ${WRFCOIN_GENESIS_FAUCET_ADDRESS:-}
' >"$ROOT/seed-only.yml"
#  3. a key that merely shares the prefix
node '    environment:
      WRFCOIN_GENESIS_FAUCET_ADDRESS_NOTE: "x"
' >"$ROOT/prefix.yml"
printf 'services:\n  wrfcoin-seed:\n    image: busybox\n' >"$ROOT/no-node.yml"

printf 'WRFCOIN_CUT_CHAIN_ID=777\n' >"$ROOT/pins-777-unpinned.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_GENESIS_HASH=%s\nWRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=%s\n' "$GENESIS" "$ADDR" >"$ROOT/pins-777.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=f72059c3b4a6d3c431920c3cf3e40dbf68a6b5d3\n' >"$ROOT/pins-777-no0x.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=%s\n' "$ZERO" >"$ROOT/pins-777-zero.env"
printf 'WRFCOIN_CUT_CHAIN_ID=1\n' >"$ROOT/pins-main.env"

printf 'WRFCOIN_GENESIS_FAUCET_ADDRESS=%s\n' "$ADDR" >"$ROOT/host.env"
printf 'WRFCOIN_GENESIS_FAUCET_ADDRESS="%s"\n' "$ADDR_UPPER" >"$ROOT/host-upper.env"
printf 'WRFCOIN_GENESIS_FAUCET_ADDRESS=%s\n' "$OTHER" >"$ROOT/host-other.env"
printf 'WRFCOIN_GENESIS_FAUCET_ADDRESS=0xnot-an-address\n' >"$ROOT/host-bad.env"
printf 'WRFCOIN_GENESIS_FAUCET_ADDRESS=\n' >"$ROOT/host-empty.env"
: >"$ROOT/host-absent.env"
printf 'WRFCOIN_CHAIN_ID=1\n' >"$ROOT/host-main.env"

# The pins-to-node overlay render-cut-overlay.sh writes (infra#1122 P2).
bash "$REPO_ROOT/testnet/scripts/render-cut-overlay.sh" --pins "$ROOT/pins-777.env" --out "$ROOT/cut.yml" >/dev/null

# run NAME COMPOSE ENVFILE PINSFILE [--cut]
# COMPOSE may name several files, comma-separated, in override order.
run() {
  local name="$1" compose="$2" env="$3" pins="$4" f files=(); shift 4
  IFS=, read -r -a composes <<<"$compose"
  for f in "${composes[@]}"; do files+=(-f "$ROOT/$f"); done
  "$CHECK" "${files[@]}" --env "$ROOT/$env" --cut-pins "$ROOT/$pins" "$@" >"$ROOT/$name.out" 2>&1
}
show() { sed 's/^/  /' "$ROOT/$1.out" >&2; }
expect_pass() {
  local name="$1" pattern="$2"; shift 2
  if ! run "$name" "$@"; then echo "FAIL: $name: expected exit 0" >&2; show "$name"; exit 1; fi
  grep -qF -- "$pattern" "$ROOT/$name.out" || { echo "FAIL: $name: missing '$pattern'" >&2; show "$name"; exit 1; }
  echo "ok: $name"
}
expect_fail() {
  local name="$1" pattern="$2"; shift 2
  local rc=0
  run "$name" "$@" || rc=$?
  # Exit 1 is the gate's refusal; exit 2 (unknown argument) is not.
  [ "$rc" -eq 1 ] || { echo "FAIL: $name: expected exit 1, got $rc" >&2; show "$name"; exit 1; }
  grep -qF -- "$pattern" "$ROOT/$name.out" || { echo "FAIL: $name: missing '$pattern'" >&2; show "$name"; exit 1; }
  echo "ok: $name"
}
expect_no() {
  local name="$1" pattern="$2"
  if grep -qF -- "$pattern" "$ROOT/$name.out"; then echo "FAIL: $name: unexpected '$pattern'" >&2; show "$name"; exit 1; fi
}

# --cut on a faucet chain: refused unless wrfcoin-node RECEIVES the pinned address.
expect_fail cut_777_unpinned_red   'ERROR WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS: chain 777 funds a faucet slice' forward.yml host.env        pins-777-unpinned.env --cut
expect_fail cut_777_pin_no0x_red   'ERROR WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS in'      forward.yml host.env        pins-777-no0x.env --cut
expect_fail cut_777_pin_zero_red   'ERROR WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS in'      forward.yml host.env        pins-777-zero.env --cut
expect_fail cut_777_host_absent_red 'wrfcoin-node does not receive it'                forward.yml host-absent.env pins-777.env --cut
expect_fail cut_777_host_empty_red  'wrfcoin-node does not receive it'                forward.yml host-empty.env  pins-777.env --cut
expect_fail cut_777_host_bad_red   'the value wrfcoin-node receives must be 0x'       forward.yml host-bad.env    pins-777.env --cut
expect_fail cut_777_mismatch_red   'the value wrfcoin-node receives does not match'   forward.yml host-other.env  pins-777.env --cut
expect_fail cut_777_not_forwarded_red 'wrfcoin-node does not receive it'              no-forward.yml host.env     pins-777.env --cut
# infra#1122 P1: each of these printed "passed to the node" under the text grep.
expect_fail cut_777_literal_wrong_red 'the value wrfcoin-node receives does not match' literal-wrong.yml host.env  pins-777.env --cut
expect_fail cut_777_seed_only_red  'wrfcoin-node does not receive it'                 seed-only.yml host.env      pins-777.env --cut
expect_fail cut_777_prefix_key_red 'wrfcoin-node does not receive it'                 prefix.yml host.env         pins-777.env --cut
expect_fail cut_777_no_node_red    'no wrfcoin-node service'                          no-node.yml host.env        pins-777.env --cut
# An exported shell value overrides .env in the render, and the gate sees it.
WRFCOIN_GENESIS_FAUCET_ADDRESS="$OTHER" expect_fail cut_777_exported_override_red 'the value wrfcoin-node receives does not match' forward.yml host.env pins-777.env --cut
expect_pass cut_777_match          'genesis faucet: wrfcoin-node receives a valid address equal to the cut pin' forward.yml host.env       pins-777.env --cut
expect_pass cut_777_match_case     'genesis faucet: wrfcoin-node receives a valid address equal to the cut pin' forward.yml host-upper.env pins-777.env --cut
# infra#1122 P2: the render-cut-overlay.sh literal alone is enough, with no .env line.
expect_pass cut_777_overlay_literal 'genesis faucet: wrfcoin-node receives a valid address equal to the cut pin' no-forward.yml,cut.yml host-absent.env pins-777.env --cut
for out in "$ROOT"/cut_777_*.out; do
  if grep -qiF -- "${ADDR#0x}" "$out" || grep -qiF -- "${OTHER#0x}" "$out"; then
    echo "FAIL: $(basename "$out" .out): printed an address value" >&2; exit 1
  fi
done
echo "ok: no_value_printed"

# New testnet identity is determined from the pins, not a runtime 777 default.
printf 'WRFCOIN_CUT_CHAIN_ID=888\nWRFCOIN_CUT_NETWORK_ID=testnet\n' >"$ROOT/pins-888.env"
expect_fail cut_888_unpinned_red 'chain 888 funds a faucet slice' no-forward.yml host-absent.env pins-888.env --cut

# Mainnet: 0 bps faucet share, never required — even at a cut.
expect_pass cut_main_not_required  'genesis faucet: not required'                   no-forward.yml host-main.env pins-main.env --cut

# Steady state (followers, daily gate): never an ERROR.
expect_pass steady_777_unpinned_warns 'WARN  WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS: chain predates #3361; faucet unbound until option A' no-forward.yml host-absent.env pins-777-unpinned.env
expect_pass steady_777_pinned_absent_ok 'PASS: every required variable'             no-forward.yml host-absent.env pins-777.env
expect_no   steady_777_pinned_absent_ok 'genesis faucet:'
expect_pass steady_777_mismatch_warns 'WARN  WRFCOIN_GENESIS_FAUCET_ADDRESS: set on this host but does not match' no-forward.yml host-other.env pins-777.env
expect_pass steady_777_malformed_pin_warns 'WARN  WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS in' no-forward.yml host-absent.env pins-777-no0x.env
expect_pass steady_main_silent      'PASS: every required variable'                 no-forward.yml host-main.env pins-main.env
expect_no   steady_main_silent      'GENESIS_FAUCET_ADDRESS'

# The committed pins must stay parseable by this gate. They pin chain 888, which
# funds a faucet slice and pins its address, so the chain-777 "predates #3361"
# WARN is covered above by synthetic pins only. A follower configured the way
# join-testnet-sync-node.sh / operator-install.sh leave it declares chain 888.
cp "$REPO_ROOT/testnet/cut-pins.env" "$ROOT/real-pins.env"
real_chain="$(sed -n 's/^WRFCOIN_CUT_CHAIN_ID=//p' "$ROOT/real-pins.env")"
sed -n 's/^WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=/WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=/p' "$ROOT/real-pins.env" >"$ROOT/host-follower-nochain.env"
{ cat "$ROOT/host-follower-nochain.env"; printf 'WRFCOIN_CHAIN_ID=%s\n' "$real_chain"; } >"$ROOT/host-follower.env"
cat "$ROOT/host-follower.env" "$ROOT/host.env" >"$ROOT/host-real.env"
cat "$ROOT/host-follower.env" "$ROOT/host-other.env" >"$ROOT/host-real-other.env"
expect_pass real_pins_steady_ok 'PASS: every required variable' no-forward.yml host-follower.env real-pins.env
expect_no   real_pins_steady_ok 'faucet unbound'
# A follower whose .env lacks WRFCOIN_CHAIN_ID boots as 777 under compose's
# ${WRFCOIN_CHAIN_ID:-777}: that must stay an ERROR against the committed pins.
expect_fail real_pins_absent_chain_red 'persisted WRFCOIN_CHAIN_ID differs from cut pins' no-forward.yml host-follower-nochain.env real-pins.env
expect_pass real_pins_cut_match 'genesis faucet: wrfcoin-node receives a valid address equal to the cut pin' forward.yml host-real.env real-pins.env --cut
expect_fail real_pins_cut_mismatch_red 'the value wrfcoin-node receives does not match' forward.yml host-real-other.env real-pins.env --cut
expect_fail real_pins_cut_unforwarded_red 'wrfcoin-node does not receive it' no-forward.yml host-real.env real-pins.env --cut

echo "PASS: genesis faucet pin (core4#3361)"
