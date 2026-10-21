# N5 heartbeat: LEAD deployment runbook

This is source and local-test evidence only. No host inspection, deployment,
node-image rebuild, chain submission, merge, or runtime cadence observation was
performed by this lane. Deploy only after both PRs have been reviewed.

Collector code is owned by core4. Companion collector head:
`de83205cbb572630f6b4f5ced0f85aa000bd1739`. Its base is
`29c698504` and its changes are confined to the shared Ambient pipeline and
its inclusion tests. The base has no `tests/security` or `tests/utils` delta
against node pin `355ae7a3`; this does not establish the live collector revision.

At infra `c9badeec`, single-collector mounts are
`${CORE4_PATH:-<repo-root>/core4}/tests/{security,utils}`;
multi-collector mounts are
`${MULTI_COLLECTOR_CORE4:-<repo-root>/core4}/tests/{security,utils}`.
These bind mounts select a host tree, not the node image's revision. Per LEAD,
the live source is `<repo-root>/core4`; its SHA is **UNKNOWN** to
this lane because host inspection is prohibited. The new overlay's
`COLLECTOR_CORE4_PATH` replaces only those two mounts in each collector.
Existing default mounts, commands, roster and state volumes remain intact.

## Preflight and stage (LEAD on CT101 only)

1. Record actual script mount sources without inspecting container environment:

   ```sh
   docker inspect wrfcoin-testnet-weather-collector wrfcoin-testnet-weather-collector-multi --format '{{.Name}}{{range .Mounts}}{{if or (eq .Destination "/app/tests/security") (eq .Destination "/app/tests/utils")}} {{.Source}} -> {{.Destination}}{{end}}{{end}}'
   git -C <repo-root>/core4 rev-parse HEAD
   git -C <repo-root>/core4 status --short -- tests/security tests/utils
   ```

   Resolve each actual mounted source separately if paths differ. Stop if the
   revision cannot be established, or those source directories are dirty.
   Record the current infra revision and complete live Compose file list too.
   Confirm both collectors' existing pending state, signing identity and
   watermarks are on their dedicated persistent volumes; do not recreate a
   collector with state only in its writable container layer.

2. Fetch the reviewed collector head and establish that all other collector
   source matches the mounted tree before selecting the new release directory:

   ```sh
   COLLECTOR_SHA=de83205cbb572630f6b4f5ced0f85aa000bd1739
   git -C <repo-root>/core4 fetch origin "$COLLECTOR_SHA"
   git -C <repo-root>/core4 diff --quiet HEAD 29c698504 -- tests/security tests/utils
   # STOP if the preceding command is nonzero; reconcile the collector base first.
   git -C <repo-root>/core4 worktree add --detach "<repo-root>/releases/core4-collector-$COLLECTOR_SHA" "$COLLECTOR_SHA"
   ```

   Repeat the source comparison against the multi collector's actual base if
   different. Do not switch `CORE4_PATH`, modify the existing core4 checkout,
   or rebuild/recreate the node. Use the reviewed infra head to stage ONLY
   `testnet/docker-compose.block-heartbeat.yml` and
   `testnet/services/block-heartbeat/` into the existing deployment's infra
   tree; the daemon's read-only bind mount uses that directory. Fetch/archive
   or copy these exact paths from the reviewed infra release, rather than
   replacing the live Compose chain with a different stack.

   ```sh
   INFRA_HEARTBEAT_SHA=REPLACE_WITH_REVIEWED_INFRA_FULL_HEAD
   git -C <repo-root>/infra fetch origin "$INFRA_HEARTBEAT_SHA"
   git -C <repo-root>/infra archive "$INFRA_HEARTBEAT_SHA" \
     testnet/docker-compose.block-heartbeat.yml testnet/services/block-heartbeat \
     | tar -x -C <repo-root>/infra
   ```

   Select the full reviewed SHA from the infra PR; do not substitute a moving
   branch name. These are newly added paths. Record their source SHA in the
   deployment receipt. The existing node and other Compose services are not
   recreated by the service-specific commands below.

3. In the existing CT101 `.env`, add these non-secret settings (retain existing
   operator-token wiring by NAME; no new credential is required):

   ```dotenv
   BLOCK_HEARTBEAT_INTERVAL_SECONDS=77
   COLLECTOR_CORE4_PATH=<repo-root>/releases/core4-collector-de83205cbb572630f6b4f5ced0f85aa000bd1739
   WEATHER_COLLECTOR_MINE=true
   WEATHER_COLLECTOR_MULTI_MINE=true
   ```

   Add `block-heartbeat-n5` to enabled profiles. Add
   `docker-compose.block-heartbeat.yml` LAST to the existing Compose chain.
   The following function shows the supplied three-file N5 base; preserve any
   additional live overlays in their existing order BEFORE the new overlay:

   ```sh
   cd <repo-root>/infra/testnet
   dc() {
     docker compose --env-file .env --profile collector --profile block-heartbeat-n5 \
       -f docker-compose.testnet.yml -f docker-compose.override.yml \
       -f docker-compose.cut-miner.yml -f docker-compose.block-heartbeat.yml "$@"
   }
   dc config --quiet
   dc up -d --no-deps block-heartbeat
   dc ps block-heartbeat
   ```

   Wait for heartbeat health and successful height/status logs. This healthcheck
   needs a recent successful production, not merely a running PID. 503/partition
   and network failures back off; persistent refusal becomes unhealthy.

4. Set `WEATHER_COLLECTOR_MINE=false` in `.env`, then:

   ```sh
   dc up -d --no-deps --force-recreate weather-collector
   dc exec -T weather-collector node -e 'const p=require("/app/tests/security/lib/ambient-pipeline.cjs");if(p.collectorMineEnabled())process.exit(1)'
   ```

   Observe commit inclusion, reveal inclusion and the existing
   `pending_reconciliation`/finalization outcomes. Then set
   `WEATHER_COLLECTOR_MULTI_MINE=false` and run the corresponding two commands
   for `weather-collector-multi`. Keep all identity, roster, state, command and
   registration settings unchanged. Two temporary producers during this
   transition are expected; cadence verification starts after BOTH switches.

5. Wait at least 16 minutes after the second switch, then sample the latest
   twelve block timestamps (13 GETs total; no retries). Run inside the heartbeat
   container, so auth stays in its environment and never appears in argv:

   ```sh
   dc exec -T block-heartbeat node - <<'JS'
   (async () => {
     const base='http://wrfcoin-node:8556';
     async function get(path) {
       const response=await fetch(base+path,{headers:{Authorization:'Bearer '+process.env.WRFCOIN_OPERATOR_TOKEN},signal:AbortSignal.timeout(10000)});
       if(!response.ok)throw Error('sample HTTP '+response.status);
       const value=await response.json();return value.data||value;
     }
     const tip=(await get('/blockchain')).height;
     if(!Number.isSafeInteger(tip)||tip<12)throw Error('invalid height');
     let prior;
     for(let height=tip-11;height<=tip;height++) {
       const block=await get('/chain/block/'+height);
       const timestamp=Date.parse(block.timestamp)/1000;
       if(!Number.isFinite(timestamp)||block.height!==height)throw Error('invalid block');
       const gap=prior===undefined?null:timestamp-prior;
       console.log(JSON.stringify({height,gap_seconds:gap}));
       if(gap!==null&&Math.abs(gap-77)>10)throw Error('cadence outside 77 +/- 10 seconds');
       prior=timestamp;
     }
   })().catch(error=>{console.error(error.message);process.exitCode=1});
   JS
   ```

   If migration produced many extra blocks, ensure all twelve sampled blocks
   were produced after the second switch. A passed timestamp sample establishes
   observed cadence only; reward finalization remains a separate observation.

## Rollback (LEAD)

Stop the heartbeat first: `dc stop block-heartbeat`. Set both
`WEATHER_COLLECTOR_MINE=true` and `WEATHER_COLLECTOR_MULTI_MINE=true` in `.env`
(`COLLECTOR_MINE=true` is the shared fallback). Recreate each collector with
`dc up -d --no-deps --force-recreate SERVICE`. Keep the reviewed collector tree
and its persistent state mounts: the default true path retains the existing
collector-driven mining behavior. Do not remove volumes or change signing
identity. Remove the heartbeat profile from the enabled set after rollback.

## Reveal timing and issuance (core4 355ae7a3)

`shared-protocol/src/common/constants.rs:121-135` defines base commit/reveal
windows 720/1440 and the 14,400-second cap.
`proof_of_publishing.rs:2066-2089` scales by the scheduled target block time
with a three-block floor. At the supplied >=40500, <100000 tier (600-second
target), both windows are three blocks: 231 seconds at actual 77-second cadence.
Commits are tracked independently; confirmed records proceed while unresolved
records remain pending without blocking new cycles. Bound expiry and existing
max-age policies retire stale records with durable terminal reading IDs.
A commit is confirmed by two canonical status reads, then its reveal normally
lands in the next block, well inside this window. Each inclusion wait is bounded
to three actual intervals (231 seconds); a failed reveal wait preserves pending
state rather than promising inclusion. Backoff/partition can expire a commit.

`meteo-types/src/lib.rs:388-393` defaults to 14,400 seconds per block plus
900 seconds skew. `weather/validation.rs:663-690` uses the greater of the
block-count allowance and accepting-block timestamp gap + 900 when the
WeatherSkewBlockTimeAllowance gate and prior block timestamp are available.
This is the post-halt skew rule, not a 77-second reveal-age limit.
`blockchain/transaction.rs:2863-2873` binds the observation timestamp in the
commit hash; this change retains that timestamp unchanged through the wait.

Emission uses `INITIAL_BLOCK_REWARD=800 WRF`, genesis target 14,400 seconds,
126,000,000 scheduled seconds per reduction, 2/3 retention, and
`adjusted_block_reward=base*target/14400` (proof_of_publishing.rs:453-474,
534-573,613-623,700-713). Testnet shares are [6900,1500,1000,500,100] bps
(line 833); coinbase is 2500 bps of the contribution slice (1124-1140).
Empty-liveness coinbase is divided by 10 (445,3710-3716).

Nominal WRF/day at a fixed height/period, rounded to six decimals:

| Height/period | Actual interval | Total emission budget | Qualifying coinbase | Empty-liveness coinbase |
|---|---:|---:|---:|---:|
| 40500 / first period | 60 s | 48000.000000 | 8280.000000 | 828.000000 |
| 40500 / first period | 77 s | 37402.597399 | 6451.948052 | 645.194805 |
| 43000 / second period | 60 s | 32000.000000 | 5520.000000 | 552.000000 |
| 43000 / second period | 77 s | 24935.064933 | 4301.298698 | 430.129866 |

These are source-derived rates, not observed total issuance: unused role slices
are not automatically minted, empty blocks use the reduced coinbase, actual
heights can cross reduction boundaries, and supply caps still apply. The lane
cannot establish current height without forbidden live inspection. 77 is the
owner-selected approximate replacement for the old burst cadence; 60 increases
the nominal fixed-height rate by 28.333333% compared with 77.

## Local gates

Core4: 19 inclusion/transport/full-batch and stale-record controls, 77 existing multi collector
controls, and 23 existing Jest tests (119 assertions/controls total). Infra: 6 heartbeat tests and
5 Compose render controls; ShellCheck and targeted ESLint pass. The repository
Jest passes 23 assertions but exits 1 on asynchronous teardown; that exit also
reproduces on the pristine reviewed collector head. It is not a green process gate.
No Rust build was required. CI and deployment evidence are separate.

## Producer rotation mode (infra#1327, opt-in)

**DEPLOYMENT HELD until after the first node-share payout; requires core4#3590 deployed first (gossip).**
Design: `docs/plans/2026-10-18-producer-rotation-design.md`. With the rotation env unset the
heartbeat behaves exactly as above (N5-only, fixed 77 s grid).

Env (all three seated producers run their own heartbeat against their own node):

| Variable | Meaning |
|---|---|
| `BLOCK_HEARTBEAT_ROTATION` | Must be exactly `n5-node-a,producer-standby,mango-mini` (fixed roster order) |
| `BLOCK_HEARTBEAT_SELF` | This host's roster id |
| `BLOCK_HEARTBEAT_FALLBACK_STEP_SECONDS` | Fallback step per rank, default 60 (1-600) |
| `BLOCK_HEARTBEAT_MAX_SKEW_SECONDS` | Refuse to mine if the tip timestamp is further than this in the future of the local clock, default 5 |

Rule: each tick reads `GET /network/upgrade` (`tip_height`) and `GET /chain/block/{tip}`
(`data.timestamp`). The owner of `next = tip+1` is `ROSTER[next % 3]` and mines once
`now - tip_ts >= interval`; a non-owner mines only when `now - tip_ts >= interval + rank*step`
(rank 1 or 2 = distance after the owner). The host mines only to its own pinned payout address
(`n5-node-a 0x680d…0ed0`, `producer-standby 0x39ee…5b1a`, `mango-mini 0xc536…a990`, from core4
`genesis_producer_pins.rs`); startup refuses if `WRFCOIN_MINER_ADDRESS` differs. A skewed clock logs
`{"status":"clock_skew"}` once and does not mine. Logs carry only status/height.

**N5 enable step:** add `testnet/docker-compose.block-heartbeat-rotation.n5.yml` to the compose file set (after `docker-compose.block-heartbeat.yml`). The base N5 service is unchanged, so its default render never drifts. Rotation runtime: 5 s poll, 15 s retry after a failed mine; the health file is refreshed on every successful tip read.

Compose: profiles `block-heartbeat-ws` and `block-heartbeat-mango` (run on their own hosts).
**N5's `COLLECTOR_MINE` (and `WEATHER_COLLECTOR_MINE` / `WEATHER_COLLECTOR_MULTI_MINE`) must be
`false` before rotation is enabled on N5**, or collectors mine out of turn.

### Staged rollout (each step gated; nothing before the payout)

| Step | When | Gate to proceed |
|---|---|---|
| 0. Verify | Now (read-only) | Each host's node has a producer key resolving to its pinned key (no signing); clocks within 5 s; ws/Mango producer keys are not snapshot/server keys |
| 1. Deploy #3588 binary to all 3 nodes | After the first payout is observed | All 3 nodes same hash at the same height; a test receipt submitted on ws appears in N5's mempool |
| 2. ws produces in **fallback only** (rank 2) | +1 day | ws produces only when N5 misses (stop N5's heartbeat for 3 blocks to force it); ws's blocks accepted by all 3 |
| 3. Full rotation N5 + ws | +1 day | 100 consecutive blocks with no fork; payout to `0x39ee…` observed |
| 4. Add Mango | after Mango has run 24 h at full rotation memory | Mango's blocks accepted; no OOM (node limit 8 G) |

Rollback at every step: stop the new heartbeat profile; N5's heartbeat alone keeps the chain going.
