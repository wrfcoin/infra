#!/usr/bin/env bash
# Validate that testnet/setup-env.sh generates a valid .env file and rendered
# AlertManager config.
# Checks: required variables present, non-empty, no dangerous characters,
# no duplicate secrets, config render success.
#
# Related: scripts/test-compose-smoke.sh, scripts/test-backend-node-connectivity.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/../testnet/setup-env.sh"

if [ ! -f "$SETUP_SCRIPT" ]; then
  echo "FAIL: setup-env.sh not found at ${SETUP_SCRIPT}"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# setup-env.sh writes .env relative to its own directory (SCRIPT_DIR).
# Copy the AlertManager template too so the rendered config step can run.
cp "$SETUP_SCRIPT" "$TMPDIR/setup-env.sh"
TEST_CUT_CHAIN_ID="${TEST_CUT_CHAIN_ID:-777}"
printf 'WRFCOIN_CUT_CHAIN_ID=%s\n' "$TEST_CUT_CHAIN_ID" > "$TMPDIR/cut-pins.env"
cp "${SCRIPT_DIR}/../testnet/alertmanager.yml" "$TMPDIR/alertmanager.yml"
cp "${SCRIPT_DIR}/../testnet/render-alertmanager-config.sh" "$TMPDIR/render-alertmanager-config.sh"
mkdir -p "$TMPDIR/scripts"
cp "$SCRIPT_DIR/../testnet/scripts/chain-identity.py" "$TMPDIR/scripts/chain-identity.py"
cp "${SCRIPT_DIR}/../testnet/scripts/validate-runtime-image.sh" "$TMPDIR/scripts/validate-runtime-image.sh"
cd "$TMPDIR"

echo "--- Running setup-env.sh ---"
# infra#627: delivery is webhook-only (alert-receiver -> ntfy/Telegram). SMTP was
# removed. Pass an explicit webhook URL to prove the render override still works,
# plus the forwarding vars that replaced the SMTP settings.
ALERTMANAGER_WEBHOOK_URL='http://wrfcoin-alert-receiver:19093/alerts' \
ALERT_FORWARD_URL='https://ntfy.sh/wrf-testnet-example' \
ALERT_FORWARD_FORMAT='ntfy' \
WRFCOIN_TESTNET_RUNTIME_IMAGE='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' \
  bash setup-env.sh
echo ""

ENV_FILE="$TMPDIR/.env"
if ! grep -Fxq "WRFCOIN_CHAIN_ID=$TEST_CUT_CHAIN_ID" "$ENV_FILE"; then
  echo "FAIL: generated chain identity differs from active cut pins"; exit 1
fi
if ! grep -Fxq 'WRFCOIN_MIN_WORK_FACTOR=0' "$ENV_FILE"; then
  echo "FAIL: generated testnet validation floor must be explicit 0"; exit 1
fi
if [ ! -f "$ENV_FILE" ]; then
  echo "FAIL: .env file was not created"
  exit 1
fi

# --- Check required variables ---
REQUIRED=(
  POSTGRES_PASSWORD
  REDIS_PASSWORD
  JWT_SECRET
  RPC_API_KEY
  ADMIN_TOKEN
  N8N_WEBHOOK_SECRET
  GRAFANA_ADMIN_PASSWORD
  ALERTMANAGER_WEBHOOK_URL
  PROMETHEUS_ADMIN_PASSWORD
  PROMETHEUS_BEARER_TOKEN
  WRFCOIN_OPERATOR_TOKEN
  WRFCOIN_CONTRIBUTOR_TOKEN
  WRFCOIN_ORACLE_TOKEN
  WRFCOIN_READER_TOKEN
  WRFCOIN_TESTNET_RUNTIME_IMAGE
  WRFCOIN_RUNTIME_IMAGE_PROFILE
  WRFCOIN_RUNTIME_IMAGE_CLASS
)

FAIL=0
for var in "${REQUIRED[@]}"; do
  value=$(grep "^${var}=" "$ENV_FILE" | cut -d= -f2- || true)
  if [ -z "$value" ]; then
    echo "FAIL: ${var} is empty or missing"
    FAIL=1
  fi
done

# Optional notification-forwarding settings should still be written, even if
# blank (infra#627: ALERT_FORWARD_* replaced the SMTP settings).
for line in \
  '^ALERTMANAGER_WEBHOOK_URL=' \
  '^ALERT_FORWARD_URL=' \
  '^ALERT_FORWARD_FORMAT='; do
  if ! grep -q "$line" "$ENV_FILE"; then
    echo "FAIL: ${line#^} line missing"
    FAIL=1
  fi
done

# --- Check for dangerous characters ---
# Null bytes and backticks can break shell expansion in Docker Compose.
if grep -P '[\x00`]' "$ENV_FILE" >/dev/null 2>&1; then
  echo "FAIL: dangerous characters (null byte or backtick) in .env"
  FAIL=1
fi

# --- Check for duplicate secret values ---
SECRETS=$(grep -E '^(POSTGRES_PASSWORD|REDIS_PASSWORD|JWT_SECRET|RPC_API_KEY|ADMIN_TOKEN|N8N_WEBHOOK_SECRET|GRAFANA_ADMIN_PASSWORD|PROMETHEUS_ADMIN_PASSWORD|PROMETHEUS_BEARER_TOKEN)=' "$ENV_FILE" | cut -d= -f2- | sort)
UNIQUE=$(echo "$SECRETS" | sort -u)
if [ "$SECRETS" != "$UNIQUE" ]; then
  echo "FAIL: duplicate secret values detected"
  FAIL=1
fi

OPERATOR_TOKEN_VALUE=$(sed -n 's/^WRFCOIN_OPERATOR_TOKEN=//p' "$ENV_FILE")
CONTRIBUTOR_TOKEN_VALUE=$(sed -n 's/^WRFCOIN_CONTRIBUTOR_TOKEN=//p' "$ENV_FILE")
if [ "$OPERATOR_TOKEN_VALUE" = "$CONTRIBUTOR_TOKEN_VALUE" ]; then
  echo "FAIL: contributor token reuses operator authority"
  FAIL=1
fi

# --- Check rendered AlertManager config ---
ALERTMANAGER_RENDERED="$TMPDIR/alertmanager.rendered.yml"
if [ ! -f "$ALERTMANAGER_RENDERED" ]; then
  echo "FAIL: alertmanager.rendered.yml was not created"
  FAIL=1
else
  if grep -q '__ALERTMANAGER_' "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: unresolved AlertManager placeholders remain in rendered config"
    FAIL=1
  fi
  if ! grep -q "url: 'http://wrfcoin-alert-receiver:19093/alerts'" "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config did not apply ALERTMANAGER_WEBHOOK_URL"
    FAIL=1
  fi
  # infra#627: delivery is webhook-only. The SMTP/email path was removed because
  # CT 101 has no MTA; assert it stays gone so a regression can't silently
  # reintroduce a dead critical channel.
  # Match active YAML keys only (ignore explanatory comments that mention smtp).
  if grep -qE "^[[:space:]]*(smtp_smarthost|smtp_from|smtp_auth_username|smtp_require_tls|email_configs):" "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config reintroduced SMTP/email delivery (removed in #627)"
    FAIL=1
  fi
  if ! grep -q "receiver: 'log-only'" "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config is missing the log-only default receiver"
    FAIL=1
  fi
  if ! grep -q "name: 'critical-notifications'" "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config is missing the critical-notifications receiver"
    FAIL=1
  fi
  if ! grep -q "name: 'log-only'" "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config is missing the log-only receiver"
    FAIL=1
  fi
  if ! awk '
    /service: backend/ { in_backend = 1; next }
    in_backend && /continue: true/ { found_continue = 1; exit }
    in_backend && /^    - match:/ { exit }
    END { exit found_continue ? 0 : 1 }
  ' "$ALERTMANAGER_RENDERED"; then
    echo "FAIL: rendered config does not let backend alerts continue to downstream routes"
    FAIL=1
  fi
fi

# --- Check file permissions ---
PERMS=$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null || echo "unknown")
if [ "$PERMS" != "600" ]; then
  echo "FAIL: .env permissions are ${PERMS}, expected 600"
  FAIL=1
fi

for generated in prometheus-web.yml prometheus-bearer-token; do
  path="$TMPDIR/$generated"
  mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null || echo "unknown")
  group=$(stat -c '%g' "$path" 2>/dev/null || echo "unknown")
  if [ "$mode" = "640" ] && [ "$group" = "${PROMETHEUS_CONTAINER_GID:-65534}" ]; then
    :
  elif [ "$mode" = "644" ]; then
    :
  else
    echo "FAIL: ${generated} permissions are mode=${mode} group=${group}; expected 0640 with Prometheus gid or 0644 fallback"
    FAIL=1
  fi
done

PROM_HASH=$(awk '/^  admin:/ { print $2 }' "$TMPDIR/prometheus-web.yml")
if [[ ! "$PROM_HASH" =~ ^\$2[abxy]\$[0-9][0-9]\$[A-Za-z0-9./]{53}$ ]]; then
  echo "FAIL: prometheus-web.yml admin hash is not valid bcrypt"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "FAIL: setup-env.sh output validation failed"
  exit 1
fi

echo "PASS: setup-env.sh output validates"
echo "  - ${#REQUIRED[@]} required variables present and non-empty"
echo "  - No dangerous characters"
echo "  - All secret values unique"
echo "  - AlertManager rendered config generated"
echo "  - File permissions: .env ${PERMS}; Prometheus files container-readable"
echo "  - Prometheus web config contains a valid bcrypt hash"
