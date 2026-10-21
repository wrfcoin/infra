#!/usr/bin/env bash
# backend#1234 companion: backend/governance /health serve dependency detail
# only to an operator/reader bearer; anonymous callers get {status, timestamp}.
# Every semantic consumer in this repo must therefore AUTHENTICATE, not be
# downgraded to HTTP-200-only. This test drives the real consumers against a
# stub that behaves like post-#1234 backend code (bodies captured from that
# code: testnet/tests/fixtures/backend-1234-health/README.md):
#   1. validate-health-payload.py: authenticated bodies pass, anonymous fail.
#   2. the governance container healthcheck from docker-compose.testnet.yml.
#   3. check-health.sh --probe-service (backend + governance).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FX="$REPO_ROOT/testnet/tests/fixtures/backend-1234-health"
VALIDATOR="$REPO_ROOT/testnet/scripts/validate-health-payload.py"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "  ok    $*"; }

TOKEN="reader-token-1234-fixture"

# Healthy authenticated backend body: the backend /health envelope when every
# dependency is up (the same shape test-check-health-oracle-reference.sh uses).
cat > "$TMP/backend-authenticated-200.json" <<'JSON'
{"success":true,"data":{"status":"healthy","dependencies":{"cache":{"status":"up"},"core4":{"status":"up"},"database":{"status":"up"}}}}
JSON
# The anonymous 200 twin: exactly the keys backend#1234 emits for anonymous callers.
cat > "$TMP/backend-anonymous-200.json" <<'JSON'
{"success":true,"status":"healthy","timestamp":"2026-09-26T17:43:44.119Z"}
JSON

# infra#1066 round 13: a curl wrapper that records its argv, then runs the real
# curl. The token must never appear in any argv (visible in ps / /proc).
REAL_CURL="$(command -v curl)"
mkdir -p "$TMP/argv-bin"
cat > "$TMP/argv-bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/curl-argv.log"
exec "$REAL_CURL" "\$@"
SH
chmod +x "$TMP/argv-bin/curl"
assert_no_token_in_argv() {
  [[ -s "$TMP/curl-argv.log" ]] || fail "$1: curl was not invoked through the argv recorder"
  if grep -qF -- "$TOKEN" "$TMP/curl-argv.log"; then fail "$1: token visible in curl argv"; fi
  : > "$TMP/curl-argv.log"
}

echo "== 1. real validator: authenticated passes, anonymous is RED =="
python3 "$VALIDATOR" --contract governance "$FX/governance-authenticated.json" >/dev/null ||
  fail "authenticated governance body rejected"
ok "governance authenticated body passes the governance contract"
if python3 "$VALIDATOR" --contract governance "$FX/governance-anonymous.json" >/dev/null 2>&1; then
  fail "anonymous governance body passed the governance contract"
fi
ok "governance anonymous body is RED (no dependencies.database)"
python3 "$VALIDATOR" --contract backend "$TMP/backend-authenticated-200.json" >/dev/null ||
  fail "authenticated backend body rejected"
ok "backend authenticated body passes the backend contract"
if python3 "$VALIDATOR" --contract backend "$TMP/backend-anonymous-200.json" >/dev/null 2>&1; then
  fail "anonymous backend body passed the backend contract"
fi
ok "backend anonymous body is RED (no data.dependencies)"

echo "== stub: post-#1234 semantics (detail only for the bearer) =="
PORT_FILE="$TMP/port"
python3 - "$PORT_FILE" "$TOKEN" "$FX" "$TMP" <<'PY' &
import http.server, socketserver, sys
port_file, token, fx, tmp = sys.argv[1:5]
bodies = {
    "/governance/health": (f"{fx}/governance-authenticated.json", f"{fx}/governance-anonymous.json"),
    "/backend/health": (f"{tmp}/backend-authenticated-200.json", f"{tmp}/backend-anonymous-200.json"),
}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        authed_path, anon_path = bodies.get(self.path, (None, None))
        if authed_path is None:
            self.send_response(404); self.end_headers(); return
        authed = self.headers.get("Authorization") == f"Bearer {token}"
        body = open(authed_path if authed else anon_path, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass
with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
    open(port_file, "w").write(str(server.server_address[1]))
    server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..100}; do [[ -s "$PORT_FILE" ]] && break; sleep 0.05; done
PORT="$(cat "$PORT_FILE")"

echo "== 2. governance container healthcheck (from the real compose file) =="
COMMAND="$(python3 - "$REPO_ROOT/testnet/docker-compose.testnet.yml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
print(data["services"]["wrfcoin-governance"]["healthcheck"]["test"][1])
PY
)"
grep -q 'Authorization: Bearer' <<<"$COMMAND" || fail "governance healthcheck sends no bearer"
COMMAND="${COMMAND//http:\/\/localhost:8000\/health/http:\/\/127.0.0.1:$PORT\/governance\/health}"
COMMAND="${COMMAND//\$\$/\$}"
run_hc() { env -u WRFCOIN_READER_TOKEN -u WRFCOIN_OPERATOR_TOKEN PATH="$TMP/argv-bin:$PATH" "$@" sh -c "$COMMAND"; }
run_hc WRFCOIN_READER_TOKEN="$TOKEN" || fail "healthcheck RED with the reader token"
assert_no_token_in_argv "healthcheck (reader token)"
ok "healthcheck GREEN with WRFCOIN_READER_TOKEN; token not in curl argv"
run_hc WRFCOIN_OPERATOR_TOKEN="$TOKEN" || fail "healthcheck RED with only the operator token"
assert_no_token_in_argv "healthcheck (operator fallback)"
ok "healthcheck GREEN with only WRFCOIN_OPERATOR_TOKEN (fallback); token not in curl argv"
if run_hc; then fail "healthcheck GREEN with no credential (anonymous minimal body)"; fi
ok "healthcheck RED with no credential: semantic contract not downgraded"
if run_hc WRFCOIN_READER_TOKEN=wrong-token; then fail "healthcheck GREEN with a wrong token"; fi
ok "healthcheck RED with a wrong token"

echo "== 3. check-health.sh --probe-service =="
# Run a copy so the host's real testnet/.env (if any) cannot supply a token.
FIXTURE_DIR="$TMP/testnet"
mkdir -p "$FIXTURE_DIR/lib" "$FIXTURE_DIR/scripts"
cp "$REPO_ROOT/testnet/check-health.sh" "$FIXTURE_DIR/check-health.sh"
cp "$REPO_ROOT/testnet/lib/compose-inputs.sh" "$FIXTURE_DIR/lib/compose-inputs.sh"
cp "$VALIDATOR" "$FIXTURE_DIR/scripts/validate-health-payload.py"
chmod +x "$FIXTURE_DIR/scripts/validate-health-payload.py"
for compose_file in docker-compose.testnet.yml docker-compose.override.yml \
                    docker-compose.local-paths.yml docker-compose.cut.yml \
                    docker-compose.cut-miner.yml docker-compose.cut-genesis-seed.yml \
                    docker-compose.yubikey.n5.yml docker-compose.oracle-attester.yml \
                    docker-compose.oracle-attester-yubikey.n5.yml; do
  printf '%s\n' 'services: {}' > "$FIXTURE_DIR/$compose_file"
done
probe() {
  local contract="$1" path="$2"; shift 2
  env -u WRFCOIN_READER_TOKEN -u WRFCOIN_OPERATOR_TOKEN PATH="$TMP/argv-bin:$PATH" WRFCOIN_HSM_MODE=yubikey "$@" \
    bash "$FIXTURE_DIR/check-health.sh" --probe-service "$contract" "http://127.0.0.1:$PORT$path" Label \
    > "$TMP/probe.out" 2>&1
}
for pair in governance:/governance/health backend:/backend/health; do
  contract="${pair%%:*}"; path="${pair#*:}"
  probe "$contract" "$path" WRFCOIN_READER_TOKEN="$TOKEN" || { cat "$TMP/probe.out" >&2; fail "$contract probe RED with the reader token"; }
  grep -q "SEMANTIC_HEALTH_PASS: contract=$contract" "$TMP/probe.out" || fail "$contract probe did not run the validator"
  assert_no_token_in_argv "$contract probe"
  ok "$contract probe GREEN (validator PASS) with WRFCOIN_READER_TOKEN; token not in curl argv"
  if probe "$contract" "$path"; then fail "$contract probe GREEN with no credential"; fi
  grep -q 'dependency health is unverified' "$TMP/probe.out" || { cat "$TMP/probe.out" >&2; fail "$contract no-credential failure is not explicit"; }
  ok "$contract probe RED and explicit with no credential"
  if probe "$contract" "$path" WRFCOIN_READER_TOKEN=wrong-token; then fail "$contract probe GREEN with a wrong token"; fi
  grep -q 'semantic contract failed' "$TMP/probe.out" || fail "$contract wrong-token failure was not the semantic validator"
  ok "$contract probe RED on the anonymous body (wrong token)"
done
: > "$TMP/curl-argv.log"
printf 'WRFCOIN_OPERATOR_TOKEN=%s\n' "$TOKEN" > "$FIXTURE_DIR/.env"
probe governance /governance/health || { cat "$TMP/probe.out" >&2; fail "probe did not fall back to testnet/.env"; }
ok "probe reads the operator token from testnet/.env when the env has none"
if grep -rq -- "$TOKEN" "$TMP/probe.out"; then fail "token leaked into probe output"; fi
ok "token never printed"

echo "PASS: $pass authenticated-health-consumer checks"
