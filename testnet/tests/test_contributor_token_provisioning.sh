#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="$ROOT/testnet/docker-compose.testnet.yml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

compose_env=(
  env -i "PATH=$PATH" HOME="${HOME:-/tmp}"
  POSTGRES_PASSWORD=ci REDIS_PASSWORD=ci JWT_SECRET=ci
  OAUTH_STATE_SECRET=ci RPC_API_KEY=ci ADMIN_TOKEN=ci
  N8N_WEBHOOK_SECRET=ci GRAFANA_ADMIN_PASSWORD=ci
  WRFCOIN_OPERATOR_TOKEN=operator-ci
  WRFCOIN_HSM_PIN=ci WRFCOIN_HSM_SO_PIN=ci
  WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
)

echo missing_contributor_token_red
set +e
# compose_env is the `env -i VAR=value ...` prefix array defined at the top of this file (assignments only).
# dynamic-payload-reviewed: contributor-token-missing-render-env-prefix
"${compose_env[@]}" bash "$ROOT/testnet/tests/render-testnet-compose.sh" -f "$COMPOSE" config --format json \
  >"$TMP/missing.json" 2>"$TMP/missing.err"
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'WRFCOIN_CONTRIBUTOR_TOKEN must be set' "$TMP/missing.err"

echo dedicated_token_reaches_node_and_backend
# compose_env is the `env -i VAR=value ...` prefix array defined at the top of this file (assignments only).
# dynamic-payload-reviewed: contributor-token-rendered-env-prefix
"${compose_env[@]}" WRFCOIN_CONTRIBUTOR_TOKEN=contributor-ci \
  bash "$ROOT/testnet/tests/render-testnet-compose.sh" -f "$COMPOSE" config --format json > "$TMP/rendered.json"
jq -e '
  .services["wrfcoin-node"].environment.WRFCOIN_CONTRIBUTOR_TOKEN == "contributor-ci" and
  .services["wrfcoin-backend"].environment.WRFCOIN_CONTRIBUTOR_TOKEN == "contributor-ci"
' "$TMP/rendered.json" >/dev/null

echo contributor_token_must_not_reuse_operator
cp "$ROOT/testnet/.env.testnet.example" "$TMP/duplicate.env"
sed -i 's/^WRFCOIN_OPERATOR_TOKEN=.*/WRFCOIN_OPERATOR_TOKEN=same-token/; s/^WRFCOIN_CONTRIBUTOR_TOKEN=.*/WRFCOIN_CONTRIBUTOR_TOKEN=same-token/' "$TMP/duplicate.env"
set +e
bash "$ROOT/testnet/check-env-completeness.sh" -f "$COMPOSE" --env "$TMP/duplicate.env" \
  >"$TMP/duplicate.out" 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -Fq 'WRFCOIN_CONTRIBUTOR_TOKEN must differ from WRFCOIN_OPERATOR_TOKEN' "$TMP/duplicate.out"

echo CONTRIBUTOR_TOKEN_PROVISIONING_TESTS=PASS
