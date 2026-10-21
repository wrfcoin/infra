# WRFCoin Testnet k6 Load Tests

Issue: #122

## Install k6

```bash
# macOS
brew install k6

# Debian / Ubuntu
sudo gpg -k
sudo gpg --no-default-keyring \
     --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
     --keyserver hkp://keyserver.ubuntu.com:80 \
     --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] \
     https://dl.k6.io/deb stable main" \
     | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6

# Alpine / Docker
docker run --rm -i grafana/k6 version
```

## Prerequisites

1. Start the testnet:

   ```bash
   cd testnet
   docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml up -d
   ```

2. Confirm all services are healthy:

   ```bash
   ./testnet/check-health.sh
   ```

## Running the baseline test

```bash
# Syntax validation (no requests sent)
k6 run --dry-run scripts/load-test/baseline.js

# Smoke: 1 VU, 30 seconds (default)
k6 run --env BASE_URL=http://localhost:4001 scripts/load-test/baseline.js

# Soak: 10 VUs, 5-minute ramp
k6 run --env BASE_URL=http://localhost:4001 --env PHASE=soak scripts/load-test/baseline.js

# Stress: ramp from 10 → 100 VUs
k6 run --env BASE_URL=http://localhost:4001 --env PHASE=stress scripts/load-test/baseline.js
```

## Environment variables

| Variable            | Default                     | Description                               |
|---------------------|-----------------------------|-------------------------------------------|
| `BASE_URL`          | `http://localhost:4001`     | API gateway                               |
| `CROSSCHAIN_URL`    | `http://localhost:3000`     | Cross-chain service                       |
| `WALLET_URL`        | `http://localhost:4000`     | Wallet service                            |
| `COMPUTE_URL`       | `http://localhost:6000`     | Compute service                           |
| `WEATHER_URL`       | `http://localhost:8080`     | Weather service                           |
| `GOVERNANCE_URL`    | `http://localhost:8000`     | Governance service                        |
| `PHASE`             | `smoke`                     | `smoke`, `soak`, or `stress`              |
| `WEATHER_STATION_ID`| `TEST-STATION-001`          | Station ID used in weather POST payloads  |

## Endpoints tested

- `GET  /health` on each of 6 services (ports 4001, 3000, 4000, 6000, 8080, 8000)
- `GET  /api/v1/blocks/latest`
- `POST /api/v1/weather/observation` with a synthetic sensor payload

## Pass/fail thresholds

| Metric                    | Threshold        |
|---------------------------|------------------|
| Health check latency p95  | < 500 ms         |
| Blocks latest latency p95 | < 1 000 ms       |
| Weather POST latency p95  | < 2 000 ms       |
| Custom error rate         | < 1 %            |
| HTTP failure rate         | < 5 %            |

## CI integration

The self-hosted runner workflow (`ci-self-hosted.yml`) can run k6 directly on the N5 Pro against
a locally-started testnet. Add a step like:

```yaml
- name: k6 smoke test
  run: |
    k6 run --env BASE_URL=http://localhost:4001 \
           --env PHASE=smoke \
           scripts/load-test/baseline.js
```
