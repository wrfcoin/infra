#!/usr/bin/env bash
# /downloads deep links on the frontend image's nginx (frontend-archive#598).
#
# dist/downloads/ is a real directory (it holds manifest.json) AND /downloads is
# an SPA route. `try_files $uri $uri/ /index.html` matched the directory, found
# no index file, and answered 403 before the SPA fallback; the directory
# redirect also leaked the container port (":5000") in its Location header.
#
# Runs the real testnet/nginx-frontend.conf in the same pinned nginx image the
# Dockerfile serves with, bound to loopback only, over a fixture dist/:
#   /downloads, /downloads/   200 and the SPA index.html
#   /downloads/manifest.json  200 and the manifest JSON, byte for byte
#   /no-such-route            200 SPA fallback (unchanged)
#   /assets/missing.js        404 (a missing asset is not the SPA)
#   no Location header names :5000
#
# usage: test-nginx-frontend-downloads.sh [CONF]   (default: testnet/nginx-frontend.conf)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${1:-$ROOT/testnet/nginx-frontend.conf}"
DOCKERFILE="$ROOT/testnet/Dockerfile.frontend"
TMP="$(mktemp -d)"
CID=""
cleanup() { [[ -n "$CID" ]] && docker rm -f "$CID" >/dev/null 2>&1; rm -rf "$TMP"; }
trap cleanup EXIT
FAILED=()
fail() { echo "  FAIL: $*" >&2; FAILED+=("$1"); }

if ! docker version >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "NGINX_DOWNLOADS=VOID docker and curl are required; nothing was served" >&2
  exit 1
fi
IMAGE="$(sed -n -E 's/^FROM (nginx:[^ ]+).*/\1/p' "$DOCKERFILE" | head -1)"
[[ -n "$IMAGE" ]] || { echo "NGINX_DOWNLOADS=VOID no nginx image in $DOCKERFILE" >&2; exit 1; }

mkdir -p "$TMP/dist/downloads" "$TMP/dist/assets"
printf '<!doctype html><title>spa-index</title>\n' > "$TMP/dist/index.html"
printf '{"releases":[]}\n' > "$TMP/dist/downloads/manifest.json"
printf 'console.log(1)\n' > "$TMP/dist/assets/app.js"

# wrfcoin-backend only has to resolve for nginx to start; nothing is proxied.
CID="$(docker run -d --add-host wrfcoin-backend:127.0.0.1 -p 127.0.0.1::5000 \
  -v "$TMP/dist:/usr/share/nginx/html:ro" -v "$CONF:/etc/nginx/conf.d/default.conf:ro" "$IMAGE")" \
  || { echo "NGINX_DOWNLOADS=VOID could not start $IMAGE" >&2; exit 1; }
PORT="$(docker port "$CID" 5000/tcp | sed -n -E '1s/.*:([0-9]+)$/\1/p')"
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 50); do curl -s -o /dev/null "$BASE/health" && break; sleep 0.2; done
curl -s -o /dev/null "$BASE/health" || { docker logs "$CID" >&2; echo "NGINX_DOWNLOADS=VOID nginx did not come up" >&2; exit 1; }

# probe NAME PATH WANT-STATUS [WANT-BODY-SUBSTRING]
probe() {
  local name="$1" path="$2" want="$3" body="${4-}" got
  got="$(curl -s -D "$TMP/$name.hdr" -o "$TMP/$name.body" -w '%{http_code}' "$BASE$path")"
  if [[ "$got" != "$want" ]]; then
    fail "$name" "GET $path returned $got, expected $want"
  elif [[ -n "$body" ]] && ! grep -Fq -- "$body" "$TMP/$name.body"; then
    fail "$name" "GET $path body lacks: $body"
  else
    echo "  ok    $name (GET $path -> $got)"
  fi
  if grep -iE '^location:.*:5000' "$TMP/$name.hdr" >/dev/null; then
    fail "${name}_port_leak" "GET $path leaked :5000 in Location"
  fi
}

echo "nginx $IMAGE, conf ${CONF#"$ROOT"/}"
probe downloads_bare /downloads 200 spa-index
probe downloads_slash /downloads/ 200 spa-index
probe downloads_manifest /downloads/manifest.json 200 '"releases"'
cmp -s "$TMP/downloads_manifest.body" "$TMP/dist/downloads/manifest.json" || fail downloads_manifest_bytes "manifest body differs from the file"
probe spa_fallback /no-such-route 200 spa-index
probe missing_asset /assets/missing.js 404
probe real_asset /assets/app.js 200 'console.log'

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "NGINX_DOWNLOADS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo NGINX_DOWNLOADS=PASS
