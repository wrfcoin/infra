#!/usr/bin/env bash
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/runtime-image-gate.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/validate-runtime-image.sh"
GOOD="sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

expect_red() {
  local label="$1" value="$2"
  if bash "$GATE" --image "$value" >"$ROOT/$label.out" 2>&1; then
    echo "FAIL: $label unexpectedly passed" >&2
    exit 1
  fi
  grep -q 'RUNTIME_IMAGE_FAIL:' "$ROOT/$label.out"
}

bash "$GATE" --image "$GOOD" | grep -q 'classification=IMMUTABLE'
expect_red missing ''
expect_red tag-only 'wrfcoin/native-chain:testnet-local'
expect_red placeholder 'sha256:REPLACE_WITH_RUNTIME_IMAGE_ID'
expect_red short 'sha256:abc123'
expect_red uppercase "sha256:$(printf 'A%.0s' {1..64})"
expect_red nonhex "sha256:$(printf 'g%.0s' {1..64})"
expect_red malformed "image:sha256:$(printf 'a%.0s' {1..64})"

bash "$GATE" --profile developer --image wrfcoin/native-chain:testnet >"$ROOT/dev.out"
grep -q 'classification=NON_RELEASE' "$ROOT/dev.out"

mkdir -p "$ROOT/bin"
cat >"$ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "${RUNNING_IMAGE:-}" == missing ]]; then exit 1; fi
printf '%s\n' "${RUNNING_IMAGE:-}"
SH
chmod +x "$ROOT/bin/docker"

PATH="$ROOT/bin:$PATH" RUNNING_IMAGE="$GOOD" \
  bash "$GATE" --image "$GOOD" --check-running --container node >"$ROOT/match.out"
grep -q "configured=$GOOD running=$GOOD" "$ROOT/match.out"

OTHER="sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
if PATH="$ROOT/bin:$PATH" RUNNING_IMAGE="$OTHER" \
  bash "$GATE" --image "$GOOD" --check-running --container node >"$ROOT/mismatch.out" 2>&1; then
  echo 'FAIL: configured/running mismatch unexpectedly passed' >&2
  exit 1
fi
grep -q "configured=$GOOD running=$OTHER mismatch=true" "$ROOT/mismatch.out"

# Default container set follows the "seed" profile (infra#1057 Q4: seed retired).
cat >"$ROOT/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >> "${DOCKER_LOG:?}"
printf '%s\n' "${RUNNING_IMAGE:-}"
SH
chmod +x "$ROOT/bin/docker"
: >"$ROOT/retired.log"
PATH="$ROOT/bin:$PATH" RUNNING_IMAGE="$GOOD" DOCKER_LOG="$ROOT/retired.log" COMPOSE_PROFILES=collector \
  bash "$GATE" --image "$GOOD" --check-running >"$ROOT/retired.out"
grep -q 'seed profile not active' "$ROOT/retired.out"
[[ "$(sort "$ROOT/retired.log" | tr '\n' ' ')" == "wrfcoin-testnet-node wrfcoin-testnet-softhsm-init " ]] \
  || { echo "FAIL: seed retired: default set was $(tr '\n' ' ' <"$ROOT/retired.log")" >&2; exit 1; }
: >"$ROOT/active.log"
PATH="$ROOT/bin:$PATH" RUNNING_IMAGE="$GOOD" DOCKER_LOG="$ROOT/active.log" COMPOSE_PROFILES=seed,collector \
  bash "$GATE" --image "$GOOD" --check-running >"$ROOT/active.out"
if [[ "$(wc -l <"$ROOT/active.log")" -ne 4 ]] || ! grep -qx wrfcoin-testnet-seed "$ROOT/active.log"; then
  echo "FAIL: seed active: default set was $(tr '\n' ' ' <"$ROOT/active.log")" >&2; exit 1
fi

echo 'PASS: immutable local image-ID gate rejects malformed pins and running drift'
