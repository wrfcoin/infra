# Backend Services Operations Runbook

## Architecture Overview

```
                         ┌─────────────────┐
                         │    Ingress /     │
                         │  Load Balancer   │
                         └────────┬────────┘
                                  │
          ┌───────────┬───────────┼───────────┬───────────┐
          │           │           │           │           │
    ┌─────▼─────┐ ┌───▼───┐ ┌────▼────┐ ┌────▼────┐ ┌───▼────┐
    │  API      │ │ Cross-│ │ Wallet  │ │ Weather │ │ Gov    │
    │  Gateway  │ │ Chain │ │ Service │ │ IoT     │ │ Service│
    │  :4001    │ │ :3000 │ │ :4000   │ │ :8080   │ │ :8000  │
    └─────┬─────┘ └───┬───┘ └────┬────┘ └────┬────┘ └───┬────┘
          │           │          │            │          │
    ┌─────▼───────────▼──────────▼────────────▼──────────▼─────┐
    │                     PostgreSQL :5432                       │
    │                     Redis      :6379                       │
    └──────────────────────────────────────────────────────────┘
```

### Service Ports

| Service | Port | Purpose |
|---------|------|---------|
| API Gateway | 4001 | Primary REST API |
| Cross-Chain Bridge | 3000 | Cross-chain transfer coordination |
| Wallet Service | 4000 | Wallet management, signing |
| Compute Service | 6000 | Weather compute orchestration |
| AI/ML Service | 6001 | Inference and model management |
| Storage Router | 7000 | Multi-provider storage dispatch |
| IoT Collector | 3002 | Weather station data ingestion |
| Weather Service | 8080 | Weather data queries |
| Governance Service | 8000 | DAO proposals, voting |

### Namespace & Deployment

Services run in the `default` Kubernetes namespace (or `backend` if namespace isolation is enabled).

```bash
kubectl get deployments -l tier=backend
kubectl get pods -l tier=backend
```

---

## Health Checks

### Quick Health (all services)

```bash
# Check all backend service health endpoints
for port in 4001 3000 4000 6000 6001 7000 3002 8080 8000; do
  status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:$port/health 2>/dev/null)
  echo "Port $port: $status"
done
```

### Database Health

```bash
# PostgreSQL connection test
psql "$DATABASE_URL" -c "SELECT 1;" 2>&1

# Check active connections
psql "$DATABASE_URL" -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active';"

# Check database size
psql "$DATABASE_URL" -c "SELECT pg_size_pretty(pg_database_size(current_database()));"
```

### Redis Health

```bash
# Redis ping
redis-cli -u "$REDIS_URL" ping

# Check connected clients
redis-cli -u "$REDIS_URL" info clients | grep connected_clients

# Check memory usage
redis-cli -u "$REDIS_URL" info memory | grep used_memory_human
```

---

## Common Operations

### Restart a Service

```bash
# Restart a specific deployment
kubectl rollout restart deployment/<service-name>

# Check rollout status
kubectl rollout status deployment/<service-name>
```

### Scale a Service

```bash
# Scale up (e.g., API gateway under load)
kubectl scale deployment/api-gateway --replicas=5

# Scale down
kubectl scale deployment/api-gateway --replicas=2
```

### View Logs

```bash
# Service logs
kubectl logs -l app=<service-name> --tail=200

# Follow logs
kubectl logs -f -l app=<service-name>

# All backend services (last 5 min)
kubectl logs -l tier=backend --since=5m --tail=100
```

### Database Migrations

```bash
# Check migration status
cd backend && npx drizzle-kit status

# Run pending migrations
cd backend && npx drizzle-kit push

# Generate migration from schema changes
cd backend && npx drizzle-kit generate
```

**Warning:** Always back up the database before running migrations in production:
```bash
pg_dump "$DATABASE_URL" > backup-$(date +%Y%m%d-%H%M%S).sql
```

### Environment Variables

Critical environment variables (stored as Kubernetes secrets):

```bash
# View secret names
kubectl get secrets -l tier=backend

# Decode a specific secret value
kubectl get secret backend-secrets -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

### Rotate Secrets

1. Generate new credentials.
2. Update Kubernetes secrets:
   ```bash
   kubectl create secret generic backend-secrets \
     --from-literal=DATABASE_URL="<new_url>" \
     --from-literal=REDIS_URL="<new_url>" \
     --from-literal=JWT_SECRET="<new_secret>" \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Restart affected services:
   ```bash
   kubectl rollout restart deployment -l tier=backend
   ```

---

## Incident Response

### Service Unhealthy (BackendServiceDown alert)

**Severity:** Critical

1. Identify which service is down:
   ```bash
   kubectl get pods -l tier=backend | grep -v Running
   ```

2. Check pod events:
   ```bash
   kubectl describe pod <pod-name> | tail -20
   ```

3. Check for OOM kills:
   ```bash
   kubectl get events --field-selector reason=OOMKilled --sort-by=.lastTimestamp
   ```

4. Check logs for the crash:
   ```bash
   kubectl logs <pod-name> --previous --tail=100
   ```

5. If OOM: increase memory limits in the deployment spec.
6. If crash loop: check for missing env vars or failed dependency connections.

### Database Connection Pool Exhausted (DatabasePoolExhausted alert)

**Severity:** Critical

1. Check active connections:
   ```bash
   psql "$DATABASE_URL" -c "
     SELECT application_name, state, count(*)
     FROM pg_stat_activity
     GROUP BY application_name, state
     ORDER BY count DESC;
   "
   ```

2. Kill idle-in-transaction connections (> 5 minutes):
   ```bash
   psql "$DATABASE_URL" -c "
     SELECT pg_terminate_backend(pid)
     FROM pg_stat_activity
     WHERE state = 'idle in transaction'
       AND state_change < now() - interval '5 minutes';
   "
   ```

3. If the pool is still exhausted, restart the affected service to release all connections.

4. Long-term fix: tune `max_connections` in PostgreSQL and pool size in Drizzle ORM config.

### High Latency (BackendLatencyHigh alert)

**Severity:** Warning

1. Check which endpoint is slow:
   ```bash
   # Check Prometheus for slow endpoints
   curl -s http://prometheus:9090/api/v1/query?query=http_request_duration_seconds_bucket | jq .
   ```

2. Check database query performance:
   ```bash
   psql "$DATABASE_URL" -c "
     SELECT query, calls, mean_exec_time, total_exec_time
     FROM pg_stat_statements
     ORDER BY mean_exec_time DESC
     LIMIT 10;
   "
   ```

3. Check Redis latency:
   ```bash
   redis-cli -u "$REDIS_URL" --latency
   ```

4. If a specific query is slow, check for missing indexes.
5. If overall latency is high, check pod resource usage and consider scaling.

### Redis Down (RedisConnectionFailed alert)

**Severity:** Critical — affects caching, sessions, and pub/sub.

1. Check Redis pod:
   ```bash
   kubectl get pods -l app=redis
   kubectl logs -l app=redis --tail=100
   ```

2. Check if Redis is accepting connections:
   ```bash
   kubectl exec -it <redis-pod> -- redis-cli ping
   ```

3. If Redis is out of memory:
   ```bash
   kubectl exec -it <redis-pod> -- redis-cli info memory
   # Flush non-critical caches if needed
   kubectl exec -it <redis-pod> -- redis-cli FLUSHDB
   ```

4. Restart Redis if unresponsive:
   ```bash
   kubectl delete pod <redis-pod>
   ```

Services should reconnect automatically. If they don't, restart them.

---

## Backup & Disaster Recovery

### Recovery Objectives

| Metric | Target |
|--------|--------|
| **RTO** | < 1 hour |
| **RPO** | < 15 minutes (WAL archiving) |

### PostgreSQL Backup

Automated daily backups via CronJob:

```bash
# Check backup job status
kubectl get cronjob pg-backup
kubectl get jobs -l app=pg-backup --sort-by=.status.startTime | tail -5

# Manual backup
pg_dump "$DATABASE_URL" --format=custom > backup-$(date +%Y%m%d-%H%M%S).dump

# Restore from backup
pg_restore -d "$DATABASE_URL" --clean backup-YYYYMMDD-HHMMSS.dump
```

### Redis Backup

Redis is used for caching and ephemeral state. On restart, caches warm from the database. No persistent backup required unless using Redis for durable pub/sub queues.

---

## Monitoring

| Resource | Location |
|----------|----------|
| Grafana dashboard | "WRFCoin Backend Services" (uid: `wrfcoin-backend`) |
| Alert rules | `infra/monitoring/alerts/backend.yml` |
| Prometheus scrape | Auto-discovered via pod annotations |

### Key Metrics

- `http_requests_total` — Request count by service, method, status
- `http_request_duration_seconds` — Request latency histogram
- `db_pool_active_connections` — Active database connections
- `db_pool_idle_connections` — Idle database connections
- `redis_connected_clients` — Redis client count
- `redis_memory_used_bytes` — Redis memory usage
- `process_resident_memory_bytes` — Per-service memory usage
- `nodejs_eventloop_lag_seconds` — Event loop lag (Node.js services)
