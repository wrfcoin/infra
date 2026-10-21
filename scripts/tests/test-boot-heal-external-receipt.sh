#!/usr/bin/env bash
# External P2P reachability receipt: accept fresh, reject everything else (#840).
#
# boot-heal exits 1 on a self-dial that NAT hairpin makes unanswerable, even
# though outside peers reach the node fine (measured on CT 101, 2026-08-15:
# every container ID unchanged, only the self-dial failed). The cure is a
# receipt from a probe outside the NAT — which means this verifier is now the
# thing standing between a forged file and a boot-time PASS.
#
# So the interesting assertions here are the REJECTIONS. An accept-only suite
# would pass just as happily against `exit 0`, and that is exactly the failure
# mode a security gate must not have. Every rejection below is paired with the
# fresh receipt it was mutated from, so a rejection can only come from the
# mutated field and never from a receipt that was broken to begin with.
#
# Runs with no node, no network, no reboot, no Docker.
#
# Run: bash scripts/tests/test-boot-heal-external-receipt.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="${REPO_ROOT}/testnet/verify-p2p-reachability-receipt.sh"
EMITTER="${REPO_ROOT}/testnet/edge/emit-p2p-reachability-receipt.sh"
BOOT_HEAL="${REPO_ROOT}/testnet/boot-heal.sh"

fails=0
assertions=0

pass_msg() { printf '  ok    %s\n' "$1"; }
fail_msg() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

check() {
  local name="$1"; shift
  assertions=$((assertions + 1))
  if "$@"; then pass_msg "$name"; else fail_msg "$name"; fi
}

check_not() {
  local name="$1"; shift
  assertions=$((assertions + 1))
  if "$@"; then fail_msg "$name"; else pass_msg "$name"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Asymmetric keys (#841 review): the probe signs with an ed25519 PRIVATE key;
# the node verifies with the PUBLIC half and can never mint a receipt.
PROBE_PRIV="${WORK}/probe.pem"
KEY="${WORK}/probe.pub"           # what the NODE holds — public only
WRONG_PRIV="${WORK}/wrong.pem"
WRONG_PUB="${WORK}/wrong.pub"
openssl genpkey -algorithm ed25519 -out "${PROBE_PRIV}" 2>/dev/null
openssl pkey -in "${PROBE_PRIV}" -pubout -out "${KEY}" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "${WRONG_PRIV}" 2>/dev/null
openssl pkey -in "${WRONG_PRIV}" -pubout -out "${WRONG_PUB}" 2>/dev/null

ADDR="/ip4/203.0.113.10/tcp/9000"
PEER="12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr"
GENESIS="0xa3301def00000000000000000000000000000000000000000000000000000000"

# Fixed clock. Freshness is the property under test, so the test must control
# time rather than race it: a suite that slept 900s to prove staleness would be
# skipped by whoever is in a hurry, and a suite that used the real clock would
# go red on its own at some point.
NOW=1786852800   # 2026-08-16T04:00:00Z (verified below, not eyeballed)
FRESH_AT="2026-08-16T03:55:00Z"   # 300s old  -> inside the 900s window
STALE_AT="2026-08-16T03:30:00Z"   # 1800s old -> outside it
FUTURE_AT="2026-08-16T05:00:00Z"  # 3600s ahead

# The fixed clock is load-bearing and was WRONG on the first run of this suite:
# NOW was set a year behind the fixture timestamps, so every receipt looked
# future-dated and all twenty rejection assertions passed for a reason that had
# nothing to do with what they claimed to test. Only the accept case noticed.
# So the clock now proves itself before any assertion runs — an arithmetic
# mistake here silently converts this whole file into theatre.
assert_offset() { # label rfc3339 expected-age-seconds
  local label="$1" stamp="$2" want="$3" got
  got="$(python3 -c '
import datetime, sys
value = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ")
value = value.replace(tzinfo=datetime.timezone.utc)
print(int(sys.argv[2]) - int(value.timestamp()))
' "${stamp}" "${NOW}")"
  if [[ "${got}" != "${want}" ]]; then
    printf '  FAIL  fixture clock: %s is %ss from NOW, expected %ss\n' "${label}" "${got}" "${want}"
    printf 'ABORT: the fixed clock is wrong; every freshness assertion would be vacuous.\n'
    exit 1
  fi
}
assert_offset "FRESH_AT"  "${FRESH_AT}"   300
assert_offset "STALE_AT"  "${STALE_AT}"   1800
assert_offset "FUTURE_AT" "${FUTURE_AT}" -3600

# Sign whatever field set is handed in, using the verifier's own canonical
# bytes. Building the signing input here instead would let this suite drift
# from the verifier and start certifying a serialization nobody uses.
sign_receipt() { # out_file private_key_file <<< body-without-signature
  local out="$1" key="$2" body
  body="$(cat)"
  local unsigned="${WORK}/unsigned.$$"
  printf '%s\n' "${body}" > "${unsigned}"
  local signing_input sig input_file="${WORK}/signing-input.$$"
  signing_input="$("${VERIFIER}" --print-signing-input --receipt "${unsigned}")" || return 1
  # openssl's ed25519 oneshot signing needs a SEEKABLE input, not a pipe.
  printf '%s\n' "${signing_input}" > "${input_file}"
  sig="$(openssl pkeyutl -sign -inkey "${key}" -rawin -in "${input_file}" 2>/dev/null | base64 | tr -d '\n')" || { rm -f "${input_file}"; return 1; }
  rm -f "${input_file}"
  [ -n "${sig}" ] || return 1
  { cat "${unsigned}"; printf 'signature_ed25519=%s\n' "${sig}"; } > "${out}"
  rm -f "${unsigned}"
}

# One generator for every fixture, so each rejection differs from the accepted
# receipt in exactly ONE field.
make_receipt() { # out key multiaddr peer genesis observed_at result
  sign_receipt "$1" "$2" <<EOF
receipt_version=1
multiaddr=$3
peer_id=$4
genesis_hash=$5
observed_at=$6
result=$7
observer=edge-probe-test
EOF
}

verify() { # receipt [extra args...]
  local receipt="$1"; shift
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" \
    --test-only --now-epoch "${NOW}" \
    --receipt "${receipt}" --key-file "${KEY}" \
    --expect-multiaddr "${ADDR}" --expect-peer-id "${PEER}" \
    --expect-genesis "${GENESIS}" \
    "$@" >/dev/null 2>&1
}

printf '\n== fixtures ==\n'
make_receipt "${WORK}/fresh.env"        "${PROBE_PRIV}"       "${ADDR}" "${PEER}" "${GENESIS}" "${FRESH_AT}"  reachable
make_receipt "${WORK}/stale.env"        "${PROBE_PRIV}"       "${ADDR}" "${PEER}" "${GENESIS}" "${STALE_AT}"  reachable
make_receipt "${WORK}/future.env"       "${PROBE_PRIV}"       "${ADDR}" "${PEER}" "${GENESIS}" "${FUTURE_AT}" reachable
make_receipt "${WORK}/wrong-addr.env"   "${PROBE_PRIV}"       "/ip4/198.51.100.99/tcp/9000" "${PEER}" "${GENESIS}" "${FRESH_AT}" reachable
make_receipt "${WORK}/wrong-peer.env"   "${PROBE_PRIV}"       "${ADDR}" "12D3KooWImposterImposterImposterImposterImposterImposter" "${GENESIS}" "${FRESH_AT}" reachable
make_receipt "${WORK}/wrong-genesis.env" "${PROBE_PRIV}"      "${ADDR}" "${PEER}" "0xdeadbeef00000000000000000000000000000000000000000000000000000000" "${FRESH_AT}" reachable
make_receipt "${WORK}/no-genesis.env"   "${PROBE_PRIV}"       "${ADDR}" "${PEER}" ""          "${FRESH_AT}"  reachable
make_receipt "${WORK}/unreachable.env"  "${PROBE_PRIV}"       "${ADDR}" "${PEER}" "${GENESIS}" "${FRESH_AT}"  unreachable
make_receipt "${WORK}/wrong-key.env"    "${WRONG_PRIV}" "${ADDR}" "${PEER}" "${GENESIS}" "${FRESH_AT}"  reachable
printf '  fixtures generated\n'

# ---------------------------------------------------------------------------
# ACCEPT: a fresh, authentic, on-target receipt
# ---------------------------------------------------------------------------
printf '\n== accept-fresh ==\n'
check "accept-fresh: fresh signed on-target receipt is ACCEPTED" \
  verify "${WORK}/fresh.env"

check "accept-fresh: accepted at the exact freshness boundary (age == max-age)" \
  verify "${WORK}/fresh.env" --max-age-secs 300

# ---------------------------------------------------------------------------
# REJECT: stale
# ---------------------------------------------------------------------------
printf '\n== reject-stale ==\n'
check_not "reject-stale: 1800s-old receipt is REJECTED under the 900s default" \
  verify "${WORK}/stale.env"

check_not "reject-stale: fresh receipt is REJECTED one second past its window" \
  verify "${WORK}/fresh.env" --max-age-secs 299

check_not "reject-stale: future-dated receipt is REJECTED (no buying freshness)" \
  verify "${WORK}/future.env"

# A hard ceiling in the verifier is the only thing that keeps 'bounded' true;
# without it an operator edits the unit file to a year and freshness is theatre.
check_not "reject-stale: max-age above the 3600s ceiling is REJECTED" \
  verify "${WORK}/stale.env" --max-age-secs 86400

# ---------------------------------------------------------------------------
# REJECT: wrong target
# ---------------------------------------------------------------------------
printf '\n== reject-wrong-target ==\n'
check_not "reject-wrong-target: receipt for a different multiaddr is REJECTED" \
  verify "${WORK}/wrong-addr.env"

check_not "reject-wrong-target: receipt for a different peer id is REJECTED" \
  verify "${WORK}/wrong-peer.env"

check_not "reject-wrong-target: receipt for a different genesis is REJECTED" \
  verify "${WORK}/wrong-genesis.env"

check_not "reject-wrong-target: receipt with NO genesis is REJECTED when one is expected" \
  verify "${WORK}/no-genesis.env"

# ---------------------------------------------------------------------------
# REJECT: everything else that is not evidence
# ---------------------------------------------------------------------------
printf '\n== reject-not-evidence ==\n'
check_not "reject: a receipt signed with the wrong key is REJECTED" \
  verify "${WORK}/wrong-key.env"

check_not "reject: result=unreachable is REJECTED (failed external dial stays RED)" \
  verify "${WORK}/unreachable.env"

check_not "reject: a missing receipt file is REJECTED" \
  verify "${WORK}/does-not-exist.env"

cp "${WORK}/fresh.env" "${WORK}/tampered.env"
sed -i "s|^multiaddr=.*|multiaddr=/ip4/198.51.100.99/tcp/9000|" "${WORK}/tampered.env"
check_not "reject: editing a signed field invalidates the receipt" \
  verify "${WORK}/tampered.env"

grep -v "^signature_ed25519=" "${WORK}/fresh.env" > "${WORK}/unsigned.env"
check_not "reject: an unsigned receipt is REJECTED" \
  verify "${WORK}/unsigned.env"

no_key_verify() {
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" --test-only --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --expect-multiaddr "${ADDR}" >/dev/null 2>&1
}
check_not "reject: verification without a key file is REJECTED" no_key_verify

: > "${WORK}/empty.key"
empty_key_verify() {
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" --test-only --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --key-file "${WORK}/empty.key" \
    --expect-multiaddr "${ADDR}" >/dev/null 2>&1
}
check_not "reject: an empty key file is REJECTED" empty_key_verify

printf 'receipt_version=1\nsurprise_field=x\n' > "${WORK}/unknown-field.env"
check_not "reject: an unknown receipt field is REJECTED" \
  verify "${WORK}/unknown-field.env"

make_receipt "${WORK}/badtime.env" "${PROBE_PRIV}" "${ADDR}" "${PEER}" "${GENESIS}" "16 Aug 2026" reachable
check_not "reject: a non-RFC3339 observed_at is REJECTED" \
  verify "${WORK}/badtime.env"

make_receipt "${WORK}/v2.env" "${PROBE_PRIV}" "${ADDR}" "${PEER}" "${GENESIS}" "${FRESH_AT}" reachable
sed -i 's/^receipt_version=1$/receipt_version=2/' "${WORK}/v2.env"
check_not "reject: an unsupported receipt_version is REJECTED" \
  verify "${WORK}/v2.env"

# ---------------------------------------------------------------------------
# The test-only clock seam must not be reachable in production.
#
# --now-epoch can defeat the freshness check outright, so it is gated the same
# way the sibling guard gates --validate-only. Without this assertion the
# feature ships with a documented bypass.
# ---------------------------------------------------------------------------
printf '\n== test-seam containment ==\n'
ungated_now_epoch() {
  env -u WRFCOIN_P2P_RECEIPT_TEST_MODE "${VERIFIER}" --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --key-file "${KEY}" \
    --expect-multiaddr "${ADDR}" >/dev/null 2>&1
}
check_not "--now-epoch is refused without the explicit test-mode gate" ungated_now_epoch

now_epoch_without_test_only() {
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --key-file "${KEY}" \
    --expect-multiaddr "${ADDR}" >/dev/null 2>&1
}
check_not "--now-epoch is refused without --test-only" now_epoch_without_test_only

# ---------------------------------------------------------------------------
# Producer round-trip.
#
# A verifier nothing can produce a receipt for is a gate that always says no,
# and it would pass every rejection test above. This dials a real listening
# socket on loopback and requires the emitted receipt to verify — which also
# proves the signer and verifier agree on the canonical bytes.
# ---------------------------------------------------------------------------
printf '\n== producer round-trip ==\n'
roundtrip() {
  local port=18771 pid rc=0
  python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', ${port}))
s.listen(4)
time.sleep(25)
" &
  pid=$!
  sleep 1
  local live_addr="/ip4/127.0.0.1/tcp/${port}"
  if ! "${EMITTER}" --multiaddr "${live_addr}" --peer-id "${PEER}" \
       --genesis "${GENESIS}" --key-file "${PROBE_PRIV}" \
       --out "${WORK}/emitted.env" --observer roundtrip >/dev/null 2>&1; then
    rc=1
  fi
  kill "${pid}" 2>/dev/null
  wait "${pid}" 2>/dev/null
  [[ ${rc} -eq 0 ]] || return 1
  # Real clock here on purpose: the emitter stamps now, so this also proves a
  # just-produced receipt is fresh under the production freshness path.
  "${VERIFIER}" --receipt "${WORK}/emitted.env" --key-file "${KEY}" \
    --expect-multiaddr "${live_addr}" --expect-peer-id "${PEER}" \
    --expect-genesis "${GENESIS}" >/dev/null 2>&1
}
check "emitter produces a receipt the verifier accepts (no test seam used)" roundtrip

emitter_refuses_dead_port() {
  ! "${EMITTER}" --multiaddr "/ip4/127.0.0.1/tcp/18772" --peer-id "${PEER}" \
    --key-file "${KEY}" --out "${WORK}/should-not-exist.env" >/dev/null 2>&1
}
check "emitter refuses to sign a receipt for a port that did not answer" \
  emitter_refuses_dead_port
check_not "emitter wrote no receipt for the unreachable dial" \
  test -f "${WORK}/should-not-exist.env"

# ---------------------------------------------------------------------------
# boot-heal wiring: the override is scoped to the hairpin verdict ONLY.
#
# Source assertions, because the alternative is a reboot. The issue is explicit
# that not all exit-1 outcomes may become success, and the guard already
# separates them: 3 = public address did not answer (hairpin can cause this),
# 1 = unparsable/unset/vacant/private-self-dial-failed (hairpin cannot).
# ---------------------------------------------------------------------------
printf '\n== boot-heal wiring ==\n'

override_is_scoped_to_warn() {
  # The receipt path must be reachable only under the rc==3 branch.
  awk '/^guard_external_address_after_up\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -q 'rc != 3'
}
check "boot-heal restricts the receipt override to the guard WARN verdict (rc=3)" \
  override_is_scoped_to_warn

failure_still_returns_one() {
  awk '/^guard_external_address_after_up\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -cq 'return 1'
}
check "boot-heal still returns 1 when no valid receipt is available" \
  failure_still_returns_one

no_blanket_success() {
  # Nothing in the gate may turn an arbitrary guard failure into success.
  ! awk '/^guard_external_address_after_up\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -qE 'guard_external_address[[:space:]]*\|\|[[:space:]]*(return 0|true)'
}
check "boot-heal does not blanket-convert guard failure into success" \
  no_blanket_success

receipt_helper_is_wired() {
  grep -q 'accept_external_reachability_receipt' "${BOOT_HEAL}" &&
    grep -q 'P2P_RECEIPT_VERIFIER' "${BOOT_HEAL}"
}
check "boot-heal calls the receipt verifier" receipt_helper_is_wired

unconfigured_receipt_is_red() {
  # No receipt configured must stay a failure: absence of evidence is not
  # evidence. Asserted on the helper body so an added default cannot slip in.
  awk '/^accept_external_reachability_receipt\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -q 'return 1'
}
check "boot-heal treats an unconfigured receipt as RED" unconfigured_receipt_is_red

guard_still_runs() {
  grep -q 'guard_external_address_after_up' "${BOOT_HEAL}" &&
    grep -q -- '--require' "${BOOT_HEAL}"
}
check "the self-dial guard still runs, still with --require" guard_still_runs

# ---------------------------------------------------------------------------
# #831 custody gate must be untouched.
#
# This change lives entirely in the advertised-address verdict. If it ever
# reaches the HSM-init custody path, the failure is silent and the cost is the
# node's identity, so it is asserted rather than assumed.
# ---------------------------------------------------------------------------
printf '\n== #831 HSM custody preserved ==\n'
for required in \
  'reconcile_preserving_hsm_init' \
  'force_recovery_preserving_hsm_init' \
  'stop_preserving_hsm_init' \
  'validate_hsm_safe_dry_run' \
  'capture_verified_hsm_init_custody' \
  'verify_hsm_init_custody_unchanged'
do
  check "#831: ${required} still present" grep -q "${required}" "${BOOT_HEAL}"
done

reconcile_still_no_recreate() {
  awk '/^reconcile_preserving_hsm_init\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -q -- 'compose up -d --no-build --no-recreate'
}
check "#831: reconciliation still runs --no-build --no-recreate" \
  reconcile_still_no_recreate

dry_run_still_rejects_create() {
  awk '/^validate_hsm_safe_dry_run\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -q 'create or recreate in Compose diagnostic dry-run'
}
check "#831: dry-run still rejects create/recreate actions" \
  dry_run_still_rejects_create

receipt_path_touches_no_containers() {
  # The receipt path must be pure verification. Any docker/compose verb inside
  # these two functions would mean a reachability decision can mutate custody.
  ! awk '/^accept_external_reachability_receipt\(\)/,/^}/;
         /^guard_external_address_after_up\(\)/,/^}/' "${BOOT_HEAL}" \
    | grep -qE '(^|[^[:alnum:]_])(docker|compose)[[:space:]]'
}
check "#831: the receipt path issues no docker/compose commands" \
  receipt_path_touches_no_containers

# ---------------------------------------------------------------------------
# #841 review: asymmetry and mandatory identity binding
# ---------------------------------------------------------------------------
printf '\n== asymmetric authenticity (#841 review) ==\n'

# The node-held key is PUBLIC and cannot sign. This is the property that makes
# the receipt evidence: with a symmetric (HMAC) key, a node that can verify
# can also mint a fresh "reachable" receipt for itself without any external
# dial — the exact false PASS the gate exists to prevent.
node_key_cannot_sign() {
  printf 'anything' | openssl pkeyutl -sign -inkey "${KEY}" -rawin >/dev/null 2>&1
}
check_not "the node-held public key cannot produce a signature" node_key_cannot_sign

verify_with_private_key_in_node_slot() {
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" --test-only --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --key-file "${PROBE_PRIV}" \
    --expect-multiaddr "${ADDR}" --expect-peer-id "${PEER}" \
    --expect-genesis "${GENESIS}" >/dev/null 2>&1
}
check_not "the verifier rejects a PRIVATE key in the node's key slot" \
  verify_with_private_key_in_node_slot

verify_with_wrong_public_key() {
  WRFCOIN_P2P_RECEIPT_TEST_MODE=1 "${VERIFIER}" --test-only --now-epoch "${NOW}" \
    --receipt "${WORK}/fresh.env" --key-file "${WRONG_PUB}" \
    --expect-multiaddr "${ADDR}" --expect-peer-id "${PEER}" \
    --expect-genesis "${GENESIS}" >/dev/null 2>&1
}
check_not "a receipt does not verify against a different probe's public key" \
  verify_with_wrong_public_key

printf '\n== mandatory identity binding (#841 review) ==\n'
# boot-heal must hard-require the peer-id and genesis expectations instead of
# passing them only when configured — an authentic receipt for some OTHER node
# or chain must never settle this node's guard.
binding_is_mandatory() {
  local fn
  fn="$(awk '/^accept_external_reachability_receipt\(\)/,/^}$/' "${BOOT_HEAL}")"
  grep -q 'peer id unresolvable' <<<"${fn}" &&
    grep -q 'WRFCOIN_GENESIS_HASH is not set' <<<"${fn}" &&
    grep -qF -- 'args+=(--expect-peer-id "${expect_peer}")' <<<"${fn}" &&
    grep -qF -- 'args+=(--expect-genesis "${expect_genesis}")' <<<"${fn}" &&
    ! grep -qE '\[\[ -n "\$\{expect_(peer|genesis)\}" \]\] && args' <<<"${fn}"
}
check "boot-heal hard-requires peer-id and genesis binding (no optional path)" \
  binding_is_mandatory

printf '\n'
if (( fails > 0 )); then
  printf 'FAIL: %d of %d external-receipt assertion(s) failed\n' "${fails}" "${assertions}"
  exit 1
fi
printf 'PASS: external reachability receipt gate (%d assertions)\n' "${assertions}"
