#!/usr/bin/env bash
# =============================================================================
# Emergency wallet-secret-route block (security audit 2026-08-17)
# =============================================================================
# The deployed frontend serves seed-phrase / private-key ENTRY forms at /earn,
# /connect-station and /onboarding. Until the frontend ships browser-wallet
# signing, the public edge fail-closes those routes with a 302 to the
# read-only dashboard. This test pins the block's shape so it cannot silently
# regress — including the exact Caddy trap that made the first attempt a no-op.
#
# If `caddy` (or the edge image) is available, it additionally adapts the
# config and asserts the block became a real 302 static_response matched on the
# wallet paths. Without it, the static assertions still run (CI-safe, no
# Docker) and the adapt check is SKIPPED loudly rather than passing vacuously.
#
# Run: bash scripts/tests/test-edge-onboarding-block.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNIPPET="${REPO}/testnet/edge/public_onboarding.caddy"
FUNNEL="${REPO}/testnet/edge/Caddyfile.funnel"
DIRECT="${REPO}/testnet/edge/Caddyfile"

fails=0
assertions=0
check() {
  local name="$1"; shift
  assertions=$((assertions + 1))
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: edge-onboarding-check-forwards-argv
  if "$@"; then printf '  ok    %s\n' "$name"
  else printf '  FAIL  %s\n' "$name"; fails=$((fails + 1)); fi
}

echo "== the block exists; exact /onboarding is open, everything else stays blocked =="

if [[ -n "${S9_CADDY_BIN:-}" ]]; then
  check "S9 signed transfer real-Caddy runtime matrix" python3 "${REPO}/testnet/edge/verify_wallet_send_runtime.py" "${S9_CADDY_BIN}"
else
  echo "  SKIP  S9 runtime matrix (set S9_CADDY_BIN to the edge Caddy executable)"
fi
check "S9 boundary and weakening controls pass" python3 "${REPO}/testnet/edge/verify_public_exposure_boundary.py" --self-test
check "snippet defines (disabled_wallet_secret_routes)" \
  grep -q '(disabled_wallet_secret_routes)' "${SNIPPET}"

# The one matcher line, so a path elsewhere in the snippet cannot satisfy these checks.
matcher_line() { grep -E '^[[:space:]]*@wallet_secret_entry[[:space:]]+path[[:space:]]' "${SNIPPET}"; }
matcher_covers_blocked() {
  [ "$(matcher_line | wc -l)" -eq 1 ] &&
  matcher_line | grep -qE ' /earn/\*( |$)' &&
  matcher_line | grep -qE ' /connect-station/\*( |$)' &&
  matcher_line | grep -qE ' /onboarding/\*( |$)'
}
check "matcher still blocks /earn/*, /connect-station/* and /onboarding/*" matcher_covers_blocked
# Owner ruling 2026-10-02 #14 (FULL WEB JOIN PATH, W28): the exact /earn and /connect-station leave the
# block too (both render the create-only ConnectStationPage); every subpath stays blocked. The matcher
# lists exactly the three subpath families, nothing more and nothing less.
matcher_paths() { matcher_line | sed -E 's/^[[:space:]]*@wallet_secret_entry[[:space:]]+path[[:space:]]+//' | tr -s ' \t' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
check "matcher lists exactly /connect-station/* /earn/* /onboarding/*" \
  bash -c '[ "$1" = "/connect-station/* /earn/* /onboarding/* " ]' _ "$(matcher_paths)"
check "the 2026-10-02 reopening of /earn and /connect-station cites the owner ruling" \
  bash -c 'grep -q "owner ruling 2026-10-02" "$1"' _ "${SNIPPET}"
# Owner ruling 2026-10-01 (web onboarding opens; frontend#437): frontend#440 made the
# exact /onboarding page key-free in the public build, so only that path leaves the block.
check "matcher no longer lists the exact /onboarding" bash -c '! grep -E "^[[:space:]]*@wallet_secret_entry[[:space:]]+path[[:space:]]" "$1" | grep -qE " /onboarding( |$)"' _ "${SNIPPET}"
check "the reopening cites frontend#440 and the owner ruling" \
  bash -c 'grep -q "frontend#440" "$1" && grep -q "owner ruling 2026-10-01" "$1"' _ "${SNIPPET}"

echo "== the redir-matcher trap is NOT reintroduced =="

# `redir / 302` parses `/` as a PATH MATCHER, silently redirecting only the
# path `/` to the URL `302` — a no-op for /connect-station. The block MUST use
# an explicit relative Location + respond instead. Guard both directions.
# Strip comment lines first — the snippet documents the trap in prose, and
# that mention must not trip the guard; only a real directive should.
check "block does NOT use the buggy 'redir / 302' form" \
  bash -c "! grep -vE '^[[:space:]]*#' '${SNIPPET}' | grep -qE 'redir[[:space:]]+/[[:space:]]+30[0-9]'"

emits_relative_302() {
  # header Location / (relative — no scheme, so no https->http downgrade behind
  # the funnel) AND respond 302, inside the disabled-routes handle.
  grep -qE 'header[[:space:]]+Location[[:space:]]+/[[:space:]]*$' "${SNIPPET}" &&
  grep -qE 'respond[[:space:]]+302' "${SNIPPET}"
}
check "block emits a relative Location / with respond 302" emits_relative_302

echo "== both public edges import the block before the frontend catch-all =="

imports_before_frontend() {
  local file="$1" imp fe
  imp="$(grep -n 'import disabled_wallet_secret_routes' "$file" | head -1 | cut -d: -f1)"
  fe="$(grep -n 'reverse_proxy wrfcoin-testnet-frontend' "$file" | head -1 | cut -d: -f1)"
  [ -n "$imp" ] && [ -n "$fe" ] && [ "$imp" -lt "$fe" ]
}
check "funnel edge imports the block before the frontend proxy" imports_before_frontend "${FUNNEL}"
check "direct edge imports the block before the frontend proxy" imports_before_frontend "${DIRECT}"

status_json_is_get_only() {
  local block
  block="$(grep -A5 '@public_status {' "${SNIPPET}")"
  grep -qE 'method[[:space:]]+GET' <<<"$block" &&
  grep -qE 'path[[:space:]]+/status\.json' <<<"$block" &&
  grep -qE 'handle[[:space:]]+/status\.json\*' "${SNIPPET}" &&
  grep -A2 -E 'handle[[:space:]]+/status\.json\*' "${SNIPPET}" | grep -qE 'respond.*404'
}
check "GET /status.json is exact and POST/sibling paths fail closed" status_json_is_get_only

echo "== the funnel edge trusts exactly the pinned ingress gateway (backend#1229, infra#884) =="

# History: #885 added `trusted_proxies static private_ranges` + strict; infra#884
# removed both because it was unknown whether tailscale funnel appends to or
# passes through X-Forwarded-For. backend#1229 established from tailscale's
# source that tailscaled REPLACES the header with the true source address, so
# the funnel edge now trusts exactly one hop -- the pinned wrfcoin-ingress
# gateway that docker-proxy delivers its 127.0.0.1:8444 traffic from -- with
# strict (rightmost-untrusted) parsing.
#
# These guard that decision: the trusted set must stay that single /32 (never
# private_ranges or any wider range, which is what made #885 spoofable), strict
# must accompany it, and the address must match the compose pin.

check "funnel edge trusts exactly one hop: static 10.251.0.1/32" \
  bash -c '[ "$(grep -cE "^[[:space:]]*trusted_proxies([[:space:]]|$)" "$1")" = 1 ] &&
    grep -qE "^[[:space:]]*trusted_proxies[[:space:]]+static[[:space:]]+10\.251\.0\.1/32[[:space:]]*$" "$1"' _ "${FUNNEL}"

check "funnel edge never trusts private_ranges or a wider range" \
  bash -c '! grep -E "^[[:space:]]*trusted_proxies([[:space:]]|$)" "$1" | grep -qE "private_ranges|/(0|[1-9]|[12][0-9]|3[01])([[:space:]]|$)"' _ "${FUNNEL}"

check "funnel edge sets trusted_proxies_strict alongside it" \
  bash -c 'grep -qE "^[[:space:]]*trusted_proxies_strict[[:space:]]*$" "$1"' _ "${FUNNEL}"

COMPOSE_BASE="${REPO}/testnet/docker-compose.testnet.yml"
COMPOSE_FUNNEL="${REPO}/testnet/docker-compose.funnel-edge.yml"
check "the trusted address is the pinned wrfcoin-ingress gateway" \
  bash -c 'grep -qE "^[[:space:]]*gateway:[[:space:]]*10\.251\.0\.1[[:space:]]*$" "$1" &&
    grep -qE "^[[:space:]]*-[[:space:]]*subnet:[[:space:]]*10\.251\.0\.0/24[[:space:]]*$" "$1"' _ "${COMPOSE_BASE}"
check "funnel-edge is pinned on wrfcoin-ingress only" \
  bash -c 'grep -A3 -E "^[[:space:]]+networks:" "$1" | grep -qE "ipv4_address:[[:space:]]*10\.251\.0\.12" &&
    ! grep -qE "^[[:space:]]+-[[:space:]]*wrfcoin-testnet[[:space:]]*$" "$1"' _ "${COMPOSE_FUNNEL}"

echo "== runtime adapt check (skipped without caddy/edge image) =="

CADDY_IMG="wrfcoin/edge-caddy:testnet-local"
adapt_json=""
if command -v caddy >/dev/null 2>&1; then
  adapt_json="$(cd "${REPO}/testnet/edge" && caddy adapt --config Caddyfile.funnel --adapter caddyfile 2>/dev/null)"
elif command -v docker >/dev/null 2>&1 && docker image inspect "${CADDY_IMG}" >/dev/null 2>&1; then
  adapt_json="$(cd "${REPO}/testnet/edge" && docker run --rm \
    -v "$PWD/Caddyfile.funnel:/etc/caddy/Caddyfile:ro" \
    -v "$PWD/public_onboarding.caddy:/etc/caddy/public_onboarding.caddy:ro" \
    -v "$PWD/downloads.caddy:/etc/caddy/downloads.caddy:ro" \
    "${CADDY_IMG}" caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null)"
fi

if [ -z "${adapt_json}" ]; then
  echo "  SKIP  no caddy binary and no ${CADDY_IMG} image — adapt check not run"
else
  adapt_has_302_on_wallet_paths() {
    printf '%s' "${adapt_json}" | python3 -c '
import json,sys
d=json.load(sys.stdin); s=json.dumps(d)
# a static_response with status 302 must exist, matched on a wallet path,
# and the redirect must NOT be gated behind an inner path:["/"] (the trap).
import re
ok = "connect-station" in s and "\"status_code\": 302" in s.replace(" ","").replace("\"status_code\":302","\"status_code\": 302")
# reject the trap signature: a static_response whose ONLY governing path match is "/"
trap = re.search(r"static_response.{0,120}\"status_code\":\s*302.{0,200}\"path\":\s*\[\"/\"\]", s)
sys.exit(0 if (ok and not trap) else 1)
' 2>/dev/null
  }
  check "adapted config has a 302 on the wallet paths (no redir-/ trap)" adapt_has_302_on_wallet_paths
fi

echo "== runtime path matrix against the real edge (skipped without the edge image) =="

# A throwaway edge from this checkout's funnel config (no upstream runs, so a request the
# edge lets through reaches the frontend proxy and answers 502/503). Blocked: 302 to `/`.
# Non-canonical spellings are refused with 400 before routing (public_onboarding_api).
# Caddy's path matcher is case-insensitive and matches the unescaped path, so case and
# %-encoded variants follow their canonical path.
if command -v docker >/dev/null 2>&1 && docker image inspect "${CADDY_IMG}" >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  probe_name="edge-onboarding-test-$$"
  if docker run -d --rm --name "${probe_name}" -p 127.0.0.1::8444 \
      -v "${REPO}/testnet/edge/Caddyfile.funnel:/etc/caddy/Caddyfile:ro" \
      -v "${REPO}/testnet/edge/public_onboarding.caddy:/etc/caddy/public_onboarding.caddy:ro" \
      -v "${REPO}/testnet/edge/downloads.caddy:/etc/caddy/downloads.caddy:ro" \
      "${CADDY_IMG}" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null; then
    trap 'docker stop "${probe_name}" >/dev/null 2>&1' EXIT
    probe_port="$(docker port "${probe_name}" 8444/tcp | head -1 | sed 's/.*://')"
    for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${probe_port}/" && break; sleep 0.2; done
    edge_answer() { curl -s --path-as-is -o /dev/null --max-time 5 -w '%{http_code} %{redirect_url}' "http://127.0.0.1:${probe_port}$1"; }
    passes() { case "$(edge_answer "$1")" in 502\ *|503\ *) return 0 ;; *) return 1 ;; esac; }
    blocked() { [ "$(edge_answer "$1")" = "302 http://127.0.0.1:${probe_port}/" ]; }
    refused() { [ "$(edge_answer "$1")" = "400 " ]; }
    for p in /onboarding /Onboarding /ONBOARDING '/onboarding?ref=x' /%6Fnboarding \
             /earn /EARN /Earn '/earn?ref=x' /%65arn \
             /connect-station /Connect-Station /CONNECT-STATION '/connect-station?ref=x' /connect%2Dstation; do
      check "edge lets ${p} through to the frontend" passes "$p"
    done
    # Trailing slash: /onboarding/, /earn/ and /connect-station/ are subpaths (they match the /x/* form)
    # and stay blocked; the frontend's public sets are the exact paths too.
    for p in /onboarding/ /onboarding/x /onboarding/qr /Onboarding/x /ONBOARDING/QR /%6Fnboarding/x \
             /earn/ /earn/x /Earn/x /EARN/X '/earn/x?ref=y' /%65arn/x \
             /connect-station/ /connect-station/x /Connect-Station/x '/connect-station/x?ref=y' /connect%2Dstation/x; do
      check "edge still 302s ${p} to /" blocked "$p"
    done
    for p in /onboarding%2Fx /onboarding%2fx /onboarding//x /onboarding/./x /x/../onboarding/x /onboarding%2F /earn%2Fx \
             /earn//x /earn/./x /x/../earn/x /earn/x/.. /connect-station%2Fx /connect-station//x /connect-station/./x \
             /x/../connect-station/x; do
      check "edge refuses the non-canonical ${p} (400, never routed)" refused "$p"
    done
    # Owner ruling 2026-10-02 (frontend#463): the signed-in wallet's own phone-station status. This throwaway
    # edge has no backend behind it, so an admitted /api route answers 502/503 (proxied to the backend) and an
    # unadmitted one answers the edge's own 404.
    api_answer() {
      curl -s --path-as-is -o /dev/null --max-time 5 -w '%{http_code}' -X "$1" \
        -H 'Authorization: Bearer test-session' "http://127.0.0.1:${probe_port}$2"
    }
    to_backend() { case "$(api_answer "$1" "$2")" in 502|503) return 0 ;; *) return 1 ;; esac; }
    edge_404() { [ "$(api_answer "$1" "$2")" = "404" ]; }
    check "GET /api/weather/stations/mobile with a session reaches the backend" \
      to_backend GET /api/weather/stations/mobile
    for v in 'GET /api/weather/stations/mobile?x=1' 'GET /api/weather/stations/mobile?status=on_chain' \
             'POST /api/weather/stations/mobile' 'PUT /api/weather/stations/mobile' 'DELETE /api/weather/stations/mobile' \
             'GET /api/weather/stations/mobile/x' 'GET /api/weather/stations/mobile/challenge' \
             'POST /api/weather/stations/mobile/challenge' 'GET /api/weather/stations/mobilex'; do
      # shellcheck disable=SC2086
      check "edge 404s ${v} (query, method and subpath variants stay off)" edge_404 $v
    done
    for p in /api/weather/stations/./mobile /api/weather/stations//mobile /api/weather/stations/mobile/.. \
             /api/weather/stations/mobile%2Fx; do
      check "edge refuses the non-canonical ${p} (400, never routed)" refused "$p"
    done
    # No other route moved: the gated station list stays off, registration and reward progress still proxy.
    check "GET /api/weather/stations (Stage 1.5, gated off) still 404s" edge_404 GET /api/weather/stations
    check "GET /api/stations/abc/earnings (Stage 1.5/backend#1232, gated off) still 404s" edge_404 GET /api/stations/abc/earnings
    check "GET /api/weather/leaderboard (backend#1456, gated off) still 404s" edge_404 GET \
      '/api/weather/leaderboard?metric=earnings&period=30d&limit=30'
    check "GET /api/stations/<alias>/ownership (infra#1095, gated off) still 404s" edge_404 GET /api/stations/st_0123456789ab/ownership
    check "POST /api/stations/<alias>/owner-actions (infra#1095, ungated) reaches the backend" \
      to_backend POST /api/stations/st_0123456789ab/owner-actions
    check "POST /api/stations/<raw id>/owner-actions (infra#1095) stays off" edge_404 POST /api/stations/abc/owner-actions
    check "GET /api/stations/<alias>/owner-actions (infra#1095) stays off" edge_404 GET /api/stations/st_0123456789ab/owner-actions
    check "POST /api/weather/stations still reaches the backend" to_backend POST /api/weather/stations
    # S1 + S2 website-parity reads (own wallet with Bearer, governance, weather): gated by PUBLIC_READONLY_API,
    # which this throwaway edge leaves unset, so every one of them (bearer sent) must still 404. The admitted
    # and refused shapes with the gate ON are proven by testnet/edge/verify_public_exposure_runtime.py.
    wallet_addr=0xa1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
    for v in "GET /api/wallet/${wallet_addr}" "GET /api/wallet/${wallet_addr}/transactions?limit=20&offset=0" \
             'GET /api/governance/proposals' 'GET /api/governance/proposals/prop-002' 'GET /api/governance/treasury' \
             'GET /api/weather/current/47.6,-122.3' 'GET /api/weather/forecast/47.6,-122.3?days=14' \
             'GET /api/weather/forecast/47.6,-122.3?type=hourly&days=1'; do
      # shellcheck disable=SC2086
      check "S1/S2 parity read gated off still 404s: ${v}" edge_404 $v
    done
    # S9 submit and nonce are admitted only with the gate on; this fixture leaves it off.
    for v in "POST /api/wallet/send" "GET /api/wallet/${wallet_addr}/nonce" "POST /api/wallet/${wallet_addr}/transactions" \
             'POST /api/governance/proposals' 'GET /api/governance/treasury/transactions' \
             'GET /api/weather/data/47.6,-122.3' 'GET /api/weather/historical/47.6,-122.3'; do
      # shellcheck disable=SC2086
      check "S1/S2 sibling stays 404: ${v}" edge_404 $v
    done
    check "GET .../reward-progress still reaches the backend" to_backend GET /api/weather/stations/abc/reward-progress
  else
    echo "  SKIP  could not start ${CADDY_IMG} — runtime path matrix not run"
  fi
else
  echo "  SKIP  no docker/${CADDY_IMG}/curl — runtime path matrix not run"
fi

echo ""
echo "${assertions} assertions, ${fails} failures"
[ "${fails}" -eq 0 ]
