#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="${ROOT}/testnet/edge/probe_public_build_freshness.sh"
SERVER="${ROOT}/testnet/tests/fixtures/public-build-freshness-server.py"
TMP="$(mktemp -d)"
SERVER_PID=""
trap '[[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

cat > "$TMP/pins.env" <<'PINS'
WRFCOIN_RC_CORE4_COMMIT=1111111111111111111111111111111111111111
WRFCOIN_RC_BACKEND_COMMIT=2222222222222222222222222222222222222222
WRFCOIN_RC_FRONTEND_COMMIT=3333333333333333333333333333333333333333
WRFCOIN_RC_INFRA_COMMIT=4444444444444444444444444444444444444444
WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE=2026-09-18
PINS

stop_server() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
  fi
}

start_server() {
  local mode="$1"
  local port_file="$TMP/${mode}.port"
  rm -f "$port_file"
  python3 "$SERVER" --mode "$mode" --port-file "$port_file" &
  SERVER_PID=$!
  for _ in {1..50}; do
    [[ -s "$port_file" ]] && break
    sleep 0.05
  done
  [[ -s "$port_file" ]] || { echo "fixture server did not start" >&2; exit 1; }
  ORIGIN="http://127.0.0.1:$(cat "$port_file")"
}

assert_class() {
  local expected="$1" file="$2"
  python3 - "$expected" "$file" <<'PY'
import json, sys
payload = json.load(open(sys.argv[2], encoding="utf-8"))
assert payload["classification"] == sys.argv[1], payload
PY
}

echo fresh_build_passes
start_server fresh
bash "$PROBE" --origin "$ORIGIN" --pins "$TMP/pins.env" --json > "$TMP/fresh.json"
assert_class FRESH "$TMP/fresh.json"
stop_server

echo stale_backend_revision_red
start_server backendstale
set +e
bash "$PROBE" --origin "$ORIGIN" --pins "$TMP/pins.env" --json > "$TMP/backendstale.json"
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "stale backend fixture returned $rc, expected 1" >&2; exit 1; }
assert_class STALE "$TMP/backendstale.json"
grep -Fq '/api/build: revision does not match release pin' "$TMP/backendstale.json"
stop_server

echo stale_last_modified_red
start_server stale
set +e
bash "$PROBE" --origin "$ORIGIN" --pins "$TMP/pins.env" --json > "$TMP/stale.json"
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "stale fixture returned $rc, expected 1" >&2; exit 1; }
assert_class STALE "$TMP/stale.json"
grep -Fq '18 Aug 2026' "$TMP/stale.json"
stop_server

echo edge_404_viewer_route_red
start_server edge404
set +e
bash "$PROBE" --origin "$ORIGIN" --pins "$TMP/pins.env" --json > "$TMP/edge404.json"
rc=$?
set -e
[[ $rc -eq 1 ]] || { echo "edge-404 fixture returned $rc, expected 1" >&2; exit 1; }
assert_class STALE "$TMP/edge404.json"
grep -Fq '/api/blockchain/status: edge 404 Not found' "$TMP/edge404.json"
stop_server

echo unreachable_is_unknown_not_pass
set +e
bash "$PROBE" --origin http://127.0.0.1:9 --pins "$TMP/pins.env" --json > "$TMP/unreachable.json" 2>/dev/null
rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "unreachable fixture returned $rc, expected 2" >&2; exit 1; }
assert_class UNREACHABLE "$TMP/unreachable.json"

echo fresh_build_restored
start_server fresh
bash "$PROBE" --origin "$ORIGIN" --pins "$TMP/pins.env" --json > "$TMP/restored.json"
assert_class FRESH "$TMP/restored.json"
stop_server

echo PUBLIC_BUILD_FRESHNESS_TESTS=PASS
