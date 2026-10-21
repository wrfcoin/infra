#!/usr/bin/env bash
# Validate the WAL replay healthcheck with synthetic /readyz and /metrics payloads.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-wal-healthcheck-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${REPO_ROOT}/infra/docker/wal-replay-healthcheck.sh"
READYZ="${ROOT}/readyz.json"
METRICS="${ROOT}/metrics.prom"

bash -n "$CHECK"
printf '{"status":"ready"}\n' > "$READYZ"

cat > "$METRICS" <<'EOF'
# HELP wrfcoin_wal_replay_status 1 when the last WAL replay completed cleanly.
# TYPE wrfcoin_wal_replay_status gauge
wrfcoin_wal_replay_status 1
# HELP wrfcoin_state_divergence_total Same-height state divergence events.
# TYPE wrfcoin_state_divergence_total counter
wrfcoin_state_divergence_total 0
EOF

NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/clean.out"
grep -q "wrfcoin_wal_replay_status=1" "${ROOT}/clean.out"
grep -q "wrfcoin_state_divergence_total=0" "${ROOT}/clean.out"

cat > "$METRICS" <<'EOF'
wrfcoin_wal_replay_status 0
wrfcoin_state_divergence_total 0
EOF
if NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/corrupt.out" 2>&1; then
  echo "FAIL: healthcheck passed with wrfcoin_wal_replay_status=0"
  exit 1
fi
grep -q "WAL replay integrity check failed" "${ROOT}/corrupt.out"

cat > "$METRICS" <<'EOF'
wrfcoin_chain_height 42
wrfcoin_state_divergence_total 0
EOF
NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/missing-optional.out"
grep -q "not exported yet" "${ROOT}/missing-optional.out"

cat > "$METRICS" <<'EOF'
wrfcoin_chain_height 42
wrfcoin_state_divergence_total 2
EOF
if NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/missing-wal-diverged.out" 2>&1; then
  echo "FAIL: healthcheck passed with missing optional WAL metric and divergence"
  exit 1
fi
grep -q "state divergence detected" "${ROOT}/missing-wal-diverged.out"

if NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  WAL_REPLAY_METRIC_REQUIRED=true bash "$CHECK" > "${ROOT}/missing-required.out" 2>&1; then
  echo "FAIL: healthcheck passed with required WAL replay metric missing"
  exit 1
fi
grep -q "missing from metrics" "${ROOT}/missing-required.out"

cat > "$METRICS" <<'EOF'
wrfcoin_wal_replay_status 1
EOF
if NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/missing-divergence.out" 2>&1; then
  echo "FAIL: healthcheck passed with required divergence metric missing"
  exit 1
fi
grep -q "wrfcoin_state_divergence_total is missing from metrics" "${ROOT}/missing-divergence.out"

cat > "$METRICS" <<'EOF'
wrfcoin_wal_replay_status 1
wrfcoin_state_divergence_total 2
EOF
if NODE_READYZ_URL="file://${READYZ}" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/diverged.out" 2>&1; then
  echo "FAIL: healthcheck passed with wrfcoin_state_divergence_total=2"
  exit 1
fi
grep -q "state divergence detected" "${ROOT}/diverged.out"

if NODE_READYZ_URL="file://${ROOT}/does-not-exist" NODE_METRICS_URL="file://${METRICS}" \
  bash "$CHECK" > "${ROOT}/readyz-down.out" 2>&1; then
  echo "FAIL: healthcheck passed when /readyz was unavailable"
  exit 1
fi
grep -q "readiness endpoint is not healthy" "${ROOT}/readyz-down.out"

echo "PASS: WAL replay healthcheck validates"
