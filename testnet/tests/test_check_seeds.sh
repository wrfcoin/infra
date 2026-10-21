#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${SCRIPT_DIR}/../check-seeds.sh"
FIXTURES="${SCRIPT_DIR}/fixtures/check-seeds"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

public_output="$({
  SEEDS_FILE="${FIXTURES}/public-seeds.txt" \
  CUT_PINS_FILE="${FIXTURES}/public-cut-pins.env" \
    bash "$CHECKER" --print
})"
expected_public='BOOTSTRAP_PEERS=/ip4/198.51.100.42/tcp/9000/p2p/12D3KooWSyntheticPublic'
[ "$public_output" = "$expected_public" ] || fail "pinned_bootstrap_present_green"
echo 'PASS: pinned_bootstrap_present_green'

if SEEDS_FILE="${FIXTURES}/lan-seeds.txt" \
  CUT_PINS_FILE="${FIXTURES}/lan-cut-pins.env" \
  bash "$CHECKER" >/dev/null 2>&1; then
  fail "mutation_lan_ip_red"
fi
echo 'PASS: mutation_lan_ip_red'

if SEEDS_FILE="${FIXTURES}/mismatch-seeds.txt" \
  CUT_PINS_FILE="${FIXTURES}/public-cut-pins.env" \
  bash "$CHECKER" >/dev/null 2>&1; then
  fail "mutation_peer_id_mismatch_red"
fi
echo 'PASS: mutation_peer_id_mismatch_red'

lan_output="$({
  SEEDS_FILE="${FIXTURES}/lan-seeds.txt" \
  CUT_PINS_FILE="${FIXTURES}/lan-cut-pins.env" \
    bash "$CHECKER" --allow-lan --print
})"
expected_lan='BOOTSTRAP_PEERS=/ip4/192.168.40.9/tcp/9000/p2p/12D3KooWSyntheticLan'
[ "$lan_output" = "$expected_lan" ] || fail "allow_lan_flag_permits_lan"
echo 'PASS: allow_lan_flag_permits_lan'
