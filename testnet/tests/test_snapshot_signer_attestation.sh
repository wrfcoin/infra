#!/usr/bin/env bash
# Offline re-verification of the snapshot-signer ceremony record (infra#1080,
# ceremony step C4). Needs only openssl; no network, no YubiKey, no live host.
#
# Asserts, from the committed public certificates in
# testnet/ceremony/snapshot-signer-9c/:
#   1. the two token certificates are byte-identical to the ones exported at
#      the ceremony (sha256 recorded there);
#   2. the trust anchor is Yubico Attestation Root 1 (sha256 fingerprint pinned);
#   3. the slot-9C attestation chains to that root through the token's F9 cert;
#   4. the attested key is ED25519, and is EXACTLY the signer pinned in
#      testnet/cut-pins.env (WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS);
#   5. the Yubico extensions: serial 35278470, firmware 5.7.4, policy PIN once /
#      touch never (02 01), form factor 03.
# The certificates are force-added past the repo-wide *.pem ignore, which exists
# to keep keys out; the test fails on any file there other than README.md and
# certificate-only PEM.
# RED controls: a one-byte-tampered attestation must fail verification, a chain
# built without the F9 cert must fail, and a different key must fail the pin
# comparison. Each control proves the corresponding check can fail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="$REPO_ROOT/testnet/ceremony/snapshot-signer-9c"
CUT_PINS="$REPO_ROOT/testnet/cut-pins.env"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-signer-attest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ATTEST_SHA256=ddef70ed6682cc543b906d79a1bd3d1d4320aa7ab8fc601302c7214de595e187
F9_SHA256=4ca6aa761371243d61355fd43b37de7b78552aedcc879e7a4e060e66b9da950e
ROOT_FP=62:76:0C:6A:6E:F9:16:79:F4:54:C8:90:2B:80:FD:00:98:25:B3:F2:5D:A9:0F:1F:BA:CE:2E:C6:58:6C:D5:A8

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

command -v openssl >/dev/null || fail "openssl not found"

# Raw 32-byte ED25519 public key of a certificate, as lowercase hex.
attested_pubkey() {
  openssl x509 -in "$1" -noout -pubkey | openssl pkey -pubin -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n'
}
# Value (hex) of the Yubico extension 1.3.6.1.4.1.41482.3.<n> in a certificate.
yubico_ext() {
  openssl asn1parse -in "$1" | awk -v oid=":1.3.6.1.4.1.41482.3.$2" '
    found { sub(/.*\[HEX DUMP\]:/, ""); print; exit }
    $0 ~ oid"$" { found = 1 }'
}
# The one signer pinned in a cut-pins file, lowercased.
pinned_signer() {
  sed -n 's/^WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=//p' "$1" | tail -1 | tr -d '"'"'"' ' | tr 'A-F' 'a-f'
}
verify_chain() {
  openssl verify -show_chain -CAfile "$DIR/yubico-ca-1.pem" -untrusted "$2" "$1"
}

# 0. public material only. *.pem is gitignored repo-wide, and the certificates
# were force-added, so this test is the guard: EVERY file in the ceremony
# directory (any name, any depth, dotfiles included) must be the top-level
# README.md or consist solely of PEM CERTIFICATE blocks. A key, a CSR, a DER
# blob, stray text, or an empty file fails.
certificates_only() {
  awk '
    /^-----BEGIN CERTIFICATE-----$/ { if (inb) exit 1; inb = 1; n++; next }
    /^-----END CERTIFICATE-----$/   { if (!inb) exit 1; inb = 0; next }
    inb && /^[A-Za-z0-9+\/=]+$/     { next }
    /^[[:space:]]*$/ && !inb        { next }
    { exit 1 }
    END { if (inb || n == 0) exit 1 }' "$1"
}
while IFS= read -r -d '' f; do
  [ "$f" = "$DIR/README.md" ] && continue
  certificates_only "$f" || fail "$f is not README.md and not certificate-only PEM"
done < <(find "$DIR" -type f -print0)
ok ceremony_dir_holds_certificates_only

# 1. ceremony bytes
[ "$(sha256sum "$DIR/attest-9c.pem" | cut -d' ' -f1)" = "$ATTEST_SHA256" ] || fail "attest-9c.pem differs from the ceremony export"
[ "$(sha256sum "$DIR/f9.pem" | cut -d' ' -f1)" = "$F9_SHA256" ] || fail "f9.pem differs from the ceremony export"
ok ceremony_certificates_unchanged

# 2. trust anchor
fp="$(openssl x509 -in "$DIR/yubico-ca-1.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
[ "$fp" = "$ROOT_FP" ] || fail "yubico-ca-1.pem fingerprint $fp, expected $ROOT_FP"
openssl x509 -in "$DIR/yubico-ca-1.pem" -noout -subject | grep -q 'CN *= *Yubico Attestation Root 1' || fail "root subject"
ok trust_anchor_is_yubico_attestation_root_1

# 3. chain
cat "$DIR/f9.pem" "$DIR/yubico-piv-intermediates.pem" >"$TMP/untrusted.pem"
verify_chain "$DIR/attest-9c.pem" "$TMP/untrusted.pem" >"$TMP/verify.out" 2>&1 || { cat "$TMP/verify.out" >&2; fail "chain does not verify"; }
cat "$TMP/verify.out"
for cn in 'YubiKey PIV Attestation 9c' 'YubiKey PIV Attestation' 'Yubico PIV Attestation B 1' 'Yubico Attestation Intermediate B 1' 'Yubico Attestation Root 1'; do
  grep -qE "CN = ${cn}( \(untrusted\))?$" "$TMP/verify.out" || fail "chain lacks '$cn'"
done
ok attestation_chains_to_root

# RED: one byte of the signature flipped
openssl x509 -in "$DIR/attest-9c.pem" -outform DER -out "$TMP/attest.der"
size=$(wc -c <"$TMP/attest.der")
last=$(tail -c 1 "$TMP/attest.der" | od -An -tu1 | tr -d ' ')
{ head -c $((size - 1)) "$TMP/attest.der"; printf "\\$(printf '%03o' $(( (last + 1) % 256 )))"; } >"$TMP/tampered.der"
openssl x509 -inform DER -in "$TMP/tampered.der" -out "$TMP/tampered.pem"
if verify_chain "$TMP/tampered.pem" "$TMP/untrusted.pem" >/dev/null 2>&1; then fail "tampered attestation verified"; fi
ok red_tampered_attestation_rejected
# RED: without the token's F9 cert there is no path to the root
if verify_chain "$DIR/attest-9c.pem" "$DIR/yubico-piv-intermediates.pem" >/dev/null 2>&1; then fail "chain verified without F9"; fi
ok red_chain_without_f9_rejected

# 4. pubkey == pin
openssl x509 -in "$DIR/attest-9c.pem" -noout -text | grep -q 'Public Key Algorithm: ED25519' || fail "attested key is not ED25519"
key="$(attested_pubkey "$DIR/attest-9c.pem")"
pin="$(pinned_signer "$CUT_PINS")"
[[ "$key" =~ ^[0-9a-f]{64}$ ]] || fail "could not extract the attested key ($key)"
[ -n "$pin" ] || fail "no WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS in cut-pins.env"
[ "$key" = "$pin" ] || fail "cut-pins.env pins '$pin', attested key is '$key' (a rotation overlap needs this test updated)"
echo "  attested key = pin = $key"
ok pinned_signer_is_attested_key
example="$(sed -n 's/^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=//p' "$REPO_ROOT/testnet/.env.testnet.example" | tail -1 | tr 'A-F' 'a-f')"
[ "$example" = "$pin" ] || fail ".env.testnet.example WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS='$example' differs from the cut pin"
ok env_example_carries_the_pin
# RED: the same comparison against a different key
printf 'WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$(printf 'ab%.0s' {1..32})" >"$TMP/other-pins.env"
[ "$key" != "$(pinned_signer "$TMP/other-pins.env")" ] || fail "comparison accepted a different key"
ok red_other_pin_rejected

# 5. Yubico attestation extensions
expect_ext() {
  local n="$1" want="$2" what="$3" got
  got="$(yubico_ext "$DIR/attest-9c.pem" "$n")"
  [ "$got" = "$want" ] || fail "$what (41482.3.$n) = '$got', expected '$want'"
  echo "  41482.3.$n $what = $got"
}
expect_ext 3 050704 firmware
expect_ext 7 0204021A4E86 serial
[ $((16#021A4E86)) -eq 35278470 ] || fail serial
expect_ext 8 0201 'policy (PIN once, touch never)'
expect_ext 9 03 'form factor'
ok attestation_extensions

echo "PASS: snapshot-signer 9C attestation verifies offline and matches the cut pin"
