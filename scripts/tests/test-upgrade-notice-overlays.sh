#!/usr/bin/env bash
# core4#3277 S7: the B3 node release ships with governance-signed upgrade-notice
# transport (core4#3095). Two things must hold for that to be more than an env
# var the binary ignores:
#
#   1. the shipped node binary is built with core4's `upgrade-notice-fetch`
#      cargo feature (without it WRFCOIN_UPGRADE_NOTICE_PEER_FETCH=1 only logs
#      "built without `--features upgrade-notice-fetch`");
#   2. the node can be handed a signed notice FILE and/or peer URLs through two
#      opt-in overlays that touch nothing but wrfcoin-node, so every other
#      service renders identically and a host that does not opt in is unchanged.
#
# Config-only renders (`docker compose config`): nothing is built, pulled or
# started. Without Docker Compose the render cases cannot run, so the suite
# exits 77 (UNVERIFIED), never 0.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/testnet"
D="$ROOT/infra/docker/Dockerfile.core"
FILE_OVERLAY="$T/docker-compose.upgrade-notice-file.yml"
PEER_OVERLAY="$T/docker-compose.upgrade-notice-peer-fetch.yml"
NOTICE_TARGET=/etc/wrfcoin/upgrade-notice.signed.json
TMP="$(mktemp -d "${TMPDIR:-/tmp}/upgrade-notice-overlay-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILED=()
fail() { FAILED+=("$1"); echo "  FAIL: $1: $2" >&2; }

echo node_build_carries_upgrade_notice_fetch
# The node stage's --features list, exactly (the attester stage is separate).
node_features="$(awk '/^FROM builder-base AS node-builder$/{n=1;next} /^FROM /{n=0} n && /--features/{print}' "$D")"
if [ "$(printf '%s\n' "$node_features" | grep -c -- '--features')" -ne 1 ]; then
  fail node_build_carries_upgrade_notice_fetch "expected exactly one --features line in the node-builder stage, got: ${node_features:-none}"
elif ! printf '%s\n' "$node_features" | grep -Eq -- '--features "([a-z0-9-]+,)*upgrade-notice-fetch(,[a-z0-9-]+)*"'; then
  fail node_build_carries_upgrade_notice_fetch "node-builder features lack upgrade-notice-fetch: ${node_features}"
fi

echo attester_build_unchanged
attester_features="$(awk '/^FROM builder-base AS attester-builder$/{n=1;next} /^FROM /{n=0} n && /--features/{print}' "$D")"
if ! printf '%s\n' "$attester_features" | grep -Fq -- '--features "hsm,attester"'; then
  fail attester_build_unchanged "attester-builder features changed: ${attester_features:-none}"
fi

echo overlays_exist
for overlay in "$FILE_OVERLAY" "$PEER_OVERLAY"; do
  [ -f "$overlay" ] || fail overlays_exist "${overlay#"$ROOT"/} missing"
done

if ! docker compose version >/dev/null 2>&1; then
  echo "UPGRADE_NOTICE_OVERLAY_TESTS=UNVERIFIED docker compose unavailable; render cases not run"
  [ ${#FAILED[@]} -eq 0 ] || { echo "UPGRADE_NOTICE_OVERLAY_TESTS=FAIL cases: ${FAILED[*]}" >&2; exit 1; }
  exit 77
fi
if [ ! -f "$FILE_OVERLAY" ] || [ ! -f "$PEER_OVERLAY" ]; then
  echo "UPGRADE_NOTICE_OVERLAY_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi

# render NAME [compose args...]: config-only render with the example env; the
# caller's own values for the overlay variables never leak in.
render() {
  local name="$1"; shift
  # RENDER_ENV is a space-separated list of NAME=value words (no spaces in values).
  # shellcheck disable=SC2086
  env -u WRFCOIN_UPGRADE_NOTICE_HOST_FILE -u WRFCOIN_UPGRADE_NOTICE_PEER_URLS \
      -u WRFCOIN_UPGRADE_NOTICE_FILE -u WRFCOIN_UPGRADE_NOTICE_PEER_FETCH \
      ${RENDER_ENV:+$RENDER_ENV} \
    bash "$T/tests/render-testnet-compose.sh" --env-file "$T/.env.testnet.example" \
    -f "$T/docker-compose.testnet.yml" "$@" config --format json > "$TMP/$name.json" 2> "$TMP/$name.err"
}
must_render() { # NAME ARGS...
  local name="$1"; shift
  render "$name" "$@" || { sed 's/^/    /' "$TMP/$name.err" >&2; fail "$name" "render failed"; return 1; }
}
# expect NAME PYTHON-EXPR: d = default render, r = this render,
# ne/dne = this/default wrfcoin-node environment.
expect() {
  python3 - "$TMP/base.json" "$TMP/$1.json" "$2" <<'PY' || fail "$1" "assertion failed: $2"
import json, sys
d = json.load(open(sys.argv[1]))["services"]
r = json.load(open(sys.argv[2]))["services"]
ne = r["wrfcoin-node"].get("environment") or {}
dne = d["wrfcoin-node"].get("environment") or {}
def env_diff():
    return {k for k in set(ne) | set(dne) if ne.get(k) != dne.get(k)}
def others_identical():
    return {k: v for k, v in r.items() if k != "wrfcoin-node"} == \
           {k: v for k, v in d.items() if k != "wrfcoin-node"}
def node_except(*keys):
    a = {k: v for k, v in r["wrfcoin-node"].items() if k not in keys}
    b = {k: v for k, v in d["wrfcoin-node"].items() if k not in keys}
    return a == b
def new_volumes():
    base = d["wrfcoin-node"].get("volumes") or []
    return [v for v in (r["wrfcoin-node"].get("volumes") or []) if v not in base]
assert eval(sys.argv[3]), (sys.argv[3], {k: ne.get(k) for k in sorted(ne) if "UPGRADE" in k}, new_volumes())
PY
}

must_render base || { echo "UPGRADE_NOTICE_OVERLAY_TESTS=FAIL cases: base" >&2; exit 1; }

echo default_render_has_no_notice_transport
expect base 'not any("UPGRADE_NOTICE" in k for k in ne)'

echo file_overlay_refuses_without_host_file
if render file_unset -f "$FILE_OVERLAY"; then
  fail file_overlay_refuses_without_host_file "rendered without WRFCOIN_UPGRADE_NOTICE_HOST_FILE"
elif ! grep -q 'WRFCOIN_UPGRADE_NOTICE_HOST_FILE' "$TMP/file_unset.err"; then
  sed 's/^/    /' "$TMP/file_unset.err" >&2
  fail file_overlay_refuses_without_host_file "render failed, but not on the missing variable"
fi

echo file_overlay_mounts_one_read_only_file_and_sets_only_the_path
printf '{}' > "$TMP/notice.signed.json"
if RENDER_ENV="WRFCOIN_UPGRADE_NOTICE_HOST_FILE=$TMP/notice.signed.json" must_render file -f "$FILE_OVERLAY"; then
  expect file "ne.get(\"WRFCOIN_UPGRADE_NOTICE_FILE\") == \"$NOTICE_TARGET\""
  expect file 'env_diff() == {"WRFCOIN_UPGRADE_NOTICE_FILE"}'
  expect file "len(new_volumes()) == 1 and new_volumes()[0][\"type\"] == \"bind\" and new_volumes()[0][\"target\"] == \"$NOTICE_TARGET\""
  expect file "new_volumes()[0][\"source\"] == \"$TMP/notice.signed.json\""
  expect file 'new_volumes()[0].get("read_only") is True'
  expect file '(new_volumes()[0].get("bind") or {}).get("create_host_path") is False'
  expect file 'node_except("environment", "volumes")'
  expect file 'others_identical()'
fi

echo peer_overlay_refuses_without_urls
if render peer_unset -f "$PEER_OVERLAY"; then
  fail peer_overlay_refuses_without_urls "rendered without WRFCOIN_UPGRADE_NOTICE_PEER_URLS"
elif ! grep -q 'WRFCOIN_UPGRADE_NOTICE_PEER_URLS' "$TMP/peer_unset.err"; then
  sed 's/^/    /' "$TMP/peer_unset.err" >&2
  fail peer_overlay_refuses_without_urls "render failed, but not on the missing variable"
fi

echo peer_overlay_enables_fetch_and_passes_urls_only
URLS='http://peer-a.example:8556,http://peer-b.example:8556'
if RENDER_ENV="WRFCOIN_UPGRADE_NOTICE_PEER_URLS=$URLS" must_render peer -f "$PEER_OVERLAY"; then
  expect peer 'ne.get("WRFCOIN_UPGRADE_NOTICE_PEER_FETCH") == "1"'
  expect peer "ne.get(\"WRFCOIN_UPGRADE_NOTICE_PEER_URLS\") == \"$URLS\""
  expect peer 'env_diff() == {"WRFCOIN_UPGRADE_NOTICE_PEER_FETCH", "WRFCOIN_UPGRADE_NOTICE_PEER_URLS"}'
  expect peer 'node_except("environment")'
  expect peer 'others_identical()'
fi

echo both_overlays_compose
if RENDER_ENV="WRFCOIN_UPGRADE_NOTICE_HOST_FILE=$TMP/notice.signed.json WRFCOIN_UPGRADE_NOTICE_PEER_URLS=$URLS" \
   must_render both -f "$FILE_OVERLAY" -f "$PEER_OVERLAY"; then
  expect both 'env_diff() == {"WRFCOIN_UPGRADE_NOTICE_FILE", "WRFCOIN_UPGRADE_NOTICE_PEER_FETCH", "WRFCOIN_UPGRADE_NOTICE_PEER_URLS"}'
  expect both 'len(new_volumes()) == 1'
  expect both 'others_identical()'
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "UPGRADE_NOTICE_OVERLAY_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo UPGRADE_NOTICE_OVERLAY_TESTS=PASS
