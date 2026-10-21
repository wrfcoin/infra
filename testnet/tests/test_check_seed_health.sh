#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../check-seed-health.sh
source "${SCRIPT_DIR}/../check-seed-health.sh"

TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0

test_pass() {
  TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

test_fail() {
  TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
}

lookup_dnsaddr_records() {
  case "$1" in
    bootstrap.libp2p.example)
      printf '%s\n' 'dnsaddr=/dns6/seed6.example.net/tcp/9005/p2p/12D3KooWDnsAddr'
      ;;
    *)
      return 1
      ;;
  esac
}

assert_host_port() {
  local name="$1"
  local multiaddr="$2"
  local expected_host="$3"
  local expected_port="$4"
  local parsed host port

  if ! parsed=$(extract_host_port "$multiaddr"); then
    test_fail "${name}: parser returned non-zero"
    return
  fi

  IFS=$'\t' read -r host port <<<"$parsed"
  if [ "$host" = "$expected_host" ] && [ "$port" = "$expected_port" ]; then
    test_pass "${name}: ${host}:${port}"
  else
    test_fail "${name}: expected ${expected_host}:${expected_port}, got ${host}:${port}"
  fi
}

assert_positional_args() {
  PROBE_MODE=0
  FIX_MODE=0
  POSITIONAL_PEERS=()

  parse_args --probe --fix -- \
    /ip4/192.0.2.20/tcp/9000/p2p/12D3KooWPositional1 \
    /dns/seed.example.net/tcp/9001/p2p/12D3KooWPositional2

  if [ "$PROBE_MODE" -eq 1 ] && [ "$FIX_MODE" -eq 1 ] && [ "${#POSITIONAL_PEERS[@]}" -eq 2 ]; then
    test_pass "parse_args captures positional multiaddrs after --"
  else
    test_fail "parse_args did not preserve flags and explicit multiaddrs"
  fi
}

cases=(
  "ip4|/ip4/192.0.2.10/tcp/9000/p2p/12D3KooWIp4|192.0.2.10|9000"
  "ip6|/ip6/2001:db8::10/tcp/9001/p2p/12D3KooWIp6|2001:db8::10|9001"
  "dns|/dns/seed.example.net/tcp/9002/p2p/12D3KooWDns|seed.example.net|9002"
  "dns4|/dns4/seed4.example.net/tcp/9003/p2p/12D3KooWDns4|seed4.example.net|9003"
  "dns6|/dns6/seed6.example.net/tcp/9004/p2p/12D3KooWDns6|seed6.example.net|9004"
  "dnsaddr|/dnsaddr/bootstrap.libp2p.example/p2p/12D3KooWDnsAddr|seed6.example.net|9005"
)

for case_entry in "${cases[@]}"; do
  IFS='|' read -r name multiaddr expected_host expected_port <<<"$case_entry"
  assert_host_port "$name" "$multiaddr" "$expected_host" "$expected_port"
done

assert_positional_args

if [ "$TEST_FAIL_COUNT" -gt 0 ]; then
  echo
  printf 'Failed %d of %d assertions\n' "$TEST_FAIL_COUNT" "$((TEST_PASS_COUNT + TEST_FAIL_COUNT))"
  exit 1
fi

echo
printf 'Passed %d assertions\n' "$TEST_PASS_COUNT"
