#!/usr/bin/env bash
# The docs-sync gate's mode from the three PRODUCTION_* variables (infra#27 review):
# none set -> docs-sync with a notice; all set -> all; any partial set -> exit 2 with an
# error naming the empty ones. Every one of the 8 combinations, plus the workflow wiring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE_SCRIPT="${MODE_SCRIPT_UNDER_TEST:-$ROOT/scripts/docs-sync-gateway-mode.sh}"
WORKFLOW="$ROOT/.github/workflows/docs-sync-production-gateway-gate.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/docs-sync-gateway-mode.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cases=0

# Distinctive synthetic values: none of them may ever appear in the output.
BASE='https://synthetic-main.example.invalid'
WS='wss://synthetic-ws.example.invalid'
COMPUTE='https://synthetic-compute.example.invalid'

run_case() { # $1 $2 $3: 1 = set, 0 = empty, for BASE, WS, COMPUTE
  local status=0
  env -i PATH="$PATH" \
    MAIN_API_BASE_URL="$( [ "$1" = 1 ] && echo "$BASE" )" \
    MAIN_API_WS_URL="$( [ "$2" = 1 ] && echo "$WS" )" \
    COMPUTE_API_BASE_URL="$( [ "$3" = 1 ] && echo "$COMPUTE" )" \
    bash "$MODE_SCRIPT" >"$TMP/out" 2>"$TMP/err" || status=$?
  echo "$status"
}

for combo in 000 001 010 011 100 101 110 111; do
  b=${combo:0:1}; w=${combo:1:1}; c=${combo:2:1}
  status="$(run_case "$b" "$w" "$c")"
  out="$(cat "$TMP/out")"; err="$(cat "$TMP/err")"
  if grep -qF -e "$BASE" -e "$WS" -e "$COMPUTE" "$TMP/out" "$TMP/err"; then fail "$combo printed a value"; fi
  case "$combo" in
    000)
      [ "$status" = 0 ] || fail "none set: exit $status"
      [ "$out" = docs-sync ] || fail "none set: mode '$out'"
      grep -q '^::notice::PRODUCTION_\* variables are not set; running docs-sync only, gateway check skipped$' "$TMP/err" \
        || fail "none set: notice missing: $err"
      ;;
    111)
      [ "$status" = 0 ] || fail "all set: exit $status"
      [ "$out" = all ] || fail "all set: mode '$out'"
      [ -z "$err" ] || fail "all set: unexpected stderr: $err"
      ;;
    *)
      [ "$status" = 2 ] || fail "partial $combo: exit $status (want 2)"
      [ -z "$out" ] || fail "partial $combo: a mode was printed: '$out'"
      grep -q '^::error title=Partial production gateway configuration::' "$TMP/err" || fail "partial $combo: no error annotation: $err"
      # The error names every empty variable and only those.
      for i in 0 1 2; do
        name=(MAIN_API_BASE_URL MAIN_API_WS_URL COMPUTE_API_BASE_URL); n="${name[$i]}"
        if [ "${combo:$i:1}" = 0 ]; then
          grep -q "empty or unset: .*\\b$n\\b" "$TMP/err" || fail "partial $combo: $n not named as empty: $err"
        else
          grep -q "set: .*\\b$n\\b.*; empty or unset" "$TMP/err" || fail "partial $combo: $n not named as set: $err"
        fi
      done
      ;;
  esac
  cases=$((cases + 1))
done

# The workflow maps exactly these three names from the PRODUCTION_* variables and lets the
# script decide; the old inline any-empty-skips check must not come back.
# The patterns below are literal workflow text (${{ }} and $(...)), never meant to expand.
# shellcheck disable=SC2016
grep -qF 'MAIN_API_BASE_URL: ${{ vars.PRODUCTION_MAIN_API_BASE_URL }}' "$WORKFLOW" || fail "workflow no longer maps MAIN_API_BASE_URL"
grep -qF 'MAIN_API_WS_URL: ${{ vars.PRODUCTION_MAIN_API_WS_URL }}' "$WORKFLOW" || fail "workflow no longer maps MAIN_API_WS_URL"
grep -qF 'COMPUTE_API_BASE_URL: ${{ vars.PRODUCTION_COMPUTE_API_BASE_URL }}' "$WORKFLOW" || fail "workflow no longer maps COMPUTE_API_BASE_URL"
grep -qF 'MODE="$(bash scripts/docs-sync-gateway-mode.sh)" || exit 1' "$WORKFLOW" || fail "workflow does not take its mode from the script (or ignores its failure)"
if grep -qE '\[ -z "\$(MAIN_API_BASE_URL|MAIN_API_WS_URL|COMPUTE_API_BASE_URL)" \]' "$WORKFLOW"; then
  fail "workflow still has an inline empty-variable check"
fi
cases=$((cases + 1))

echo "PASS docs-sync gateway mode: $cases checks (8 variable combinations + workflow wiring)"
