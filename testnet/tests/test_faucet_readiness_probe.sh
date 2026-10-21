#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$REPO_ROOT/testnet/scripts/probe-faucet-readiness.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/faucet-readiness-test.XXXXXX")"
trap 'if [[ -n "${SERVER_PID:-}" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$ROOT"' EXIT

cat >"$ROOT/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

fixtures = {
    "/direct/health": {"walletConfigured": True, "apiTokenConfigured": True, "captchaReady": True, "directClaimsEnabled": True, "dispenseMode": "direct"},
    "/proxy/health": {"walletConfigured": True, "apiTokenConfigured": True, "captchaReady": False, "directClaimsEnabled": False, "dispenseMode": "proxy-only"},
    "/unconfigured/health": {"walletConfigured": False, "apiTokenConfigured": False, "captchaReady": True, "directClaimsEnabled": False, "dispenseMode": "unconfigured"},
}

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = fixtures.get(self.path)
        if payload is None:
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_args):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PY

PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
python3 "$ROOT/server.py" "$PORT" &
SERVER_PID=$!

for _ in $(seq 1 40); do
  if "$PROBE" --url "http://127.0.0.1:$PORT/direct" >/dev/null 2>&1; then break; fi
  sleep 0.05
done

[[ "$("$PROBE" --url "http://127.0.0.1:$PORT/direct")" == "DIRECT_READY" ]]
[[ "$("$PROBE" --url "http://127.0.0.1:$PORT/proxy")" == "PROXY_ONLY" ]]
[[ "$("$PROBE" --url "http://127.0.0.1:$PORT/unconfigured")" == "UNCONFIGURED" ]]

"$PROBE" --url "http://127.0.0.1:$PORT/direct" --public-release >/dev/null
if "$PROBE" --url "http://127.0.0.1:$PORT/proxy" --public-release >/dev/null; then
  echo "FAIL: unverified proxy-only faucet passed public-release mode" >&2
  exit 1
fi
"$PROBE" --url "http://127.0.0.1:$PORT/proxy" --public-release --onboarding-proxy-verified >/dev/null

if "$PROBE" --url "http://127.0.0.1:1/missing" --public-release >/dev/null 2>&1; then
  echo "FAIL: unreachable faucet passed" >&2
  exit 1
fi

echo "PASS: faucet readiness classifications and public-release policy validate"
