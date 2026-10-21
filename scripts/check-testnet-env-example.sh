#!/usr/bin/env bash
# Verify testnet/.env.testnet.example covers setup-env.sh and compose vars.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TESTNET_DIR="${REPO_ROOT}/testnet"
ENV_EXAMPLE="${TESTNET_DIR}/.env.testnet.example"
SETUP_ENV="${TESTNET_DIR}/setup-env.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_assignment() {
  local var="$1"
  grep -Eq "^(# ?)?${var}=" "${ENV_EXAMPLE}" || fail "${var} missing from testnet/.env.testnet.example"
}

require_active_var() {
  local var="$1"
  grep -Eq "^${var}=" "${ENV_EXAMPLE}" || fail "${var} missing from testnet/.env.testnet.example"
}

require_value() {
  local var="$1"
  local expected="$2"
  grep -Eq "^${var}=${expected}$" "${ENV_EXAMPLE}" || fail "${var} does not match expected placeholder/value"
}

while IFS= read -r var; do
  require_assignment "$var"
done < <(
  rg -o -P '(?<!\$)\$\{[A-Z0-9_]+(?::[^}]*)?\}' "${TESTNET_DIR}"/docker-compose*.yml |
    sed -E 's/.*\$\{([A-Z0-9_]+).*/\1/' |
    sort -u
)

# infra#627: AlertManager delivery is webhook-only (alert-receiver -> ntfy/
# Telegram). The SMTP/email vars were removed; ALERT_FORWARD_* replaced them.
for generated_var in \
  POSTGRES_PASSWORD REDIS_PASSWORD JWT_SECRET OAUTH_STATE_SECRET \
  API_KEY_ENCRYPTION_KEY GRAFANA_ADMIN_PASSWORD PROMETHEUS_ADMIN_PASSWORD \
  PROMETHEUS_BEARER_TOKEN WRFCOIN_OPERATOR_TOKEN WRFCOIN_CONTRIBUTOR_TOKEN \
  WRFCOIN_ORACLE_TOKEN WRFCOIN_READER_TOKEN ALERTMANAGER_WEBHOOK_URL \
  ALERT_FORWARD_URL ALERT_FORWARD_FORMAT CORS_ORIGIN GRAFANA_ADMIN_USER
do
  grep -Eq "^${generated_var}=" "${SETUP_ENV}" || fail "setup-env.sh does not generate ${generated_var}"
  require_active_var "$generated_var"
done

require_value API_KEY_ENCRYPTION_KEY 'REPLACE_with_hex_32_bytes'
require_value ENCRYPTION_KEY 'REPLACE_with_hex_32_bytes'
grep -q 'Rotate before any exposed testnet use' "${ENV_EXAMPLE}" || fail "WRFCOIN_HSM_SO_PIN rotation warning missing"

echo "PASS: testnet env example covers setup-env.sh and compose variables"
