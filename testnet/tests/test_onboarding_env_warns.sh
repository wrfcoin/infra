#!/usr/bin/env bash
# infra#1113-adjacent (invitee onboarding dry run): check-env-completeness WARNs, never
# fails, when an invitee-facing backend variable is empty, naming the user-visible effect.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_ROOT/testnet/check-env-completeness.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/onboarding-env.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
printf 'WRFCOIN_CUT_CHAIN_ID=777\n' >"$ROOT/pins.env"
# A compose chain that passes the variables through (as testnet compose does) and one that does not.
cat >"$ROOT/with.yml" <<'YML'
services:
  wrfcoin-backend:
    environment:
      STATION_CHAIN_SYNC_ENABLED: ${STATION_CHAIN_SYNC_ENABLED:-}
      WRFCOIN_READER_TOKEN: ${WRFCOIN_READER_TOKEN:-}
      EXPLORER_FAUCET_ADDRESS: ${EXPLORER_FAUCET_ADDRESS:-}
      WRFCOIN_GOVERNANCE_CHAIN_ID: ${WRFCOIN_GOVERNANCE_CHAIN_ID:-}
      WRFCOIN_GOVERNANCE_NETWORK_ID: ${WRFCOIN_GOVERNANCE_NETWORK_ID:-}
      WRFCOIN_GOVERNANCE_SIGNING_VERSION: ${WRFCOIN_GOVERNANCE_SIGNING_VERSION:-}
YML
printf 'services: {}\n' >"$ROOT/without.yml"

run() { "$CHECK" -f "$1" --env "$2" --cut-pins "$ROOT/pins.env" >"$3" 2>&1; }
pass_with() { # NAME COMPOSE ENV  -> exit 0 required
  if ! run "$2" "$3" "$ROOT/$1.out"; then echo "FAIL: $1: WARNs must not fail the check" >&2; sed 's/^/  /' "$ROOT/$1.out" >&2; exit 1; fi
}
has() { grep -qF -- "$2" "$ROOT/$1.out" || { echo "FAIL: $1: missing '$2'" >&2; sed 's/^/  /' "$ROOT/$1.out" >&2; exit 1; }; }
hasnt() { ! grep -qF -- "$2" "$ROOT/$1.out" || { echo "FAIL: $1: unexpected '$2'" >&2; exit 1; }; }

: >"$ROOT/empty.env"
pass_with empty "$ROOT/with.yml" "$ROOT/empty.env"
has empty "WARN  STATION_CHAIN_SYNC_ENABLED: not 'true'"; has empty "awaiting activation"
has empty "WARN  WRFCOIN_READER_TOKEN: empty"; has empty "CORE4_READER_CREDENTIAL_UNCONFIGURED"
for v in CHAIN_ID NETWORK_ID SIGNING_VERSION; do has empty "WARN  WRFCOIN_GOVERNANCE_$v: empty"; done
has empty "cannot vote"
has empty "WARN  EXPLORER_FAUCET_ADDRESS: empty"
echo "ok empty env warns for every variable, exit 0"

cat >"$ROOT/good.env" <<'ENV'
STATION_CHAIN_SYNC_ENABLED=true
WRFCOIN_READER_TOKEN=reader-secret-value
WRFCOIN_GOVERNANCE_CHAIN_ID=777
WRFCOIN_GOVERNANCE_NETWORK_ID=testnet
WRFCOIN_GOVERNANCE_SIGNING_VERSION=1
ENV
pass_with good "$ROOT/with.yml" "$ROOT/good.env"
hasnt good "WARN  STATION_CHAIN_SYNC"; hasnt good "WARN  WRFCOIN_READER_TOKEN"; hasnt good "WARN  WRFCOIN_GOVERNANCE"
hasnt good "reader-secret-value"
echo "ok fully configured env is quiet and never prints a value"

printf 'STATION_CHAIN_SYNC_ENABLED=false\nWRFCOIN_READER_TOKEN=x\nWRFCOIN_GOVERNANCE_CHAIN_ID=777\nWRFCOIN_GOVERNANCE_NETWORK_ID=testnet\nWRFCOIN_GOVERNANCE_SIGNING_VERSION=3\n' >"$ROOT/bad.env"
pass_with bad "$ROOT/with.yml" "$ROOT/bad.env"
has bad "WARN  STATION_CHAIN_SYNC_ENABLED: not 'true'"; has bad "WARN  WRFCOIN_GOVERNANCE_SIGNING_VERSION: not 1 or 2"
echo "ok 'false' and an invalid signing version warn"

printf '# STATION_CHAIN_SYNC_ENABLED=true\n' >"$ROOT/commented.env"
pass_with commented "$ROOT/with.yml" "$ROOT/commented.env"; has commented "WARN  STATION_CHAIN_SYNC_ENABLED"
echo "ok a commented line does not count"

pass_with without "$ROOT/without.yml" "$ROOT/empty.env"
hasnt without "WARN  STATION_CHAIN_SYNC"; hasnt without "WARN  WRFCOIN_READER_TOKEN"; hasnt without "WARN  WRFCOIN_GOVERNANCE"
echo "ok a chain that does not pass the variables is not warned"

# The real testnet compose must trigger the warnings on an empty env.
: >"$ROOT/real-empty.env"
if "$CHECK" -f "$REPO_ROOT/testnet/docker-compose.testnet.yml" --env "$ROOT/real-empty.env" --cut-pins "$ROOT/pins.env" >"$ROOT/real.out" 2>&1; then :; fi
grep -qF "WARN  STATION_CHAIN_SYNC_ENABLED" "$ROOT/real.out" || { echo "FAIL: real compose does not trigger the warning" >&2; exit 1; }
echo "ok real testnet compose triggers the warnings"
# The env example must not call STATION_CHAIN_SYNC_LABELS a comma-separated list (it is a JSON object).
! grep -qi 'LABELS is a comma-separated' "$REPO_ROOT/testnet/.env.testnet.example" || { echo "FAIL: env example still calls LABELS comma-separated" >&2; exit 1; }
grep -qF '# STATION_CHAIN_SYNC_LABELS={}' "$REPO_ROOT/testnet/.env.testnet.example" || { echo "FAIL: env example lacks the {} empty value" >&2; exit 1; }
echo "ok env example documents LABELS as a JSON object with {} as the empty value"
echo "ONBOARDING_ENV_WARNS=PASS"
