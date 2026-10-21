#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_ROOT/testnet/check-env-completeness.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-signers-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

touch "$ROOT/minimal-compose.yml"

KEY_A="$(printf 'ab%.0s' {1..32})"
KEY_B="$(printf 'CD%.0s' {1..32})"
KEY_C="$(printf 'ef%.0s' {1..32})"
KEY_B_LOWER="$(printf '%s' "$KEY_B" | tr 'A-F' 'a-f')"

# Synthetic cut-pins fixtures only; the real testnet/cut-pins.env is never read
# by these cases (asserted unchanged at the end).
printf 'WRFCOIN_CUT_CHAIN_ID=777\n' >"$ROOT/pins-unpinned.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s,%s\n' "$KEY_A" "$KEY_B" >"$ROOT/pins-pinned.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s,not-a-key\n' "$KEY_A" >"$ROOT/pins-malformed.env"

# expect_pass NAME ENVFILE PINSFILE GREP   /   expect_fail NAME ENVFILE PINSFILE GREP
check() {
  "$CHECK" -f "$ROOT/minimal-compose.yml" --env "$1" --cut-pins "$2" >"$3" 2>&1
}
expect_pass() {
  local name="$1" env="$2" pins="$3" pattern="$4"
  if ! check "$env" "$pins" "$ROOT/$name.out"; then
    echo "FAIL: $name: expected exit 0" >&2; sed 's/^/  /' "$ROOT/$name.out" >&2; exit 1
  fi
  grep -qF -- "$pattern" "$ROOT/$name.out" || { echo "FAIL: $name: missing '$pattern'" >&2; sed 's/^/  /' "$ROOT/$name.out" >&2; exit 1; }
  echo "ok: $name"
}
expect_fail() {
  local name="$1" env="$2" pins="$3" pattern="$4"
  if check "$env" "$pins" "$ROOT/$name.out"; then
    echo "FAIL: $name: expected exit 1" >&2; sed 's/^/  /' "$ROOT/$name.out" >&2; exit 1
  fi
  grep -qF -- "$pattern" "$ROOT/$name.out" || { echo "FAIL: $name: missing '$pattern'" >&2; sed 's/^/  /' "$ROOT/$name.out" >&2; exit 1; }
  echo "ok: $name"
}

printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=\n' >"$ROOT/empty.env"
: >"$ROOT/absent.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s,%s\n' "$KEY_A" "$KEY_B" >"$ROOT/valid.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS="%s,%s,%s"\n' "$KEY_B_LOWER" "$KEY_A" "$KEY_A" >"$ROOT/valid-reordered.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$KEY_A" >"$ROOT/subset.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s,%s\n' "$KEY_A" "$KEY_C" >"$ROOT/other.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s,not-a-key\n' "$KEY_A" >"$ROOT/invalid.env"

# No pin: absence is visible but not a failure (owner ruling infra#1080 Q2).
expect_pass unpinned_empty_warns        "$ROOT/empty.env"  "$ROOT/pins-unpinned.env" 'WARN  WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: snapshot-ingest UNAVAILABLE'
expect_pass unpinned_absent_warns       "$ROOT/absent.env" "$ROOT/pins-unpinned.env" 'WARN  WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: snapshot-ingest UNAVAILABLE'
expect_pass unpinned_valid_two_keys     "$ROOT/valid.env"  "$ROOT/pins-unpinned.env" 'trusted signer list valid (2 key(s)); no cut pin'
# Malformed is always an error (the #979 mutation control).
expect_fail unpinned_malformed_red      "$ROOT/invalid.env" "$ROOT/pins-unpinned.env" 'ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: every signer must be a 64-hex'
# Pinned: absence and mismatch are errors; equality is set-equality.
expect_pass pinned_match                "$ROOT/valid.env"           "$ROOT/pins-pinned.env" 'matches the cut pin'
expect_pass pinned_match_case_order_dup "$ROOT/valid-reordered.env" "$ROOT/pins-pinned.env" 'trusted signer list valid (2 key(s)) and matches the cut pin'
expect_fail pinned_empty_red            "$ROOT/empty.env"   "$ROOT/pins-pinned.env" 'absent, but pins-pinned.env pins a trusted snapshot signer'
expect_fail pinned_absent_red           "$ROOT/absent.env"  "$ROOT/pins-pinned.env" 'absent, but pins-pinned.env pins a trusted snapshot signer'
expect_fail pinned_subset_red           "$ROOT/subset.env"  "$ROOT/pins-pinned.env" 'does not match the signer(s) pinned'
expect_fail pinned_other_red            "$ROOT/other.env"   "$ROOT/pins-pinned.env" 'does not match the signer(s) pinned'
expect_fail pinned_host_malformed_red   "$ROOT/invalid.env" "$ROOT/pins-pinned.env" 'ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: every signer must be a 64-hex'
expect_fail pin_malformed_red           "$ROOT/valid.env"   "$ROOT/pins-malformed.env" 'ERROR WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS in'

# infra#1088 review (codex round 50): validate each entry BEFORE canonicalising.
KEY_A_SPLIT="${KEY_A:0:32} ${KEY_A:32}"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$KEY_A_SPLIT" >"$ROOT/internal-space.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=,,\n' >"$ROOT/commas-only.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s,,%s\n' "$KEY_A" "$KEY_B" >"$ROOT/empty-middle.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=%s,\n' "$KEY_A" >"$ROOT/trailing-comma.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=,%s\n' "$KEY_A" >"$ROOT/leading-comma.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=" %s , %s "\n' "$KEY_A" "$KEY_B" >"$ROOT/boundary-space.env"
printf 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS="   "\n' >"$ROOT/whitespace-only.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$KEY_A" >"$ROOT/pins-key-a.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$KEY_A_SPLIT" >"$ROOT/pins-internal-space.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s,,%s\n' "$KEY_A" "$KEY_B" >"$ROOT/pins-empty-middle.env"
printf 'WRFCOIN_CUT_CHAIN_ID=777\nWRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=,,\n' >"$ROOT/pins-commas-only.env"

MALFORMED_HOST='ERROR WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: every signer must be a 64-hex'
MALFORMED_PIN='ERROR WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS in'
expect_fail host_internal_space_red           "$ROOT/internal-space.env" "$ROOT/pins-unpinned.env" "$MALFORMED_HOST"
expect_fail host_internal_space_vs_pin_red    "$ROOT/internal-space.env" "$ROOT/pins-key-a.env"    "$MALFORMED_HOST"
expect_fail host_commas_only_red              "$ROOT/commas-only.env"    "$ROOT/pins-unpinned.env" "$MALFORMED_HOST"
expect_fail host_empty_middle_red             "$ROOT/empty-middle.env"   "$ROOT/pins-unpinned.env" "$MALFORMED_HOST"
expect_fail host_empty_middle_vs_pin_red      "$ROOT/empty-middle.env"   "$ROOT/pins-pinned.env"   "$MALFORMED_HOST"
expect_fail host_trailing_comma_red           "$ROOT/trailing-comma.env" "$ROOT/pins-unpinned.env" "$MALFORMED_HOST"
expect_fail host_leading_comma_red            "$ROOT/leading-comma.env"  "$ROOT/pins-unpinned.env" "$MALFORMED_HOST"
expect_pass host_boundary_space_matches_pin   "$ROOT/boundary-space.env" "$ROOT/pins-pinned.env"   'matches the cut pin'
expect_pass host_whitespace_only_warns        "$ROOT/whitespace-only.env" "$ROOT/pins-unpinned.env" 'WARN  WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS: snapshot-ingest UNAVAILABLE'
expect_fail pin_internal_space_red            "$ROOT/valid.env"          "$ROOT/pins-internal-space.env" "$MALFORMED_PIN"
expect_fail pin_empty_middle_red              "$ROOT/valid.env"          "$ROOT/pins-empty-middle.env"   "$MALFORMED_PIN"
expect_fail pin_commas_only_red               "$ROOT/empty.env"          "$ROOT/pins-commas-only.env"    "$MALFORMED_PIN"

# The pins file must be READ: missing or unreadable is an ERROR, never "no pin".
expect_fail no_pins_file_red                  "$ROOT/empty.env" "$ROOT/does-not-exist.env" 'ERROR cut pins file not found'
expect_fail pins_path_is_directory_red        "$ROOT/empty.env" "$ROOT"                    'ERROR cut pins file unreadable'
cp "$ROOT/pins-unpinned.env" "$ROOT/pins-unreadable.env"
chmod 000 "$ROOT/pins-unreadable.env"
if [ -r "$ROOT/pins-unreadable.env" ]; then
  # root ignores mode bits; the directory case above still proves the read check.
  echo "SKIP: unreadable_pins_red (running as uid $(id -u), mode 000 is still readable)"
else
  expect_fail unreadable_pins_red             "$ROOT/empty.env" "$ROOT/pins-unreadable.env" 'ERROR cut pins file unreadable'
fi
chmod 600 "$ROOT/pins-unreadable.env"
# Default resolution: with no --cut-pins and no CUT_PINS_FILE the gate reads the
# repo's own testnet/cut-pins.env (it cds to testnet/). Pin-agnostic on purpose,
# so this stays true after the option-C pin lands: the file must be READ (either
# "none pinned" or "pins a trusted snapshot signer"), never reported missing.
env -u CUT_PINS_FILE "$CHECK" -f "$ROOT/minimal-compose.yml" --env "$ROOT/empty.env" >"$ROOT/default-pins.out" 2>&1 || true
if grep -qF 'cut pins file' "$ROOT/default-pins.out" \
   || ! grep -qE 'none pinned in cut-pins\.env|cut-pins\.env pins a trusted snapshot signer' "$ROOT/default-pins.out"; then
  echo "FAIL: default_pins_resolves: default cut-pins.env was not read" >&2; sed 's/^/  /' "$ROOT/default-pins.out" >&2; exit 1
fi
echo "ok: default_pins_resolves"

# The example now carries the cut pin (infra#1080), so the no-default property
# is checked on a copy with the signer line removed: unset must render empty.
grep -v '^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=' "$REPO_ROOT/testnet/.env.testnet.example" >"$ROOT/example-unset.env"
bash "$REPO_ROOT/testnet/tests/render-testnet-compose.sh" \
  --env-file "$ROOT/example-unset.env" \
  -f "$REPO_ROOT/testnet/docker-compose.testnet.yml" \
  --profile seed config --format json >"$ROOT/compose-unset.json"
python3 - "$ROOT/compose-unset.json" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for service in ("wrfcoin-node", "wrfcoin-seed"):
    actual = payload["services"][service]["environment"].get("WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS")
    if actual != "":
        raise SystemExit(f"{service}: unset signer passthrough must render empty, got {actual!r}")
PY

# The unmodified example renders the value it carries (the cut pin) into both.
EXAMPLE_SIGNERS="$(sed -n 's/^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=//p' "$REPO_ROOT/testnet/.env.testnet.example" | tail -1)"
env -u WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS bash "$REPO_ROOT/testnet/tests/render-testnet-compose.sh" \
  --env-file "$REPO_ROOT/testnet/.env.testnet.example" \
  -f "$REPO_ROOT/testnet/docker-compose.testnet.yml" \
  --profile seed config --format json >"$ROOT/compose-example.json"
python3 - "$ROOT/compose-example.json" "$EXAMPLE_SIGNERS" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
for service in ("wrfcoin-node", "wrfcoin-seed"):
    actual = payload["services"][service]["environment"].get("WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS")
    if actual != sys.argv[2]:
        raise SystemExit(f"{service}: example signer passthrough mismatch: {actual!r}")
PY

WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS="$KEY_A,$KEY_B" \
  bash "$REPO_ROOT/testnet/tests/render-testnet-compose.sh" \
  --env-file "$REPO_ROOT/testnet/.env.testnet.example" \
  -f "$REPO_ROOT/testnet/docker-compose.testnet.yml" \
  --profile seed config --format json >"$ROOT/compose.json"
python3 - "$ROOT/compose.json" "$KEY_A,$KEY_B" <<'PY'
import json
import sys

payload = json.load(open(sys.argv[1], encoding="utf-8"))
expected = sys.argv[2]
for service in ("wrfcoin-node", "wrfcoin-seed"):
    actual = payload["services"][service]["environment"].get("WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS")
    if actual != expected:
        raise SystemExit(f"{service}: signer passthrough mismatch: {actual!r}")
PY

# Exercise the real join script through the env-write step using a synthetic
# cut-pins file, then stop at a deliberate mock seam before Docker mutation.
mkdir -p "$ROOT/join-root/infra" "$ROOT/bin"
cp -a "$REPO_ROOT/testnet" "$ROOT/join-root/infra/testnet"
cat >"$ROOT/bin/tailscale" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" ]]; then echo wrfcoin-testnet; else echo 198.51.100.7; fi
SH
chmod +x "$ROOT/bin/tailscale"
cat >"$ROOT/join-root/infra/testnet/check-p2p-external-addr.sh" <<'SH'
#!/usr/bin/env bash
exit 97
SH
chmod +x "$ROOT/join-root/infra/testnet/check-p2p-external-addr.sh"

run_join_fixture() {
  local name="$1" include_signer="$2"
  local dir="$ROOT/join-$name"
  cp -a "$ROOT/join-root" "$dir"
  mkdir -p "$dir/core4"
  cat >"$dir/pins.env" <<EOF
WRFCOIN_CUT_CORE4_COMMIT=0123456789abcdef0123456789abcdef01234567
WRFCOIN_CUT_GENESIS_HASH=$(printf '12%.0s' {1..32})
WRFCOIN_CUT_CHAIN_ID=777
WRFCOIN_CUT_NETWORK_ID=testnet
WRFCOIN_CUT_BOOTSTRAP=/ip4/198.51.100.8/tcp/9000/p2p/synthetic
EOF
  if [[ "$include_signer" == yes ]]; then
    printf 'WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=%s\n' "$KEY_A" >>"$dir/pins.env"
  fi
  printf 'WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000\n' >"$dir/infra/testnet/.env"
  set +e
  BOOTSTRAP_PEERS=/ip4/198.51.100.8/tcp/9000/p2p/synthetic \
  PATH="$ROOT/bin:$PATH" CUT_PINS_FILE="$dir/pins.env" \
    bash "$dir/infra/testnet/join-testnet-sync-node.sh" --root "$dir" >"$dir/run.out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 97 ]]; then
    echo "FAIL: join fixture stopped at unexpected rc=$rc" >&2
    sed 's/^/  /' "$dir/run.out" >&2
    exit 1
  fi
  if [[ "$include_signer" == yes ]]; then
    grep -qx "WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=$KEY_A" "$dir/infra/testnet/.env"
  elif grep -q '^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=' "$dir/infra/testnet/.env"; then
    echo "FAIL: join wrote a trusted signer without a cut pin" >&2
    exit 1
  fi
}

run_join_fixture pinned yes
run_join_fixture absent no

if git -C "$REPO_ROOT" diff --name-only | grep -qx 'testnet/cut-pins.env'; then
  echo "FAIL: testnet/cut-pins.env was modified" >&2
  exit 1
fi

echo "PASS: snapshot signer env, compose, validation, and join propagation"
