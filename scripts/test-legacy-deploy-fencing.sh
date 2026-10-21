#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT}/docker/docker-compose.rtl433.yml"
ENV_FILE="${ROOT}/docker/.env.rtl433.example"
PROVISIONER="${ROOT}/docker/provision-mosquitto-auth.sh"
VALUES_FILE="${ROOT}/infra/monitoring/prometheus-values.yaml"

rendered="$(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --format json)"
RENDERED_COMPOSE="$rendered" python3 - <<'PY'
import json
import os

config = json.loads(os.environ["RENDERED_COMPOSE"])
services = config["services"]

for name, service in services.items():
    for port in service.get("ports", []):
        assert port.get("host_ip") == "127.0.0.1", (
            f"{name} publishes a non-loopback port: {port}"
        )

assert not services["postgres"].get("ports"), "Postgres must remain internal-only"
assert not services["redis"].get("ports"), "Redis must remain internal-only"
assert services["redis"]["command"][1] == "--requirepass"

broker_env = services["mqtt_broker"]["environment"]
ingestion_env = services["rtl433_ingestion"]["environment"]
assert broker_env["MQTT_USERNAME"] == "wrfcoin_rtl433"
assert broker_env["MQTT_PASSWORD"] == "REPLACE_with_strong_URL_unreserved_password"
assert ingestion_env["MQTT_BROKER_URL"] == (
    "mqtt://wrfcoin_rtl433:REPLACE_with_strong_URL_unreserved_password"
    "@mqtt_broker:1883"
)
PY

if [[ -e "${ROOT}/docker/rtl433.env.example" ]]; then
  echo "FAIL: duplicate docker/rtl433.env.example still exists" >&2
  exit 1
fi

if reserved_output="$(
  MQTT_USERNAME=wrfcoin_rtl433 \
    MQTT_PASSWORD='p%40ss' \
    sh "$PROVISIONER" 2>&1
)"; then
  echo "FAIL: provisioner accepted a percent-encoded MQTT password" >&2
  exit 1
fi
if [[ "$reserved_output" != *"MQTT_PASSWORD must use only URL-unreserved characters"* ]]; then
  echo "FAIL: reserved-character refusal came from the wrong guard: $reserved_output" >&2
  exit 1
fi

# infra#671 — the username shares the URL userinfo with the password and must
# carry the same guard. 'user%40name' decodes to 'user@name' in mqtt.js while
# Mosquitto would see it literally.
if username_output="$(
  MQTT_USERNAME='user%40name' \
    MQTT_PASSWORD='validpass123' \
    sh "$PROVISIONER" 2>&1
)"; then
  echo "FAIL: provisioner accepted a percent-encoded MQTT username" >&2
  exit 1
fi
if [[ "$username_output" != *"MQTT_USERNAME must use only URL-unreserved characters"* ]]; then
  echo "FAIL: username refusal came from the wrong guard: $username_output" >&2
  exit 1
fi

if env -u POSTGRES_PASSWORD -u REDIS_PASSWORD \
  docker compose -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
  echo "FAIL: legacy compose accepted missing credentials" >&2
  exit 1
fi

grep -q 'wrfcoin-alertmanager-smtp' "$VALUES_FILE"
grep -q "smtp_auth_password_file: '/etc/alertmanager/secrets/wrfcoin-alertmanager-smtp/password'" "$VALUES_FILE"
if grep -Eq "smtp_auth_password:[[:space:]]*['\"]?password" "$VALUES_FILE"; then
  echo "FAIL: literal Alertmanager SMTP password remains" >&2
  exit 1
fi

bash -n "${ROOT}/scripts/advanced-deployment.sh"
bash -n "${ROOT}/infra/deployment/advanced-deployment.sh"

echo "PASS: legacy deploy paths require URL-safe secrets and publish loopback-only ports"
