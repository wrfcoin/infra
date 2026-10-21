#!/usr/bin/env bash
# backend#1236: services/etl/pipeline_server.js requires
# ../../server/utils/strict-cors-config. Dockerfile.etl copies the ETL code to
# /app/src/etl/, so the helper must land at /app/server/utils/ or the image
# crashes at boot with MODULE_NOT_FOUND. This pins the COPY mapping and, when
# a backend checkout is available (BACKEND_DIR), boots the real entry in the
# image layout the Dockerfile builds.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="$REPO/infra/docker/Dockerfile.etl"
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "  ok    $*"; }

grep -Eq '^COPY .*backend/services/etl/ +\./src/etl/' "$DOCKERFILE" || fail "ETL code no longer copied to ./src/etl/"
ok "ETL code is copied to /app/src/etl/"
grep -Eq '^COPY .*backend/server/utils/strict-cors-config\.js +\./server/utils/strict-cors-config\.js$' "$DOCKERFILE" ||
  fail "strict-cors-config.js is not shipped at ./server/utils/ (pipeline_server.js requires ../../server/utils/strict-cors-config)"
ok "strict-cors-config.js ships at /app/server/utils/ (same relative path as the backend repo)"

if [[ -z "${BACKEND_DIR:-}" || ! -f "${BACKEND_DIR}/services/etl/pipeline_server.js" ]]; then
  echo "  SKIP  image-layout boot: set BACKEND_DIR to a backend checkout with node_modules"
  exit 0
fi
grep -q "strict-cors-config" "$BACKEND_DIR/services/etl/pipeline_server.js" || {
  echo "  SKIP  image-layout boot: this backend's pipeline_server.js predates backend#1236"
  exit 0
}
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src/etl" "$TMP/server/utils"
printf '{"name":"etl-image-layout","private":true}\n' > "$TMP/package.json"
cp "$BACKEND_DIR/services/etl/pipeline_server.js" "$TMP/src/etl/"
cp "$BACKEND_DIR/server/utils/strict-cors-config.js" "$TMP/server/utils/"
ln -s "$BACKEND_DIR/node_modules" "$TMP/node_modules"
set +e
out="$(cd "$TMP" && env -i PATH="$PATH" NODE_ENV=production CORS_ORIGIN= PORT=0 timeout 20 node src/etl/pipeline_server.js 2>&1)"
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "empty production CORS_ORIGIN: exit $rc, want 1 (output: ${out:0:300})"
grep -q "Refusing to start with NODE_ENV=production" <<<"$out" || fail "no CORS refusal in output"
! grep -q "MODULE_NOT_FOUND\|Cannot find module" <<<"$out" || fail "helper not resolvable in the image layout"
ok "image-layout boot: helper resolves and an empty production CORS_ORIGIN refuses to start"
echo "PASS: ETL image ships the CORS helper"
