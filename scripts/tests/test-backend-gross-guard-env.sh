#!/usr/bin/env bash
# infra#1111: compose passes REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT to wrfcoin-backend,
# empty by default (unscheduled), and forwards a host value verbatim.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export POSTGRES_PASSWORD=x REDIS_PASSWORD=x WRFCOIN_OPERATOR_TOKEN=x WRFCOIN_CONTRIBUTOR_TOKEN=x \
  JWT_SECRET=x OAUTH_STATE_SECRET=x RPC_API_KEY=x ADMIN_TOKEN=x GRAFANA_ADMIN_PASSWORD=x N8N_WEBHOOK_SECRET=x
J="$(mktemp)"; trap 'rm -f "$J"' EXIT
fail() { echo "GROSS_GUARD_ENV=FAIL $*" >&2; exit 1; }
render() { bash "$ROOT/testnet/tests/render-testnet-compose.sh" -f "$ROOT/testnet/docker-compose.testnet.yml" config --format json >"$J" || fail "compose render failed"; }
val() { python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["services"]["wrfcoin-backend"]["environment"]; print("<absent>" if "REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT" not in e else repr(e["REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT"]))' "$J"; }

unset REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT
render; [[ "$(val)" == "''" ]] || fail "unset host value must render empty (unscheduled); got $(val)"
echo "ok default empty"
REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT=123456 render; [[ "$(val)" == "'123456'" ]] || fail "host value not forwarded; got $(val)"
echo "ok forwarded"
grep -Eq '^# ?REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT=' "$ROOT/testnet/.env.testnet.example" || fail "not documented in .env.testnet.example"
echo "ok documented"
grep -q 'REFERENCE_GROSS_GUARD_ACTIVATION_HEIGHT' "$ROOT/testnet/UPGRADE_RUNBOOK.md" || fail "runbook does not mention it"
echo "ok runbook"
echo "GROSS_GUARD_ENV=PASS"
