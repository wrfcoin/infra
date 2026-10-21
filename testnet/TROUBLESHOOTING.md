# WRFCoin Testnet Troubleshooting Guide

Use this guide when the testnet stack is unhealthy and you need fast operator-safe
diagnostics before deciding whether to restart, restore, or escalate.

Start here if you have not already:

- [`core4/docs/TESTNET_OPERATOR_GUIDE_v3.md`](https://github.com/wrfcoin/core4/blob/main/docs/TESTNET_OPERATOR_GUIDE_v3.md) (canonical)
- Your operator-approved upgrade and rollback procedure (site-specific; supplied separately)
- [RESTORE_DRILL.md](RESTORE_DRILL.md)

This document focuses on the current `testnet/docker-compose.testnet.yml` stack and
uses the compose service names that exist there today.

## Quick Triage

Run these first to understand whether you have a startup problem, a dependency
problem, a P2P problem, or a monitoring-only problem:

```bash
cd ~/wrfcoin/infra/testnet

docker compose ps
docker compose logs --tail=50 wrfcoin-node
docker compose logs --tail=50 wrfcoin-backend
curl -sf http://localhost:8556/readyz | jq .
curl -sf http://localhost:8556/network/info | jq .
curl -sf http://localhost:4001/health | jq .
curl -sf http://localhost:9090/-/ready && echo "PROMETHEUS OK"
curl -sf http://localhost:3100/api/health && echo "GRAFANA OK"
curl -sf http://localhost:9093/-/healthy && echo "ALERTMANAGER OK"
```

If a command fails, do not guess. Use the symptom table below, then go to the
matching section.

## Symptom Map

| Symptom | Likely area | Go to |
|---------|-------------|-------|
| `docker compose ps` shows `Exit` or `Restarting` | container crash or dependency failure | [Container Failures](#container-failures) |
| `readyz` fails on `8556` | node startup or dependency issue | [Node API Not Ready](#node-api-not-ready) |
| Node API works but peer count stays at `0` | P2P reachability or bootstrap config | [No Peers or Unreachable Port 9000](#no-peers-or-unreachable-port-9000) |
| Peers exist but block height does not move | chain stall or consensus/network issue | [Peers Present but No New Blocks](#peers-present-but-no-new-blocks) |
| Backend returns unhealthy or refuses connection on `4001` | backend, migration, PostgreSQL, or Redis | [Backend or Microservice Failures](#backend-or-microservice-failures) |
| `db-migrate` failed | schema migration or database issue | [Database, Redis, and Migration Problems](#database-redis-and-migration-problems) |
| Prometheus, Grafana, or Alertmanager are down | monitoring stack issue | [Monitoring Stack Failures](#monitoring-stack-failures) |
| Host memory pressure alerts fire | sustained memory exhaustion risk | [Memory Pressure](#memory-pressure) |
| Host disk alerts fire or containers fail writing data | storage exhaustion | [Disk Pressure](#disk-pressure) |
| You are in the middle of an upgrade and things drifted | rollback/recovery decision point | [When to Roll Back or Restore](#when-to-roll-back-or-restore) |

## Service and Port Reference

These are the main service names and localhost ports used in the current testnet stack:

| Service | Compose name | Local check |
|---------|--------------|-------------|
| Node | `wrfcoin-node` | `http://localhost:8556/readyz` |
| Backend | `wrfcoin-backend` | `http://localhost:4001/health` |
| Governance | `wrfcoin-governance` | `http://localhost:8000/health` |
| IoT | `wrfcoin-iot` | `http://localhost:3002/health` |
| Weather earnings | `wrfcoin-weather-earnings` | `http://localhost:8001/health` |
| Frontend | `wrfcoin-frontend` | `http://localhost:5000/health` |
| Prometheus | `prometheus` | `http://localhost:9090/-/ready` |
| Grafana | `grafana` | `http://localhost:3100/api/health` |
| Alertmanager | `alertmanager` | `http://localhost:9093/-/healthy` |
| P2P listener | `wrfcoin-node` | TCP `9000` must be reachable from the internet |

Infrastructure dependencies with no host port binding:

- `postgres`
- `redis`
- `db-migrate`

## Container Failures

If one or more services are `Exit`, `Restarting`, or unhealthy:

```bash
docker compose ps
docker compose logs --tail=100 postgres redis db-migrate wrfcoin-node wrfcoin-backend
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep wrfcoin-testnet
```

What to look for:

- `postgres` unhealthy: downstream services will not start cleanly.
- `redis` unhealthy: backend services may fail health checks even if the node is up.
- `db-migrate` exited non-zero: backend services are blocked by migration completion.
- `wrfcoin-node` unhealthy: backend and dependent services can remain down.
- only monitoring services failing: the chain may still be healthy; treat as observability loss first.

Safe next actions:

```bash
docker compose restart postgres redis
docker compose restart wrfcoin-node
docker compose restart wrfcoin-backend wrfcoin-governance wrfcoin-iot wrfcoin-weather-earnings
docker compose restart prometheus grafana alertmanager node-exporter
```

Do not repeatedly restart everything without reading logs first. Restart loops can hide
the real failure and make recovery harder.

## Node API Not Ready

If `curl -sf http://localhost:8556/readyz` fails or never returns healthy:

```bash
docker compose logs --tail=150 wrfcoin-node
docker compose ps wrfcoin-node postgres redis
curl -s http://localhost:8556/health || true
curl -s http://localhost:8556/blockchain | jq . || true
```

Common causes:

- `postgres` or `redis` is not healthy yet
- corrupted or incomplete node data
- missing or invalid environment values in `.env`
- the node is still in its startup window after container recreation

Differentiate the failure:

- `readyz` down and `postgres` or `redis` unhealthy: fix dependencies first.
- `readyz` down and node logs show connection errors: check database or Redis credentials.
- `readyz` down but `health` responds: the API process is alive but not ready for traffic yet.
- `readyz` healthy but `network/info` shows no peers: move to [No Peers or Unreachable Port 9000](#no-peers-or-unreachable-port-9000).

If the node data itself looks suspect after a crash, stop here and review
[RESTORE_DRILL.md](RESTORE_DRILL.md) before trying destructive recovery.

## No Peers or Unreachable Port 9000

If the node API is up but peer count stays at `0`:

```bash
curl -s http://localhost:8556/network/info | jq .
docker compose logs --tail=100 wrfcoin-node | grep -Ei 'peer|bootstrap|gossip|p2p'
grep '^BOOTSTRAP_PEERS=' .env
ss -ltn '( sport = :9000 )'
```

What to verify:

- `BOOTSTRAP_PEERS` is populated and not malformed.
- your firewall or router forwards TCP `9000` to this host.
- the host is actually listening on `0.0.0.0:9000`.
- you are not mixing seed-node addresses and local API ports.

Interpretation:

- `peer_count = 0` and no bootstrap peers configured: expected isolation.
- `peer_count = 0` with valid bootstrap peers and port `9000` closed externally: network/firewall issue.
- peers connect briefly then disappear: unstable network path or incompatible peer configuration.
- peers exist but the chain does not advance: go to [Peers Present but No New Blocks](#peers-present-but-no-new-blocks).

Operator-safe remediation:

- correct `BOOTSTRAP_PEERS` in `.env`
- fix firewall or NAT forwarding for TCP `9000`
- restart only the node after config changes:

```bash
docker compose restart wrfcoin-node
```

## Peers Present but No New Blocks

If `curl -s http://localhost:8556/network/info | jq '.connected_peers'` shows peers but
block height is flat:

```bash
curl -s http://localhost:8556/blockchain | jq '{height: .height}'
sleep 30
curl -s http://localhost:8556/blockchain | jq '{height: .height}'
docker compose logs --tail=150 wrfcoin-node
```

Also check whether alerts like `ChainStalled`, `NoPeers`, `BlockProductionStalled`,
`ChainForkDetected`, `ChainReorgDetected`, `FinalityLag`, or `FinalityStalled` are firing in
Prometheus or Alertmanager.

Use these rules of thumb:

- no peers and no new blocks: treat as P2P isolation first
- peers present and no new blocks: treat as chain stall or consensus issue
- backend healthy but chain stalled: this is not just an API outage

Safe actions:

```bash
docker compose restart wrfcoin-node
curl -s http://localhost:8556/network/info | jq .
curl -s http://localhost:8556/blockchain | jq .
```

If the node does not resume block production after a single clean restart, stop making
changes locally and contact the WRFCoin team. Repeated node restarts can make incident
analysis harder when the network itself is unhealthy.

## Backend or Microservice Failures

If `wrfcoin-backend` is unhealthy, returns errors on `4001`, or dependent services fail:

```bash
curl -s http://localhost:4001/health | jq . || true
docker compose ps wrfcoin-backend wrfcoin-governance wrfcoin-iot wrfcoin-weather-earnings
docker compose logs --tail=100 wrfcoin-backend wrfcoin-governance wrfcoin-iot wrfcoin-weather-earnings
```

Interpret the pattern:

- only `wrfcoin-backend` unhealthy: check its logs and the node API first
- all microservices unhealthy together: suspect `postgres`, `redis`, `db-migrate`, or `wrfcoin-node`
- backend healthy but frontend unhealthy: inspect `wrfcoin-frontend` separately

Dependency checks:

```bash
curl -sf http://localhost:8556/readyz | jq .
docker compose ps postgres redis db-migrate
docker compose logs --tail=100 db-migrate
```

Safe restart flow:

```bash
docker compose restart wrfcoin-backend wrfcoin-governance wrfcoin-iot wrfcoin-weather-earnings
docker compose restart wrfcoin-frontend
```

If the backend health payload shows database or Redis failures, move to
[Database, Redis, and Migration Problems](#database-redis-and-migration-problems).

## Database, Redis, and Migration Problems

Check the dependency layer directly:

```bash
docker compose ps postgres redis db-migrate
docker compose logs --tail=100 postgres
docker compose logs --tail=100 redis
docker compose logs --tail=100 db-migrate
docker compose exec -T postgres pg_isready -U wrfcoin -d wrfcoin
docker compose exec -T redis sh -lc 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --no-auth-warning ping'
```

Common cases:

- `POSTGRES_PASSWORD must be set` or `REDIS_PASSWORD must be set`: `.env` is missing or incomplete
- `db-migrate` failed once: backend services will wait on `service_completed_successfully`
- PostgreSQL starts but the app cannot connect: verify credentials and database URL
- Redis starts but auth fails: verify `REDIS_PASSWORD` consistency

If `.env` or secrets were lost or corrupted, restore them from a known-good backup or rerun
`setup-env.sh` only if you understand the credential impact. Secret rotation during an outage
can create a larger incident than the original failure.

For data recovery or re-import:

- use [RESTORE_DRILL.md](RESTORE_DRILL.md) for restore procedure
- obtain the operator-approved schema-change rollback procedure before changing schema

Do not drop databases, wipe volumes, or reinitialize Redis as a first response unless you are
already executing a planned restore.

## Monitoring Stack Failures

Monitoring issues should be diagnosed separately from chain health. The node may still be fine
even if Grafana or Prometheus is down.

Start with:

```bash
docker compose ps prometheus grafana alertmanager node-exporter
docker compose logs --tail=100 prometheus grafana alertmanager node-exporter
curl -sf http://localhost:9090/-/ready && echo "PROMETHEUS OK"
curl -sf http://localhost:3100/api/health && echo "GRAFANA OK"
curl -sf http://localhost:9093/-/healthy && echo "ALERTMANAGER OK"
curl -sf http://localhost:9100/metrics >/dev/null && echo "NODE-EXPORTER OK"
```

Typical failures:

- Prometheus exits immediately: confirm `prometheus-web.yml` and `prometheus-bearer-token` exist
  and are readable by the non-root `prom/prometheus` user. The image runs as uid/gid `65534`;
  files generated as `0600 root:root` will produce `open /etc/prometheus/web.yml: permission denied`.
- Prometheus runs but Docker reports `unhealthy`: if web auth is enabled, unauthenticated probes
  to `/-/healthy` return `401 Unauthorized`; use authenticated `curl` for readiness checks.
- Grafana unhealthy: confirm Prometheus is healthy first
- Alertmanager unhealthy: inspect `alertmanager.yml` and recent logs
- dashboards show no data but Prometheus is up: check scrape targets and alert rules

If your environment also includes the optional logging stack from `infra#118` or later, verify it
separately:

```bash
docker compose ps loki promtail
docker compose logs --tail=100 loki promtail
curl -sf http://localhost:3100/api/health && echo "GRAFANA OK"
```

If Loki or Promtail is absent from `docker compose ps`, that logging slice is not deployed on
this branch or host yet, and its absence is not the root cause of a base testnet outage.

## Memory Pressure

If you see `HostMemoryPressureWarning`, `HostMemoryPressureCritical`,
`ContainerRssNearLimitWarning`, or `ContainerRssNearLimitCritical`, treat this as sustained
resource pressure that can degrade block production and backend reliability.

Thresholds on the N5 Pro host:

- `HostMemoryPressureWarning`: memory usage > 85% for 10 minutes
- `HostMemoryPressureCritical`: memory usage > 92% for 15 minutes
- `ContainerRssNearLimitWarning`: per-container RSS > 80% of memory limit for 10 minutes
- `ContainerRssNearLimitCritical`: per-container RSS > 92% of memory limit for 15 minutes

Check host and container memory pressure:

```bash
free -h
docker stats --no-stream
docker compose logs --tail=100 wrfcoin-node wrfcoin-backend postgres redis
```

What to do:

- stop or scale down non-essential workloads on the host
- confirm `postgres`, `redis`, and `wrfcoin-node` stay healthy after pressure drops
- if critical memory pressure persists, reduce testnet concurrency until stable

## Disk Pressure

If you see `RootDiskPressureWarning`, `RootDiskPressureCritical`, `ZfsTankAlmostFull`, `ZfsBlockchainAlmostFull`, or
`ZfsPostgresAlmostFull` alerts, treat this as an operational risk even if services still look
healthy.

Thresholds on the host root filesystem (`/`):

- `RootDiskPressureWarning`: disk usage > 80% for 10 minutes
- `RootDiskPressureCritical`: disk usage > 90% for 15 minutes

Check usage:

```bash
df -h
docker system df
docker compose logs --tail=100 postgres wrfcoin-node
```

On the reference node, also inspect the ZFS datasets called out by the alerts:

```bash
zfs list -o name,used,avail,mountpoint tank tank/postgres tank/redis tank/blockchain
```

What to do:

- free obvious non-essential space first
- confirm backups exist before any cleanup that touches durable data
- avoid deleting PostgreSQL, Redis, or blockchain volumes as a quick fix

If disk pressure is severe and the node is already failing writes, prepare for a controlled
restore path using [RESTORE_DRILL.md](RESTORE_DRILL.md).

## When to Roll Back or Restore

Use a restart only for transient failures. Use rollback or restore when the system state itself
is wrong.

Obtain and follow the operator-approved upgrade and rollback procedure when:

- the incident started during or immediately after an upgrade
- image, compose, or schema changes were just applied
- you need the supported stop/start order or rollback sequence

Use [RESTORE_DRILL.md](RESTORE_DRILL.md) when:

- durable data looks corrupted or incomplete
- node state does not recover after dependency health is restored
- PostgreSQL or Redis data must be restored from backup

Do not improvise a new rollback procedure during an incident. Follow one runbook.

## Escalation

Operators can usually self-remediate:

- missing or malformed `BOOTSTRAP_PEERS`
- closed TCP `9000`
- unhealthy but recoverable monitoring services
- a single service restart after reading logs

Stop and contact the WRFCoin team when:

- peers are present but the chain still does not advance
- fork, reorg, or finality alerts are firing
- you are considering destructive data repair
- restore or rollback is required and you do not have a current backup
- repeated restarts change symptoms without restoring service

When escalating, include:

```bash
docker compose ps
docker compose logs --tail=150 wrfcoin-node wrfcoin-backend postgres redis
curl -s http://localhost:8556/readyz || true
curl -s http://localhost:8556/network/info || true
curl -s http://localhost:8556/blockchain || true
curl -s http://localhost:4001/health || true
```

That snapshot is usually enough to separate local operator error from a wider network or
release problem.
