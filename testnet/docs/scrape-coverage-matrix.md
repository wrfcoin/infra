# Testnet Scrape Coverage Matrix

This matrix closes the launch-review artifact for infra#476. It records what
Prometheus scrapes today, which services only have healthchecks, and where
coverage is intentionally deferred.

The scrape set is enforced by `scripts/tests/test-prometheus-scrape-config.sh`
(infra#1078, run by the Scripts Tests workflow): every job targets a compose
service on its real port, every app job has a known `/metrics` route, the
`ServiceDown` allowlist equals the job set, and `promtool check config` passes.

## Active Testnet Coverage

| Service | Prometheus job | Metrics scraped | Healthcheck defined | Scrape alert | Notes |
| --- | --- | --- | --- | --- | --- |
| `wrfcoin-node` | `wrfcoin-node` | Yes, `wrfcoin-node:8556/metrics` | Yes, API liveness / WAL replay / divergence override | Generic `ServiceDown`; chain-specific alerts in `alert-rules-blockchain-health.yml` | Tier 3 requires `wrfcoin_chain_height`; Tier 4 requires `wrfcoin_state_divergence_total=0`. |
| `wrfcoin-seed` | Commented `wrfcoin-seed` template | Optional only when `--profile seed` is active | Yes | None while inactive | Keep commented by default to avoid constant failed scrapes when the seed profile is off. Uncomment during seed-profile runs. |
| `wrfcoin-backend` | `wrfcoin-backend` | Yes, `wrfcoin-backend:4001/metrics` | Yes | Generic `ServiceDown`; backend-specific alerts in `alert-rules-backend-down.yml` | Uses the shared Prometheus bearer token. |
| `wrfcoin-governance` | `/metrics`: none (removed, infra#1078); `/health`: `wrfcoin-service-health` (blackbox) | No | Yes | `ServiceHealthProbeFailed` | `server/governance_server.js` has no `/metrics` route; the old job returned 404 and kept `ServiceDown` firing. Re-add the job only together with a real route. |
| `wrfcoin-iot` | `/metrics`: none (removed, infra#1078); `/health`: `wrfcoin-service-health` (blackbox) | No | Yes | `ServiceHealthProbeFailed` | `server/iot_sensor_networks_server.js` has no `/metrics` route (only the JSON `/api/iot/metrics`); same as governance. |
| `wrfcoin-weather-earnings` | `wrfcoin-weather-earnings` | Yes | Yes | Generic `ServiceDown` | `server/enhanced_weather_rewards.ts` (`dist/weather_earnings.cjs`) serves `/metrics`. |
| `wrfcoin-faucet` | `wrfcoin-faucet`; `/health`: `wrfcoin-service-health` (blackbox) | Yes, faucet `prom-client` registry | Yes | Liveness: `ServiceHealthProbeFailed` (critical). Scrape failure: `FaucetMetricsScrapeFailing` (warning, log-only), NOT `ServiceDown` | `testnet/services/faucet/server.js` exposes `/metrics` behind `FAUCET_METRICS_TOKEN`, which must equal `prometheus-bearer-token` (403 otherwise, infra#1078). Seed profile. |
| `wrfcoin-cross-chain` | None (full profile) | No | Yes | None | Omitted from the public-testnet scrape set while the `full` profile is inactive (see `prometheus.testnet.yml`). |
| `wrfcoin-compute` | None (full profile) | No | Yes | None | Omitted from the public-testnet scrape set while the `full` profile is inactive (see `prometheus.testnet.yml`). |
| `wrfcoin-ml` | None (full profile) | No | Yes | None | Omitted from the public-testnet scrape set while the `full` profile is inactive (see `prometheus.testnet.yml`). |
| `wrfcoin-storage` | None (full profile) | No | Yes | None | Omitted from the public-testnet scrape set while the `full` profile is inactive (see `prometheus.testnet.yml`). |
| `wrfcoin-node-discovery` | None (full profile) | No | Yes | None | Omitted while the `full` profile is inactive. If re-added, scrape the Docker-internal `wrfcoin-node-discovery:9001` (host port is `9005`). |
| `wrfcoin-explorer` | None | No | Yes | None | Audited source has `/health` but no `/metrics` endpoint in `testnet/explorer/server.js`; do not add a scrape job until prom-client support lands. |
| `prometheus` | None | No | Yes | None | Self-scrape is omitted: the web UI is behind basic auth (see `prometheus.testnet.yml`). |
| `loki` | `loki` | Yes | Yes | Generic `ServiceDown` | Internal metrics scrape. |
| `node-exporter` | `node-exporter` | Yes, `node-exporter:9100` | Yes | `NodeExporterScrapeDown` | Active testnet and comprehensive monitoring compose files pin `prom/node-exporter:v1.8.0`. |
| `cadvisor` | `cadvisor` | Yes, Docker-internal `cadvisor:8080` | Yes | `CAdvisorScrapeDown`, `CAdvisorContainerMetricsMissing` | Host bind is `127.0.0.1:8082:8080`, so the faucet host-port conflict from infra#421 does not affect the Prometheus Docker-network target. v0.60.6 + containerd socket since 2026-11-01: v0.49.1 exported no container names under Docker 29's containerd image store, so `ContainerRss*` were blind. |
| `postgres-exporter` | `postgres-exporter` | Yes | Yes | Generic `ServiceDown` | Provides `pg_up` / PostgreSQL exporter metrics. |
| `blackbox-exporter` | `wrfcoin-backend-health`, `wrfcoin-service-health` | Yes, probe metrics | Yes | Generic `ServiceDown` (exporter reachability); `BackendHealthBlackbox` / `ServiceHealthProbeFailed` on `probe_success == 0` | Probes backend, governance, iot and faucet `/health` (anonymous, 200). |

## Launch Notes

- `scripts/tests/test-testnet-scrape-coverage.sh` (run on CT102 by Scripts Tests) statically verifies the core
  infra#476 guardrails: discovery, cAdvisor, node_exporter scrape jobs, exporter
  scrape-down alerts, node_exporter version pin, and this matrix.
- infra#475 is unblocked by core4#1620: Tier 4 now requires
  `wrfcoin_state_divergence_total=0` in both the launch-readiness wrapper and
  the local-build Docker healthcheck path.
- If the seed profile is active for a launch rehearsal, uncomment the
  `wrfcoin-seed` job in `testnet/prometheus.testnet.yml` for that run and
  confirm `up{job="wrfcoin-seed"} == 1`.
