# WRFCoin Testnet Post-Deploy Checklist

Use this after local-build deploys on the N5 Pro and desktop peer. The goal is to prove what code/config reached runtime and whether the two-node testnet is converging.

## 1. Source Provenance

Run before deploy from the CT checkout root:

```bash
cd <repo-root>/infra
bash testnet/scripts/deploy-hygiene-preflight.sh
```

Record the reported SHA for each repo:

| Repo | Branch | SHA |
|---|---|---|
| infra |  |  |
| backend |  |  |
| core4 |  |  |
| frontend |  |  |

Generate a visibly labelled test notification, then immediately capture a
machine-readable snapshot on each node. The canary forwards through the configured
operator channel; seeing `TEST: WRFCoin launch-readiness delivery canary` is expected
and requires no incident action.

```bash
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=n5-pro bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-n5-pro.json
bash testnet/scripts/alert-delivery-canary.sh
NODE_NAME=desktop bash testnet/scripts/deploy-status-snapshot.sh > deploy-status-desktop.json
```

Attach both JSON files to the deploy note. They record source repo SHAs,
container state, node/backend endpoint output, and the targeted node log scan
in one reusable format.

After both snapshots exist, run the launch-readiness gate:

```bash
bash testnet/scripts/launch-readiness-gate.sh \
  --n5 deploy-status-n5-pro.json \
  --desktop deploy-status-desktop.json \
  --json-out launch-readiness-report.json \
  --markdown-out launch-readiness-report.md
```

Treat a non-zero exit as a deploy-promotion stop.

## 2. Container State

```bash
cd <repo-root>/infra/testnet
docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml -f docker-compose.local-paths.example.yml ps
docker ps --filter health=unhealthy --format 'unhealthy {{.Names}} {{.Status}}'
```

Expected: no unhealthy containers. If frontend/backend are intentionally stopped or `Created`, note why before proceeding.

## 3. Node And Backend Health

On each node:

```bash
curl -sf http://localhost:8556/readyz
curl -sf http://localhost:8556/health
curl -sf http://localhost:8556/network/info | jq .
curl -sf http://localhost:4001/health | jq .
```

Record:

| Node | readyz | health | peer_count | chain_height | sync_status |
|---|---|---|---:|---:|---|
| N5 Pro |  |  |  |  |  |
| Desktop |  |  |  |  |  |

## 4. Convergence Check

Obtain the operator-approved peer comparison procedure before deployment.
Compare chain position and peer state across the intended peers.

Run the IBD verifier when validating desktop against the N5 seed:

```bash
bash scripts/verify-ibd.sh --max-wait 1800 --interval 30
```

Fail the deploy if desktop remains at `chain_height=0` while N5 advances, or if heights match but tip hashes diverge.

## 5. Targeted Log Scan

Scan recent node logs for the launch-blocker family:

```bash
docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml -f docker-compose.local-paths.example.yml logs --since=30m wrfcoin-node \
  | grep -Ei 'orphan|genesis|fork|reorg|validation|min_work_factor|sync|panic|error'
```

Record the first blocking reason, not just the fact that logs are noisy.

The same scan is included in `deploy-status-*.json` under `node_log_scan`.

## 6. Decision

| Gate | Result |
|---|---|
| Source repos clean, attached, on intended branch, and not ahead/behind upstream |  |
| N5 node healthy and advancing |  |
| Desktop node healthy and converging |  |
| Backend health green or intentionally out of scope |  |
| No unresolved blocker in targeted sync/orphan log scan |  |

Overall: `PASS` / `FAIL`

Next action:

- If PASS: proceed to the next launch-readiness gate.
- If FAIL: stop deploy promotion and file or update the blocking GitHub issue with the table above.
