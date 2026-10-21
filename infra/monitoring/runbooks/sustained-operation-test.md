# Runbook — 48-hour Sustained Operation Test

**Issue:** [core4#758](https://github.com/wrfcoin/core4/issues/758)
**Script:** `infra/testnet/scripts/sustained-operation-test.sh`
**Classification:** Human Required — long-running, must be supervised
**Expected runtime:** 48 hours (configurable)

---

## Purpose

Run a long-duration soak test against the live testnet stack to detect memory
leaks, connection-pool exhaustion, disk growth anomalies, peer-count drops,
and service restarts **before** we invite external operators to join the
testnet. Everything in the testnet has been run "once, pass, done" — this
runbook converts that into "pass for 48 hours under load."

The script is a single bash entrypoint that:

1. **Pre-flight:** verifies the containers are all running, `/readyz` is 200,
   Prometheus is reachable, and the `wrfcoin_blockchain_block_height` sample
   is being scraped.
2. **Baseline capture (t=0):** writes JSON with the success-criteria metrics
   (block height, mempool, RSS for node+backend, fork/reorg counts, peer
   count, Postgres backend count, docker volume sizes, API latency p95).
3. **Load generation:** spawns a background loop that posts commit/reveal
   contribution pairs to the Rust node (`/transactions/contribution/commit`
   and `/reveal` on `:8556`) every 60 seconds. Auth token is read from
   `testnet/.env` (`WRFCOIN_CONTRIBUTOR_TOKEN` preferred,
   `WRFCOIN_OPERATOR_TOKEN` as fallback).
4. **Periodic sampling:** every 15 minutes it re-captures the same metrics
   and appends to the JSONL log.
5. **Termination:** after `--duration` elapses (default 48h) the loop stops,
   a final capture is taken, and the script evaluates pass/fail and writes
   a markdown report.

---

## When to run

| Trigger                                           | Required |
|---------------------------------------------------|:--------:|
| Before inviting external operators                | Yes      |
| After any infra or compose-stack change           | Yes      |
| After any `wrfcoin-node` binary upgrade           | Yes      |
| Weekly cadence on the reference node              | Recommended |
| After a deep consensus or mempool code change     | Yes      |

---

## Invocation

### Primary path (N5 Pro reference node, via SSH + tmux)

The test runs for 48 hours, so it **must** survive SSH disconnect. Use tmux
on the LXC container.

```bash
# From your workstation, SSH to the Proxmox host, then exec into CT 101:
ssh <node-host>
pct enter 101

# Inside CT 101:
cd /root/wrfcoin/infra/testnet
tmux new -s sustained-test

# Inside tmux:
./scripts/sustained-operation-test.sh --duration 48h 2>&1 | tee /var/log/wrfcoin-sustained-test/console.log

# Detach with Ctrl-b then d
# Re-attach later with:
tmux attach -t sustained-test
```

### Single-line non-interactive invocation

```bash
<node-shell> "bash -lc 'cd /root/wrfcoin/infra/testnet && tmux new -d -s sustained-test \"./scripts/sustained-operation-test.sh --duration 48h\"'"
```

### Shorter smoke test (1 hour)

```bash
./scripts/sustained-operation-test.sh --duration 1h --interval 5m
```

### Dry-run (pre-flight + baseline only, ~10 seconds)

```bash
./scripts/sustained-operation-test.sh --dry-run
```

Use dry-run to verify the script can talk to the stack before committing
to a real 48-hour run. It does pre-flight and writes a single baseline
sample then exits with a short report.

---

## Tailing the JSON log while the test runs

```bash
# Find the active log (newest JSONL in the output dir)
LOG=$(ls -t /var/log/wrfcoin-sustained-test/sustained-test-*.jsonl | head -1)

# Pretty-print each new sample as it arrives
tail -F "$LOG" | jq -c '{tag, ts, block_height, peer_count, node_process_rss_bytes, backend_process_rss_bytes, api_latency_p95_ms}'
```

The load generator log is next to it:

```bash
tail -F /var/log/wrfcoin-sustained-test/load-*.log
```

---

## Pass criteria

After 48 hours the report (`sustained-test-<timestamp>.md`) prints one of
`PASS` or `FAIL`. A `PASS` requires **all** of:

| Criterion                                   | Threshold                      |
|---------------------------------------------|--------------------------------|
| Block height advanced monotonically         | No sample `height[i] < height[i-1]` |
| Node process RSS growth                     | < 20% vs baseline              |
| Backend process RSS growth                  | < 20% vs baseline              |
| Peer count throughout                       | >= `MIN_PEER_COUNT` (default 0)|
| Max API latency p95                         | < 500ms                        |
| OOM kills                                   | none (checked via `docker events`) |
| Container exits/restarts during run         | none                           |

Thresholds are CLI/env configurable:
`MAX_MEMORY_GROWTH_PCT`, `MIN_PEER_COUNT`, `MAX_API_LATENCY_P95_MS`.

---

## Interpreting a FAIL verdict

The report lists each failing criterion with its delta. Map it back to a
root cause before declaring the test a launch blocker:

| Failure                              | Likely root cause                                         | Next step |
|--------------------------------------|-----------------------------------------------------------|-----------|
| node RSS grew > 20%                  | Memory leak in mempool, WAL replay cache, or peer store   | `cargo run --features dhat-heap` on dev, review heap profile |
| backend RSS grew > 20%               | Unbounded Map/Set growth in Node process, or winston file sinks | Heap snapshot via `node --inspect=0.0.0.0:9229` |
| block height not monotonic           | Reorg exceeded finality depth, or height query flaked     | Correlate with `wrfcoin_chain_reorg_total` + `wrfcoin_blockchain_block_height` in Prometheus |
| block height didn't advance          | Mining halted — consensus stall or solo-node stopped      | Check `tail -F` of `docker compose logs wrfcoin-node` |
| peer count < threshold               | P2P disconnect, seed node unreachable, NAT issue          | `curl http://localhost:8556/network/info`, check firewall on :9000 |
| max API latency p95 > 500ms          | GC pause, lock contention, large request queue            | `docker stats`, review Prometheus `rate(http_request_duration_seconds_sum[5m])` |
| OOM kill                             | Container memory limit too tight                          | `docker inspect <container> | jq '.[0].HostConfig.Memory'` vs observed peak |
| container exited during run          | Crash, panic, healthcheck failure                         | `docker compose logs <name>`, inspect exit code |

Always attach the JSON log and the markdown report when filing a follow-up
issue.

---

## Clean-up / follow-up

The script is idempotent and safe to re-run. On completion:

- Keep the JSON log and markdown report under `/var/log/wrfcoin-sustained-test/`
- Copy the `sustained-test-<timestamp>.md` report to the nearest sprint
  tracking doc under `docs/testnet/`
- If PASS: mark [core4#758](https://github.com/wrfcoin/core4/issues/758) as
  verified with a comment linking to the report
- If FAIL: file a new issue in the appropriate repo with the failing
  criterion, the JSON log excerpt, and the markdown report attached

---

## Related runbooks

- [`backup-restore-verification.md`](./backup-restore-verification.md) — the
  other pre-launch "Human Required" procedure (issue core4#753)
- [`testnet/RESTORE_DRILL.md`](../../../testnet/RESTORE_DRILL.md) — manual
  restore checklist that the verification script automates

`<node-shell>` means the operator-provided shell inside the node deployment.
Replace it with your own access method; no host/container layout is assumed.
