# Blockchain Node Operations Runbook

## Architecture Overview

```
                    ┌──────────────────────────────────────┐
                    │         Load Balancer / Ingress       │
                    └──────────┬───────────────┬───────────┘
                               │               │
                    ┌──────────▼──┐     ┌──────▼──────────┐
                    │  API Server │     │  API Server (2)  │
                    │  (port 8556)│     │  (port 8556)     │
                    └──────┬──────┘     └──────┬───────────┘
                           │                   │
                    ┌──────▼───────────────────▼───────────┐
                    │        native-chain runtime          │
                    │  ┌────────────┐  ┌────────────────┐  │
                    │  │ Consensus  │  │ P2P (libp2p)   │  │
                    │  │ Engines    │  │ port 9000      │  │
                    │  └────────────┘  └────────────────┘  │
                    │  ┌────────────┐  ┌────────────────┐  │
                    │  │ Privacy    │  │ Block Storage  │  │
                    │  │ Module     │  │ (RocksDB)      │  │
                    │  └────────────┘  └────────────────┘  │
                    └──────────────────────────────────────┘
```

### Key Ports

| Service | Port | Protocol | Purpose |
|---------|------|----------|---------|
| API Server | 8556 | HTTP/JSON | External RPC queries |
| P2P | 9000 | TCP | Peer-to-peer gossip and sync |
| Metrics | 9090 | HTTP | Prometheus metrics endpoint |

### Namespace & Deployment

Blockchain nodes run in the `blockchain` Kubernetes namespace as a StatefulSet (`blockchain-node`).

```bash
kubectl -n blockchain get statefulset
kubectl -n blockchain get pods -l app=blockchain-node
```

---

## Health Checks

### Quick Health

```bash
# Check if the API is responding
curl -s http://blockchain-node.blockchain:8556/health | jq .

# Check current block height
curl -s http://blockchain-node.blockchain:8556/status | jq '.block_height'

# Check peer count
curl -s http://blockchain-node.blockchain:8556/network/peers | jq '.count'
```

### Expected Healthy State

| Metric | Healthy Value |
|--------|--------------|
| API `/health` | `{"status": "ok"}` |
| Block height | Increasing (new block every ~15s at steady state) |
| Peer count | >= 3 |
| Consensus participation | Active (check logs for `block_produced` or `block_validated`) |

### Kubernetes Health

```bash
# Pod status and restarts
kubectl -n blockchain get pods -o wide

# Recent events
kubectl -n blockchain get events --sort-by=.lastTimestamp | tail -20

# Resource usage
kubectl -n blockchain top pods
```

---

## Common Operations

### Restart a Node

```bash
# Graceful restart (preferred — allows block finalization)
kubectl -n blockchain rollout restart statefulset/blockchain-node

# Delete a specific pod (will be recreated by StatefulSet)
kubectl -n blockchain delete pod blockchain-node-0
```

**Warning:** Restarting during consensus rounds may cause the node to miss its slot. Schedule restarts during low-activity windows if possible.

### Scale Nodes

```bash
# Scale up
kubectl -n blockchain scale statefulset/blockchain-node --replicas=5

# Scale down (ensure quorum is maintained)
kubectl -n blockchain scale statefulset/blockchain-node --replicas=3
```

Minimum quorum for consensus: 2/3 of validators + 1. Never scale below quorum.

### Check Sync Status

```bash
# Compare local height to network height
LOCAL=$(curl -s http://blockchain-node.blockchain:8556/status | jq '.block_height')
NETWORK=$(curl -s http://blockchain-node.blockchain:8556/network/status | jq '.highest_block')
echo "Local: $LOCAL, Network: $NETWORK, Behind: $((NETWORK - LOCAL))"
```

If the node is more than 100 blocks behind, it may need a snapshot resync (see Disaster Recovery).

### View Logs

```bash
# Recent logs
kubectl -n blockchain logs blockchain-node-0 --tail=200

# Follow logs (live)
kubectl -n blockchain logs -f blockchain-node-0

# Filter for consensus events
kubectl -n blockchain logs blockchain-node-0 --tail=500 | grep -E "block_produced|block_validated|consensus"

# Filter for errors
kubectl -n blockchain logs blockchain-node-0 --tail=500 | grep -i error
```

### Update Node Configuration

Configuration is managed via ConfigMap:

```bash
# View current config
kubectl -n blockchain get configmap blockchain-config -o yaml

# Edit config (opens editor)
kubectl -n blockchain edit configmap blockchain-config

# Apply changes (requires pod restart)
kubectl -n blockchain rollout restart statefulset/blockchain-node
```

---

## Incident Response

### Node Not Producing Blocks (ConsensusStalled alert)

**Severity:** Critical

1. Check if the node is synced:
   ```bash
   curl -s http://blockchain-node.blockchain:8556/status | jq '{block_height, syncing, last_block_time}'
   ```

2. Check peer connectivity:
   ```bash
   curl -s http://blockchain-node.blockchain:8556/network/peers | jq '.count'
   ```
   If peer count is 0, check network policies and P2P port accessibility.

3. Check for resource exhaustion:
   ```bash
   kubectl -n blockchain top pods
   kubectl -n blockchain describe pod blockchain-node-0 | grep -A5 "Conditions"
   ```

4. Check for panic/crash in logs:
   ```bash
   kubectl -n blockchain logs blockchain-node-0 --previous --tail=100
   ```

5. If the node is stuck, try a graceful restart:
   ```bash
   kubectl -n blockchain delete pod blockchain-node-0
   ```

### Fork Detected (ChainForkDetected alert)

**Severity:** Critical

1. Identify the fork point:
   ```bash
   kubectl -n blockchain logs blockchain-node-0 --tail=1000 | grep -i "fork\|reorg"
   ```

2. Check if other nodes agree on the canonical chain:
   ```bash
   for i in 0 1 2; do
     echo "Node $i:"
     kubectl -n blockchain exec blockchain-node-$i -- \
       curl -s http://localhost:8556/status | jq '{block_height, block_hash}'
   done
   ```

3. If a minority node is on the wrong fork, restart it to resync from peers.

4. If majority of nodes are on different forks, escalate to the on-call engineer. Do NOT force any node to a specific chain without investigation.

### High Memory Usage (NodeMemoryHigh alert)

**Severity:** Warning

1. Check current memory:
   ```bash
   kubectl -n blockchain top pod blockchain-node-0
   ```

2. Check if RocksDB compaction is running (temporary memory spike):
   ```bash
   kubectl -n blockchain logs blockchain-node-0 --tail=200 | grep -i compaction
   ```

3. If memory is persistently high, consider:
   - Increasing pod memory limits in the StatefulSet spec
   - Running RocksDB compaction manually
   - Pruning old block data if archival is not required

### P2P Connectivity Lost (PeerCountLow alert)

**Severity:** Warning → Critical if peer count = 0

1. Check network policies:
   ```bash
   kubectl -n blockchain get networkpolicy
   ```

2. Check if port 9000 is accessible:
   ```bash
   kubectl -n blockchain exec blockchain-node-0 -- \
     nc -zv blockchain-node-1.blockchain-node.blockchain.svc.cluster.local 9000
   ```

3. Check if bootnodes are reachable:
   ```bash
   kubectl -n blockchain logs blockchain-node-0 --tail=200 | grep -i "bootnode\|bootstrap"
   ```

4. If the cluster network is healthy but P2P is down, restart the P2P layer:
   ```bash
   kubectl -n blockchain delete pod blockchain-node-0
   ```

---

## Backup & Disaster Recovery

### Recovery Objectives

| Metric | Target |
|--------|--------|
| **RTO** | < 2 hours |
| **RPO** | < 1 block (~15 seconds) |

### Backup Strategy

1. **Block data** is replicated across all validator nodes via consensus. As long as quorum is maintained, no data is lost.

2. **RocksDB snapshots** are taken daily by the `blockchain-backup` CronJob:
   ```bash
   kubectl -n blockchain get cronjob blockchain-backup
   kubectl -n blockchain get jobs -l app=blockchain-backup --sort-by=.status.startTime | tail -5
   ```

3. **Configuration** is stored in ConfigMaps and version-controlled in `infra/k8s/blockchain/`.

### Full Node Recovery

1. Deploy the StatefulSet from manifests:
   ```bash
   kubectl apply -f infra/k8s/blockchain/
   ```

2. The node will sync from peers automatically via P2P. For faster recovery, restore from the latest RocksDB snapshot:
   ```bash
   # Copy snapshot to the PVC
   kubectl -n blockchain cp /path/to/snapshot blockchain-node-0:/data/blockchain/
   # Restart to load snapshot
   kubectl -n blockchain delete pod blockchain-node-0
   ```

3. Monitor sync progress:
   ```bash
   watch -n5 "curl -s http://blockchain-node.blockchain:8556/status | jq '{block_height, syncing}'"
   ```

---

## Monitoring

| Resource | Location |
|----------|----------|
| Grafana dashboard | "WRFCoin Blockchain Nodes" (uid: `wrfcoin-blockchain-nodes`) |
| Alert rules | `infra/monitoring/alerts/blockchain.yml` |
| Prometheus scrape | `http://blockchain-node.blockchain:9090/metrics` |

### Key Metrics

- `blockchain_block_height` — Current chain height
- `blockchain_peers_connected` — Number of connected P2P peers
- `blockchain_consensus_rounds_total` — Consensus participation counter
- `blockchain_block_production_seconds` — Block production latency histogram
- `blockchain_mempool_size` — Pending transaction count
- `blockchain_storage_bytes` — RocksDB disk usage
- `blockchain_sync_lag_blocks` — Blocks behind network tip
