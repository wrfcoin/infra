#!/usr/bin/env bash
# Dry-run smoke test for the testnet AlertManager notification path.
#
# The script starts a temporary local webhook capture server, runs a throwaway
# AlertManager container against a minimal config that points at that capture
# endpoint, posts a synthetic alert through AlertManager's API, and asserts
# that the webhook receiver fires.
#
# Usage:
#   bash infra/scripts/alertmanager-smoke-test.sh [--dry-run]
#
# The default mode is dry-run because the stack may not have a real webhook
# configured yet. This keeps the test safe to run on fresh operator hosts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
CAPTURE_PORT_FILE="${TMPDIR}/capture-port"
CAPTURE_BODY_FILE="${TMPDIR}/capture-body.json"
ALERTMANAGER_PORT_FILE="${TMPDIR}/alertmanager-port"
ALERTMANAGER_CONTAINER="wrfcoin-alertmanager-smoke-$$-${RANDOM}"
MODE="dry-run"

cleanup() {
  if docker ps -aq --filter "name=^/${ALERTMANAGER_CONTAINER}$" | grep -q .; then
    docker rm -f "${ALERTMANAGER_CONTAINER}" >/dev/null 2>&1 || true
  fi
  if [ -n "${CAPTURE_PID:-}" ]; then
    kill "${CAPTURE_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPDIR}"
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Dry-run smoke test for the WRFCoin testnet AlertManager webhook path.
Usage:
  bash infra/scripts/alertmanager-smoke-test.sh [--dry-run]
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is required for the smoke test" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required for the smoke test" >&2
  exit 1
fi

python3 - "$ALERTMANAGER_PORT_FILE" <<'PY'
from pathlib import Path
import socket
import sys

port_file = Path(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    port_file.write_text(str(sock.getsockname()[1]))
PY

python3 - "$CAPTURE_PORT_FILE" "$CAPTURE_BODY_FILE" <<'PY' &
from http.server import BaseHTTPRequestHandler
from pathlib import Path
import socketserver
import sys
import threading

port_file = Path(sys.argv[1])
body_file = Path(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        body_file.write_bytes(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")
        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, format, *args):
        return


with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    port_file.write_text(str(server.server_address[1]))
    server.serve_forever()
PY
CAPTURE_PID=$!

for _ in $(seq 1 50); do
  if [ -s "${CAPTURE_PORT_FILE}" ]; then
    break
  fi
  sleep 0.1
done

if [ ! -s "${CAPTURE_PORT_FILE}" ]; then
  echo "ERROR: capture server did not start" >&2
  exit 1
fi

CAPTURE_PORT="$(cat "${CAPTURE_PORT_FILE}")"
ALERTMANAGER_PORT="$(cat "${ALERTMANAGER_PORT_FILE}")"
ALERTMANAGER_CONFIG="${TMPDIR}/alertmanager-smoke.yml"
cat > "${ALERTMANAGER_CONFIG}" <<EOF
global:
  resolve_timeout: 5m

route:
  receiver: smoke-webhook
  group_by: ['alertname']
  group_wait: 0s
  group_interval: 1m
  repeat_interval: 1h

receivers:
  - name: smoke-webhook
    webhook_configs:
      - url: http://127.0.0.1:${CAPTURE_PORT}/webhook
        send_resolved: true
EOF

docker run -d --rm \
  --name "${ALERTMANAGER_CONTAINER}" \
  --network=host \
  -v "${ALERTMANAGER_CONFIG}:/etc/alertmanager/alertmanager.yml:ro" \
  prom/alertmanager:v0.28.0 \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --web.listen-address="127.0.0.1:${ALERTMANAGER_PORT}" \
  --storage.path=/alertmanager >/dev/null

for _ in $(seq 1 120); do
  if curl -sf "http://127.0.0.1:${ALERTMANAGER_PORT}/-/healthy" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! curl -sf "http://127.0.0.1:${ALERTMANAGER_PORT}/-/healthy" >/dev/null 2>&1; then
  echo "ERROR: AlertManager did not become healthy" >&2
  echo "AlertManager logs:" >&2
  docker logs "${ALERTMANAGER_CONTAINER}" >&2 || true
  exit 1
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ALERT_PAYLOAD=$(cat <<EOF
[
  {
    "labels": {
      "alertname": "SyntheticTestnetAlert",
      "severity": "critical",
      "service": "testnet",
      "instance": "smoke-test"
    },
    "annotations": {
      "summary": "Synthetic testnet AlertManager smoke test",
      "description": "Verifies the AlertManager webhook receiver fires during a dry run",
      "runbook_url": "https://docs.wrfcoin.com/testnet/alertmanager"
    },
    "startsAt": "${TIMESTAMP}",
    "generatorURL": "http://localhost:9090/graph?g0.expr=SyntheticTestnetAlert"
  }
]
EOF
)

POST_RESPONSE="$(mktemp)"
POST_CODE="$(curl -s -o "${POST_RESPONSE}" -w '%{http_code}' -X POST \
  -H "Content-Type: application/json" \
  -d "${ALERT_PAYLOAD}" \
  "http://127.0.0.1:${ALERTMANAGER_PORT}/api/v2/alerts" || true)"
if [ -z "${POST_CODE}" ]; then
  POST_CODE="000"
fi

if [ "${POST_CODE}" != "200" ]; then
  echo "ERROR: AlertManager API returned HTTP ${POST_CODE}" >&2
  cat "${POST_RESPONSE}" >&2 || true
  docker logs "${ALERTMANAGER_CONTAINER}" >&2 || true
  exit 1
fi

rm -f "${POST_RESPONSE}"

for _ in $(seq 1 75); do
  if [ -s "${CAPTURE_BODY_FILE}" ]; then
    break
  fi
  sleep 0.2
done

if [ ! -s "${CAPTURE_BODY_FILE}" ]; then
  echo "ERROR: webhook receiver did not fire" >&2
  echo "AlertManager logs:" >&2
  docker logs "${ALERTMANAGER_CONTAINER}" >&2 || true
  exit 1
fi

if ! grep -q 'SyntheticTestnetAlert' "${CAPTURE_BODY_FILE}"; then
  echo "ERROR: capture server received an unexpected payload" >&2
  echo "Captured payload:" >&2
  cat "${CAPTURE_BODY_FILE}" >&2 || true
  exit 1
fi

echo "PASS: AlertManager smoke test completed (${MODE})"
echo "  - AlertManager API: http://127.0.0.1:${ALERTMANAGER_PORT}"
echo "  - Captured webhook payload: ${CAPTURE_BODY_FILE}"
