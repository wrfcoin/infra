#!/usr/bin/env bash
# #798: the node's container healthcheck is a DEPENDENCY GATE and must be
# liveness, never readiness.
#
# The override once probed /readyz, which 503s when block production is stale
# — and the block producer is itself gated on the node being healthy, so the
# stack could not cold-start after any stall (measured 2026-08-06:
# block_age_seconds 1778, every dependent in "dependency failed to start").
#
# Asserted on the EFFECTIVE MERGED config (`docker compose config`), not on
# any single file, because the deadlock was introduced by an override winning
# over a correct base file — a single-file grep would have stayed green.
#
# What this canNOT check, stated plainly: that a real cold boot succeeds, or
# that /readyz itself behaves. It pins which endpoint the dependency gate
# probes, nothing more.
#
# Run: bash scripts/tests/test-node-health-gate-liveness.sh
set -uo pipefail

TESTNET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/testnet"
fails=0

check() {
  local name="$1" ; shift
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: node-health-liveness-check-forwards-argv
  if "$@"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    fails=$((fails + 1))
  fi
}

if ! docker compose version >/dev/null 2>&1; then
  echo "FAIL: docker compose is required to render the effective config" >&2
  exit 1
fi

# Render the merged config the way boot-heal.sh composes it, restricted to the
# files carried by the repo (cut overlays are host-local and do not touch the
# node healthcheck). The `${VAR:?}`-required interpolations get inert dummy
# values — this renders config only, nothing is started and nothing live is
# touched — so the assertion is on structure, never on real secrets.
render_node_healthcheck() {
  env \
    ADMIN_TOKEN=test-render-only \
    FAUCET_API_TOKEN=test-render-only \
    GRAFANA_ADMIN_PASSWORD=test-render-only \
    JWT_SECRET=test-render-only \
    N8N_WEBHOOK_SECRET=test-render-only \
    OAUTH_STATE_SECRET=test-render-only \
    POSTGRES_PASSWORD=test-render-only \
    REDIS_PASSWORD=test-render-only \
    RPC_API_KEY=test-render-only \
    WRFCOIN_OPERATOR_TOKEN=test-render-only \
    WRFCOIN_CONTRIBUTOR_TOKEN=contributor-test-render-only \
    WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/127.0.0.1/tcp/9000 \
    WRFCOIN_TESTNET_RUNTIME_IMAGE=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    bash "${TESTNET_DIR}/tests/render-testnet-compose.sh" \
    -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" \
    config 2>/dev/null \
    | awk '/^  wrfcoin-node:$/{in_node=1; next}
           in_node && /^  [a-z]/{in_node=0}
           in_node && /^    healthcheck:$/{in_hc=1; next}
           in_hc && /^    [a-z]/{in_hc=0}
           in_hc {print}'
}

MERGED_HEALTHCHECK="$(render_node_healthcheck)"

if [[ -z "${MERGED_HEALTHCHECK}" ]]; then
  # An empty extraction means the parse above broke, not that the config is
  # fine. Refuse to pass vacuously.
  echo "FAIL: could not extract the wrfcoin-node healthcheck from the merged config" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. The effective node healthcheck probes /health (liveness).
# ---------------------------------------------------------------------------
gate_probes_liveness() {
  grep -q 'localhost:8556/health' <<<"${MERGED_HEALTHCHECK}"
}
check "effective node healthcheck probes /health (liveness)" gate_probes_liveness

# ---------------------------------------------------------------------------
# 2. The effective node healthcheck does NOT probe /readyz. Readiness 503s on
#    stale block production, and the producer is downstream of this gate —
#    that is the #798 deadlock.
# ---------------------------------------------------------------------------
gate_does_not_probe_readyz() {
  ! grep -q '/readyz' <<<"${MERGED_HEALTHCHECK}"
}
check "effective node healthcheck does not probe /readyz" gate_does_not_probe_readyz

# ---------------------------------------------------------------------------
# 3. The #1717 divergence-metric-export guard survives the fix. Deleting the
#    /metrics grep would also make assertion 2 pass trivially; this pins that
#    the fix removed only the readiness coupling, not the export guard.
# ---------------------------------------------------------------------------
divergence_export_guard_present() {
  grep -q 'wrfcoin_state_divergence_total' <<<"${MERGED_HEALTHCHECK}"
}
check "divergence-metric export guard is still present" divergence_export_guard_present

# ---------------------------------------------------------------------------
# 4. /readyz is still consumed by the concrete promtail monitoring surface —
#    the fix moves readiness OUT of the gate, it must not erase the real probe.
# ---------------------------------------------------------------------------
readyz_still_monitored() {
  grep -Eq '^[[:space:]]*[^#].*/readyz' "${TESTNET_DIR}/promtail-config.yaml"
}
check "/readyz remains in the monitoring surface" readyz_still_monitored

echo
if (( fails > 0 )); then
  echo "test-node-health-gate-liveness: ${fails} assertion(s) failed"
  exit 1
fi
echo "test-node-health-gate-liveness: all assertions passed"
