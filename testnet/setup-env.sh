#!/usr/bin/env bash
# Generate .env for WRFCoin testnet deployment with random secrets.
# Run once on initial setup. Prints credentials to stdout — save them.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARNING: $*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

make_prometheus_container_readable() {
  local file="$1"
  local gid="${PROMETHEUS_CONTAINER_GID:-65534}"

  # prom/prometheus runs as uid/gid 65534. These files are bind-mounted
  # read-only into the container, so 0600 root:root makes Prometheus crash
  # before startup. Prefer group-readable secrets for gid 65534; fall back
  # to world-readable only when chgrp is unavailable for non-root setup.
  if chgrp "$gid" "$file" 2>/dev/null; then
    chmod 640 "$file"
  else
    chmod 644 "$file"
    warn "Could not chgrp ${file} to gid ${gid}; using mode 0644 so prom/prometheus can read the bind mount."
  fi
}

has_python_bcrypt() {
  command -v python3 >/dev/null 2>&1 && python3 -c "import bcrypt" >/dev/null 2>&1
}

detect_compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf '%s' 'docker compose'
    return 0
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    printf '%s' 'docker-compose'
    return 0
  fi

  return 1
}

# prereq checks stay light so the script can still generate files on a
# fresh host, but it will tell operators what they still need before startup.
require_cmd openssl
require_cmd python3

RUNTIME_IMAGE_PROFILE="${WRFCOIN_RUNTIME_IMAGE_PROFILE:-public-release}"
RUNTIME_IMAGE="${WRFCOIN_TESTNET_RUNTIME_IMAGE:-}"
RUNTIME_IMAGE_GATE="${SCRIPT_DIR}/scripts/validate-runtime-image.sh"
[[ -x "$RUNTIME_IMAGE_GATE" ]] || die "runtime-image validator missing or not executable: ${RUNTIME_IMAGE_GATE}"
if ! "$RUNTIME_IMAGE_GATE" --profile "$RUNTIME_IMAGE_PROFILE" --image "$RUNTIME_IMAGE"; then
  die "refusing to generate deploy configuration without an accepted runtime image"
fi
if [[ "$RUNTIME_IMAGE_PROFILE" == developer || "$RUNTIME_IMAGE_PROFILE" == demo ]]; then
  RUNTIME_IMAGE_CLASS="NON_RELEASE"
  warn "NON_RELEASE developer runtime image selected: ${RUNTIME_IMAGE}"
else
  RUNTIME_IMAGE_CLASS="IMMUTABLE"
fi

if [ -f "$ENV_FILE" ]; then
  die "${ENV_FILE} already exists. Remove it first if you want to regenerate."
fi

# Public cut identity is validated before any configuration or secret generation.
CUT_PINS_FILE="${CUT_PINS_FILE:-${SCRIPT_DIR}/cut-pins.env}"
CHAIN_ID="$(python3 "${SCRIPT_DIR}/scripts/chain-identity.py" --pins "$CUT_PINS_FILE" --print-chain)" \
  || die "cut chain identity unavailable or inconsistent"

# Hex keeps the generated secrets URL-safe for DATABASE_URL and REDIS_URL.
PG_PW=$(openssl rand -hex 16)
REDIS_PW=$(openssl rand -hex 16)
# Backend-only JWT secret (not used by the blockchain node).
JWT=$(openssl rand -hex 32)
OAUTH_STATE=$(openssl rand -hex 32)
API_KEY_ENCRYPTION_KEY=$(openssl rand -hex 32)
ENCRYPTION_KEY=$(openssl rand -hex 32)
# Backend operator-route credentials. These are distinct from node RBAC tokens.
RPC_API_KEY=$(openssl rand -hex 32)
ADMIN_TOKEN=$(openssl rand -hex 32)
N8N_WEBHOOK_SECRET=$(openssl rand -hex 32)
GRAF_PW=$(openssl rand -hex 16)
# Prometheus web UI password.
PROM_ADMIN_PW=$(openssl rand -hex 16)
# Role-based API tokens for the blockchain node.
OPERATOR_TOKEN=$(openssl rand -hex 32)
CONTRIBUTOR_TOKEN=$(openssl rand -hex 32)
ORACLE_TOKEN=$(openssl rand -hex 32)
READER_TOKEN=$(openssl rand -hex 16)
# Prometheus scrapes node /metrics with the read-only node token.
PROM_BEARER=${READER_TOKEN}

# AlertManager notification defaults (infra#627). Delivery is webhook-only:
# AlertManager posts critical alerts to the alert-receiver service, which
# forwards them to a real channel (ntfy/Telegram) via ALERT_FORWARD_URL. The old
# SMTP/email path was removed — CT 101 has no MTA, so localhost:25 dropped every
# page. Operators can override these in .env.
LEGACY_ALERTMANAGER_SLACK_WEBHOOK_URL="${ALERTMANAGER_SLACK_WEBHOOK_URL:-}"
ALERTMANAGER_WEBHOOK_URL="${ALERTMANAGER_WEBHOOK_URL:-${LEGACY_ALERTMANAGER_SLACK_WEBHOOK_URL:-}}"
if [ -z "$ALERTMANAGER_WEBHOOK_URL" ]; then
  ALERTMANAGER_WEBHOOK_URL="http://wrfcoin-alert-receiver:19093/alerts"
fi

# Human paging channel the alert-receiver forwards to. Blank by default — the
# live .env MUST set a real ntfy topic / Telegram bot URL or no critical alert
# reaches a human.
ALERT_FORWARD_URL="${ALERT_FORWARD_URL:-}"
ALERT_FORWARD_FORMAT="${ALERT_FORWARD_FORMAT:-ntfy}"
ALERT_FORWARD_TELEGRAM_CHAT_ID="${ALERT_FORWARD_TELEGRAM_CHAT_ID:-}"

COMPOSE_CMD=""
if ! COMPOSE_CMD="$(detect_compose_cmd)"; then
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker is not installed yet. You can still generate secrets now, but you will need Docker before running compose."
  else
    warn "Neither docker compose nor docker-compose is available yet. Install Docker Compose before starting the stack."
  fi
elif [ "$COMPOSE_CMD" = "docker-compose" ]; then
  warn "Using classic docker-compose detection. Docker Compose v2 is preferred, but v1 can still run this stack."
fi

if command -v htpasswd >/dev/null 2>&1; then
  PROM_HASH=$(htpasswd -nbBC 10 "" "$PROM_ADMIN_PW" | cut -d: -f2)
  PROM_HASH_SOURCE="htpasswd"
elif has_python_bcrypt; then
  PROM_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${PROM_ADMIN_PW}', bcrypt.gensalt(rounds=10)).decode())")
  PROM_HASH_SOURCE="python3+bcrypt"
else
  warn "Neither htpasswd nor python3+bcrypt is available."
  die "cannot generate prometheus-web.yml. Install one of: apt install apache2-utils | pip3 install bcrypt"
fi

cat > "$ENV_FILE" << EOF
# Public fleet identity from the reviewed cut pins.
WRFCOIN_CHAIN_ID=${CHAIN_ID}
WRFCOIN_MIN_WORK_FACTOR=0
POSTGRES_PASSWORD=${PG_PW}
REDIS_PASSWORD=${REDIS_PW}
JWT_SECRET=${JWT}
OAUTH_STATE_SECRET=${OAUTH_STATE}
API_KEY_ENCRYPTION_KEY=${API_KEY_ENCRYPTION_KEY}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
RPC_API_KEY=${RPC_API_KEY}
ADMIN_TOKEN=${ADMIN_TOKEN}
N8N_WEBHOOK_SECRET=${N8N_WEBHOOK_SECRET}
GRAFANA_ADMIN_PASSWORD=${GRAF_PW}
ALERTMANAGER_WEBHOOK_URL=${ALERTMANAGER_WEBHOOK_URL}
ALERT_FORWARD_URL=${ALERT_FORWARD_URL}
ALERT_FORWARD_FORMAT=${ALERT_FORWARD_FORMAT}
ALERT_FORWARD_TELEGRAM_CHAT_ID=${ALERT_FORWARD_TELEGRAM_CHAT_ID}
PROMETHEUS_ADMIN_PASSWORD=${PROM_ADMIN_PW}
PROMETHEUS_BEARER_TOKEN=${PROM_BEARER}
WRFCOIN_OPERATOR_TOKEN=${OPERATOR_TOKEN}
WRFCOIN_CONTRIBUTOR_TOKEN=${CONTRIBUTOR_TOKEN}
WRFCOIN_ORACLE_TOKEN=${ORACLE_TOKEN}
WRFCOIN_READER_TOKEN=${READER_TOKEN}
WRFCOIN_TESTNET_RUNTIME_IMAGE=${RUNTIME_IMAGE}
WRFCOIN_RUNTIME_IMAGE_PROFILE=${RUNTIME_IMAGE_PROFILE}
WRFCOIN_RUNTIME_IMAGE_CLASS=${RUNTIME_IMAGE_CLASS}
WRFCOIN_CONTRIBUTOR_ADDRESS=0x0000000000000000000000000000000000000b02
BOOTSTRAP_PEERS=
RUST_LOG=info
LOG_LEVEL=info
# CORS allowed origin(s) for every backend service: a comma-separated list of
# browser origins, e.g. https://wrfcoin-testnet.taila1c049.ts.net (the funnel
# host). REQUIRED on a host that runs the backend services, no localhost default
# (infra#1056): check-env-completeness.sh and the release manifest refuse an
# empty or loopback value. (A sync-only join node does not need it.)
CORS_ORIGIN=${CORS_ORIGIN:-${WRFCOIN_FUNNEL_ORIGIN:-}}
GRAFANA_ADMIN_USER=admin
EOF

chmod 600 "$ENV_FILE"

for required_var in JWT_SECRET OAUTH_STATE_SECRET API_KEY_ENCRYPTION_KEY ENCRYPTION_KEY RPC_API_KEY ADMIN_TOKEN N8N_WEBHOOK_SECRET WRFCOIN_OPERATOR_TOKEN WRFCOIN_CONTRIBUTOR_TOKEN; do
  if ! grep -Eq "^${required_var}=.+" "$ENV_FILE"; then
    die "generated ${ENV_FILE} is missing required ${required_var}"
  fi
done

render_alertmanager_config() {
  local render_script="${SCRIPT_DIR}/render-alertmanager-config.sh"
  local template_file="${SCRIPT_DIR}/alertmanager.yml"
  local rendered_file="${SCRIPT_DIR}/alertmanager.rendered.yml"

  if [ ! -f "$template_file" ]; then
    warn "AlertManager template missing at ${template_file}; skipping render."
    return 0
  fi

  if [ ! -f "$render_script" ]; then
    warn "AlertManager renderer missing at ${render_script}; skipping render."
    return 0
  fi

  bash "$render_script" \
    --env-file "$ENV_FILE" \
    --template "$template_file" \
    --output "$rendered_file"
}

render_alertmanager_config

if [ -z "${CORS_ORIGIN:-${WRFCOIN_FUNNEL_ORIGIN:-}}" ]; then
  warn "CORS_ORIGIN is blank; check-env-completeness.sh and the release manifest will refuse this host until you set it in ${ENV_FILE} to the browser origin(s), e.g. https://wrfcoin-testnet.taila1c049.ts.net (infra#1056)."
fi
if [ -z "$ALERTMANAGER_WEBHOOK_URL" ]; then
  warn "ALERTMANAGER_WEBHOOK_URL is blank; critical AlertManager webhook delivery will stay disabled until you set it and rerun render-alertmanager-config.sh."
fi
if [ -z "$ALERT_FORWARD_URL" ]; then
  warn "ALERT_FORWARD_URL is blank; critical alerts will be captured to the alert-receiver logs only and will NOT page a human. Set a real ntfy/Telegram URL in .env before launch."
fi

# --- Prometheus web config (basic auth with bcrypt hash) ---
PROM_WEB_FILE="${SCRIPT_DIR}/prometheus-web.yml"
echo "prometheus-web.yml: bcrypt hash generated via ${PROM_HASH_SOURCE}."

cat > "$PROM_WEB_FILE" << WEBEOF
basic_auth_users:
  admin: ${PROM_HASH}
WEBEOF
if [[ ! "$PROM_HASH" =~ ^\$2[abxy]\$[0-9][0-9]\$[A-Za-z0-9./]{53}$ ]]; then
  die "generated Prometheus admin hash is not a valid bcrypt hash"
fi
make_prometheus_container_readable "$PROM_WEB_FILE"

# --- Prometheus bearer token file (for scrape auth) ---
PROM_TOKEN_FILE="${SCRIPT_DIR}/prometheus-bearer-token"
printf '%s' "$PROM_BEARER" > "$PROM_TOKEN_FILE"
make_prometheus_container_readable "$PROM_TOKEN_FILE"

echo ""
echo "=== SAVE THESE CREDENTIALS ==="
echo "POSTGRES_PASSWORD=${PG_PW}"
echo "REDIS_PASSWORD=${REDIS_PW}"
echo "JWT_SECRET=${JWT}"
echo "OAUTH_STATE_SECRET=${OAUTH_STATE}"
echo "API_KEY_ENCRYPTION_KEY=${API_KEY_ENCRYPTION_KEY}"
echo "ENCRYPTION_KEY=${ENCRYPTION_KEY}"
echo "RPC_API_KEY=${RPC_API_KEY}"
echo "  ^ Sent as x-api-key for protected backend RPC/operator routes"
echo "ADMIN_TOKEN=${ADMIN_TOKEN}"
echo "  ^ Sent as x-admin-token together with RPC_API_KEY for node control"
echo "N8N_WEBHOOK_SECRET=${N8N_WEBHOOK_SECRET}"
echo "  ^ Shared secret for authenticated n8n webhook execution"
echo "GRAFANA_ADMIN_PASSWORD=${GRAF_PW}"
echo "PROMETHEUS_ADMIN_PASSWORD=${PROM_ADMIN_PW}"
echo "PROMETHEUS_BEARER_TOKEN=${PROM_BEARER}"
echo "ALERTMANAGER_WEBHOOK_URL=${ALERTMANAGER_WEBHOOK_URL}"
echo "ALERT_FORWARD_URL=${ALERT_FORWARD_URL:-<unset — set before launch>}"
echo "ALERT_FORWARD_FORMAT=${ALERT_FORWARD_FORMAT}"
echo "WRFCOIN_OPERATOR_TOKEN=${OPERATOR_TOKEN}"
echo "  ^ Privileged node endpoints (admin, reorg, snapshot)"
echo "WRFCOIN_CONTRIBUTOR_TOKEN=${CONTRIBUTOR_TOKEN}"
echo "  ^ Weather data submissions (commit/reveal)"
echo "WRFCOIN_ORACLE_TOKEN=${ORACLE_TOKEN}"
echo "  ^ Oracle attestation and verification"
echo "WRFCOIN_READER_TOKEN=${READER_TOKEN}"
echo "  ^ Read-only chain state queries"
echo ""
echo ".env written to ${ENV_FILE}"

# --- Preflight verification ---
echo ""
echo "=== PREFLIGHT CHECK ==="
PREFLIGHT_OK=true
for f in prometheus-web.yml prometheus-bearer-token .env alertmanager.rendered.yml; do
  if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
    echo "MISSING: ${f}"
    PREFLIGHT_OK=false
  else
    echo "OK: ${f}"
  fi
done
if [ "$PREFLIGHT_OK" = false ]; then
  die "Some required files are missing. Fix before running docker compose."
fi
echo "All preflight checks passed."

echo ""
echo "=== NEXT STEPS ==="
echo "Next step: populate BOOTSTRAP_PEERS from ${SCRIPT_DIR}/seeds.txt before starting compose."
echo "1. Review ${SCRIPT_DIR}/seeds.txt and set BOOTSTRAP_PEERS in ${ENV_FILE}."
echo "   If seeds exist, run: bash ${SCRIPT_DIR}/check-seeds.sh --print"
echo "2. Start the stack:"
if [ -n "$COMPOSE_CMD" ]; then
  echo "   ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.testnet.yml up -d"
else
  echo "   docker compose -f ${SCRIPT_DIR}/docker-compose.testnet.yml up -d"
fi
echo "3. Confirm the node and services are healthy:"
echo "   bash ${SCRIPT_DIR}/check-health.sh"
echo "4. For bootstrapping and recovery guidance, read:"
echo "   ${SCRIPT_DIR}/TESTNET_OPERATOR_GUIDE.md"
echo "   ${SCRIPT_DIR}/TESTNET_OPERATOR_GUIDE.md (see the Troubleshooting section)"
