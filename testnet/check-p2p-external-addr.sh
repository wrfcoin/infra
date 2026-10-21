#!/usr/bin/env bash
# =============================================================================
# WRFCOIN_P2P_EXTERNAL_ADDR preflight (infra#673)
# =============================================================================
# A node that advertises a multiaddr nothing answers on fails SILENTLY: its own
# health stays green, inbound peers still connect, but every remote dial to the
# advertised address dies — exactly the failure #673 found live, where the
# reference node advertised an unreachable address. Tests use TEST-NET-1.
#
# This script actually DIALS the advertised address instead of trusting it.
# Run it on the node host after setting WRFCOIN_P2P_EXTERNAL_ADDR and after
# every restart of the node (DHCP leases move — CT101's LAN address is DHCP).
#
# Usage:
#   ./check-p2p-external-addr.sh [multiaddr]        # arg, else $WRFCOIN_P2P_EXTERNAL_ADDR
#   ./check-p2p-external-addr.sh --env-file .env    # read the var from an env file
#   ./check-p2p-external-addr.sh --require [...]    # empty/unset is a FAILURE
#                                                   # (reference/bootstrap nodes MUST advertise)
#   WRFCOIN_P2P_GUARD_TEST_MODE=1 ./check-p2p-external-addr.sh --test-only --validate-only [...]
#                                                   # explicit test-only syntax/policy check; no dial
#   ./check-p2p-external-addr.sh --self-test
#
# Verdicts:
#   PASS  the advertised address accepted a TCP connection from here
#   WARN  public address unreachable from here — NAT hairpin can false-negative;
#         prove it with a dial from outside (see testnet/edge/ probe pattern)
#   FAIL  private/tailnet address unreachable (self-dial must work), vacant
#         address (connect timeout), connection refused, unparsable multiaddr,
#         or unset under --require
#
# Exit codes: 0 PASS (or unset without --require), 1 FAIL, 2 usage error, 3 WARN.
# =============================================================================
set -u

ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-}"
REQUIRE=0
TIMEOUT=6
SELF_TEST=0
VALIDATE_ONLY=0
TEST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)
      [ -f "$2" ] || { echo "no such env file: $2" >&2; exit 2; }
      ADDR="$(sed -n 's/^[[:space:]]*WRFCOIN_P2P_EXTERNAL_ADDR=//p' "$2" | tail -1 | tr -d '"' | tr -d "'")"
      shift 2 ;;
    --require) REQUIRE=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    --test-only) TEST_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) ADDR="$1"; shift ;;
  esac
done

if [ "$VALIDATE_ONLY" = 1 ] && { [ "$TEST_ONLY" != 1 ] || [ "${WRFCOIN_P2P_GUARD_TEST_MODE:-}" != "1" ]; }; then
  echo "FAIL: --validate-only is test-only; use --test-only with WRFCOIN_P2P_GUARD_TEST_MODE=1." >&2
  echo "      Production startup must perform the bounded TCP reachability proof." >&2
  exit 1
fi

is_private() { # ipv4 -> 0 if RFC1918 / CGNAT-tailnet / loopback / link-local
  case "$1" in
    10.*|192.168.*|127.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 0 ;;
    *) return 1 ;;
  esac
}

is_private_addr() { # kind host -> 0 when the address is private/tailnet-scoped
  case "$1" in
    ip4) is_private "$2" ;;
    ip6)
      # loopback, ULA (fc00::/7), link-local (fe80::/10), and Tailscale's
      # fd7a:115c:a1e0::/48 all self-dial; anything else is public.
      case "$2" in
        ::1|fc*|fd*|FC*|FD*|fe8*|fe9*|fea*|feb*|FE8*|FE9*|FEA*|FEB*) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    dns)
      # A name that resolves only inside the tailnet still self-dials; a public
      # name does not have to. Treat *.ts.net and localhost as private, the
      # rest as public - the conservative direction, since a public name
      # wrongly called private would FAIL under hairpin.
      case "$2" in
        localhost|*.ts.net) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# Reject anything that is not a bare host literal BEFORE it reaches the dialer.
# Unvalidated hosts were both an injection vector and - the part that mattered -
# a FALSE PASS: '/ip4/127.0.0.1;echo x/tcp/18762' dialed 127.0.0.1, succeeded,
# and certified a vacant advertisement as honest. A checker that can emit a
# false PASS is worse than no checker (that is #673's whole lesson).
is_valid_host() { # host -> 0 when it is a plain IPv4/IPv6/DNS literal
  case "$1" in
    *[!0-9A-Za-z.:_-]*) return 1 ;;   # any shell metacharacter, space, slash
    '') return 1 ;;
    *) return 0 ;;
  esac
}

is_valid_ip() { # host version -> 0 when host is a syntactically valid IP
  python3 -c '
import ipaddress
import sys

value = ipaddress.ip_address(sys.argv[1])
raise SystemExit(0 if value.version == int(sys.argv[2]) else 1)
' "$1" "$2" >/dev/null 2>&1
}

is_valid_dns_host() { # host -> 0 when host uses DNS label syntax
  local host="$1" label
  local -a labels
  [ -n "$host" ] || return 1
  [ "${#host}" -le 253 ] || return 1
  case "$host" in
    .*|*.) return 1 ;;
  esac
  local IFS=.
  read -r -a labels <<< "$host"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

dial() { # host port -> 0 open, 124 timeout(vacant/filtered), other refused
  # Host/port are passed as ARGUMENTS ($0/$1 inside the child), never
  # interpolated into the -c string. shellcheck SC2016 is expected and correct:
  # not expanding here is the entire point.
  # shellcheck disable=SC2016
  timeout "$TIMEOUT" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "$1" "$2" 2>/dev/null
}

require_runtime_proof_tools() {
  local tool
  for tool in timeout bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "FAIL: runtime reachability proof tool is unavailable: $tool" >&2
      return 1
    fi
  done
}

check_addr() { # multiaddr -> exit per header
  local addr="$1" host="" port="" kind=""
  case "$addr" in
    /ip4/*/tcp/*) kind=ip4 ;;
    /ip6/*/tcp/*) kind=ip6 ;;
    /dns4/*/tcp/*|/dns/*/tcp/*) kind=dns ;;
    *)
      echo "FAIL: cannot parse multiaddr '$addr' — expected /ip4/<ip>/tcp/<port> (or /ip6/, /dns4/)"
      return 1 ;;
  esac
  host="$(printf '%s' "$addr" | cut -d/ -f3)"
  port="$(printf '%s' "$addr" | cut -d/ -f5)"
  case "$port" in ''|*[!0-9]*) echo "FAIL: bad tcp port in '$addr'"; return 1 ;; esac
  if [ "${#port}" -gt 5 ] || ! port_value=$((10#$port)) || [ "$port_value" -lt 1 ] || [ "$port_value" -gt 65535 ]; then
    echo "FAIL: tcp port must be between 1 and 65535 in '$addr'"
    return 1
  fi
  if ! is_valid_host "$host"; then
    echo "FAIL: '$addr' contains an invalid host component ('$host') - refusing to dial it."
    echo "      A malformed multiaddr must never reach the dialer: it can succeed on a"
    echo "      prefix and certify a vacant advertisement as honest."
    return 1
  fi

  case "$kind" in
    ip4|ip6)
      if ! is_valid_ip "$host" "${kind#ip}"; then
        echo "FAIL: '$host' is not a valid ${kind} address in '$addr'"
        return 1
      fi
      ;;
    dns)
      if ! is_valid_dns_host "$host"; then
        echo "FAIL: '$host' is not a valid DNS host in '$addr'"
        return 1
      fi
      ;;
  esac

  # TEST-NET-1 stands in for the historical vacant-address fixture.
  # A documentation placeholder must not be used as an operator endpoint.
  if [ "$host" = "192.0.2.2" ]; then
    echo "FAIL: refusing documentation-only address '$host'."
    echo "      Supply the operator's verified LAN, tailnet, or public multiaddr instead."
    return 1
  fi

  if [ "$VALIDATE_ONLY" = 1 ]; then
    echo "VALID: $addr has an allowed multiaddr shape and address policy."
    return 0
  fi

  if ! require_runtime_proof_tools; then
    echo "      Refusing startup because the advertised address cannot be proven reachable."
    return 1
  fi

  echo "dialing $host:$port (timeout ${TIMEOUT}s) ..."
  dial "$host" "$port"
  local rc=$?
  if [ $rc -eq 0 ]; then
    echo "PASS: $addr accepted a TCP connection — the advertisement is honest from this vantage point."
    return 0
  fi
  local how="connection refused (host answered, nothing listens on $port)"
  [ $rc -eq 124 ] && how="connect timeout (vacant or filtered address — the #673 failure mode)"
  # Public addresses of ANY class - ip4, ip6, or a dns name - can false-negative
  # through NAT hairpin, so they WARN rather than FAIL. Restricting this to ip4
  # made a /dns4/ public bootstrap address report FAIL with a "must accept a
  # self-dial" message about a public name (found reviewing the #587 runbook,
  # which tells the operator to expect WARN at exactly that step).
  if ! is_private_addr "$kind" "$host"; then
    echo "WARN: $addr unreachable from here: $how"
    echo "      Public addresses can false-negative through NAT hairpin — prove reachability"
    echo "      with a dial from OUTSIDE this network before publishing this multiaddr."
    return 3
  fi
  echo "FAIL: $addr unreachable from here: $how"
  echo "      A private/tailnet advertisement must accept a self-dial. Remote peers WILL"
  echo "      fail silently against this address. Fix WRFCOIN_P2P_EXTERNAL_ADDR (verify the"
  echo "      live address with 'ip -4 addr' — do not copy an example) and restart the node."
  return 1
}

self_test() {
  local rc=0 pid='' lport=18761
  echo "=== A: listening private address -> expect PASS ==="
  python3 -c "import socket,time; s=socket.socket(); s.bind(('127.0.0.1',$lport)); s.listen(1); time.sleep(20)" & pid=$!
  sleep 1
  "$0" "/ip4/127.0.0.1/tcp/$lport" || rc=1
  kill "$pid" 2>/dev/null
  echo
  echo "=== B (RED control): vacant-style refused private address -> expect FAIL ==="
  if "$0" "/ip4/127.0.0.1/tcp/18762"; then rc=1; else echo "(failed as required)"; fi
  echo
  echo "=== C: unparsable multiaddr -> expect FAIL ==="
  if "$0" "192.0.2.2:9000"; then rc=1; else echo "(failed as required)"; fi
  echo
  echo "=== D (RED): injected host must NOT dial and must NOT pass -> expect FAIL ==="
  if "$0" "/ip4/127.0.0.1;echo INJECTED/tcp/$lport"; then rc=1; else echo "(refused as required)"; fi
  echo
  echo "=== E: public DNS name unreachable -> expect WARN (rc=3), never FAIL ==="
  "$0" "/dns4/unreachable.invalid/tcp/9" >/dev/null 2>&1
  if [ $? -eq 3 ]; then echo "(warned as required)"; else echo "FAIL: public dns did not WARN"; rc=1; fi
  echo
  if [ $rc -eq 0 ]; then echo "SELF-TEST: PASS"; else echo "SELF-TEST: FAIL"; fi
  return $rc
}

if [ "$SELF_TEST" = 1 ]; then self_test; exit $?; fi

if [ -z "$ADDR" ]; then
  if [ "$REQUIRE" = 1 ]; then
    echo "FAIL: WRFCOIN_P2P_EXTERNAL_ADDR is unset/empty but --require was given."
    echo "      Reference/bootstrap nodes MUST advertise a reachable multiaddr — joiners"
    echo "      cannot dial a node that advertises nothing (or only a Docker bridge address)."
    exit 1
  fi
  echo "note: WRFCOIN_P2P_EXTERNAL_ADDR is empty — nothing advertised; this node is dial-out"
  echo "      only. That is fine for a joiner, wrong for the reference node (use --require)."
  exit 0
fi

check_addr "$ADDR"
