#!/usr/bin/env bash
# infra#1031: every testnet service that connects to the internal `postgres`
# service must say `sslmode=disable` in its connection URL.
#
# The internal Postgres has no TLS. Under NODE_ENV=production, backend's
# createDatabaseSSLConfig() (server/config/secure-ssl-config.js) forces TLS
# with verification, and governance/weather-earnings/... then fail with
# "The server does not support SSL connections" and fall back to mock data.
# With pg, a URL `sslmode=disable` overrides that explicit `ssl` object.
# PGSSLMODE does NOT, because pg reads the env only when `ssl` is undefined.
# So the URL is the one lever that works.
#
# Static gate (always runs): render the full compose (all profiles) and require
# every DATABASE_URL / DATA_SOURCE_NAME that targets @postgres: to carry
# sslmode=disable. A RED control proves the checker is not blind.
#
# Live repro (opt-in): SSLMODE_REPRO_BACKEND_DIR=<backend checkout with
# node_modules> starts a throwaway postgres:16 (no SSL) on 127.0.0.1. It then
# shows that governance's exact pool config fails without the suffix and
# connects with it. It never touches a testnet host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-${ROOT}/testnet/docker-compose.testnet.yml}"
TMP="$(mktemp -d)"
REPRO_CONTAINER=""
cleanup() {
  [[ -n "$REPRO_CONTAINER" ]] && docker rm -f "$REPRO_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || {
  echo 'PG_SSLMODE_GATE=UNVERIFIED docker (compose) unavailable; cannot render' >&2
  exit 77
}

bash "${ROOT}/testnet/tests/render-testnet-compose.sh" \
  --env-file "${ROOT}/testnet/.env.testnet.example" --profile '*' \
  -f "$COMPOSE_FILE" config --format json > "${TMP}/compose.json"

check() {
  python3 - "$1" <<'PY'
import json
import sys

services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
checked, missing = 0, []
for name, svc in sorted(services.items()):
    env = svc.get("environment") or {}
    for key in ("DATABASE_URL", "DATA_SOURCE_NAME"):
        url = env.get(key)
        if not url or "@postgres:" not in url:
            continue
        checked += 1
        query = url.split("?", 1)[1] if "?" in url else ""
        if "sslmode=disable" not in query.split("&"):
            missing.append(f"{name}.{key}")
if checked == 0:
    print("PG_SSLMODE_GATE=FAIL no internal postgres URLs found (blind render?)")
    raise SystemExit(1)
if missing:
    print(f"PG_SSLMODE_GATE=FAIL checked={checked} missing_sslmode_disable={','.join(missing)}")
    raise SystemExit(1)
print(f"PG_SSLMODE_GATE=PASS checked={checked}")
PY
}

check "${TMP}/compose.json"

# RED control: strip the suffix from the rendered config; the checker must fail.
sed 's/?sslmode=disable//g' "${TMP}/compose.json" > "${TMP}/stripped.json"
if check "${TMP}/stripped.json" >/dev/null; then
  echo 'PG_SSLMODE_GATE=FAIL RED control passed; checker is blind' >&2
  exit 1
fi
echo 'stripped_suffix_red'

if [[ -z "${SSLMODE_REPRO_BACKEND_DIR:-}" ]]; then
  echo 'PG_SSLMODE_LIVE_REPRO=SKIPPED (set SSLMODE_REPRO_BACKEND_DIR to run)'
  exit 0
fi

BACKEND="$(cd "$SSLMODE_REPRO_BACKEND_DIR" && pwd)"
PORT="${SSLMODE_REPRO_PORT:-55431}"
REPRO_CONTAINER="infra-1031-pg-nossl-$$"
docker run -d --rm --name "$REPRO_CONTAINER" \
  -e POSTGRES_USER=wrfcoin -e POSTGRES_PASSWORD=repro -e POSTGRES_DB=wrfcoin \
  -p "127.0.0.1:${PORT}:5432" postgres:16 >/dev/null
for _ in $(seq 1 60); do
  docker exec "$REPRO_CONTAINER" pg_isready -U wrfcoin -h 127.0.0.1 >/dev/null 2>&1 && break
  sleep 1
done
[[ "$(docker exec "$REPRO_CONTAINER" psql -U wrfcoin -tAc 'show ssl')" == "off" ]] || {
  echo 'PG_SSLMODE_LIVE_REPRO=FAIL throwaway postgres unexpectedly has ssl on' >&2
  exit 1
}

# Mirrors backend governance_server.js: getSharedPgPool({ connectionString, ssl: createDatabaseSSLConfig() })
cat > "${TMP}/repro.cjs" <<'JS'
const { getSharedPgPool } = require(process.env.B + '/server/utils/shared-pg-pool');
const { createDatabaseSSLConfig } = require(process.env.B + '/server/config/secure-ssl-config.js');
(async () => {
  const out = {};
  for (const [label, url] of [['bare', process.env.URL], ['sslmode_disable', process.env.URL + '?sslmode=disable']]) {
    const pool = getSharedPgPool({ connectionString: url, ssl: createDatabaseSSLConfig() });
    try { await pool.query('select 1'); out[label] = 'CONNECTED'; }
    catch (e) { out[label] = 'FAILED: ' + e.message; }
    await pool.end().catch(() => {});
  }
  process.stdout.write('__REPRO__' + JSON.stringify(out) + '\n');
})();
JS
result="$(cd "$BACKEND" && NODE_ENV=production SILENT_LOGS=true B="$BACKEND" \
  URL="postgresql://wrfcoin:repro@127.0.0.1:${PORT}/wrfcoin" node "${TMP}/repro.cjs" 2>/dev/null \
  | sed -n 's/^__REPRO__//p')"
echo "repro: ${result}"
python3 - "$result" <<'PY'
import json
import sys

r = json.loads(sys.argv[1])
ok = r.get("bare", "").startswith("FAILED") and "does not support SSL" in r["bare"] \
    and r.get("sslmode_disable") == "CONNECTED"
print("PG_SSLMODE_LIVE_REPRO=" + ("PASS" if ok else "FAIL"))
raise SystemExit(0 if ok else 1)
PY
