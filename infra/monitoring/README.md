# Wrfcoin Comprehensive Monitoring Infrastructure

This directory contains a complete monitoring solution for the Wrfcoin blockchain platform,
featuring real-time dashboards, distributed tracing, alerting, and observability tools.

## Local node operator dashboard
Run Prometheus in the node host network namespace; append this job to `scrape_configs` (localhost is otherwise the Prometheus container itself):
```yaml
  - job_name: wrfcoin-node
    metrics_path: /metrics
    static_configs: [{targets: ['localhost:8556']}]
    authorization: {type: Bearer, credentials_file: /etc/prometheus/node-reader-token}
```
Provision that file privately with a valid node Reader-role token; `/metrics` requires it. Never put the token in this repository or dashboard.
In Grafana, import [node-operator.json](grafana/dashboards/node-operator.json), select your Prometheus datasource and node; CPU/memory are unavailable, and block interval is a height-progress estimate (catch-up is not production).

## Overview

The monitoring infrastructure provides:

- **Real-time Metrics Collection** with Prometheus
- **Interactive Dashboards** with Grafana
- **Distributed Tracing** with Jaeger and Tempo
- **Intelligent Alerting** with AlertManager
- **Log Aggregation** with Loki
- **Infrastructure Monitoring** with Node Exporter and cAdvisor
- **Custom Metrics** for blockchain operations

## GFS Fetcher Health Checks (`infra#39`)

This directory includes a focused, CI/local-friendly GFS fetcher health-check package for the
`execution-engine` NOAA NOMADS dependency.

- Script: `gfs-fetch-health-check.sh`
- Focused compose stack: `docker-compose.gfs-fetcher-health.yml`
- Focused Prometheus config: `prometheus-gfs-fetcher.yml`
- Alert rules: `alert-rules-gfs-fetcher.yml`
- Runbook: `runbooks/gfs-fetcher-health-response.md`

The probe validates the fetch contract used by `core4/execution-engine/src/models/gfs_fetch.rs`:

- HTTP reachability
- response latency
- non-trivial payload size
- GRIB magic bytes at the start of the payload
- rejection of HTML/error payloads that would indicate an upstream format change

### Local / CI Dry-Run

Run the script directly in deterministic dry-run mode:

```bash
GFS_HEALTH_RUN_ONCE=1 ./gfs-fetch-health-check.sh
cat ./gfs_fetch_health.prom
```

To exercise a deterministic format regression:

```bash
GFS_HEALTH_RUN_ONCE=1 \
GFS_HEALTH_DRY_RUN_FIXTURE=./testdata/gfs-format-error.html.fixture \
./gfs-fetch-health-check.sh
```

### Focused Monitoring Stack

Start the minimal monitoring bundle for this check:

```bash
docker-compose -f docker-compose.gfs-fetcher-health.yml up -d --build
curl -s http://127.0.0.1:9100/metrics | grep '^gfs_fetch_health_'
```

This stack is intentionally narrow: Prometheus, Node Exporter textfile collector, and the GFS
health sidecar only.

### Optional Live NOAA Probe

Live probing is opt-in because CI/local validation should remain deterministic:

```bash
GFS_HEALTH_MODE=live \
GFS_HEALTH_RUN_ONCE=1 \
./gfs-fetch-health-check.sh
```

### Future Attachment Examples

This repo does not currently define an authoritative `execution-engine` deployment manifest. Use the
sidecar package below when a real Compose or Kubernetes deployment is introduced.

Compose example:

```yaml
services:
  execution-engine:
    image: ghcr.io/wrfcoin/execution-engine:latest

  gfs-fetch-health:
    build:
      context: infra/monitoring
      dockerfile: Dockerfile.gfs-fetch-healthcheck
    environment:
      - GFS_HEALTH_MODE=live
      - GFS_METRICS_OUTPUT_PATH=/var/lib/node_exporter/textfile_collector/gfs_fetch_health.prom
    volumes:
      - node-exporter-textfiles:/var/lib/node_exporter/textfile_collector
      - gfs-fetch-health-state:/var/lib/gfs-fetch-health
    depends_on:
      - execution-engine
```

Kubernetes sidecar example:

```yaml
containers:
  - name: execution-engine
    image: ghcr.io/wrfcoin/execution-engine:latest
  - name: gfs-fetch-health
    image: ghcr.io/wrfcoin/gfs-fetch-health:latest
    env:
      - name: GFS_HEALTH_MODE
        value: live
      - name: GFS_METRICS_OUTPUT_PATH
        value: /var/lib/node_exporter/textfile_collector/gfs_fetch_health.prom
    volumeMounts:
      - name: node-exporter-textfiles
        mountPath: /var/lib/node_exporter/textfile_collector
      - name: gfs-fetch-health-state
        mountPath: /var/lib/gfs-fetch-health
```

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Wrfcoin       │    │   Monitoring     │    │   Observability │
│   Blockchain    │───▶│   Collectors     │───▶│   Stack         │
│   Services      │    │                  │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
        │                       │                       │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   OpenTelemetry │    │   Prometheus     │    │   Grafana       │
│   Tracing       │    │   Metrics        │    │   Dashboards    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Jaeger/Tempo  │    │   AlertManager   │    │   Real-time     │
│   Trace Storage │    │   Notifications  │    │   Monitoring    │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

## Components

### Core Monitoring Stack

1. **Prometheus** (Port 9090)

   - Metrics collection and storage
   - 30-day retention with 50GB limit
   - Auto-discovery of targets

2. **Grafana** (Port 3000)

   - Real-time dashboards
   - Trace correlation
   - Alert visualization
   - Requires `GRAFANA_ADMIN_PASSWORD` env var to be set before starting

3. **Jaeger** (Port 16686)

   - Distributed tracing
   - Service dependency mapping
   - Performance analysis

4. **Tempo** (Port 3200)

   - Alternative tracing backend
   - Long-term trace storage
   - TraceQL query support

5. **AlertManager** (Port 9093)
   - Intelligent alert routing
   - Multi-channel notifications
   - Alert grouping and suppression

### Supporting Services

6. **OpenTelemetry Collector** (Ports 4317, 4318)

   - Trace collection and processing
   - Multi-backend export
   - Sampling and filtering

7. **Loki** (Port 3100)

   - Log aggregation
   - Trace-to-log correlation

8. **Node Exporter** (Port 9100)

   - System metrics collection
   - Hardware monitoring

9. **cAdvisor** (Port 8080)

   - Container metrics
   - Resource usage tracking

10. **Redis** (Port 6379)
    - Caching and session storage
    - Performance optimization

## Dashboard Categories

### Alignment Integrity Observability (`infra#2`)

- Dashboard: `dashboards/wrfcoin-alignment-integrity-observability.json`
- Alert rules: `alert-rules-alignment-integrity.yml`
- Runbook: `runbooks/alignment-integrity-incident-response.md`

This package tracks:

- abuse and sybil signal rates
- sanction parity and appeal overturn efficacy
- participation accessibility and geoblocking risk indicators
- soil/ocean/hydrology phase-2 forecast coverage integrity

Alert rules include explicit threshold annotations and direct `runbook_url` links.

### Sanctions Parity Fairness Observability (`infra#5`)

- Dashboard: `dashboards/wrfcoin-sanctions-parity-phase2.json`
- Alert rules: `alert-rules-sanctions-parity-phase2.yml`
- Runbook: `runbooks/sanctions-parity-drift-response.md`

This package tracks:

- sanction rate parity across actor classes (`human`, `ai`, `robot`)
- sanction rate parity across offense severity levels (`low`, `medium`, `high`)
- outcome mix parity for equivalent actor/severity cohorts
- parity remediation latency and telemetry completeness

Alert rules explicitly enforce equal-liability drift thresholds and include direct `runbook_url` anchors for incident handling.

### Real-Time Monitoring Dashboards

1. **Comprehensive Monitoring** (`wrfcoin-comprehensive-monitoring.json`)

   - System health overview
   - Real-time transaction flow
   - Distributed tracing integration
   - Service dependencies
   - 5-second refresh rate

2. **Performance Real-Time** (`wrfcoin-performance-realtime.json`)

   - Live transaction rate
   - Response time heatmaps
   - Error rates by operation
   - Resource pressure monitoring
   - 1-second refresh rate

3. **Tracing & Observability** (`wrfcoin-tracing-observability.json`)
   - Service map visualization
   - Trace volume analysis
   - Span performance metrics
   - Error trace correlation

### Specialized Monitoring Dashboards

4. **Security Monitoring** (`wrfcoin-security-monitoring.json`)

   - Threat level indicators
   - HSM status monitoring
   - Authentication events
   - Security incident tracking

5. **System Infrastructure** (`wrfcoin-system-infrastructure.json`)

   - Resource utilization
   - Hardware monitoring
   - Container metrics
   - System health checks

6. **Existing Dashboards** (Enhanced)
   - Blockchain Overview
   - Consensus Monitoring
   - Cross-Chain Bridge
   - Weather & IoT

## Quick Start

### 1. Environment Setup

```bash
# Copy environment template
cp .env.example .env

# Edit environment variables
vim .env
```

Required environment variables:

```bash
GRAFANA_ADMIN_PASSWORD=secure_password
REDIS_PASSWORD=redis_password
SMTP_FROM=alerts@wrfcoin.com
SMTP_USERNAME=your_smtp_user
SMTP_PASSWORD=your_smtp_password
SLACK_WEBHOOK_URL=https://hooks.slack.com/...
WEBHOOK_SECRET=webhook_secret
WEBHOOK_HMAC_SECRET=replace_with_long_random_secret
```

Alert webhook endpoints now require HMAC authentication headers:
- `X-WRF-Timestamp` (unix epoch seconds)
- `X-WRF-Signature` (`hex(hmac_sha256(secret, "<timestamp>.<raw_body>"))`)

### 2. Start Monitoring Stack

```bash
# Start complete monitoring infrastructure
docker-compose -f docker-compose.monitoring-complete.yml up -d

# Start tracing-only setup
docker-compose -f docker-compose.tracing.yml up -d

# Verify services
docker-compose ps
```

### 3. Access Dashboards

- **Grafana**: http://localhost:3000 (admin / password set via `GRAFANA_ADMIN_PASSWORD` env var)
- **Prometheus**: http://localhost:9090
- **Jaeger UI**: http://localhost:16686
- **AlertManager**: http://localhost:9093

### 4. Integrate with Wrfcoin

Add to your Wrfcoin service:

```rust
use wrfcoin_monitoring::{MonitoringSystem, TracingInstrumentation};

// Initialize monitoring
let monitoring = MonitoringSystem::builder()
    .with_prometheus_endpoint("http://localhost:9090")
    .with_tracing_enabled(true)
    .with_jaeger_endpoint("http://localhost:14268/api/traces")
    .build()
    .await?;

// Start monitoring
monitoring.start().await?;
```

## Configuration

### Prometheus Configuration

Edit `prometheus.yml` to add new scrape targets:

```yaml
scrape_configs:
  - job_name: 'wrfcoin-node'
    static_configs:
      - targets: ['blockchain-node:8080']
    scrape_interval: 15s
    metrics_path: /metrics
```

### Alert Rules

Custom alert rules in `alerts/` directory:

- `blockchain-alerts.yml` - Core blockchain monitoring
- `consensus-alerts.yml` - Consensus mechanism alerts
- `security-alerts.yml` - Security and threat detection
- `performance-alerts.yml` - Performance and resource alerts

### Grafana Datasources

Automatically provisioned:

- Prometheus (metrics)
- Jaeger (tracing)
- Tempo (alternative tracing)
- Loki (logs)
- AlertManager (alerts)

## Advanced Features

### Trace Correlation

Dashboards support automatic correlation between:

- **Metrics ↔ Traces**: Click metric spike to see related traces
- **Traces ↔ Logs**: Jump from trace spans to relevant logs
- **Alerts ↔ Traces**: Alert notifications include trace queries

### Custom Metrics

Add blockchain-specific metrics:

```rust
// Custom metrics in your Rust code
use wrfcoin_monitoring::metrics::*;

// Counter for consensus rounds
let consensus_rounds = CONSENSUS_ROUNDS_TOTAL
    .with_label_values(&["completed"])
    .inc();

// Histogram for transaction processing time
let processing_time = TRANSACTION_PROCESSING_DURATION
    .observe(duration.as_secs_f64());
```

### Real-Time Alerting

Configure Slack notifications in `alertmanager-enhanced.yml`:

```yaml
receivers:
  - name: 'critical-alerts'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK'
        channel: '#blockchain-alerts'
        title: 'Critical: {{ .GroupLabels.alertname }}'
```

## Monitoring Categories

### 1. Blockchain Core Metrics

- Block height and production rate
- Transaction throughput (TPS)
- Mempool size and processing time
- Consensus performance
- Validator participation

### 2. Cross-Chain Operations

- Bridge transfer rates
- HTLC contract status
- Multi-signature validation
- Liquidity monitoring
- Cross-chain latency

### 3. Security Monitoring

- Authentication attempts and failures
- HSM operation status
- Threat detection events
- Access control violations
- Certificate expiry tracking

### 4. Infrastructure Health

- CPU, memory, disk usage
- Network throughput and latency
- Container resource utilization
- Service availability
- Hardware temperature and power

### 5. Weather & IoT Data

- Sensor data quality
- Device connectivity status
- Environmental measurements
- Data validation results
- Network coverage

## Troubleshooting

### Common Issues

1. **Grafana won't start**

   ```bash
   # Check permissions
   sudo chown -R 472:472 grafana_data/

   # Check logs
   docker logs wrfcoin-grafana
   ```

2. **Prometheus data not appearing**

   ```bash
   # Verify targets
   curl http://localhost:9090/api/v1/targets

   # Check configuration
   docker exec wrfcoin-prometheus promtool check config /etc/prometheus/prometheus.yml
   ```

3. **Traces not appearing in Jaeger**

   ```bash
   # Verify collector connectivity
   curl http://localhost:14268/api/traces

   # Check sampling configuration
   docker logs wrfcoin-otel-collector
   ```

### Performance Tuning

1. **Prometheus Storage**

   - Adjust retention time: `--storage.tsdb.retention.time=30d`
   - Modify retention size: `--storage.tsdb.retention.size=50GB`

2. **Grafana Performance**

   - Limit dashboard refresh rates
   - Use query result caching
   - Optimize complex queries

3. **Tracing Sampling**
   - Adjust sampling rates in `otel-collector-config.yaml`
   - Configure adaptive sampling
   - Monitor trace volume

## Security Considerations

1. **Access Control**

   - Set `GRAFANA_ADMIN_PASSWORD` env var (required; containers will refuse to start without it)
   - Enable HTTPS in production
   - Implement proper authentication

2. **Network Security**

   - Use internal networks
   - Configure firewalls
   - Enable monitoring encryption

3. **Data Protection**
   - Regular backup of metrics data
   - Secure alert channels
   - Monitor access logs

## Maintenance

### Regular Tasks

1. **Update Components**

   ```bash
   # Pull latest images
   docker-compose pull

   # Restart with new images
   docker-compose up -d
   ```

2. **Backup Data**

   ```bash
   # Backup Prometheus data
   docker run --rm -v monitoring_prometheus_data:/data -v $(pwd):/backup alpine tar czf /backup/prometheus-backup.tar.gz -C /data .

   # Backup Grafana data
   docker run --rm -v monitoring_grafana_data:/data -v $(pwd):/backup alpine tar czf /backup/grafana-backup.tar.gz -C /data .
   ```

3. **Clean Up**

   ```bash
   # Remove old containers
   docker system prune -f

   # Clean unused volumes
   docker volume prune -f
   ```

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review component logs: `docker logs <container_name>`
3. Consult official documentation for each component
4. Open issues in the Wrfcoin repository

## License

This monitoring configuration is part of the Wrfcoin project and follows the same licensing terms.
