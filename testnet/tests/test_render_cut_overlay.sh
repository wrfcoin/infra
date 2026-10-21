#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RENDERER="${ROOT}/testnet/scripts/render-cut-overlay.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PIN=1111111111111111111111111111111111111111111111111111111111111111
printf 'WRFCOIN_CUT_GENESIS_HASH=%s\n' "$PIN" > "$TMP/pins.env"

echo renders_pin_into_overlay
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/cut.yml"
grep -Fq "WRFCOIN_GENESIS_HASH: '$PIN'" "$TMP/cut.yml"
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/cut.yml" --check

echo check_detects_drift_red
sed -i 's/1111/2222/' "$TMP/cut.yml"
set +e
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/cut.yml" --check >"$TMP/drift.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]]
grep -Fq 'overlay genesis' "$TMP/drift.out"

echo malformed_hash_red
printf '%s\n' 'WRFCOIN_CUT_GENESIS_HASH=ABC123' > "$TMP/bad.env"
set +e
bash "$RENDERER" --pins "$TMP/bad.env" --out "$TMP/bad.yml" >"$TMP/bad.out" 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]]
grep -Fq '64 lowercase hex' "$TMP/bad.out"

# core4#3361 option B: the genesis faucet pin rides the same overlay.
FAUCET=0xf72059c3b4a6d3c431920c3cf3e40dbf68a6b5d3
FAUCET_UPPER=0xF72059C3B4A6D3C431920C3CF3E40DBF68A6B5D3

echo no_faucet_pin_renders_no_faucet_line
grep -q 'WRFCOIN_GENESIS_FAUCET_ADDRESS' "$TMP/cut.yml" && exit 1
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/plain.yml" | grep -Fq 'faucet=none'
grep -q 'WRFCOIN_GENESIS_FAUCET_ADDRESS' "$TMP/plain.yml" && exit 1
printf 'WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=\n' >> "$TMP/pins.env"
# Custody binds every reviewed pin-file byte, including this empty declaration.
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/plain.yml" >/dev/null
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/plain.yml" --check >/dev/null

echo renders_faucet_pin_into_overlay
printf 'WRFCOIN_CUT_GENESIS_HASH=%s\nWRFCOIN_CUT_GENESIS_FAUCET_ADDRESS="%s"\n' "$PIN" "$FAUCET_UPPER" > "$TMP/faucet.env"
bash "$RENDERER" --pins "$TMP/faucet.env" --out "$TMP/faucet.yml" >"$TMP/faucet.out"
grep -Fq "WRFCOIN_GENESIS_FAUCET_ADDRESS: '$FAUCET'" "$TMP/faucet.yml"
grep -Fq 'faucet=pinned' "$TMP/faucet.out"
grep -qiF "${FAUCET#0x}" "$TMP/faucet.out" && exit 1
bash "$RENDERER" --pins "$TMP/faucet.env" --out "$TMP/faucet.yml" --check >/dev/null

echo check_detects_faucet_drift_red
for overlay in "$TMP/plain.yml" "$TMP/faucet-drift.yml"; do
  sed "s/$FAUCET/0x1111111111111111111111111111111111111111/" "$TMP/faucet.yml" > "$TMP/faucet-drift.yml"
  set +e
  bash "$RENDERER" --pins "$TMP/faucet.env" --out "$overlay" --check >"$TMP/fdrift.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]]
  grep -Fq 'faucet address does not match the pin' "$TMP/fdrift.out"
done
# ...and an overlay carrying a faucet the pins no longer name is drift too.
set +e
bash "$RENDERER" --pins "$TMP/pins.env" --out "$TMP/faucet.yml" --check >/dev/null 2>&1
rc=$?
set -e
[[ $rc -eq 1 ]]

echo malformed_faucet_pin_red
for bad in f72059c3b4a6d3c431920c3cf3e40dbf68a6b5d3 0xnot-hex 0x0000000000000000000000000000000000000000; do
  printf 'WRFCOIN_CUT_GENESIS_HASH=%s\nWRFCOIN_CUT_GENESIS_FAUCET_ADDRESS=%s\n' "$PIN" "$bad" > "$TMP/badf.env"
  set +e
  bash "$RENDERER" --pins "$TMP/badf.env" --out "$TMP/badf.yml" >"$TMP/badf.out" 2>&1
  rc=$?
  set -e
  [[ $rc -eq 1 ]]
  grep -Fq '0x + 40 hex and not the zero address' "$TMP/badf.out"
  [[ ! -e "$TMP/badf.yml" ]]
done

echo CUT_OVERLAY_TESTS=PASS
