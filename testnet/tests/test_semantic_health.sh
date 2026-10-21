#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/semantic-health.XXXXXX")"
trap '[[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VALIDATOR="$REPO_ROOT/testnet/scripts/validate-health-payload.py"
CHECK="$REPO_ROOT/testnet/check-health.sh"

cat >"$ROOT/healthy.json" <<'JSON'
{"status":"healthy","service":"governance-server","dependencies":{"database":{"critical":false,"status":"up","mode":"connected"}},"draining":false}
JSON
cat >"$ROOT/degraded.json" <<'JSON'
{"status":"degraded","service":"governance-server","dependencies":{"database":{"critical":false,"status":"down","mode":"connected"}},"draining":false}
JSON
cat >"$ROOT/mismatch.json" <<'JSON'
{"status":"healthy","service":"governance-server","dependencies":{"database":{"critical":false,"status":"down","mode":"connected"}},"draining":false}
JSON
cat >"$ROOT/mock-mode.json" <<'JSON'
{"status":"healthy","service":"governance-server","dependencies":{"database":{"critical":false,"status":"up","mode":"mock-mode"}},"draining":false}
JSON
cat >"$ROOT/nested-down.json" <<'JSON'
{"status":"healthy","service":"governance-server","dependencies":{"database":{"critical":false,"status":"up","mode":"connected"},"redis":{"status":"down"}},"draining":false}
JSON
cat >"$ROOT/backend-healthy.json" <<'JSON'
{"success":true,"data":{"status":"healthy","dependencies":{"cache":{"status":"up"},"core4":{"status":"up"},"database":{"status":"up"}}}}
JSON
printf '{not-json' >"$ROOT/malformed.json"

python3 "$VALIDATOR" --contract governance "$ROOT/healthy.json" >/dev/null
python3 "$VALIDATOR" --contract backend "$ROOT/backend-healthy.json" >/dev/null
for fixture in degraded mismatch mock-mode nested-down malformed; do
  if python3 "$VALIDATOR" --contract governance "$ROOT/$fixture.json" >/dev/null 2>&1; then
    echo "FAIL: $fixture semantic payload passed" >&2
    exit 1
  fi
done

PORT_FILE="$ROOT/port"
python3 - "$PORT_FILE" <<'PY' &
import http.server, json, socketserver, sys
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body=json.dumps({"status":"degraded","service":"governance-server","dependencies":{"database":{"critical":False,"status":"down","mode":"connected"}},"draining":False}).encode()
        self.send_response(200); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*args): pass
with socketserver.TCPServer(("127.0.0.1",0),Handler) as server:
    open(sys.argv[1],"w").write(str(server.server_address[1]))
    server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..50}; do [[ -s "$PORT_FILE" ]] && break; sleep 0.05; done
PORT="$(cat "$PORT_FILE")"

# backend#1234: the probe needs an operator/reader bearer to see dependency detail.
# infra#1106: check-health.sh sources compose-inputs.sh, which refuses when
# cut-pins.env names a genesis but the RENDERED (untracked) docker-compose.cut.yml
# is absent, as in every clean checkout. --probe-service never composes anything,
# so the developer escape hatch is the honest setup here; it is what silently
# failed this test on a clean tree before.
if WRFCOIN_ALLOW_UNPINNED_GENESIS=1 WRFCOIN_READER_TOKEN=fixture-reader-token bash "$CHECK" --probe-service governance "http://127.0.0.1:$PORT/health" Governance >"$ROOT/promotion.out" 2>&1; then
  echo 'FAIL: promotion health gate accepted HTTP 200 degraded payload' >&2
  exit 1
fi
# Never let a failed grep end the run silently under `set -e`: say what was seen.
for expected in 'HTTP 200 but semantic contract failed' 'root.status'; do
  grep -q "$expected" "$ROOT/promotion.out" || {
    echo "FAIL: promotion probe output lacks '$expected'; it was:" >&2
    sed 's/^/    /' "$ROOT/promotion.out" >&2
    exit 1
  }
done

COMMAND="$(python3 - "$REPO_ROOT/testnet/docker-compose.testnet.yml" <<'PY'
import sys,yaml
with open(sys.argv[1],encoding="utf-8") as f: data=yaml.safe_load(f)
print(data["services"]["wrfcoin-governance"]["healthcheck"]["test"][1])
PY
)"
COMMAND="${COMMAND//http:\/\/localhost:8000/http:\/\/127.0.0.1:$PORT}"
COMMAND="${COMMAND//\$\$/\$}"
# dynamic-payload-reviewed: semantic-health-container-gate
# $COMMAND is the governance healthcheck read from the compose file above
# (a curl/python probe), not a Compose render.
if bash -c "$COMMAND"; then
  echo 'FAIL: container health gate accepted HTTP 200 degraded payload' >&2
  exit 1
fi

for fixture in mismatch mock-mode nested-down; do
  # dynamic-payload-reviewed: semantic-health-fixture-gate
  # The same healthcheck probe (its part after `&&`), fed a fixture payload.
  if body="$(cat "$ROOT/$fixture.json")" bash -c "${COMMAND#*&&}"; then
    echo "FAIL: container health gate accepted $fixture payload" >&2
    exit 1
  fi
done

echo 'PASS: HTTP 200 degraded/down payload is RED in container and promotion gates'
