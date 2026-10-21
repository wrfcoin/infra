#!/usr/bin/env bash
# =============================================================================
# External P2P reachability probe -> signed receipt (infra#840)
# =============================================================================
# Run this from a host OUTSIDE the testnet's NAT (any cloud box, a phone
# tether, a friend's machine — anywhere whose packets reach the advertised
# address the way a real peer's do). It dials the advertised multiaddr and, ONLY
# on a successful connection, emits the signed receipt that boot-heal's
# verify-p2p-reachability-receipt.sh will accept.
#
# This is the producer half of the #840 trust boundary. Two rules make it
# trustworthy, and neither is optional:
#
#   1. It signs nothing it did not observe. A failed dial writes a
#      result=unreachable receipt (which the verifier rejects) or no receipt at
#      all. There is no flag to assert reachability without dialing.
#   2. It never re-implements the canonical signing serialization. It asks the
#      VERIFIER for those bytes via --print-signing-input and signs exactly
#      what will later be verified. A hand-copied serializer here would drift
#      from the verifier on the first added field and fail closed at 3am on a
#      reboot — or worse, drift in a way that still verifies.
#
# Usage:
#   emit-p2p-reachability-receipt.sh --multiaddr /ip4/203.0.113.10/tcp/9000 \
#       --peer-id 12D3KooW... --key-file /path/to/receipt.key \
#       --out receipt.env [--genesis 0x<64hex>] [--observer NAME] [--timeout N]
#
# Then copy --out to the node host at $WRFCOIN_P2P_RECEIPT_FILE before the next
# boot. Receipts expire (default 900s), so this belongs on a timer next to the
# reboot, not in a runbook step someone did last Tuesday.
#
# Exit codes: 0 reachable + receipt written, 1 unreachable or signing failed,
#             2 usage error.
# =============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFIER="${SCRIPT_DIR}/../verify-p2p-reachability-receipt.sh"

MULTIADDR=""
PEER_ID=""
GENESIS=""
KEY_FILE=""
OUT=""
OBSERVER="${WRFCOIN_P2P_RECEIPT_OBSERVER:-$(hostname 2>/dev/null || echo external-probe)}"
TIMEOUT=6

usage_error() { echo "usage error: $1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --multiaddr) [ $# -ge 2 ] || usage_error "--multiaddr needs a value"; MULTIADDR="$2"; shift 2 ;;
    --peer-id) [ $# -ge 2 ] || usage_error "--peer-id needs a value"; PEER_ID="$2"; shift 2 ;;
    --genesis) [ $# -ge 2 ] || usage_error "--genesis needs a value"; GENESIS="$2"; shift 2 ;;
    --key-file) [ $# -ge 2 ] || usage_error "--key-file needs a value"; KEY_FILE="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage_error "--out needs a value"; OUT="$2"; shift 2 ;;
    --observer) [ $# -ge 2 ] || usage_error "--observer needs a value"; OBSERVER="$2"; shift 2 ;;
    --timeout) [ $# -ge 2 ] || usage_error "--timeout needs a value"; TIMEOUT="$2"; shift 2 ;;
    --*) usage_error "unknown flag: $1" ;;
    *) usage_error "unexpected positional argument: $1" ;;
  esac
done

[ -n "${MULTIADDR}" ] || usage_error "--multiaddr is required"
[ -n "${PEER_ID}" ] || usage_error "--peer-id is required"
[ -n "${KEY_FILE}" ] || usage_error "--key-file is required"
[ -n "${OUT}" ] || usage_error "--out is required"
[ -r "${KEY_FILE}" ] || { echo "no readable key file: ${KEY_FILE}" >&2; exit 2; }
[ -x "${VERIFIER}" ] || { echo "verifier not found/executable: ${VERIFIER}" >&2; exit 2; }
case "${TIMEOUT}" in ''|*[!0-9]*) usage_error "--timeout must be an integer" ;; esac

# Reject anything that is not a plain host literal before it reaches the dialer,
# for the same reason the sibling guard does: a host that dials a PREFIX can
# succeed and certify a vacant advertisement. Here it would also get that lie
# SIGNED, which is strictly worse.
case "${MULTIADDR}" in
  /ip4/*/tcp/*|/ip6/*/tcp/*|/dns4/*/tcp/*|/dns/*/tcp/*) ;;
  *) echo "cannot parse multiaddr '${MULTIADDR}'" >&2; exit 2 ;;
esac
HOST="$(printf '%s' "${MULTIADDR}" | cut -d/ -f3)"
PORT="$(printf '%s' "${MULTIADDR}" | cut -d/ -f5)"
case "${HOST}" in
  *[!0-9A-Za-z.:_-]*|'') echo "invalid host component '${HOST}' — refusing to dial" >&2; exit 2 ;;
esac
case "${PORT}" in ''|*[!0-9]*) echo "bad tcp port in '${MULTIADDR}'" >&2; exit 2 ;; esac

# Newline-separated fields would let a crafted observer/peer id inject extra
# receipt lines. The canonical serialization is line-based, so this is a
# forgery vector, not a cosmetic concern.
for value in "${MULTIADDR}" "${PEER_ID}" "${GENESIS}" "${OBSERVER}"; do
  case "${value}" in
    *$'\n'*|*$'\r'*) echo "receipt field values must not contain newlines" >&2; exit 2 ;;
  esac
done

echo "dialing ${HOST}:${PORT} from $(hostname 2>/dev/null || echo this-host) (timeout ${TIMEOUT}s) ..."
# shellcheck disable=SC2016
if timeout "${TIMEOUT}" bash -c 'exec 3<>/dev/tcp/"$0"/"$1"' "${HOST}" "${PORT}" 2>/dev/null; then
  RESULT="reachable"
else
  RESULT="unreachable"
fi

OBSERVED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ "${RESULT}" != "reachable" ]; then
  echo "UNREACHABLE: ${MULTIADDR} did not accept a connection from outside the NAT." >&2
  echo "             No acceptable receipt written. This is a REAL failure, not hairpin:" >&2
  echo "             an external vantage point is exactly the one that should succeed." >&2
  exit 1
fi

umask 077
unsigned="$(mktemp)"
trap 'rm -f "${unsigned}"' EXIT
{
  printf 'receipt_version=1\n'
  printf 'multiaddr=%s\n' "${MULTIADDR}"
  printf 'peer_id=%s\n' "${PEER_ID}"
  printf 'genesis_hash=%s\n' "${GENESIS}"
  printf 'observed_at=%s\n' "${OBSERVED_AT}"
  printf 'observer=%s\n' "${OBSERVER}"
  printf 'result=%s\n' "${RESULT}"
} > "${unsigned}"

# Sign the verifier's own canonical bytes, never a local reconstruction.
if ! signing_input="$("${VERIFIER}" --print-signing-input --receipt "${unsigned}")"; then
  echo "failed to derive the canonical signing input from ${VERIFIER}" >&2
  exit 1
fi

# Asymmetric signing (#841 review): KEY_FILE is the probe's ed25519 PRIVATE
# key (PEM), generated with `openssl genpkey -algorithm ed25519`. It must
# exist ONLY on this probe host — the node verifies with the public half and
# can never mint a receipt.
if ! grep -q "PRIVATE KEY" "${KEY_FILE}" 2>/dev/null; then
  echo "'${KEY_FILE}' is not a PEM ed25519 PRIVATE key — generate one on THIS host with:" >&2
  echo "  openssl genpkey -algorithm ed25519 -out '${KEY_FILE}'" >&2
  exit 1
fi
# openssl's ed25519 oneshot signing needs a SEEKABLE input, not a pipe.
sign_input_file="$(mktemp)"
printf '%s\n' "${signing_input}" > "${sign_input_file}"
sig="$(openssl pkeyutl -sign -inkey "${KEY_FILE}" -rawin -in "${sign_input_file}" 2>/dev/null | base64 | tr -d '\n')"
sign_rc=$?
rm -f "${sign_input_file}"
if [ "${sign_rc}" -ne 0 ]; then
  echo "failed to sign the receipt with ${KEY_FILE}" >&2
  exit 1
fi
if [ -z "${sig}" ]; then
  echo "signing produced an empty signature with ${KEY_FILE}" >&2
  exit 1
fi

{
  cat "${unsigned}"
  printf 'signature_ed25519=%s\n' "${sig}"
} > "${OUT}"

echo "REACHABLE: wrote signed receipt to ${OUT}"
echo "           observed_at=${OBSERVED_AT} observer=${OBSERVER}"
echo "           Copy it to the node's \$WRFCOIN_P2P_RECEIPT_FILE — it expires."
