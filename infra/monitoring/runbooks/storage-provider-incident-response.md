# Storage Provider Incident Response Runbook

Runbook for `infra#13` storage provider alerts.

## Scope

- IPFS pin failures and retrieval errors
- Filecoin deal failures and expiry
- Arweave archive failures
- Data integrity check failures
- Provenance quarantine rate anomalies

## Alert Thresholds

| Alert | Trigger |
|---|---|
| `StoragePinFailureRateHigh` | pin failure rate `> 10%` for 5m |
| `StorageDealFailureRateHigh` | deal failure rate `> 20%` for 10m |
| `StorageRetrievalErrorRateHigh` | retrieval error rate `> 5%` for 3m |
| `StorageRetrievalLatencyHigh` | p95 retrieval latency `> 10s` for 5m |
| `StorageIntegrityCheckFailures` | any integrity failure in 10m window |
| `StorageProviderDown` | provider health check failing for 2m |
| `StorageQuarantineRateHigh` | quarantine rate `> 0.5/s` for 10m |

## Pin Failure Response (IPFS)

1. Check IPFS daemon health: `docker exec wrfcoin-ipfs ipfs id`
2. Verify disk space on `ipfs-data` volume: `docker exec wrfcoin-ipfs df -h /data/ipfs`
3. Check IPFS swarm connectivity: `docker exec wrfcoin-ipfs ipfs swarm peers | wc -l`
4. Review IPFS daemon logs: `docker logs wrfcoin-ipfs --tail 100`
5. If disk full: expand PVC or trigger GC (`ipfs repo gc`)
6. If daemon unresponsive: restart pod/container and verify pin recovery
7. Escalate to SEV2 if pin failure persists >15m after remediation

## Deal Failure Response (Filecoin)

1. Check Lotus lite sync status: `docker exec wrfcoin-filecoin lotus sync status`
2. Verify Filecoin wallet balance: `docker exec wrfcoin-filecoin lotus wallet balance`
3. Check active deals: `docker exec wrfcoin-filecoin lotus client list-deals`
4. Review deal proposal errors in logs: `docker logs wrfcoin-filecoin --tail 100`
5. If wallet low: top up from treasury and alert finance
6. If network congestion: increase gas premium or wait for next epoch
7. If miner unavailable: retry with alternative miner from trusted list
8. Escalate to SEV2 if deal failure rate persists >30m

## Retrieval Error Response

1. Identify failing provider from `wrfcoin_storage_retrieval_total{status="error"}` labels
2. Check provider health endpoint directly
3. Verify network connectivity between storage-provider and backend services
4. Check for integrity mismatches in retrieval logs (indicates data corruption)
5. If single provider: failover router should handle automatically; verify circuit breaker tripped
6. If multiple providers: check shared dependency (network, DNS, secrets expiry)
7. Escalate to SEV1 if retrieval errors affect live forecast delivery

## Integrity Check Failure Response

1. **CRITICAL** — any integrity failure indicates potential data corruption or tampering
2. Identify affected content IDs from logs
3. Cross-reference with archive receipts to find all provider copies
4. Attempt retrieval from alternate providers and verify blake3 hash
5. If all copies corrupted: check for infrastructure compromise (security team)
6. If single provider corrupted: remove provider from failover rotation, re-archive from healthy copy
7. File incident report with data lineage and provenance chain
8. Escalate to SEV1 immediately

## Quarantine Rate Spike Response

1. Review provenance validation failure reasons in audit log
2. Check if spike correlates with a specific data source or ingestion client
3. Verify provenance policy hasn't been inadvertently changed
4. If legitimate data rejected: review policy thresholds (min chain length, algorithm list)
5. If synthetic/bot-generated data: coordinate with security-testing team
6. Escalate to SEV2 if quarantine rate stays elevated >30m

## Provider Down Response

1. Identify which provider is down from `up{job="storage-provider"}` metric
2. Check container/pod status: `kubectl get pods -n wrfcoin-storage` or `docker ps`
3. Review container logs for crash reason
4. Check resource limits (OOM kill, CPU throttle)
5. Restart pod/container
6. Verify health check passes after restart
7. If crash-looping: check recent config/secret changes, rollback if needed
8. Escalate to SEV2 if provider unavailable >10m

## Escalation Matrix

| Severity | Criteria | Response Time | Notify |
|---|---|---|---|
| SEV1 | Integrity failure, multi-provider outage, forecast delivery impacted | 15m | On-call + storage lead + security |
| SEV2 | Single provider outage, elevated error rates, deal failures | 30m | On-call + storage lead |
| SEV3 | Elevated latency, quarantine spikes, capacity warnings | 2h | On-call |
