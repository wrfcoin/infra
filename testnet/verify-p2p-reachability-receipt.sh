#!/usr/bin/env bash
# =============================================================================
# External P2P reachability receipt verifier (infra#840)
# =============================================================================
# check-p2p-external-addr.sh proves the advertised multiaddr by dialing it. From
# CT 101 that dial leaves and re-enters through the same NAT, and the router does
# not support hairpin reflection, so a PUBLIC advertised address reports
# unreachable even while outside peers are connecting to it fine. On 2026-08-15
# boot-heal reconciled the whole stack with unchanged container IDs and then
# exited 1 on exactly that self-dial. That is a false negative about the network
# path, not a statement about the node.
#
# The cure is evidence from the only vantage point that can settle the question:
# a probe OUTSIDE the NAT. This script verifies the receipt such a probe leaves
# behind. It is deliberately the whole trust boundary, so it is written to
# fail closed on every axis:
#
#   AUTHENTIC  ed25519 over a canonical field serialization. The PRIVATE key
#              lives only on the external probe host; this node stores the
#              PUBLIC key and gains no signing capability from it. (An HMAC
#              here would be symmetric: a node that can verify can mint — the
#              exact false PASS this is supposed to prevent. #841 review.)
#   FRESH      observed_at must be within a SHORT bounded window (default 900s,
#              hard ceiling 3600s). A receipt from last week says nothing about
#              the port mapping right now.
#   ON-TARGET  multiaddr, peer id, and (when configured) genesis hash must match
#              what this node actually advertises. A valid signed receipt for a
#              DIFFERENT node or a different chain is not evidence about this one.
#
# Anything missing, stale, mismatched, unparsable, or not signed is a rejection.
# There is no "assume good" branch anywhere in this file.
#
# Receipt format — key=value lines, '#' comments and blank lines ignored:
#
#   receipt_version=1
#   multiaddr=/ip4/203.0.113.10/tcp/9000
#   peer_id=12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr
#   genesis_hash=0x<64 hex>            # optional; checked when expected
#   observed_at=2026-08-16T04:05:06Z   # RFC3339 UTC, when the dial SUCCEEDED
#   observer=edge-probe-lon-1          # free-form probe identity, signed
#   result=reachable
#   signature_ed25519=<base64 raw ed25519 signature>
#
# Usage:
#   verify-p2p-reachability-receipt.sh --receipt F --key-file K \
#       --expect-multiaddr MA --expect-peer-id ID [--expect-genesis H] \
#       [--max-age-secs N]
#   verify-p2p-reachability-receipt.sh --print-signing-input --receipt F
#   WRFCOIN_P2P_RECEIPT_TEST_MODE=1 ... --test-only --now-epoch N
#
# Exit codes: 0 receipt ACCEPTED, 1 receipt REJECTED, 2 usage error.
# =============================================================================
set -u

RECEIPT=""
KEY_FILE=""
EXPECT_MULTIADDR=""
EXPECT_PEER_ID=""
EXPECT_GENESIS=""
MAX_AGE_SECS="${WRFCOIN_P2P_RECEIPT_MAX_AGE_SECS:-900}"
NOW_EPOCH=""
TEST_ONLY=0
PRINT_SIGNING_INPUT=0

# A receipt older than this is never acceptable, whatever the operator asks for.
# "Bounded" has to mean bounded by the script, not by whoever edits the unit
# file: MAX_AGE=31536000 would turn the freshness check into decoration.
readonly MAX_AGE_CEILING_SECS=3600
# Tolerated clock skew between the external probe and this host. A receipt
# stamped in the future is otherwise a way to buy unlimited freshness.
readonly MAX_FUTURE_SKEW_SECS=60

# Every field that is covered by the signature, in canonical order. Adding a
# field here without adding it to the probe's signer breaks verification loudly
# rather than silently leaving the new field unauthenticated.
readonly SIGNED_FIELDS=(
  receipt_version
  multiaddr
  peer_id
  genesis_hash
  observed_at
  observer
  result
)

usage_error() { echo "usage error: $1" >&2; exit 2; }
reject() { echo "REJECT: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --receipt) [ $# -ge 2 ] || usage_error "--receipt needs a value"; RECEIPT="$2"; shift 2 ;;
    --key-file) [ $# -ge 2 ] || usage_error "--key-file needs a value"; KEY_FILE="$2"; shift 2 ;;
    --expect-multiaddr) [ $# -ge 2 ] || usage_error "--expect-multiaddr needs a value"; EXPECT_MULTIADDR="$2"; shift 2 ;;
    --expect-peer-id) [ $# -ge 2 ] || usage_error "--expect-peer-id needs a value"; EXPECT_PEER_ID="$2"; shift 2 ;;
    --expect-genesis) [ $# -ge 2 ] || usage_error "--expect-genesis needs a value"; EXPECT_GENESIS="$2"; shift 2 ;;
    --max-age-secs) [ $# -ge 2 ] || usage_error "--max-age-secs needs a value"; MAX_AGE_SECS="$2"; shift 2 ;;
    --now-epoch) [ $# -ge 2 ] || usage_error "--now-epoch needs a value"; NOW_EPOCH="$2"; shift 2 ;;
    --test-only) TEST_ONLY=1; shift ;;
    --print-signing-input) PRINT_SIGNING_INPUT=1; shift ;;
    --*) usage_error "unknown flag: $1" ;;
    *) usage_error "unexpected positional argument: $1" ;;
  esac
done

# --now-epoch exists so the freshness tests are deterministic without sleeping
# for fifteen minutes. It is also, obviously, a way to defeat the freshness
# check, so it is gated exactly like --validate-only is in the sibling guard:
# explicit test flag AND an explicit test-mode environment variable.
if [ -n "${NOW_EPOCH}" ] && { [ "${TEST_ONLY}" != 1 ] || [ "${WRFCOIN_P2P_RECEIPT_TEST_MODE:-}" != "1" ]; }; then
  echo "FAIL: --now-epoch is test-only; use --test-only with WRFCOIN_P2P_RECEIPT_TEST_MODE=1." >&2
  echo "      Production verification must read the real clock." >&2
  exit 1
fi

[ -n "${RECEIPT}" ] || usage_error "--receipt is required"

if [ ! -f "${RECEIPT}" ] || [ ! -r "${RECEIPT}" ]; then
  reject "no readable reachability receipt at '${RECEIPT}' — external evidence is MISSING."
fi

# --- parse -----------------------------------------------------------------
# Values are read into fixed named variables rather than eval'd, so a hostile
# receipt cannot introduce a variable this script later trusts.
FIELD_receipt_version=""
FIELD_multiaddr=""
FIELD_peer_id=""
FIELD_genesis_hash=""
FIELD_observed_at=""
FIELD_observer=""
FIELD_result=""
FIELD_signature_ed25519=""

line_no=0
while IFS= read -r line || [ -n "${line}" ]; do
  line_no=$((line_no + 1))
  case "${line}" in
    ''|'#'*) continue ;;
  esac
  # Strip a single trailing CR so a receipt written on another host still parses.
  line="${line%$'\r'}"
  case "${line}" in
    *=*) ;;
    *) reject "receipt line ${line_no} is not key=value: '${line}'" ;;
  esac
  key="${line%%=*}"
  value="${line#*=}"
  case "${key}" in
    receipt_version) FIELD_receipt_version="${value}" ;;
    multiaddr) FIELD_multiaddr="${value}" ;;
    peer_id) FIELD_peer_id="${value}" ;;
    genesis_hash) FIELD_genesis_hash="${value}" ;;
    observed_at) FIELD_observed_at="${value}" ;;
    observer) FIELD_observer="${value}" ;;
    result) FIELD_result="${value}" ;;
    signature_ed25519) FIELD_signature_ed25519="${value}" ;;
    *) reject "receipt line ${line_no} has an unknown field '${key}' — refusing a receipt this verifier does not fully understand." ;;
  esac
done < "${RECEIPT}"

# --- canonical signing input ------------------------------------------------
# Newline-joined key=value over SIGNED_FIELDS in declared order, with a trailing
# newline. Absent optional fields serialize as an empty value rather than being
# omitted, so the serialization is total and two different receipts can never
# produce the same signing input.
signing_input() {
  local field var
  for field in "${SIGNED_FIELDS[@]}"; do
    var="FIELD_${field}"
    printf '%s=%s\n' "${field}" "${!var}"
  done
}

if [ "${PRINT_SIGNING_INPUT}" = 1 ]; then
  signing_input
  exit 0
fi

# --- structural / policy checks --------------------------------------------
[ -n "${FIELD_receipt_version}" ] || reject "receipt is missing receipt_version."
[ "${FIELD_receipt_version}" = "1" ] || reject "unsupported receipt_version '${FIELD_receipt_version}' (this verifier understands 1)."

for required in multiaddr peer_id observed_at observer result signature_ed25519; do
  var="FIELD_${required}"
  [ -n "${!var}" ] || reject "receipt is missing required field '${required}'."
done

if [ "${FIELD_result}" != "reachable" ]; then
  reject "receipt records result='${FIELD_result}', not 'reachable' — the external probe did NOT connect. A failed external dial stays RED."
fi

# Raw ed25519 signatures are 64 bytes -> 88 base64 chars with padding.
case "${FIELD_signature_ed25519}" in
  *[!A-Za-z0-9+/=]*|'') reject "signature_ed25519 is not base64." ;;
esac
[ "${#FIELD_signature_ed25519}" -eq 88 ] || reject "signature_ed25519 must be 88 base64 characters (a raw 64-byte ed25519 signature; got ${#FIELD_signature_ed25519})."

# --- target binding ---------------------------------------------------------
# Checked BEFORE the MAC, so a mismatched target is reported as a mismatch
# rather than as a signature failure. Both outcomes are rejections; only the
# operator-facing diagnosis differs.
if [ -n "${EXPECT_MULTIADDR}" ] && [ "${FIELD_multiaddr}" != "${EXPECT_MULTIADDR}" ]; then
  reject "receipt is for multiaddr '${FIELD_multiaddr}' but this node advertises '${EXPECT_MULTIADDR}' — WRONG TARGET."
fi
if [ -n "${EXPECT_PEER_ID}" ] && [ "${FIELD_peer_id}" != "${EXPECT_PEER_ID}" ]; then
  reject "receipt is for peer id '${FIELD_peer_id}' but this node is '${EXPECT_PEER_ID}' — WRONG TARGET."
fi
if [ -n "${EXPECT_GENESIS}" ]; then
  [ -n "${FIELD_genesis_hash}" ] || reject "a genesis hash is expected but the receipt carries none — WRONG TARGET (cannot prove it is this chain)."
  if [ "${FIELD_genesis_hash}" != "${EXPECT_GENESIS}" ]; then
    reject "receipt is for genesis '${FIELD_genesis_hash}' but this node runs '${EXPECT_GENESIS}' — WRONG TARGET."
  fi
fi

# --- freshness --------------------------------------------------------------
case "${MAX_AGE_SECS}" in
  ''|*[!0-9]*) usage_error "--max-age-secs must be a non-negative integer (got '${MAX_AGE_SECS}')" ;;
esac
if [ "${MAX_AGE_SECS}" -gt "${MAX_AGE_CEILING_SECS}" ]; then
  reject "requested max age ${MAX_AGE_SECS}s exceeds the ${MAX_AGE_CEILING_SECS}s ceiling — refusing to widen the freshness window past what boot-time evidence can support."
fi

if [ -n "${NOW_EPOCH}" ]; then
  case "${NOW_EPOCH}" in
    ''|*[!0-9]*) usage_error "--now-epoch must be a non-negative integer" ;;
  esac
  now="${NOW_EPOCH}"
else
  now="$(date -u +%s)"
fi

observed_epoch="$(
  python3 -c '
import datetime, sys

raw = sys.argv[1]
if not raw.endswith("Z"):
    raise SystemExit(1)
value = datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ")
value = value.replace(tzinfo=datetime.timezone.utc)
print(int(value.timestamp()))
' "${FIELD_observed_at}" 2>/dev/null
)" || reject "observed_at '${FIELD_observed_at}' is not RFC3339 UTC (expected YYYY-MM-DDTHH:MM:SSZ)."
[ -n "${observed_epoch}" ] || reject "observed_at '${FIELD_observed_at}' is not RFC3339 UTC (expected YYYY-MM-DDTHH:MM:SSZ)."

age=$(( now - observed_epoch ))
if [ "${age}" -lt "$(( -MAX_FUTURE_SKEW_SECS ))" ]; then
  reject "observed_at '${FIELD_observed_at}' is $(( -age ))s in the FUTURE (skew allowance ${MAX_FUTURE_SKEW_SECS}s) — refusing a receipt that cannot have been observed yet."
fi
if [ "${age}" -gt "${MAX_AGE_SECS}" ]; then
  reject "receipt is STALE: observed ${age}s ago at '${FIELD_observed_at}', maximum age is ${MAX_AGE_SECS}s. Re-run the external probe."
fi

# --- authenticity -----------------------------------------------------------
# Asymmetric by design (#841 review): the node stores ONLY the probe's ed25519
# PUBLIC key. An HMAC here would be symmetric — a node that can verify could
# also mint a fresh "reachable" receipt for itself without any external dial.
# With ed25519, possession of this file grants zero signing capability; only
# the external probe host holds the private key.
[ -n "${KEY_FILE}" ] || reject "no --key-file given — an unauthenticated receipt is not evidence."
if [ ! -f "${KEY_FILE}" ] || [ ! -r "${KEY_FILE}" ]; then
  reject "no readable receipt public key at '${KEY_FILE}' — cannot authenticate the receipt."
fi
if [ ! -s "${KEY_FILE}" ]; then
  reject "receipt public key at '${KEY_FILE}' is empty — refusing to verify against an empty key."
fi
if ! grep -q "PUBLIC KEY" "${KEY_FILE}"; then
  reject "'${KEY_FILE}' is not a PEM public key — the node must hold the probe's PUBLIC key only (a private key here would let the node sign its own receipts)."
fi

VERIFY_TMP="$(mktemp -d)" || reject "cannot create a temp dir for signature verification."
trap 'rm -rf "${VERIFY_TMP}"' EXIT
if ! printf '%s' "${FIELD_signature_ed25519}" | base64 -d > "${VERIFY_TMP}/sig.bin" 2>/dev/null; then
  reject "signature_ed25519 does not decode as base64."
fi
signing_input > "${VERIFY_TMP}/input.bin"
if ! openssl pkeyutl -verify -pubin -inkey "${KEY_FILE}" -rawin \
    -in "${VERIFY_TMP}/input.bin" -sigfile "${VERIFY_TMP}/sig.bin" >/dev/null 2>&1; then
  reject "receipt signature does not verify against '${KEY_FILE}' — the receipt is forged, corrupted, tampered with, or signed by a different key."
fi

echo "ACCEPT: external reachability receipt for ${FIELD_multiaddr} (peer ${FIELD_peer_id})"
echo "        observed ${age}s ago at ${FIELD_observed_at} by '${FIELD_observer}', signature verified."
exit 0
