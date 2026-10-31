# WRFCoin Testnet — Overview

The `testnet/` directory contains the compose stack and supporting configuration
that runs the WRFCoin testnet on the node host (node container, `<WORKSTATION_LAN_IP>`).

## Quick Start

See [GETTING_STARTED.md](GETTING_STARTED.md) for setup prerequisites and
[JOIN_TESTNET.md](JOIN_TESTNET.md) to join as a sync-only node (no invite needed).
Deployment requires operator-supplied paths, signer configuration and peer
addresses. Public overlay examples and their required variables are documented in
[PUBLIC_DEPLOYMENT_EXAMPLES.md](PUBLIC_DEPLOYMENT_EXAMPLES.md). Internal runbooks
are not included; obtain the approved configuration from the operator before
starting a node.

## Compose Stack Files

| File | Role |
|------|------|
| `docker-compose.testnet.yml` | Base service definitions, volumes, networking |
| `docker-compose.override.yml` | Local-build image tags, SoftHSM2 env, `/health` liveness dependency gate plus divergence-metric export check |
| `docker-compose.desktop.yml` | Desktop/WSL2 data-volume and node environment overlay |
| `docker-compose.yubikey.desktop.yml` | Opt-in desktop/WSL2 USB overlay for `WRFCOIN_HSM_MODE=yubikey` |
| `docker-compose.lan.yml` | Explorer-only LAN overlay — bind `8081` to all interfaces (home LAN only) |

NEVER push Docker images to a registry — all builds are local (`wrfcoin/native-chain:testnet-local`
etc.). See [repository README](../README.md) deployment constraints.

## Key Runbooks

| Document | Purpose |
|----------|---------|
| [GETTING_STARTED.md](GETTING_STARTED.md) | First-time setup |
| [`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md) | Daily ops (canonical) |
| [LAUNCH_READINESS_CHECKLIST.md](LAUNCH_READINESS_CHECKLIST.md) | Final launch-readiness checklist |
| [POST_DEPLOY_CHECKLIST.md](POST_DEPLOY_CHECKLIST.md) | After every redeploy |
| [TROUBLESHOOTING.md](TROUBLESHOOTING.md) | Incident triage |
| [POSTGRES_PITR_RUNBOOK.md](POSTGRES_PITR_RUNBOOK.md) | DB point-in-time recovery |
| [RESTORE_DRILL.md](RESTORE_DRILL.md) | Backup / restore drill |

## YubiKey Rollout (Two Nodes)

1. Plug one YubiKey into each node host you plan to restart.
2. On each node, run `bash testnet/scripts/yubikey-bootstrap.sh --node <node-name>` to generate slot `9c`, export `testnet/secrets/validator-<node-name>.pub`, and update local `.env` with the per-node labels and PIN.
3. Rebuild the local `wrfcoin-node` image so it contains `libykcs11.so` and pcsc-lite 2.3.3.
4. Restart each node with the correct YubiKey overlay included: the included `desktop` overlay for WSL2, or an operator-provided overlay for other hosts.
5. Verify signer provenance logs show PKCS#11/YubiKey, heights keep increasing, peers remain connected, and `infra/scripts/verify-convergence.sh` exits 0 before declaring the node deployed.

## Pre-Launch Readiness

Use [LAUNCH_READINESS_CHECKLIST.md](LAUNCH_READINESS_CHECKLIST.md) as the
manager checklist for infra#490. It combines source hygiene, env/secret hygiene,
local readiness checks, post-deploy snapshots, and cross-repo blocker review.

Run the launch-readiness wrapper from the infra repo root before promoting testnet to external traffic:

```bash
bash scripts/testnet-launch-readiness.sh \
  --n5 deploy-status-n5-pro.json \
  --desktop deploy-status-desktop.json \
  --readiness-report readiness-report.json
```

This is the only final public-release verdict. It also requires paired-node,
synthetic-policy, real-contribution, outbound-alert, and five full-profile
functional proofs, then writes machine-readable JSON and human-readable
Markdown. Missing evidence is RED. `--profile developer` permits explicit
`NON_RELEASE` skips for local iteration only.

To verify scrape coverage guardrails for cAdvisor/node_exporter/discovery targets:

```bash
bash scripts/tests/test-testnet-scrape-coverage.sh
```

The one-page service coverage matrix is tracked in
[docs/scrape-coverage-matrix.md](docs/scrape-coverage-matrix.md). It records
which services are scraped, which only have healthchecks, which alert rules cover
scrape failure, and why the infra#475 divergence hard gate waits for core4#1620.

For the full two-node gate (N5 + desktop snapshot comparison):

```bash
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=n5-pro WRFCOIN_ROOT=$HOME/wrfcoin-src bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-n5-pro.json
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=desktop WRFCOIN_ROOT=$HOME/wrfcoin-src bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-desktop.json
bash testnet/scripts/launch-readiness-gate.sh \
  --n5 deploy-status-n5-pro.json \
  --desktop deploy-status-desktop.json
```

The gate defaults to `--mode public-release`. That mode fails if the explicit
`synthetic` Compose profile is active or if neither attributed snapshot window
contains a successfully mined real-collector contribution. For local demos,
start the simulator with `docker compose --profile synthetic ...` and run the
gate with `--mode developer-demo`; its report is visibly classified
`SIMULATED` and is not public-release evidence.

Peer-health dashboard slice (infra#481):
- Grafana dashboard file: `testnet/grafana-dashboards/peer-health.json`
- Provisioning path: mounted automatically via `./grafana-dashboards:/var/lib/grafana/dashboards:ro`
- Current behavior: connected-peer and P2P throughput panels are active now; divergence panel reads `wrfcoin_state_divergence_total`.

## Tailscale reachability for testers

For the June 17 testnet, testers reach the testnet **over Tailscale only** (not the
public internet). The direct explorer port is not part of the current tester
surface. Use the generated [`PUBLIC_ENDPOINTS.md`](PUBLIC_ENDPOINTS.md) rather
than assuming a service is reachable from its internal port.

```env
# Discover this inside node container with `tailscale ip -4`; do not use the host IP.
TESTNET_TAILNET_BIND_ADDR=127.0.0.1
```

P2P (`9000`) stays public. Never set a bind override to `0.0.0.0`.

Do not use `docker-compose.lan.yml` or `expose-lan.sh` to publish node/backend
services for the tailnet launch. The LAN overlay is explorer-only; use SSH tunnels
for operator-only APIs and dashboards.

Full operator steps and the canonical tester endpoint list:
- `testnet/docs/TAILSCALE_TESTER_ENDPOINTS.md` — tester onboarding sheet
- `core4/docs/TESTNET_OPERATOR_GUIDE_v3.md` → "Tailscale reachability for testers" (canonical;
  maintained in core4)

### Per-service backend override (infra#546 / mobile#44)

For a short physical-device validation window targeting the backend ONLY, set
`WRFCOIN_BACKEND_BIND_ADDR` to a LAN/Tailscale address or `0.0.0.0`. It takes
effect only for port `4001`; it is not part of the June 17 tester tailnet launch.
Keep the operator window narrow and return the value to `127.0.0.1` or unset it
after validation.

---

## Healthcheck Architecture

Tracks infra#485. The testnet node uses a four-tier healthcheck model. Each tier is described
below with its current implementation state and any blocking dependencies.

### Tier 1 — Liveness (implemented ✓)

```yaml
# docker-compose.testnet.yml — wrfcoin-testnet-node
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:8556/health"]
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 120s
```

**Purpose:** Container is up and the HTTP server is responding.
**Signal:** `/health` returns `{"status":"ok"}`.
**Current state:** Deployed and passing on node host.
**No change needed.** This tier is intentionally simple — it proves the process is alive, not
that the chain is healthy.

### Tier 2 — Readiness monitoring (implemented ✓; not a Compose dependency gate)

```yaml
# docker-compose.override.yml — wrfcoin-node (local build override)
healthcheck:
  # #798: dependency health must be liveness-only. /readyz can report stale
  # while the downstream producer is needed to restore readiness.
  test:
    - CMD-SHELL
    - 'curl -sf --max-time 5 http://localhost:8556/health >/dev/null && printf "Authorization: Bearer %s\n" "$${WRFCOIN_READER_TOKEN}" | curl -sf --max-time 5 -H @- http://localhost:8556/metrics | grep -q wrfcoin_state_divergence_total'
  interval: 30s
  timeout: 10s
  retries: 3
  start_period: 120s
```

**Purpose:** Keep readiness visible without making a downstream block producer
depend on readiness it may be required to restore.
**Signal:** monitoring probes `/readyz`; the Compose dependency healthcheck
requires auth-free `/health` to return `200` and confirms that
`wrfcoin_state_divergence_total` is exported via authenticated `/metrics`.

**Current state:**
- `/readyz` gating on `NODE_SYNC_STALE_AFTER_SECS` is **implemented** (core4 PR #1131).
- **#798:** the effective Compose dependency gate uses `/health`, not `/readyz`.
  Readiness remains a monitoring signal because a stale chain can require the
  downstream producer to start before `/readyz` can recover.
- `wal-replay-healthcheck.sh` is retained for callers that want WAL-replay /
  divergence metric assertions; it preserves `/readyz`, fails on explicit replay
  failure (`wrfcoin_wal_replay_status=0`), warns while that metric is not
  exported, and (#561) now sends `WRFCOIN_READER_TOKEN` when fetching `/metrics`.
- core4#1620 exports `wrfcoin_state_divergence_total`; the Docker healthcheck
  verifies that the metric is exported, but it does not self-fence on a nonzero
  value. Runtime divergence is fenced operationally by the critical
  `StateDivergenceDetected` alert (`wrfcoin_state_divergence_total > 0`) and the
  `StateDivergenceActive` alert (`wrfcoin_chain_state_diverged == 1`) in
  `alert-rules-blockchain-health.yml`.
- `start_period: 120s` keeps the base grace period until the measured p99
  cold-replay time on node host is recorded. **Update `start_period` after the
  next planned N5 restart with WAL timing.**

**Action required after core4#1620:**
Set `WAL_REPLAY_METRIC_REQUIRED=true` for the node container once
`wrfcoin_wal_replay_status` is exported in production builds. At that point,
missing replay status should fail the healthcheck instead of warning.

### Tier 3 — Chain Liveness Probe (implemented ✓)

Not a Docker healthcheck (too slow for 30 s interval). A one-shot script gate for use in
`scripts/testnet-launch-readiness.sh` and CI.

`scripts/testnet-launch-readiness.sh` now attempts a real Tier 3 check:

- it requires `wrfcoin_chain_height` in `/metrics`;
- it persists the last seen height and fails when height does not increase
  across runs;
- missing metrics or missing `wrfcoin_chain_height` fail closed.

Use `WRFCOIN_LAST_HEIGHT_FILE` to override the persisted state file path (default:
`/tmp/wrfcoin_last_height`) for isolated test runs.

### Tier 4 — Divergence Gate (implemented ✓)

One-shot script gate in `scripts/testnet-launch-readiness.sh`, plus Docker
healthcheck enforcement through `wal-replay-healthcheck.sh`.

```bash
curl -sf http://localhost:8556/metrics |
  awk '$1 == "wrfcoin_state_divergence_total" { print $2; exit }'
```

Expected: `0`. Missing, non-numeric, or nonzero divergence values fail closed.

### Tier Summary

| Tier | Description | Docker gate? | Status |
|------|-------------|--------------|--------|
| 1 | HTTP liveness (`/health`) | Yes | ✓ Implemented |
| 2 | Readiness plus WAL replay and divergence status | Yes | ✓ Implemented for divergence; WAL metric remains optional until exported |
| 3 | Chain liveness probe | Script only | ✓ Implemented — fail-closed |
| 4 | Divergence gate | Yes + script | ✓ Implemented — fail-closed |

### Alert: NodeHealthcheckFailing

Added to `testnet/alert-rules.yml` (infra#485). Fires when cAdvisor stops seeing the
`wrfcoin-testnet-node` container — a proxy for the container exiting after repeated
healthcheck failures.

**Limitation:** `container_last_seen` going absent indicates the container has stopped, not
merely entered `unhealthy` state. A container stuck in `(unhealthy)` while still running will
NOT trigger this alert. True healthcheck-state monitoring requires Docker daemon metrics
(`--metrics-addr`) or a cAdvisor version that surfaces `container_health_status`. Verify
cAdvisor coverage gaps before relying on this alert — see infra#476.

### Dependency Map

```
infra#485 (this spec)
├── Tier 2 WAL gate    ← infra#478 ← core4#1620
├── Tier 3 chain probe ← core4#1620
├── Tier 4 divergence  ← core4#1620
└── NodeHealthcheckFailing alert ← infra#476 (cAdvisor coverage audit)
```
