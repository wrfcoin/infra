# Storage Providers Runtime Runbook

## Architecture Overview

WRFCoin uses a multi-provider storage architecture for weather data persistence:

```
                        ┌─────────────────────┐
                        │  Storage Router     │
                        │  (backend service)  │
                        └──┬───────┬────────┬─┘
                           │       │        │
               ┌───────────┘       │        └───────────┐
               ▼                   ▼                    ▼
        ┌──────────┐       ┌──────────────┐      ┌───────────┐
        │   IPFS   │       │   Filecoin   │      │  Arweave  │
        │ (Kubo)   │       │   (Lotus)    │      │ (Gateway) │
        │ 3 nodes  │       │   1 node     │      │  1 node   │
        └──────────┘       └──────────────┘      └───────────┘
         Hot storage        Cold / deal-based     Permanent
         100Gi x 3          500Gi                 50Gi cache
```

**IPFS** -- Hot storage layer. Weather data is pinned to the IPFS cluster for fast retrieval
and content-addressed integrity. Three replicas provide redundancy within the cluster.

**Filecoin** -- Cold / archival storage. Larger weather datasets are stored via Filecoin
deals for cost-efficient long-term retention. The Lotus full node syncs the chain and
manages deal lifecycle.

**Arweave** -- Permanent storage for critical records (verified weather station calibration
data, governance audit logs). Data stored here is immutable and permanent.

### Namespace & Services

All storage workloads run in the `storage` Kubernetes namespace.

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| `ipfs-api` | 5001 | HTTP | IPFS API (pin, cat, add) |
| `ipfs-gateway` | 8080 | HTTP | IPFS HTTP gateway (read-only) |
| `ipfs-swarm` | 4001 | TCP | IPFS peer-to-peer |
| `filecoin-api` | 1234 | JSON-RPC | Lotus API |
| `arweave-gateway` | 1984 | HTTP | Arweave read/write |

---

## Backup & Disaster Recovery

### Recovery Objectives

| Metric | Target |
|--------|--------|
| **RTO** (Recovery Time Objective) | < 4 hours |
| **RPO** (Recovery Point Objective) | < 1 hour |

### Backup Strategy

1. **IPFS**: Data is content-addressed. As long as CIDs are tracked in the backend database,
   data can be re-pinned from the IPFS network. The backend maintains a CID registry with
   replication metadata.

2. **Filecoin**: Deals are recorded on-chain. Recovery involves re-syncing the Lotus node
   from the Filecoin network (may take several hours for full chain sync). Deal metadata is
   backed up in the backend database.

3. **Arweave**: Data is permanent by design. Recovery only requires re-deploying the gateway
   node and warming its cache from the Arweave network.

4. **CID Registry**: The backend PostgreSQL database stores all CID-to-provider mappings.
   PostgreSQL backups (WAL archiving + daily snapshots) are the critical DR component. Losing
   the CID registry means losing the index of what data is stored where.

### DR Procedures

**Full region failure:**
1. Deploy storage manifests to the DR region using `infra/k8s/storage/` manifests.
2. Restore backend database from the latest WAL archive.
3. IPFS nodes will re-pin data from the CID registry (automated by the storage-router service).
4. Filecoin Lotus must chain-sync (allow 2-4 hours for snapshot import).
5. Arweave gateway starts immediately; cache warms on demand.

**Single provider failure:**
The storage router automatically fails over to the next available provider. No manual
intervention is needed unless all providers are down (see AllProvidersUnhealthy alert).

---

## Common Operational Procedures

### Scale IPFS Cluster

To add more IPFS nodes:

```bash
# Via Terraform (preferred)
terraform apply -var="ipfs_node_count=5"

# Via kubectl (immediate)
kubectl -n storage scale statefulset/ipfs --replicas=5
```

After scaling, the new pods will bootstrap from existing peers via the `ipfs-swarm` service.
Allow 5-10 minutes for IPFS content to replicate to new nodes.

### Renew Filecoin Deals

Deals approaching expiry trigger the `FilecoinDealExpiringSoon` alert (7 days before expiry).

```bash
# List expiring deals via Lotus CLI
kubectl -n storage exec -it filecoin-lotus-0 -- lotus client list-deals --show-failed

# Renew a specific deal
kubectl -n storage exec -it filecoin-lotus-0 -- lotus client deal \
  --from=<wallet_address> \
  <data_cid> <miner_id> <price> <duration>
```

The backend storage-router service also has an automated renewal job that runs daily. Check
its logs if manual renewal is needed:

```bash
kubectl -n default logs -l app=storage-router --tail=100 | grep "deal renewal"
```

### Rotate Secrets

1. Generate new credentials.
2. Update the Kubernetes secrets:
   ```bash
   kubectl -n storage create secret generic ipfs-secrets \
     --from-literal=CLUSTER_SECRET=<new_value> \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Restart the affected pods:
   ```bash
   kubectl -n storage rollout restart statefulset/ipfs
   ```

### Check IPFS Cluster Health

```bash
# Check connected peers
kubectl -n storage exec -it ipfs-0 -- ipfs swarm peers

# Check pinned data
kubectl -n storage exec -it ipfs-0 -- ipfs pin ls --type=recursive | wc -l

# Check repo stats
kubectl -n storage exec -it ipfs-0 -- ipfs repo stat
```

### Check Filecoin Lotus Sync Status

```bash
kubectl -n storage exec -it filecoin-lotus-0 -- lotus sync status
kubectl -n storage exec -it filecoin-lotus-0 -- lotus sync wait
```

---

## Incident Response

### Provider Down (StorageProviderDown alert)

**Severity:** Critical
**Auto-mitigation:** The storage router fails over to the next healthy provider.

Manual steps if the provider does not recover:

1. Check pod status: `kubectl -n storage get pods -l app=<provider>`
2. Check pod events: `kubectl -n storage describe pod <pod-name>`
3. Check logs: `kubectl -n storage logs <pod-name> --tail=200`
4. If the PVC is full, expand it or clean up old data.
5. If the node is crash-looping, check for OOM kills in `kubectl -n storage get events --sort-by=.lastTimestamp`.

### Integrity Failure (IntegrityCheckFailure alert)

**Severity:** Critical -- potential data corruption or tampering.

1. Identify the affected CIDs from the alert labels and backend logs.
2. Verify the data against the expected hash:
   ```bash
   kubectl -n storage exec -it ipfs-0 -- ipfs cat <cid> | sha256sum
   ```
3. If the hash does not match, re-fetch from an alternative provider.
4. If the data is corrupted on all providers, restore from the backend CID registry and
   re-upload from the original source.
5. File a security incident if tampering is suspected.

### All Providers Down (AllProvidersUnhealthy alert)

**Severity:** Critical -- complete storage outage.

1. Page the on-call SRE immediately.
2. Check cluster-wide issues: `kubectl get nodes`, `kubectl -n storage get events`.
3. Check if the `storage` namespace has resource quota or limit range issues.
4. If the issue is network-related, check NetworkPolicy in `infra/k8s/advanced/network-policies.yaml`.
5. As a last resort, deploy to the DR region and update DNS/service mesh routing.

### Capacity Alert (StorageCapacityWarning / StorageCapacityCritical)

1. Check current usage on the Grafana "Storage Capacity Usage" panel.
2. For IPFS: run garbage collection to remove unpinned data:
   ```bash
   kubectl -n storage exec -it ipfs-0 -- ipfs repo gc
   ```
3. For Filecoin: identify and remove expired or unnecessary deals.
4. Expand PVCs if supported by the storage class:
   ```bash
   kubectl -n storage edit pvc <pvc-name>
   # Increase spec.resources.requests.storage
   ```

---

## Monitoring Endpoints & Dashboards

| Resource | Location |
|----------|----------|
| Grafana dashboard | "WRFCoin Storage Providers" (uid: `wrfcoin-storage-providers`) |
| Alert rules | `infra/monitoring/alerts/storage-providers.yml` |
| Prometheus scrape | Auto-discovered via `prometheus.io/scrape` pod annotations |
| IPFS metrics | `http://ipfs-api.storage:5001/debug/metrics/prometheus` |
| Filecoin metrics | `http://filecoin-api.storage:1234/debug/metrics` |
| Arweave metrics | `http://arweave-gateway.storage:1984/metrics` |

### Key Metrics to Watch

- `ipfs_pin_successes_total` / `ipfs_pin_failures_total` -- Pin operation outcomes
- `filecoin_deal_successes_total` / `filecoin_deal_failures_total` -- Deal outcomes
- `filecoin_deal_expiry_seconds` -- Time until deal expiry
- `arweave_upload_duration_seconds` -- Upload latency histogram
- `storage_retrieval_duration_seconds` -- Retrieval latency histogram (all providers)
- `storage_provider_health` -- Binary health gauge per provider (1 = healthy, 0 = down)
- `storage_integrity_failures_total` -- Integrity check failure counter
- `storage_failover_events_total` -- Failover event counter
- `storage_capacity_used_bytes` / `storage_capacity_total_bytes` -- Capacity gauges
