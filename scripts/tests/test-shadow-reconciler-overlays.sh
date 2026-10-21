#!/usr/bin/env bash
# infra#972 / infra#973: both rewards-parity switches are OFF by default and are
# enabled only through their opt-in overlays. Neither overlay touches any
# service except wrfcoin-backend, so consensus services render identically.
#
# Config-only renders (`docker compose config`): nothing is built, pulled or
# started. Without Docker Compose the render cases cannot run, so the suite
# exits 77 (UNVERIFIED), never 0.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/testnet"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/shadow-reconciler-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILED=()
fail() { FAILED+=("$1"); echo "  FAIL: $1: $2" >&2; }

echo overlays_stay_out_of_boot_heal_inputs
for overlay in docker-compose.reference-shadow.yml docker-compose.payout-reconciler.yml; do
  [ -f "$T/$overlay" ] || fail overlays_stay_out_of_boot_heal_inputs "$overlay missing"
  if grep -q "$overlay" "$T/lib/compose-inputs.sh"; then
    fail overlays_stay_out_of_boot_heal_inputs "$overlay is a boot-heal input (it must never start implicitly)"
  fi
done

if ! docker compose version >/dev/null 2>&1; then
  echo "SHADOW_RECONCILER_TESTS=UNVERIFIED docker compose unavailable; render cases not run"
  [ ${#FAILED[@]} -eq 0 ] || exit 1
  exit 77
fi

# render NAME [compose args...]: config-only render with the example env and
# CI-only documentation fixtures; the caller's own values never leak in.
render() {
  local name="$1"; shift
  env -u REFERENCE_SHADOW -u REWARD_PAYOUT_RECONCILE_ENABLED \
    bash "$T/tests/render-testnet-compose.sh" --env-file "${ENV_FILE:-$T/.env.testnet.example}" \
    -f "$T/docker-compose.testnet.yml" "$@" config --format json > "$TMP/$name.json" 2> "$TMP/$name.err"
}
# expect NAME PYTHON-EXPR: d = default render (with the oracle-reference profile,
# so every service is comparable), r = this render, be = r's backend env.
expect() {
  python3 - "$TMP/base.json" "$TMP/$1.json" "$2" <<'PY' || fail "$1" "assertion failed: $2"
import json, sys
d = json.load(open(sys.argv[1]))["services"]
r = json.load(open(sys.argv[2]))["services"]
be = r["wrfcoin-backend"].get("environment") or {}
dbe = d["wrfcoin-backend"].get("environment") or {}
def env_diff():
    return {k for k in set(be) | set(dbe) if be.get(k) != dbe.get(k)}
def others_identical():
    return {k: v for k, v in r.items() if k != "wrfcoin-backend"} == \
           {k: v for k, v in d.items() if k != "wrfcoin-backend"}
assert eval(sys.argv[3]), (sys.argv[3], {k: be.get(k) for k in sorted(be) if "REFERENCE" in k or "RECONCILE" in k})
PY
}
must_render() { # NAME ARGS...
  local name="$1"; shift
  render "$name" "$@" || { sed 's/^/    /' "$TMP/$name.err" >&2; fail "$name" "render failed"; return 1; }
}

must_render base --profile oracle-reference || exit 1

echo default_render_is_off
if must_render default; then
  expect default 'be["REFERENCE_SHADOW"] == "0"'
  expect default 'be["REWARD_PAYOUT_RECONCILE_ENABLED"] == "false"'
  expect default 'be["REWARD_PAYOUT_RECONCILE_INTERVAL_MS"] == "60000"'
  expect default 'be["ORACLE_REFERENCE_URL"] == "http://oracle-reference:8010" and be["ORACLE_REFERENCE_TIMEOUT_MS"] == "5000"'
  expect default '"oracle-reference" not in r and "oracle-reference" not in (r["wrfcoin-backend"].get("depends_on") or {})'
fi

echo default_holds_without_env_file_values
grep -vE '^(REFERENCE_SHADOW|REWARD_PAYOUT_RECONCILE_ENABLED)=' "$T/.env.testnet.example" > "$TMP/bare.env"
if ENV_FILE="$TMP/bare.env" must_render bare; then
  expect bare 'be["REFERENCE_SHADOW"] == "0" and be["REWARD_PAYOUT_RECONCILE_ENABLED"] == "false"'
fi

echo shadow_overlay_without_profile_refuses_to_render
if render shadow_noprofile -f "$T/docker-compose.reference-shadow.yml"; then
  fail shadow_overlay_without_profile_refuses_to_render "shadow rendered without its sidecar"
elif ! grep -Fq 'depends on undefined service "oracle-reference"' "$TMP/shadow_noprofile.err"; then
  sed 's/^/    /' "$TMP/shadow_noprofile.err" >&2
  fail shadow_overlay_without_profile_refuses_to_render "render failed, but not on the missing sidecar"
fi

echo shadow_overlay_with_profile_touches_only_the_backend_flag
if must_render shadow -f "$T/docker-compose.reference-shadow.yml" --profile oracle-reference; then
  expect shadow 'be["REFERENCE_SHADOW"] == "1"'
  expect shadow 'env_diff() == {"REFERENCE_SHADOW"}'
  expect shadow 'r["wrfcoin-backend"]["depends_on"]["oracle-reference"]["condition"] == "service_healthy"'
  expect shadow 'set(r["wrfcoin-backend"]["depends_on"]) - set(d["wrfcoin-backend"].get("depends_on") or {}) == {"oracle-reference"}'
  expect shadow 'be["REWARD_PAYOUT_RECONCILE_ENABLED"] == "false"'
  expect shadow 'others_identical()'
fi

echo reconciler_overlay_touches_only_the_backend_flag
if must_render reconciler -f "$T/docker-compose.payout-reconciler.yml" --profile oracle-reference; then
  expect reconciler 'be["REWARD_PAYOUT_RECONCILE_ENABLED"] == "true"'
  expect reconciler 'env_diff() == {"REWARD_PAYOUT_RECONCILE_ENABLED"}'
  expect reconciler 'be["REFERENCE_SHADOW"] == "0"'
  expect reconciler 'r["wrfcoin-backend"].get("depends_on") == d["wrfcoin-backend"].get("depends_on")'
  expect reconciler 'others_identical()'
fi

echo reconciler_env_passthrough
cp "$T/.env.testnet.example" "$TMP/on.env"
sed -i 's/^REWARD_PAYOUT_RECONCILE_ENABLED=.*/REWARD_PAYOUT_RECONCILE_ENABLED=true/' "$TMP/on.env"
if ENV_FILE="$TMP/on.env" must_render passthrough --profile oracle-reference; then
  expect passthrough 'be["REWARD_PAYOUT_RECONCILE_ENABLED"] == "true" and env_diff() == {"REWARD_PAYOUT_RECONCILE_ENABLED"}'
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo "SHADOW_RECONCILER_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
echo SHADOW_RECONCILER_TESTS=PASS
