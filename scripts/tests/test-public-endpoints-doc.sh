#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDER="${ROOT}/testnet/scripts/render-public-endpoints.sh"

"$RENDER" --check

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "${ROOT}/testnet/edge/route-ledger.yml" "$tmp/route-ledger.yml"
printf '\n  mutation-only-service: { exposure: tailnet-direct, ports: { api: "127.0.0.1:9999" }, auth: none }\n' >>"$tmp/route-ledger.yml"
if ROUTE_LEDGER="$tmp/route-ledger.yml" "$RENDER" --check >/dev/null 2>&1; then
  echo "FAIL: ledger mutation did not make generated documentation stale" >&2
  exit 1
fi

# infra#983: the gated Stage 1.5 reads must be rendered as OFF-by-default, and
# removing the gate from the allowlist must make the document stale.
# shellcheck disable=SC2016  # the backticks are literal markdown, not expansion
gated_rows=$(grep -cF 'OFF unless the edge env has `PUBLIC_READONLY_API=on`' "${ROOT}/testnet/PUBLIC_ENDPOINTS.md" || true)
# backend#1481 adds the earnings leaderboard and opaque public profile.
# S1+S2 adds seven website-parity reads (own wallet x2, governance x3, weather x2).
# S9 adds the signed-transfer submit (POST /api/wallet/send) and the own-wallet nonce read.
# infra#46 adds the two passkey send routes (POST send-passkey and its nonce read).
# backend#30 adds the public passkey-wallet balance read.
# The forecaster pages add two reads (list + c_ profile); the mobile explorer adds its summary.
# backend#229 adds the proof card read.
# The producers and bonded nodes page adds its one read.
if [[ "$gated_rows" != 24 ]]; then
  echo "FAIL: expected 24 gated rows in PUBLIC_ENDPOINTS.md, found ${gated_rows}" >&2
  exit 1
fi
sed '/vars {env.PUBLIC_READONLY_API} on/d' "${ROOT}/testnet/edge/public_onboarding.caddy" >"$tmp/ungated.caddy"
if CADDY_FILE="$tmp/ungated.caddy" "$RENDER" --check >/dev/null 2>&1; then
  echo "FAIL: removing the PUBLIC_READONLY_API gate did not make generated documentation stale" >&2
  exit 1
fi

# grep, not rg: CI hosts (CT102) may lack ripgrep, and "rg: command not found"
# used to read as "no match" (infra#1005). grep exits 0 = match, 1 = no match,
# anything else = the search itself failed, which must not pass as clean.
status=0
grep -rnE --include='*.md' --exclude='PUBLIC_ENDPOINTS.md' \
  '100\.80\.70\.92' "${ROOT}/testnet" >"$tmp/forbidden-hits" 2>"$tmp/grep-err" || status=$?
case "$status" in
  0)
    cat "$tmp/forbidden-hits" >&2
    echo "FAIL: forbidden retired tailnet IP remains in tester-facing documentation" >&2
    exit 1
    ;;
  1) ;;
  *)
    cat "$tmp/grep-err" >&2
    echo "FAIL: forbidden-literal search could not run (grep exit $status)" >&2
    exit 1
    ;;
esac

echo "public endpoints doc: GREEN; ledger mutation, gate removal and forbidden literal: RED"
