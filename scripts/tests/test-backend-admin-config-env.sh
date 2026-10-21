#!/usr/bin/env bash
# backend#1329: compose passes the six admin config vars to wrfcoin-backend, empty by
# default (the backend then answers 503 CORE4_ADMIN_CONFIG_UNAVAILABLE), forwards a host
# value verbatim, and the env example documents each one with placeholders only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VARS=(WRFCOIN_GOVERNANCE_PROPOSER_ADDRESS WRFCOIN_ADMIN_GOVERNANCE_PROPOSAL_CONFIG WRFCOIN_MINING_REWARD_ADDRESS
      WRFCOIN_ADMIN_NFT_MINT_CONFIG WRFCOIN_ADMIN_NFT_TRANSFER_CONFIG WRFCOIN_ADMIN_STEALTH_CONFIG)
export POSTGRES_PASSWORD=x REDIS_PASSWORD=x WRFCOIN_OPERATOR_TOKEN=x WRFCOIN_CONTRIBUTOR_TOKEN=x \
  JWT_SECRET=x OAUTH_STATE_SECRET=x RPC_API_KEY=x ADMIN_TOKEN=x GRAFANA_ADMIN_PASSWORD=x N8N_WEBHOOK_SECRET=x
J="$(mktemp)"; trap 'rm -f "$J"' EXIT
fail() { echo "ADMIN_CONFIG_ENV=FAIL $*" >&2; exit 1; }
render() { bash "$ROOT/testnet/tests/render-testnet-compose.sh" -f "$ROOT/testnet/docker-compose.testnet.yml" config --format json >"$J" || fail "compose render failed"; }
val() { python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["services"]["wrfcoin-backend"]["environment"]; v=sys.argv[2]; print("<absent>" if v not in e else e[v])' "$J" "$1"; }

for v in "${VARS[@]}"; do unset "$v"; done
render
for v in "${VARS[@]}"; do [[ "$(val "$v")" == "" ]] || fail "$v must render empty when unset, got '$(val "$v")'"; done
echo "ok all six empty by default"

export WRFCOIN_GOVERNANCE_PROPOSER_ADDRESS=0x1111111111111111111111111111111111111111
export WRFCOIN_ADMIN_GOVERNANCE_PROPOSAL_CONFIG='{"proposal_id":"p1","parameter":"a","value":"b"}'
export WRFCOIN_MINING_REWARD_ADDRESS=0x2222222222222222222222222222222222222222
export WRFCOIN_ADMIN_NFT_MINT_CONFIG='{"id":"n1","owner":"0x3333333333333333333333333333333333333333"}'
export WRFCOIN_ADMIN_NFT_TRANSFER_CONFIG='{"id":"n1","to":"0x4444444444444444444444444444444444444444"}'
spend="$(printf 'a%.0s' {1..64})"; view="$(printf 'b%.0s' {1..64})"
# shellcheck disable=SC2089,SC2090 # the value is JSON: its quotes are meant literally
printf -v WRFCOIN_ADMIN_STEALTH_CONFIG '{"spend_key":"%s","view_key":"%s"}' "$spend" "$view"
# shellcheck disable=SC2090
export WRFCOIN_ADMIN_STEALTH_CONFIG
render
for v in "${VARS[@]}"; do [[ "$(val "$v")" == "${!v}" ]] || fail "$v was not forwarded verbatim"; done
echo "ok all six forwarded verbatim"

for v in "${VARS[@]}"; do grep -Eq "^# ${v}=" "$ROOT/testnet/.env.testnet.example" || fail "$v is not documented in .env.testnet.example"; done
echo "ok documented"
# No value in the example may look real: only zero addresses, example ids, or empty.
if grep -E '^# WRFCOIN_(GOVERNANCE_PROPOSER_ADDRESS|MINING_REWARD_ADDRESS)=0x' "$ROOT/testnet/.env.testnet.example" | grep -Ev '=0x0{40}$' >/dev/null; then fail "an example address is not the zero placeholder"; fi
grep -Eq '[0-9a-fA-F]{64}' <(sed -n '/Backend admin operation config/,/WRFCOIN_ADMIN_STEALTH_CONFIG=/p' "$ROOT/testnet/.env.testnet.example") && fail "a 64-hex value appears in the admin config block"
grep -q 'SECRET-CLASS: WRFCOIN_ADMIN_STEALTH_CONFIG' "$ROOT/testnet/.env.testnet.example" || fail "stealth config is not marked secret-class"
grep -Eq '^# WRFCOIN_ADMIN_STEALTH_CONFIG=$' "$ROOT/testnet/.env.testnet.example" || fail "stealth config example must be empty"
echo "ok placeholders only, stealth secret-class and empty"
echo "ADMIN_CONFIG_ENV=PASS"
