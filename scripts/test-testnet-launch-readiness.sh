#!/usr/bin/env bash
# Validate Tier 3 chain-liveness behavior in scripts/testnet-launch-readiness.sh.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-testnet-launch-readiness-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/scripts/testnet-launch-readiness.sh"
METRICS="${ROOT}/metrics.prom"
LAST_HEIGHT="${ROOT}/last-height.txt"
COMMON_ARGS=(--profile developer --skip-secrets --skip-runtime-image --skip-report --skip-contracts --skip-full-profile --metrics-url "file://${METRICS}" --json-out "${ROOT}/result.json" --markdown-out "${ROOT}/result.md")

bash -n "$CHECK"

cat > "$METRICS" <<'EOF'
# HELP wrfcoin_chain_height Current chain height.
# TYPE wrfcoin_chain_height gauge
wrfcoin_chain_height 42
# HELP wrfcoin_state_divergence_total Same-height state divergence events.
# TYPE wrfcoin_state_divergence_total counter
wrfcoin_state_divergence_total 0
EOF

WRFCOIN_LAST_HEIGHT_FILE="$LAST_HEIGHT" \
  bash "$CHECK" "${COMMON_ARGS[@]}" \
  > "${ROOT}/run-1.out"
grep -q "Tier 3 chain height advanced (0 -> 42)" "${ROOT}/run-1.out"
grep -q "Tier 4 divergence metric clean" "${ROOT}/run-1.out"

if WRFCOIN_LAST_HEIGHT_FILE="$LAST_HEIGHT" \
  bash "$CHECK" "${COMMON_ARGS[@]}" \
  > "${ROOT}/run-2.out" 2>&1; then
  echo "FAIL: launch readiness passed even though chain height did not advance"
  exit 1
fi
grep -q "Tier 3 chain stalled at h=42 (previous 42)" "${ROOT}/run-2.out"

cat > "$METRICS" <<'EOF'
wrfcoin_chain_height 43
wrfcoin_state_divergence_total 1
EOF
if WRFCOIN_LAST_HEIGHT_FILE="$LAST_HEIGHT" \
  bash "$CHECK" "${COMMON_ARGS[@]}" \
  > "${ROOT}/diverged.out" 2>&1; then
  echo "FAIL: launch readiness passed with wrfcoin_state_divergence_total=1"
  exit 1
fi
grep -q "Tier 4 divergence detected" "${ROOT}/diverged.out"

cat > "$METRICS" <<'EOF'
wrfcoin_chain_height 44
EOF
if WRFCOIN_LAST_HEIGHT_FILE="$LAST_HEIGHT" \
  bash "$CHECK" "${COMMON_ARGS[@]}" \
  > "${ROOT}/missing-divergence.out" 2>&1; then
  echo "FAIL: launch readiness passed without wrfcoin_state_divergence_total"
  exit 1
fi
grep -q "wrfcoin_state_divergence_total missing from metrics" "${ROOT}/missing-divergence.out"

echo "PASS: testnet launch readiness Tier 3/4 behavior validates"
