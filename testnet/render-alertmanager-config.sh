#!/usr/bin/env bash
# Render the testnet AlertManager template into the compose-ready config.
# Usage:
#   bash render-alertmanager-config.sh \
#     [--env-file .env] [--template alertmanager.yml] [--output alertmanager.rendered.yml]
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
TEMPLATE_FILE="${SCRIPT_DIR}/alertmanager.yml"
OUTPUT_FILE="${SCRIPT_DIR}/alertmanager.rendered.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --template)
      TEMPLATE_FILE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Render the WRFCoin testnet AlertManager config from .env.
Usage:
  bash render-alertmanager-config.sh [--env-file .env] [--template alertmanager.yml] [--output alertmanager.rendered.yml]
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "ERROR: template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: env file not found: $ENV_FILE" >&2
  exit 1
fi

python3 - "$ENV_FILE" "$TEMPLATE_FILE" "$OUTPUT_FILE" <<'PY'
from pathlib import Path
import sys


def yaml_single_quote(value: str) -> str:
    return value.replace("'", "''")


def yaml_bool(value: str) -> str:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return "true"
    return "false"


def load_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key.strip()] = value
    return values


env_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
# Delivery is webhook-only (infra#627): the critical receiver posts to the
# alert-receiver service, which forwards to ntfy/Telegram (ALERT_FORWARD_URL).
# Email/SMTP was removed from the template — no MTA exists in CT 101.
DEFAULT_WEBHOOK_URL = "http://wrfcoin-alert-receiver:19093/alerts"
values = {
    "ALERTMANAGER_WEBHOOK_URL": DEFAULT_WEBHOOK_URL,
    "ALERTMANAGER_SLACK_WEBHOOK_URL": "",
}
values.update(load_env_file(env_path))
if not values.get("ALERTMANAGER_WEBHOOK_URL"):
    values["ALERTMANAGER_WEBHOOK_URL"] = values.get("ALERTMANAGER_SLACK_WEBHOOK_URL", "")
if not values.get("ALERTMANAGER_WEBHOOK_URL"):
    values["ALERTMANAGER_WEBHOOK_URL"] = DEFAULT_WEBHOOK_URL

content = template_path.read_text()
replacements = {
    "url: 'http://wrfcoin-alert-receiver:19093/alerts'": "url: '{}'".format(
        yaml_single_quote(values.get("ALERTMANAGER_WEBHOOK_URL", DEFAULT_WEBHOOK_URL))
    ),
}

for needle, replacement in replacements.items():
    content = content.replace(needle, replacement)

output_path.write_text(content)
# Alertmanager runs as nobody in the container, so the rendered config must be
# readable by the container user when bind-mounted from the host.
output_path.chmod(0o644)
PY

echo "AlertManager config rendered to ${OUTPUT_FILE}"
