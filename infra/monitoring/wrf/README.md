# WRF Useful Work Observability

This bundle provides a reproducible Prometheus/Grafana setup for infra#37.
It is intentionally self-contained so it does not depend on the legacy
monitoring tree under `infra/monitoring/`.

## Files

- `docker-compose.yml`: isolated Prometheus + Grafana stack
- `prometheus.yml`: WRF-specific scrape config
- `grafana/datasources.yml`: Prometheus datasource provisioning
- `grafana/dashboards.yml`: dashboard provider provisioning
- `grafana/dashboards/`: WRF dashboards
- `verify-wrf-observability.py`: deterministic verification

## Runtime assumptions

- The Node.js compute agent exposes `GET /metrics` on `127.0.0.1:3333`
- The Rust execution engine exposes `GET /metrics` on `127.0.0.1:9100`
- The Compose stack reaches host services through `host.docker.internal`

Prometheus scrape jobs:

- `wrf-compute-agent` -> `host.docker.internal:3333/metrics`
- `wrf-execution-engine` -> `host.docker.internal:9100/metrics`

The dashboards expect these execution-engine metric names:

- `wrf_execution_active_runs`
- `wrf_execution_runs_total{status=...}`
- `wrf_execution_run_duration_seconds_bucket`
- `wrf_execution_input_bytes_total`
- `wrf_execution_output_bytes_total`
- `wrf_execution_last_forecast_horizon_hours`

## Bring-up

```bash
cd <repo-root>/worktrees/lane4-infra-37-wrf-dashboards/infra/monitoring/wrf
docker-compose config
GRAFANA_ADMIN_PASSWORD=wrf-observability docker-compose up -d
```

Grafana is exposed at `http://127.0.0.1:3006` and Prometheus at
`http://127.0.0.1:9096`.

## Verification

Deterministic verification:

```bash
cd <repo-root>/worktrees/lane4-infra-37-wrf-dashboards/infra/monitoring/wrf
python3 verify-wrf-observability.py
docker-compose config
```

Compute-agent metrics verification:

```bash
cd <repo-root>/worktrees/lane4-infra-37-wrf-dashboards/infra/compute-agent
npm run build
node --test dist/*.test.js
```

If the Rust execution engine is not running yet, the execution-engine dashboard
loads with empty panels instead of configuration errors.
