#!/usr/bin/env bash
# =============================================================================
# External exposure probe (infra#657 / infra#658)
# =============================================================================
# Proves the public-exposure negative FROM OUTSIDE THE TAILNET, where a
# correct-looking `tailscale serve/funnel` config is worthless as evidence.
#
# Run this on a machine with NO Tailscale (or Tailscale down) — the script
# refuses to run inside a tailnet, because from inside, "unreachable from the
# public internet" cannot be observed.
#
# Two modes, matching the two sides of an exposure change:
#
#   --mode closed          BEFORE any funnel is enabled: EVERYTHING must be
#                          unreachable, including the frontend.
#   --mode frontend-only   AFTER `tailscale funnel --https=443` for the
#                          frontend: the frontend MUST answer HTTP (control —
#                          a probe that passes with the node offline proves
#                          nothing), and every forbidden port must be closed.
#
# Forbidden ports (infra#658, enforced by infra#679): 4001 backend,
# 8081 explorer, 8080 faucet (dispenses funds — the live hazard),
# 8556 node chain-control API. Funnel-capable ports 8443/10000 are probed too:
# they are the only other ports Tailscale Funnel can ever publish, so a
# careless second funnel would surface there. 9444 is the tailnet-only
# full-API serve route (mobile#44): it must never answer from outside.
#
# Usage:
#   ./probe_public_exposure_external.sh --mode closed \
#       --host wrfcoin-testnet.taila1c049.ts.net [--wan-ip <home-wan-ip>]
#   ./probe_public_exposure_external.sh --mode frontend-only \
#       --host wrfcoin-testnet.taila1c049.ts.net [--wan-ip <home-wan-ip>]
#   ./probe_public_exposure_external.sh --self-test
#
# --readonly-api off|on (default off; infra#983): what the gated Stage 1.5
# station reads (GET /api/weather/stations, /api/stations/<id>/quality|earnings) must
# do through the host. `off` requires 404 — the shipped state. Pass `on` only
# after the owner has set PUBLIC_READONLY_API=on on the edge in a deploy window.
#
# Exit codes: 0 verdict PASS, 1 verdict FAIL, 2 usage/environment error.
# =============================================================================
set -u

MODE=""
HOST=""
WAN_IP=""
TIMEOUT=6
ALLOW_TAILNET=0
FRONTEND_URL=""            # derived from --host unless overridden (self-test)
# 9444: the tailnet-only full-API serve route (mobile#44, tailnet-api-serve.sh).
# From outside the tailnet it must read closed on the ts.net name AND the WAN
# IP; anything else means it leaked.
FORBIDDEN_PORTS="4001 8081 8080 8556 8443 10000 9444"
READONLY_API=off
FAILURES=()
CHECKS=0

usage() { sed -n '2,40p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --wan-ip) WAN_IP="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --frontend-url) FRONTEND_URL="$2"; shift 2 ;;
    --forbidden-ports) FORBIDDEN_PORTS="$2"; shift 2 ;;
    --allow-tailnet) ALLOW_TAILNET=1; shift ;;
    --readonly-api) READONLY_API="$2"; shift 2 ;;
    --self-test) MODE="self-test"; shift ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

# --- tailnet guard -----------------------------------------------------------
# From inside the tailnet every 100.64/10 address and every ts.net name is
# reachable regardless of what the public internet sees. Refuse to produce
# evidence from a vantage point that cannot observe the claim.
refuse_if_on_tailnet() {
  [ "$ALLOW_TAILNET" = 1 ] && return 0
  if command -v tailscale >/dev/null 2>&1; then
    if tailscale status --json 2>/dev/null | grep -q '"BackendState": *"Running"'; then
      echo "REFUSING: Tailscale is Running on this machine — this probe is only" >&2
      echo "meaningful from OUTSIDE the tailnet. Run 'tailscale down' first, or" >&2
      echo "use a machine without Tailscale." >&2
      exit 2
    fi
  fi
  if ip -4 addr 2>/dev/null | grep -qE 'inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    echo "REFUSING: a CGNAT/tailnet 100.64/10 address is configured here." >&2
    exit 2
  fi
}

# --- probes ------------------------------------------------------------------
# TCP reachability via curl exit codes: 6 (DNS), 7 (connect refused/unroutable)
# and 28 (timeout) mean CLOSED from this vantage point; anything else — 0, TLS
# or protocol garbage included — means a listener ANSWERED, i.e. OPEN. A
# TLS-only listener (the faucet serve) answers http:// probes with garbage, so
# it is correctly classified OPEN if it ever becomes reachable.
tcp_state() { # host port -> "open" | "closed" | "unresolved"
  # curl exit 6 is DNS failure, 7 connect-refused/unroutable, 28 timeout. Only
  # the latter two are evidence about a PORT; collapsing 6 into "closed" is how
  # a typo'd hostname reports six clean "unreachable" results.
  curl -m "$TIMEOUT" --connect-timeout "$TIMEOUT" -so /dev/null "http://$1:$2/" 2>/dev/null
  case $? in 6) echo unresolved ;; 7|28) echo closed ;; *) echo open ;; esac
}

host_resolves() { # host -> 0 when DNS (or a literal IP) resolves
  getent hosts "$1" >/dev/null 2>&1 && return 0
  # getent may be absent (macOS); fall back to curl's DNS-specific exit 6.
  curl -m "$TIMEOUT" --connect-timeout "$TIMEOUT" -so /dev/null "http://$1:80/" 2>/dev/null
  [ $? -ne 6 ]
}

frontend_http_code() { # url -> http code, or 000 when nothing answered
  # curl ALREADY prints 000 on a connection failure and exits non-zero, so a
  # `|| echo 000` fallback appends a SECOND 000 and yields '000000' — which made
  # `--mode closed` compare 000000 against 000, fail, and report "frontend
  # answered" about a frontend that was correctly unreachable. The gate could
  # never pass, and said the opposite of the truth when it failed.
  #
  # Retries (2026-08-17, first live funnel run): Tailscale's ingress
  # occasionally drops ONE of several back-to-back requests from the same
  # source — measured live: a different single check 000'd on each probe run,
  # and every one answered correctly when retried alone. Three spaced attempts
  # separate that ingress artifact from a genuinely dead endpoint. A REAL
  # non-answer still reports 000 — three times in a row.
  local out attempt
  for attempt in 1 2 3; do
    out="$(curl -m "$TIMEOUT" --connect-timeout "$TIMEOUT" -kso /dev/null -w '%{http_code}' "$1" 2>/dev/null)"
    [ -n "$out" ] || out=000
    [ "$out" != 000 ] && break
    [ "$attempt" -lt 3 ] && sleep 2
  done
  printf '%s' "$out"
}

check() { # description expected actual
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %-58s %s\n' "$1" "$3"
  else
    printf '  FAIL %-58s expected=%s got=%s\n' "$1" "$2" "$3"
    FAILURES+=("$1 (expected $2, got $3)")
  fi
}

probe_forbidden() { # target-label host
  local port state
  for port in $FORBIDDEN_PORTS; do
    state="$(tcp_state "$2" "$port")"
    # A *.ts.net hostname resolves to TAILSCALE'S ingress relays, never to the
    # operator's network. Whether those relays accept a raw TCP connect on the
    # funnel-capable ports (443/8443/10000) is Tailscale's behavior — measured
    # live 2026-08-17: 8443/10000 flip-flopped open/closed across runs while
    # `tailscale funnel status` bound only 443 and the SAME ports on the WAN
    # IP read closed in every run. The WAN-IP legs are the authoritative
    # evidence about the operator's surface; on a ts.net host these two are
    # reported informationally rather than graded.
    case "$2" in
      *.ts.net)
        if [ "$port" = 8443 ] || [ "$port" = 10000 ]; then
          printf '  info %-58s %s\n' "$1:$port (Tailscale relay port, informational)" "$state"
          continue
        fi
        ;;
    esac
    # "unresolved" is NOT evidence of a closed port — it fails, loudly.
    check "$1:$port unreachable" closed "$state"
  done
}

# --- through-host boundary (infra#657) ----------------------------------------
# Port checks alone cannot see the frontend-nginx bypass: nginx proxies /api/,
# /ws and /api/ws wholesale to the backend, so a funnel pointed at the frontend
# instead of the funnel-edge allowlist exposes the whole backend API ON THE
# SAME 443 the frontend answers. These checks probe the published host itself.
NONCE_PATH="/api/auth/nonce/0x0000000000000000000000000000000000000000"

probe_through_host_boundary() {
  local base="${FRONTEND_URL%/}" code

  # Non-allowlisted API and websocket paths must 404 at the edge. Through a
  # bare frontend-nginx funnel these reach the backend and answer non-404.
  code="$(frontend_http_code "$base/api/health")"
  check "boundary: GET /api/health 404s at the edge" 404 "$code"
  code="$(frontend_http_code "$base/ws")"
  check "boundary: GET /ws 404s at the edge" 404 "$code"
  code="$(frontend_http_code "$base/api/ws")"
  check "boundary: GET /api/ws 404s at the edge" 404 "$code"

  # CONTROL: an allowlisted route must be ADMITTED (any answer except 000 or
  # 404) — otherwise "everything 404s" would pass the three checks above with
  # the allowlist dead or the backend down. A backend that legitimately 404s
  # an admitted route trips this check; that is the fail-closed direction.
  code="$(frontend_http_code "$base$NONCE_PATH")"
  CHECKS=$((CHECKS + 1))
  if [ "$code" != 000 ] && [ "$code" != 404 ]; then
    printf '  ok   %-58s HTTP %s\n' "allowlist control: nonce route admitted" "$code"
  else
    printf '  FAIL %-58s got HTTP %s\n' "allowlist control: nonce route admitted" "$code"
    FAILURES+=("allowlisted nonce route not admitted (HTTP $code) — boundary 404s above would be vacuous")
  fi

  # infra#983: the gated Stage 1.5 station reads. Shipped OFF: they must 404
  # until the owner turns PUBLIC_READONLY_API on (then pass --readonly-api on).
  local path
  for path in /api/weather/stations /api/stations/wrfcoin-probe/quality /api/stations/wrfcoin-probe/earnings; do
    code="$(frontend_http_code "$base$path")"
    if [ "$READONLY_API" = off ]; then
      check "stage 1.5: GET $path 404s (PUBLIC_READONLY_API off)" 404 "$code"
    else
      CHECKS=$((CHECKS + 1))
      if [ "$code" != 000 ] && [ "$code" != 404 ]; then
        printf '  ok   %-58s HTTP %s\n' "stage 1.5: GET $path admitted (on)" "$code"
      else
        printf '  FAIL %-58s got HTTP %s\n' "stage 1.5: GET $path admitted (on)" "$code"
        FAILURES+=("--readonly-api on, but GET $path was not admitted (HTTP $code)")
      fi
    fi
  done
}

run_probe() {
  [ -n "$HOST" ] || { echo "--host is required" >&2; usage; }
  case "$READONLY_API" in off|on) ;; *) echo "--readonly-api must be 'off' or 'on'" >&2; usage ;; esac
  [ -n "$FRONTEND_URL" ] || FRONTEND_URL="https://$HOST/"
  refuse_if_on_tailnet
  echo "External exposure probe — mode=$MODE host=$HOST ${WAN_IP:+wan-ip=$WAN_IP }$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # CONTROL for both modes: a host that does not resolve makes every port probe
  # below vacuously "closed". In `closed` mode there is no frontend answer to
  # anchor on, so this IS the control — without it, a typo'd --host is a
  # confident PASS.
  CHECKS=$((CHECKS + 1))
  if host_resolves "$HOST"; then
    printf '  ok   %-58s %s\n' "host $HOST resolves (control)" "yes"
  else
    printf '  FAIL %-58s %s\n' "host $HOST resolves (control)" "no"
    FAILURES+=("$HOST does not resolve — every port result below would be vacuous")
  fi

  local code
  code="$(frontend_http_code "$FRONTEND_URL")"
  case "$MODE" in
    closed)
      # Nothing is published yet: the frontend must NOT answer either.
      if [ "$code" = 000 ]; then
        printf '  ok   %-58s %s\n' "frontend $FRONTEND_URL unreachable" "000"; CHECKS=$((CHECKS+1))
      else
        printf '  FAIL %-58s got HTTP %s\n' "frontend $FRONTEND_URL unreachable" "$code"; CHECKS=$((CHECKS+1))
        FAILURES+=("frontend answered HTTP $code while mode=closed")
      fi
      ;;
    frontend-only)
      # Control: with the frontend down this probe must fail, otherwise a dead
      # node would "pass" every negative check below.
      if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ]; then
        printf '  ok   %-58s HTTP %s\n' "frontend $FRONTEND_URL reachable (control)" "$code"; CHECKS=$((CHECKS+1))
      else
        printf '  FAIL %-58s got HTTP %s\n' "frontend $FRONTEND_URL reachable (control)" "$code"; CHECKS=$((CHECKS+1))
        FAILURES+=("frontend control not reachable (HTTP $code) — verdict would be vacuous")
      fi
      probe_through_host_boundary
      ;;
    *) echo "--mode must be 'closed' or 'frontend-only'" >&2; usage ;;
  esac

  probe_forbidden "$HOST" "$HOST"
  if [ -n "$WAN_IP" ]; then
    probe_forbidden "wan $WAN_IP" "$WAN_IP"
    # P2P 9000 is intentionally NOT asserted: infra#587 plans to publish it.
    printf '  info %-58s %s\n' "wan $WAN_IP:9000 (P2P, informational only)" "$(tcp_state "$WAN_IP" 9000)"
  fi

  echo
  if [ ${#FAILURES[@]} -eq 0 ]; then
    echo "VERDICT: PASS — $CHECKS/$CHECKS checks hold for mode=$MODE from outside the tailnet."
    exit 0
  fi
  echo "VERDICT: FAIL — ${#FAILURES[@]} of $CHECKS checks failed:"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
}

# --- self-test ---------------------------------------------------------------
# Proves the probe can actually detect a leak (the RED control): scenario B
# opens a listener on a "forbidden" port and the frontend-only mode MUST fail.
run_self_test() {
  command -v python3 >/dev/null 2>&1 || { echo "self-test needs python3" >&2; exit 2; }
  local fe_port=18500 leak_port=18501 fe_pid='' leak_pid='' rc_a rc_b
  local fixdir
  fixdir="$(mktemp -d)"
  # Edge-shaped fixture: allowlisted nonce path answers, everything else 404s
  # (http.server 404s any path without a file — the boundary shape).
  mkdir -p "$fixdir/ok/api/auth/nonce" "$fixdir/leaky/api/auth/nonce" "$fixdir/dead"
  printf 'nonce\n' >"$fixdir/ok/api/auth/nonce/0x0000000000000000000000000000000000000000"
  printf 'index\n' >"$fixdir/ok/index.html"
  # leaky: same as ok PLUS a reachable /api/health — the nginx-bypass shape.
  printf 'nonce\n' >"$fixdir/leaky/api/auth/nonce/0x0000000000000000000000000000000000000000"
  printf 'index\n' >"$fixdir/leaky/index.html"
  mkdir -p "$fixdir/leaky/api"
  printf 'healthy\n' >"$fixdir/leaky/api/health"
  # dead: frontend answers but the allowlist admits nothing.
  printf 'index\n' >"$fixdir/dead/index.html"
  # readonly: same as ok PLUS the gated Stage 1.5 reads answering (infra#983).
  mkdir -p "$fixdir/readonly/api/auth/nonce" "$fixdir/readonly/api/weather" "$fixdir/readonly/api/stations/wrfcoin-probe"
  printf 'nonce\n' >"$fixdir/readonly/api/auth/nonce/0x0000000000000000000000000000000000000000"
  printf 'index\n' >"$fixdir/readonly/index.html"
  printf '{}\n' >"$fixdir/readonly/api/weather/stations"
  printf '{}\n' >"$fixdir/readonly/api/stations/wrfcoin-probe/quality"
  printf '{}\n' >"$fixdir/readonly/api/stations/wrfcoin-probe/earnings"

  python3 -m http.server "$fe_port" --bind 127.0.0.1 --directory "$fixdir/ok" >/dev/null 2>&1 & fe_pid=$!
  trap '[ -n "$fe_pid" ] && kill "$fe_pid" 2>/dev/null; [ -n "$leak_pid" ] && kill "$leak_pid" 2>/dev/null; rm -rf "$fixdir"' EXIT
  sleep 1

  echo "=== self-test A: frontend up, boundary shaped, ports closed -> expect PASS ==="
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "$leak_port 18502"
  rc_a=$?

  echo
  echo "=== self-test B (RED control): forbidden port OPEN -> expect FAIL ==="
  python3 -m http.server "$leak_port" --bind 127.0.0.1 --directory "$fixdir/ok" >/dev/null 2>&1 & leak_pid=$!
  sleep 1
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "$leak_port 18502"
  rc_b=$?
  kill "$leak_pid" 2>/dev/null; leak_pid=''

  echo
  echo "=== self-test E (RED): /api/health reachable through the host (nginx bypass) -> expect FAIL ==="
  kill "$fe_pid" 2>/dev/null; fe_pid=''
  sleep 1
  python3 -m http.server "$fe_port" --bind 127.0.0.1 --directory "$fixdir/leaky" >/dev/null 2>&1 & fe_pid=$!
  sleep 1
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "18502" >/dev/null 2>&1
  local rc_e=$?

  echo "=== self-test F (RED): allowlist admits nothing (dead backend shape) -> expect FAIL ==="
  kill "$fe_pid" 2>/dev/null; fe_pid=''
  sleep 1
  python3 -m http.server "$fe_port" --bind 127.0.0.1 --directory "$fixdir/dead" >/dev/null 2>&1 & fe_pid=$!
  sleep 1
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "18502" >/dev/null 2>&1
  local rc_f=$?

  echo "=== self-test G (RED): Stage 1.5 reads answer while expected OFF -> expect FAIL ==="
  kill "$fe_pid" 2>/dev/null; fe_pid=''
  sleep 1
  python3 -m http.server "$fe_port" --bind 127.0.0.1 --directory "$fixdir/readonly" >/dev/null 2>&1 & fe_pid=$!
  sleep 1
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "18502" >/dev/null 2>&1
  local rc_g=$?
  echo "=== self-test H: same surface with --readonly-api on -> expect PASS ==="
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet --readonly-api on \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "18502" >/dev/null 2>&1
  local rc_h=$?
  echo "=== self-test I (RED): --readonly-api on against the shipped OFF surface -> expect FAIL ==="
  kill "$fe_pid" 2>/dev/null; fe_pid=''
  sleep 1
  python3 -m http.server "$fe_port" --bind 127.0.0.1 --directory "$fixdir/ok" >/dev/null 2>&1 & fe_pid=$!
  sleep 1
  "$0" --mode frontend-only --host 127.0.0.1 --allow-tailnet --readonly-api on \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "18502" >/dev/null 2>&1
  local rc_i=$?

  echo
  echo "=== self-test C: mode=closed against a fully closed surface -> expect PASS ==="
  kill "$fe_pid" 2>/dev/null; fe_pid=''
  sleep 1
  "$0" --mode closed --host 127.0.0.1 --allow-tailnet \
       --frontend-url "http://127.0.0.1:$fe_port/" --forbidden-ports "$leak_port 18502"
  local rc_c=$?

  echo
  echo "=== self-test D (RED): mode=closed with a host that does not resolve -> expect FAIL ==="
  "$0" --mode closed --host this-host-does-not-exist-wrfcoin.invalid --allow-tailnet \
       --forbidden-ports "4001 8081" >/dev/null 2>&1
  local rc_d=$?

  echo
  if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 1 ] && [ "$rc_c" -eq 0 ] && [ "$rc_d" -eq 1 ] \
     && [ "$rc_e" -eq 1 ] && [ "$rc_f" -eq 1 ] \
     && [ "$rc_g" -eq 1 ] && [ "$rc_h" -eq 0 ] && [ "$rc_i" -eq 1 ]; then
    echo "SELF-TEST: PASS — clean surface passes; exposed port, nginx-bypass leak and"
    echo "                  dead allowlist are each detected; closed-mode passes on a"
    echo "                  closed surface; an unresolvable host is refused; Stage 1.5"
    echo "                  reads are held to --readonly-api in both directions."
    exit 0
  fi
  echo "SELF-TEST: FAIL — A rc=$rc_a (want 0), B rc=$rc_b (want 1), C rc=$rc_c (want 0), D rc=$rc_d (want 1), E rc=$rc_e (want 1), F rc=$rc_f (want 1), G rc=$rc_g (want 1), H rc=$rc_h (want 0), I rc=$rc_i (want 1)."
  exit 1
}

case "$MODE" in
  self-test) run_self_test ;;
  *) run_probe ;;
esac
