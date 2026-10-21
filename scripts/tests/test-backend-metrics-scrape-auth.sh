#!/usr/bin/env bash
# backend#1234 companion: the backend main API /metrics answers 401 without an
# operator/reader bearer. Every checked-in Prometheus config that scrapes it
# must send one, and every compose file that loads such a config must mount
# the token file.
#
#   1. static: each config's :4001 /metrics job has
#      authorization.credentials_file=/etc/prometheus/bearer_token, and each
#      compose file loading the config mounts /etc/prometheus/bearer_token.
#   2. runtime (needs Docker and a local prom/prometheus image; otherwise it
#      reports SKIP explicitly): a real Prometheus loads each config, re-pointed
#      at a stub /metrics that 401s without the bearer, and the scrape must be
#      "up". A negative control shows the same stub is "down" without auth.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok    $*"; }

CONFIGS=(infra/docker/prometheus.yml infra/monitoring/prometheus-enhanced.yml
         testnet/prometheus.testnet.yml)
declare -A LOADERS=(
  [infra/docker/prometheus.yml]="infra/docker/docker-compose.yml"
  [infra/monitoring/prometheus-enhanced.yml]="infra/monitoring/docker-compose.alerting.yml infra/monitoring/docker-compose.comprehensive-monitoring.yml infra/monitoring/docker-compose.dependency-monitoring.yml"
  [testnet/prometheus.testnet.yml]="testnet/docker-compose.testnet.yml"
)

echo "== 1. static: every backend /metrics scrape carries the bearer =="
for cfg in "${CONFIGS[@]}"; do
  python3 - "$REPO/$cfg" <<'PY' || fail "$cfg scrapes backend /metrics without a bearer"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
found = 0
for job in cfg.get("scrape_configs", []):
    targets = [t for sc in job.get("static_configs", []) for t in sc.get("targets", [])]
    if job.get("metrics_path", "/metrics") != "/metrics":
        continue
    if not any(str(t).endswith(":4001") for t in targets):
        continue
    found += 1
    auth = job.get("authorization") or {}
    legacy = job.get("bearer_token_file")
    if auth.get("credentials_file") != "/etc/prometheus/bearer_token" and legacy != "/etc/prometheus/bearer_token":
        print(f"job {job.get('job_name')} has no bearer credentials", file=sys.stderr)
        sys.exit(1)
if found == 0:
    print("no :4001 /metrics job found", file=sys.stderr)
    sys.exit(1)
PY
  ok "$cfg: backend :4001 /metrics job sends /etc/prometheus/bearer_token"
  for compose in ${LOADERS[$cfg]}; do
    grep -Eq ':/etc/prometheus/bearer_token(:ro)?' "$REPO/$compose" ||
      fail "$compose loads $cfg but does not mount /etc/prometheus/bearer_token"
    ok "$compose mounts /etc/prometheus/bearer_token"
  done
done

echo "== 2. runtime: a real Prometheus scrape with the bearer is up =="
IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -m1 '^prom/prometheus:v' || true)"
if [[ -z "$IMAGE" ]]; then
  echo "  SKIP  runtime scrape: no Docker or no local prom/prometheus image (static checks above still ran)"
  exit 0
fi
TMP="$(mktemp -d)"
STUB_PID=""
cleanup() {
  [[ -n "$STUB_PID" ]] && kill "$STUB_PID" 2>/dev/null || true
  docker rm -f "wrfcoin-scrape-auth-$$" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
TOKEN="scrape-reader-token-1234"
printf '%s' "$TOKEN" > "$TMP/bearer_token"
chmod 644 "$TMP/bearer_token"
python3 - "$TMP/port" "$TOKEN" <<'PY' &
import http.server, socketserver, sys
port_file, token = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {token}":
            self.send_response(401); self.end_headers(); return
        body = b"# TYPE process_cpu_seconds_total counter\nprocess_cpu_seconds_total 1\n"
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
with socketserver.TCPServer(("127.0.0.1", 0), H) as s:
    open(port_file, "w").write(str(s.server_address[1])); s.serve_forever()
PY
STUB_PID=$!
for _ in {1..100}; do [[ -s "$TMP/port" ]] && break; sleep 0.05; done
PORT="$(cat "$TMP/port")"

scrape_health() {  # $1 = config to load; prints the backend job's target health
  local cfg="$1" name="wrfcoin-scrape-auth-$$"
  python3 - "$cfg" "$TMP/prometheus.yml" "$PORT" <<'PY'
import sys, yaml
src, dst, port = sys.argv[1:4]
cfg = yaml.safe_load(open(src, encoding="utf-8"))
jobs = []
for job in cfg.get("scrape_configs", []):
    targets = [t for sc in job.get("static_configs", []) for t in sc.get("targets", [])]
    if any(str(t).endswith(":4001") for t in targets) and job.get("metrics_path", "/metrics") == "/metrics":
        job["static_configs"] = [{"targets": [f"127.0.0.1:{port}"]}]
        job["scrape_interval"] = "1s"
        job["scrape_timeout"] = "1s"
        jobs.append(job)
cfg = {"global": {"scrape_interval": "1s"}, "scrape_configs": jobs}
yaml.safe_dump(cfg, open(dst, "w"))
PY
  local api_port
  api_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network host \
    -v "$TMP/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "$TMP/bearer_token:/etc/prometheus/bearer_token:ro" \
    "$IMAGE" --config.file=/etc/prometheus/prometheus.yml \
    --web.listen-address="127.0.0.1:${api_port}" >/dev/null
  local health="" _
  for _ in {1..30}; do
    sleep 1
    health="$(curl -fsS "http://127.0.0.1:${api_port}/api/v1/targets" 2>/dev/null |
      python3 -c 'import json,sys; t=json.load(sys.stdin)["data"]["activeTargets"]; print(t[0]["health"] if t else "")' 2>/dev/null || true)"
    [[ "$health" == up || "$health" == down ]] && break
  done
  docker rm -f "$name" >/dev/null 2>&1 || true
  printf '%s' "$health"
}
echo "  (image: $IMAGE)"

for cfg in "${CONFIGS[@]}"; do
  health="$(scrape_health "$REPO/$cfg")"
  [[ "$health" == up ]] || fail "$cfg: authenticated scrape of the 401-gated stub is '${health:-no result}', want up"
  ok "$cfg: real Prometheus scrape with the bearer is up"
done

# Negative control: the same stub with the authorization stanza removed is down,
# so the 'up' above is attributable to the bearer.
python3 - "$REPO/infra/monitoring/prometheus-enhanced.yml" "$TMP/unauth.yml" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for job in cfg.get("scrape_configs", []):
    job.pop("authorization", None); job.pop("bearer_token_file", None)
yaml.safe_dump(cfg, open(sys.argv[2], "w"))
PY
health="$(scrape_health "$TMP/unauth.yml")"
[[ "$health" == down ]] || fail "negative control: unauthenticated scrape is '${health:-no result}', want down"
ok "negative control: the same scrape without the bearer is down (401)"

echo "  ok    section 2 complete"

echo "== 3. infra/docker stack: rendered backend env vs mounted credential, real sibling scrape =="
# infra#1066 round 13 (P2): the prometheus service in infra/docker scrapes the
# sibling wrfcoin-backend on wrfcoin-network. Render the REAL compose file,
# check the backend's rendered token env against the credential mounted into
# prometheus, then run prometheus with the UNMODIFIED config on a bridge
# network next to a stub that answers as wrfcoin-backend and only accepts the
# rendered backend's tokens.
if ! docker compose version >/dev/null 2>&1; then
  echo "  SKIP  infra/docker sibling scrape: docker compose unavailable"
  echo "PASS: backend /metrics scrape authentication (sibling scrape skipped)"
  exit 0
fi
STUB_IMAGE="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 -E '^python:3[0-9.]*-alpine$' || true)"
if [[ -z "$STUB_IMAGE" ]]; then
  echo "  SKIP  infra/docker sibling scrape: no local python:*-alpine image for the stub backend"
  echo "PASS: backend /metrics scrape authentication (sibling scrape skipped)"
  exit 0
fi
NET="wrfcoin-scrape-net-$$"
sibling_cleanup() {
  docker rm -f "wrfcoin-scrape-stub-$$" "wrfcoin-scrape-prom-$$" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  cleanup
}
trap sibling_cleanup EXIT
docker network create "$NET" >/dev/null

render_stack() {  # reader operator credential-file -> prints JSON facts
  local reader="$1" operator="$2" cred="$3"
  (cd "$REPO/infra/docker" &&
    env DATABASE_URL=postgres://x REDIS_URL=redis://x JWT_SECRET=x REDIS_PASSWORD=x \
      WRFCOIN_READER_TOKEN="$reader" WRFCOIN_OPERATOR_TOKEN="$operator" \
      WRFCOIN_PROMETHEUS_BEARER_TOKEN_FILE="$cred" \
      bash "${REPO}/testnet/tests/render-testnet-compose.sh" --profile full -f docker-compose.yml config --format json 2>/dev/null) |
  python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"]
env = svc["wrfcoin-backend"]["environment"]
mounts = {v["target"]: v["source"] for v in svc["prometheus"]["volumes"] if v.get("type") == "bind"}
nets = sorted(set(svc["wrfcoin-backend"]["networks"]) & set(svc["prometheus"]["networks"]))
print(json.dumps({"reader": env.get("WRFCOIN_READER_TOKEN") or "", "operator": env.get("WRFCOIN_OPERATOR_TOKEN") or "",
  "cred": mounts.get("/etc/prometheus/bearer_token"), "config": mounts.get("/etc/prometheus/prometheus.yml"), "shared_networks": nets}))'
}

sibling_scrape() {  # reader operator credential-value -> prints wrfcoin-main-api target health
  local reader="$1" operator="$2" credential="$3" facts
  printf '%s' "$credential" > "$TMP/cred-$$"
  chmod 644 "$TMP/cred-$$"
  facts="$(render_stack "$reader" "$operator" "$TMP/cred-$$")"
  [[ -n "$facts" ]] || fail "infra/docker compose did not render"
  python3 - "$facts" "$TMP/cred-$$" <<'PY' || fail "rendered infra/docker stack is not wired"
import json, sys
f = json.loads(sys.argv[1])
assert f["shared_networks"], "backend and prometheus share no network"
assert f["cred"] == sys.argv[2], f"prometheus mounts {f['cred']}, want the credential file"
assert f["config"] and f["config"].endswith("infra/docker/prometheus.yml"), f["config"]
PY
  local cfg rendered_reader rendered_operator
  cfg="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["config"])' "$facts")"
  rendered_reader="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["reader"])' "$facts")"
  rendered_operator="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["operator"])' "$facts")"
  docker rm -f "wrfcoin-scrape-stub-$$" "wrfcoin-scrape-prom-$$" >/dev/null 2>&1 || true
  # The stub stands in for wrfcoin-backend's /metrics gate: it accepts exactly
  # the rendered backend's WRFCOIN_READER_TOKEN / WRFCOIN_OPERATOR_TOKEN.
  docker run -d --name "wrfcoin-scrape-stub-$$" --network "$NET" --network-alias wrfcoin-backend \
    -e WRFCOIN_READER_TOKEN="$rendered_reader" -e WRFCOIN_OPERATOR_TOKEN="$rendered_operator" \
    "$STUB_IMAGE" python3 -c '
import http.server, os
ok = {f"Bearer {t}" for t in (os.environ.get("WRFCOIN_READER_TOKEN"), os.environ.get("WRFCOIN_OPERATOR_TOKEN")) if t}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics" or self.headers.get("Authorization") not in ok:
            self.send_response(401); self.end_headers(); return
        b = b"# TYPE up_probe gauge\nup_probe 1\n"
        self.send_response(200); self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", 4001), H).serve_forever()' >/dev/null
  docker run -d --name "wrfcoin-scrape-prom-$$" --network "$NET" -p 127.0.0.1::9090 \
    -v "$cfg:/etc/prometheus/prometheus.yml:ro" \
    -v "$TMP/cred-$$:/etc/prometheus/bearer_token:ro" \
    -v "$REPO/infra/docker/wrfcoin_alerts.yml:/etc/prometheus/wrfcoin_alerts.yml:ro" \
    "$IMAGE" --config.file=/etc/prometheus/prometheus.yml >/dev/null
  local port health="" _
  for _ in {1..60}; do
    sleep 1
    port="$(docker port "wrfcoin-scrape-prom-$$" 9090/tcp 2>/dev/null | head -1 | sed 's/.*://')"
    [[ -n "$port" ]] || continue
    health="$(curl -fsS "http://127.0.0.1:${port}/api/v1/targets" 2>/dev/null | python3 -c '
import json, sys
ts = [t for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"].get("job") == "wrfcoin-main-api"]
print(ts[0]["health"] if ts else "")' 2>/dev/null || true)"
    [[ "$health" == up || "$health" == down ]] && break
  done
  printf '%s' "$health"
}

health="$(sibling_scrape scrape-reader-1234 '' scrape-reader-1234)"
[[ "$health" == up ]] || fail "infra/docker: reader-token sibling scrape is '${health:-no result}', want up"
ok "infra/docker: rendered WRFCOIN_READER_TOKEN == mounted credential; unmodified config scrapes wrfcoin-backend:4001 up"
health="$(sibling_scrape '' scrape-operator-1234 scrape-operator-1234)"
[[ "$health" == up ]] || fail "infra/docker: operator-fallback sibling scrape is '${health:-no result}', want up"
ok "infra/docker: operator fallback (WRFCOIN_OPERATOR_TOKEN only) scrapes up"
health="$(sibling_scrape scrape-reader-1234 '' not-the-backend-token)"
[[ "$health" == down ]] || fail "infra/docker: mismatched credential scrape is '${health:-no result}', want down"
ok "infra/docker negative control: a credential the backend does not hold is down (401)"
echo "PASS: infra/docker sibling scrape authentication"
