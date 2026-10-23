#!/usr/bin/env bash
# infra#1056: CORS_ORIGIN must fail closed on the testnet stack.
#
# CT101 ran all nine backend services with CORS_ORIGIN=http://localhost:5000
# because docker-compose.testnet.yml defaulted it and the host .env never set
# it. This pins what replaces that silent default:
#
#   1. compose has NO default: unset renders empty, never localhost. It is
#      deliberately not `:?`, because profiles do not scope interpolation and
#      a `:?` would break the sync-only join command (#762; see
#      scripts/test-join-path-operator-config.sh);
#   2. check-env-completeness.sh validates the EFFECTIVE rendered CORS_ORIGIN of
#      every reader (process env, overlays and interpolation included): empty,
#      loopback, wildcard, and non-origin values fail;
#   3. the shipped env templates carry a real (non-loopback) origin.
#
# The release-manifest refusal is covered in test-render-release-manifest.sh.
# Render cases need `docker compose` (config only: nothing is built, pulled or
# started). Without it they are skipped and the suite exits 77 (UNVERIFIED),
# never 0.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE="$ROOT/testnet/docker-compose.testnet.yml"
EXAMPLE="$ROOT/testnet/.env.testnet.example"
CHECK="$ROOT/testnet/check-env-completeness.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cors-origin-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILED=()
fail() { FAILED+=("$1"); echo "  FAIL: $1: $2" >&2; }

# The eight services that read CORS_ORIGIN from the base file.
SERVICES=(wrfcoin-backend wrfcoin-governance wrfcoin-iot wrfcoin-weather-earnings
  wrfcoin-cross-chain wrfcoin-compute wrfcoin-ml wrfcoin-node-discovery)

echo no_default_and_no_interpolation_guard_in_compose
if grep -nE 'CORS_ORIGIN:-[^}]' "$ROOT"/testnet/docker-compose*.yml; then
  fail no_default_and_no_interpolation_guard_in_compose "a CORS_ORIGIN fallback default reappeared"
fi
if grep -nF 'CORS_ORIGIN:?' "$COMPOSE"; then
  fail no_default_and_no_interpolation_guard_in_compose "a CORS_ORIGIN :? guard would break the join command (#762)"
fi
# shellcheck disable=SC2016 # a literal compose expression, not a shell one
readers=$(grep -cF 'CORS_ORIGIN: ${CORS_ORIGIN:-}' "$COMPOSE")
[[ "$readers" -eq ${#SERVICES[@]} ]] || fail no_default_and_no_interpolation_guard_in_compose "expected ${#SERVICES[@]} no-default readers, found $readers"

echo templates_carry_a_real_origin
for template in "$EXAMPLE" "$ROOT/config/testnet.env.example"; do
  value="$(sed -n 's/^CORS_ORIGIN=//p' "$template" | tail -n 1)"
  [[ "$value" == https://* && "$value" != *localhost* ]] || fail templates_carry_a_real_origin "$template has CORS_ORIGIN=$value"
done

# The gate compares the host's snapshot signers against the REAL cut pin
# (infra#1080), so the fixture carries whatever cut-pins.env pins; a fixture key
# is used only while nothing is pinned.
SIGNERS="$(sed -n 's/^WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=//p' "$ROOT/testnet/cut-pins.env" | tail -n 1)"
[[ -n "$SIGNERS" ]] || SIGNERS="$(printf 'ab%.0s' {1..32})"
# Likewise the chain id: the gate refuses a host whose persisted WRFCOIN_CHAIN_ID
# differs from the pin (absent defaults to 777), so the fixture declares the pin.
CHAIN="$(sed -n 's/^WRFCOIN_CUT_CHAIN_ID=//p' "$ROOT/testnet/cut-pins.env" | tail -n 1)"

# env_with NAME VALUE|unset: the example env with CORS_ORIGIN replaced or
# removed. The three host-specific values the example leaves blank get RFC 5737
# / fixture values, so a green case is green on CORS_ORIGIN alone.
env_with() {
  local out="$TMP/$1.env"
  grep -vE '^(CORS_ORIGIN|WRFCOIN_CHAIN_ID|WRFCOIN_P2P_EXTERNAL_ADDR|WRFCOIN_SEED_P2P_EXTERNAL_ADDR|WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS)=' "$EXAMPLE" > "$out"
  {
    printf 'WRFCOIN_CHAIN_ID=%s\n' "$CHAIN"
    echo 'WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000'
    echo 'WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000'
    printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$SIGNERS"
  } >> "$out"
  [[ "$2" == unset ]] || printf 'CORS_ORIGIN=%s\n' "$2" >> "$out"
  # A chain-888 host carries the genesis declarations the joiner writes from the
  # pins (bootstrap.888.env requires them to render); write them the same way.
  python3 "$ROOT/testnet/scripts/chain-identity.py" --pins "$ROOT/testnet/cut-pins.env" \
    --bootstrap-env "$out" > /dev/null
  printf '%s' "$out"
}

# check_case NAME VALUE WANT_RC PATTERN: run the env gate against the base file.
check_case() {
  local name="$1" value="$2" want="$3" pattern="$4" envf rc
  echo "$name"
  envf="$(env_with "$name" "$value")"
  env -u CORS_ORIGIN "$CHECK" -f "$COMPOSE" --env "$envf" > "$TMP/$name.out" 2>&1
  rc=$?
  if [[ $rc -ne $want ]]; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    fail "$name" "check-env-completeness exited $rc, expected $want"
    return
  fi
  grep -Fq -- "$pattern" "$TMP/$name.out" || { sed 's/^/    /' "$TMP/$name.out" >&2; fail "$name" "output lacks: $pattern"; }
}

check_case env_gate_unset_red unset 1 'MISSING or EMPTY: CORS_ORIGIN'
check_case env_gate_empty_red '' 1 'MISSING or EMPTY: CORS_ORIGIN'
check_case env_gate_localhost_red 'http://localhost:5000' 1 "UNSAFE CORS_ORIGIN: 'http://localhost:5000' is a loopback origin"
check_case env_gate_loopback_in_list_red 'https://wrfcoin-testnet.taila1c049.ts.net, http://127.0.0.1:5000' 1 "'http://127.0.0.1:5000' is a loopback origin"
check_case env_gate_ipv6_loopback_red 'http://[::1]:5000' 1 'is a loopback origin'
check_case env_gate_wildcard_red '*' 1 "UNSAFE CORS_ORIGIN: '*' is not a scheme://host[:port] origin"
check_case env_gate_path_red 'https://wrfcoin-testnet.taila1c049.ts.net/app' 1 'is not a scheme://host[:port] origin'
check_case env_gate_localhost_lookalike_green 'https://localhost.example.org' 0 'CORS_ORIGIN: 1 non-loopback origin(s)'
check_case env_gate_funnel_origin_green 'https://wrfcoin-testnet.taila1c049.ts.net' 0 'CORS_ORIGIN: 1 non-loopback origin(s)'
check_case env_gate_quoted_list_green '"https://wrfcoin-testnet.taila1c049.ts.net,https://testnet.example.org"' 0 'CORS_ORIGIN: 2 non-loopback origin(s)'

# The gate validates the EFFECTIVE rendered value, not the literal .env line
# (codex review of #1060): an exported variable, an overlay, or interpolation
# can each put loopback into the services while the .env line looks valid.
# gate_case NAME WANT PATTERN ENVFILE [VAR=VALUE ...] [-- EXTRA-COMPOSE ...]
gate_case() {
  local name="$1" want="$2" pattern="$3" envf="$4" rc
  shift 4
  local assigns=() extra=(-f "$COMPOSE")
  while [ $# -gt 0 ]; do
    if [ "$1" = -- ]; then shift; for f in "$@"; do extra+=(-f "$f"); done; break; fi
    assigns+=("$1"); shift
  done
  echo "$name"
  env -u CORS_ORIGIN "${assigns[@]}" "$CHECK" "${extra[@]}" --env "$envf" > "$TMP/$name.out" 2>&1
  rc=$?
  if [[ $rc -ne $want ]]; then
    sed 's/^/    /' "$TMP/$name.out" >&2
    fail "$name" "check-env-completeness exited $rc, expected $want"
    return
  fi
  grep -Fq -- "$pattern" "$TMP/$name.out" || { sed 's/^/    /' "$TMP/$name.out" >&2; fail "$name" "output lacks: $pattern"; }
}
FUNNEL=https://wrfcoin-testnet.taila1c049.ts.net
gate_case env_gate_process_override_to_localhost_red 1 \
  "UNSAFE CORS_ORIGIN: 'http://localhost:5000' is a loopback origin" \
  "$(env_with process-red "$FUNNEL")" CORS_ORIGIN=http://localhost:5000
grep -Fq 'effective in: wrfcoin-backend, wrfcoin-governance, wrfcoin-iot' "$TMP/env_gate_process_override_to_localhost_red.out" \
  || fail env_gate_process_override_to_localhost_red "loopback not attributed to the rendered readers"
gate_case env_gate_process_override_to_valid_green 0 'CORS_ORIGIN: 1 non-loopback origin(s) (effective render' \
  "$(env_with process-green 'http://localhost:5000')" CORS_ORIGIN="$FUNNEL"
printf 'services:\n  wrfcoin-iot:\n    environment:\n      CORS_ORIGIN: http://localhost:5000\n' > "$TMP/iot-overlay.yml"
gate_case env_gate_overlay_override_red 1 \
  "'http://localhost:5000' is a loopback origin; no real browser is served from it (infra#1056) [effective in: wrfcoin-iot]" \
  "$(env_with overlay "$FUNNEL")" -- "$TMP/iot-overlay.yml"
envf="$(env_with interp unset)"
# shellcheck disable=SC2016 # a literal ${UI_ORIGIN} for compose to interpolate
printf '%s\n' 'UI_ORIGIN=http://127.0.0.1:5000' 'CORS_ORIGIN=${UI_ORIGIN}' >> "$envf"
gate_case env_gate_env_file_interpolation_red 1 "'http://127.0.0.1:5000' is a loopback origin" "$envf"
gate_case env_gate_process_interpolation_red 1 "'http://[::1]:5000' is a loopback origin" \
  "$(env_with interp-proc "\${UI_ORIGIN}")" 'UI_ORIGIN=http://[::1]:5000'
printf 'services: [not, a, mapping\n' > "$TMP/broken-overlay.yml"
gate_case env_gate_render_failure_red 1 'UNVERIFIED CORS_ORIGIN: effective compose render failed' \
  "$(env_with broken "$FUNNEL")" -- "$TMP/broken-overlay.yml"

# Codex round 5 on #1060: the policy is parsed, not string-matched, and it is
# ONE module shared by both gates. Every spelling a browser resolves to
# loopback/unspecified must fail, and so must a wildcard host or plain http.
check_case env_gate_expanded_ipv6_loopback_red 'https://[0:0:0:0:0:0:0:1]:5000' 1 "'https://[0:0:0:0:0:0:0:1]:5000' is a loopback origin"
check_case env_gate_ipv4_mapped_loopback_red 'https://[::ffff:127.0.0.1]' 1 "'https://[::ffff:127.0.0.1]' is a loopback origin"
check_case env_gate_short_ipv4_loopback_red 'https://127.1' 1 "'https://127.1' is a loopback origin"
check_case env_gate_hex_ipv4_loopback_red 'https://0x7f.0.0.1' 1 "'https://0x7f.0.0.1' is a loopback origin"
check_case env_gate_uppercase_localhost_red 'https://LOCALHOST' 1 "'https://LOCALHOST' is a loopback origin"
check_case env_gate_wildcard_host_red 'https://*.example.org' 1 "'https://*.example.org' is not a scheme://host[:port] origin"
check_case env_gate_unspecified_red 'https://0.0.0.0' 1 "'https://0.0.0.0' is an unspecified-address origin"
check_case env_gate_plain_http_red 'http://wrfcoin-testnet.taila1c049.ts.net' 1 "is not an https origin"

echo policy_module_unit_cases
POLICY="$ROOT/testnet/scripts/cors_origin_policy.py"
for bad in 'https://[0:0:0:0:0:0:0:1]' 'https://[::ffff:127.0.0.1]' 'https://127.1' 'https://0x7f.0.0.1' \
    'https://2130706433' 'https://0177.0.0.1' 'https://127.0.0.1.' 'https://LOCALHOST' 'https://a.LocalHost' \
    'https://*.example.org' 'http://*.example.org' 'https://0' 'https://[::]' 'http://example.org' \
    'https://example.org/app' 'https://u@example.org' 'https://example.org:0' 'https://1.2.3.4.5' '*' ''; do
  if python3 "$POLICY" --check "$bad" > /dev/null; then
    fail policy_module_unit_cases "accepted: '$bad'"
  fi
done
for good in 'https://wrfcoin-testnet.taila1c049.ts.net' 'https://testnet.example.org:8443' \
    'https://localhost.example.org' 'https://[2001:db8::1]' 'https://198.51.100.7' \
    'https://a.example.org, https://b.example.org'; do
  python3 "$POLICY" --check "$good" > "$TMP/policy-good.out" || fail policy_module_unit_cases "rejected: '$good': $(cat "$TMP/policy-good.out")"
done

echo env_gate_missing_overlay_refused
envf="$(env_with missing-overlay "$FUNNEL")"
if env -u CORS_ORIGIN "$CHECK" -f "$COMPOSE" -f "$TMP/does-not-exist.yml" --env "$envf" > "$TMP/missing-overlay.out" 2>&1; then
  fail env_gate_missing_overlay_refused "a missing -f overlay passed (compose itself would exit 1)"
elif ! grep -Fq "FAIL: requested compose file does not exist: $TMP/does-not-exist.yml" "$TMP/missing-overlay.out"; then
  sed 's/^/    /' "$TMP/missing-overlay.out" >&2
  fail env_gate_missing_overlay_refused "refused, but not for the missing file"
fi

# A chain with no CORS_ORIGIN reader (the gate's own fixtures, a non-backend
# overlay run alone) must not demand one.
echo env_gate_no_reader_in_chain_green
: > "$TMP/no-reader.yml"
envf="$(env_with no-reader unset)"
if ! env -u CORS_ORIGIN "$CHECK" -f "$TMP/no-reader.yml" --env "$envf" > "$TMP/no-reader.out" 2>&1; then
  sed 's/^/    /' "$TMP/no-reader.out" >&2
  fail env_gate_no_reader_in_chain_green "CORS_ORIGIN demanded by a chain that never reads it"
fi

render_skipped=0
if ! docker compose version >/dev/null 2>&1; then
  echo "SKIP: docker compose unavailable; render cases not run"
  render_skipped=1
else
  # render NAME VALUE|unset: config-only render of the base file, with the
  # `full` profile so all nine CORS_ORIGIN readers are in the render. Through
  # the canonical helper, which forces the same two P2P fixture addresses
  # env_with writes (check-compose-render-inventory.py).
  render() {
    local envf
    envf="$(env_with "$1" "$2")"
    bash "$ROOT/testnet/tests/render-testnet-compose.sh" --env-file "$envf" -f "$COMPOSE" --profile full \
      config --format json > "$TMP/$1.json" 2> "$TMP/$1.err"
  }

  for case_value in unset ''; do
    name="render_${case_value:-empty}_is_empty_not_localhost"
    echo "$name"
    # The shell env overrides --env-file in compose; make sure nothing leaks in.
    if (unset CORS_ORIGIN; render "$name" "$case_value"); then
      python3 - "$TMP/$name.json" "${SERVICES[@]}" <<'PY' || fail "$name" "unset CORS_ORIGIN did not render empty everywhere"
import json, sys
services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
got = {n: services.get(n, {}).get("environment", {}).get("CORS_ORIGIN") for n in sys.argv[2:]}
bad = {n: v for n, v in got.items() if v != ""}
if bad:
    raise SystemExit(f"expected empty, got {bad}")
PY
    else
      sed 's/^/    /' "$TMP/$name.err" >&2
      fail "$name" "compose refused to render with CORS_ORIGIN ${case_value:-empty} (the #762 trap)"
    fi
  done

  echo render_set_value_reaches_every_service
  want='https://wrfcoin-testnet.taila1c049.ts.net,https://testnet.example.org'
  if (unset CORS_ORIGIN; render render_set "$want"); then
    python3 - "$TMP/render_set.json" "$want" "${SERVICES[@]}" <<'PY' || fail render_set_value_reaches_every_service "rendered CORS_ORIGIN mismatch"
import json, sys
services = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
want, names = sys.argv[2], sys.argv[3:]
bad = {n: services.get(n, {}).get("environment", {}).get("CORS_ORIGIN") for n in names}
bad = {n: v for n, v in bad.items() if v != want}
leftover = {n for n, s in services.items() if "localhost" in str((s.get("environment") or {}).get("CORS_ORIGIN", ""))}
if bad or leftover:
    raise SystemExit(f"mismatch={bad} localhost={sorted(leftover)}")
PY
  else
    sed 's/^/    /' "$TMP/render_set.err" >&2
    fail render_set_value_reaches_every_service "compose refused a valid CORS_ORIGIN"
  fi
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "CORS_ORIGIN_TESTS=FAIL cases: ${FAILED[*]}" >&2
  exit 1
fi
if [[ $render_skipped -ne 0 ]]; then
  echo "CORS_ORIGIN_TESTS=UNVERIFIED render cases skipped (no docker compose)"
  exit 77
fi
echo CORS_ORIGIN_TESTS=PASS
