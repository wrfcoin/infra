# Fork / Reorg / Finality Alert Verification Runbook

**Owner:** Infra / Observability
**Last verified:** 2026-04-04 on N5 Pro testnet (chain height 2062)
**Related:** core4 PR #1150, issue #1148, R14 Lane A

This runbook verifies that the 6 blockchain-health alerts in
`infra/testnet/alert-rules-blockchain-health.yml` are no longer silent drifts,
and documents the commands used to confirm wiring end to end.

## Why this runbook exists

Before core4 PR #1150, the 5 metrics referenced by the fork/reorg/finality
alert group were never registered with the Prometheus registry. The alert
rules loaded cleanly but evaluated against missing series, so the alerts
could never fire. This was discovered during TDD Round 13 Lane C.

PR #1150 wired the metrics. This runbook is the operator-facing verification
procedure to confirm the wiring after any redeploy that touches the
monitoring module, the alert rules, or the Prometheus scrape config.

## Prerequisites

- SSH access to the N5 Pro (`<node-host>`)
- CT 101 running on the Proxmox host
- The wrfcoin testnet Docker stack running inside CT 101
- `amtool` available on the alertmanager container (optional, for synthetic triggers)

## Step 1 — Confirm the 5 metrics are exposed by the node

From the dev machine:

```bash
<node-shell> "bash -lc \
  'curl -s http://127.0.0.1:8556/metrics | grep -E \"^wrfcoin_chain_(fork|reorg|finalized)\"'"
```

Expected output (values will vary):

```
wrfcoin_chain_finalized_height 1962
wrfcoin_chain_fork_active 0
wrfcoin_chain_fork_count 0
wrfcoin_chain_reorg_depth 0
wrfcoin_chain_reorg_total 0
```

All 5 lines must be present. If any are missing, the node is running a build
that predates PR #1150 — redeploy before continuing.

## Step 2 — Confirm the structural finality invariant

The finalized height is computed as `chain_tip - MAX_REORG_DEPTH`
(MAX_REORG_DEPTH = 100). On a healthy, caught-up node the gap is exactly 100.

```bash
<node-shell> "bash -lc \
  'curl -s \"http://127.0.0.1:9090/api/v1/query?query=wrfcoin_blockchain_block_height+-+wrfcoin_chain_finalized_height\" \
   | python3 -c \"import sys,json; print(json.load(sys.stdin)[\\\"data\\\"][\\\"result\\\"][0][\\\"value\\\"])\"'"
```

Expected output: `[..., '100']`

Any value other than 100 on a caught-up chain indicates a metric wiring
regression. The `FinalityLag` alert at threshold `> 150` is specifically
designed to catch this case if the drift accumulates.

## Step 3 — Confirm all 6 alerts load and evaluate

```bash
<node-shell> "bash -lc \
  'curl -s http://127.0.0.1:9090/api/v1/rules | python3 -c \"
import sys, json
target = {
    \\\"ChainForkDetected\\\", \\\"ChainForkRateHigh\\\",
    \\\"ChainReorgDetected\\\", \\\"ChainReorgOccurred\\\",
    \\\"FinalityLag\\\", \\\"FinalityStalled\\\",
}
d = json.load(sys.stdin)
seen = set()
for grp in d[\\\"data\\\"][\\\"groups\\\"]:
    for r in grp[\\\"rules\\\"]:
        if r[\\\"type\\\"] == \\\"alerting\\\" and r[\\\"name\\\"] in target:
            seen.add(r[\\\"name\\\"])
            print(f\\\"{r[\\\"name\\\"]:22s} state={r[\\\"state\\\"]:9s} health={r[\\\"health\\\"]}\\\")
missing = target - seen
if missing:
    print(\\\"MISSING:\\\", missing)
    sys.exit(1)
\"'"
```

Expected: all 6 present with `health=ok`. On a quiet chain `state=inactive`
for all 6 is the happy path.

## Step 4 — Synthetic alert trigger (optional, destructive)

To end-to-end verify that AlertManager routing works, stop the wrfcoin-node
container briefly to trigger `BlockProductionStalled` (companion alert that
uses the same scrape target):

```bash
<node-shell> "bash -lc \
  'cd /root/wrfcoin/infra/testnet && docker compose stop wrfcoin-node'"
# Wait ~4 minutes (2m scrape window + 2m for duration)
<node-shell> "bash -lc \
  'curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -m json.tool | head -40'"
# Restart
<node-shell> "bash -lc \
  'cd /root/wrfcoin/infra/testnet && docker compose start wrfcoin-node'"
```

Do NOT run this during a sustained operation test or when external operators
are connected.

## Common failures and fixes

| Symptom | Root cause | Fix |
|---|---|---|
| Metrics missing from `/metrics` | Node built before PR #1150 | Redeploy with `.claude/commands/deploy-node.sh` |
| `FinalityLag` always firing | Threshold set below MAX_REORG_DEPTH (pre-R14 bug) | Confirm threshold is `> 150`, not `> 50` |
| Gap not exactly 100 | `CoreMetricSnapshot.chain_finalized_height` not populated by caller | Check `native-chain/src/bin/launch_api/routes/chain.rs` `build_runtime_monitoring_snapshot` |
| Alerts loaded but `health=err` | Expression references a metric name that does not exist | Diff alert YAML against `curl /metrics \| grep wrfcoin_` |

## Change log

- **2026-04-04** — Initial runbook (R14 Lane A). Corrected `FinalityLag` threshold
  from `> 50` to `> 150` to sit above the MAX_REORG_DEPTH=100 structural floor.
- **2026-04-04** — First verified on N5 Pro at chain height 2062 / finalized 1962.

`<node-shell>` means the operator-provided shell inside the node deployment.
Replace it with your own access method; no host/container layout is assumed.
