# Owner command: activate a batch of phone stations (chain 888)

A phone can register itself, but only a registration signed with the governance key
makes its station earn. Until the owner runs this command, the phone stays
`db_only`, its readings are refused with `STATION_NOT_ACTIVE`, and the app says it
is waiting. This is the owner's batch for the first outside users.

Running it signs and submits registrations to chain 888/testnet, and **a successful
submission has no undo**. The tool asks the owner to type YES in a terminal first.
It reports stages and counts only.

## The one command, from the workstation

The governance key host can't reach the other two producers, so the workstation reads
those and hands the readings over. `activate-mobile-stations-888.sh` reads them, does a
dry run on the key host, reads them again, then starts the real run, which asks for YES.
Hosts are inputs; the script names none.

```bash
bash testnet/scripts/activate-mobile-stations-888.sh \
  --key-host '<command that runs a program on the key host, with a terminal>' \
  --tool-dir <this repo's testnet/scripts on the key host> \
  --key-host-producer <name>=wrfcoin-testnet-node \
  --reader <name2>='docker' \
  --reader <name3>='<command that runs docker on the third producer>' \
  --cli <CLI path on the key host> --cli-sha <digest from the build receipt> --limit 21
```

Copy `activate-mobile-stations.py` to the key host first, from the commit you reviewed.
A batch is 21 rows at most. Use a small `--limit` for the first batch.

## Stations connected on the website: the same command with `--source website`

A station connected on the website (an Ambient station, say) is in the same position as a
phone: the backend has it, but it earns only after a governance-signed registration. Add
`--source website` to the command above and the batch is taken from those stations instead:

```bash
bash testnet/scripts/activate-mobile-stations-888.sh <the same inputs> --source website --limit 5
```

What is different from a phone batch, and nothing else is:

| | Phone (default) | `--source website` |
|---|---|---|
| Who decides the list | The oldest waiting rows in `mobile_station_registrations` | The backend export. The tool asks it first, shows that list, and signs exactly that list or nothing |
| Who is on it | A phone that registered in the app | A website station that is **ready**: its owner's 12-word wallet has signed for it, its provider credentials are stored and ingestion is active, it is reporting (its provider shows a reading from its own device in the last 24 hours, checked when the tool runs), and its id is a neutral id |
| Export script in the backend container | `scripts/export-mobile-station-registrations.ts` | `scripts/export-website-station-registrations.ts`. It never changes a row |
| Station ids | `mob-` + 32 hex, derived from the wallet | `pws-` + 16 hex, issued by the backend. Older ids hold the name the owner typed; see below |
| Chain record | `phone-barometer`, `unverified`, `real` | `personal-weather-station`, `unverified`, `real`, no elevation |
| Backend switches that must be on | `STATION_CHAIN_SYNC_ENABLED` | that, and `WEBSITE_STATION_CHAIN_REGISTRATION_ENABLED` |
| Station ids on screen | Only in the exit 3 handoff list | In the dry run, and again just before the YES |

A passkey-owned station is never on the list: the chain can't check a passkey owner yet.

### What the dry run shows

```text
NOT IN THIS BATCH: pws-00000000000000c3: station_report: no reading from this station's device in the last 24 hours
NOT IN THIS BATCH: pws-00000000000000e5: provider_unreachable: the provider could not be read for this station; not exported this run
PREFLIGHT PASS: clock, node, sync, CLI and key modes
EXPORTED: 2 rows
ROW 1/2: eligible; ownership checked by exporter; station id pws-00000000000000a1; source provider; last reading 12 min ago
ROW 2/2: eligible; ownership checked by exporter; station id pws-00000000000000b2; source provider; last reading 13 min ago
DRY RUN PASS: 2 eligible rows; no signature or submission
```

- `ROW` lines are the stations that would be signed. `source provider` means the export
  asked the station's weather provider just now, with the keys the owner stored, and the
  provider showed a reading from that station's own device this many minutes ago. Nothing
  else from the provider is shown or kept.
- The first step can take a few minutes: one provider request per station, at most one a
  second, 10 seconds each at most. This happens before the YES, outside the signing window.
  The second export (the one that is signed) asks no provider for the stations just seen.
- `station_report` means the provider answered and showed no reading from that device in
  the last 24 hours. `provider_unreachable` means the provider could not be read (an error,
  a timeout, or it asked to slow down): the station is left out this run and is never put
  in a batch on an error. Run again later.
- If nothing is ready the tool prints the `NOT IN THIS BATCH` lines and stops with
  `no station is ready; the reasons are above; nothing signed`.
- The backend container needs `API_KEY_ENCRYPTION_KEY` (it already has it to store the
  keys). `WEBSITE_STATION_PROVIDER_MIN_INTERVAL_MS` slows the provider requests down; it
  can't make them faster than one a second.
- `NOT IN THIS BATCH` lines are waiting stations the export left out, with the reason. A
  station that isn't ready never takes a place in the batch, so one bad row can't hold up
  the others. Only a fixed set of reasons is printed.
- No position, owner address, key or signature is printed.

### Station ids are public for good: read them before YES

The real run prints `WILL BE PUBLIC ON CHAIN i/N: station id <id>` above the YES prompt, for
exactly the stations it will sign. If the list changes between that moment and signing, the
run stops and signs nothing.

New website stations get a neutral id from the backend. A station connected before that has
an id built from the name its owner typed (`pws-<name>-<6 hex>`). Those are left out
(`NOT IN THIS BATCH: ... station id is not a neutral id`) unless you name them one by one:

```bash
... --source website --allow-station-id pws-my-own-station-a1b2c3
```

Do that only for a station whose owner agrees to the id being public permanently (your own
station, for instance).

### A station id the chain already has

If the chain already has a station id under another owner, the backend's chain sync marks
that website station `blocked` and it leaves the waiting list; its owner is told to reconnect
the station to get a new id. If a run meets such a station before the sync has seen it, it
stops and names it (`ACTIVATION STOP: station <id> is already registered on chain ...`).
Run again after the next backend sync (ten minutes at most).

### After the batch

The same exit 3 handoff and readback apply; the receipt records `"source": "website"`. The
station's page says "earning" only after the backend's chain sync has seen the station in
the chain registry; the batch tool doesn't set that and neither does the export.

### Chain id

The backend checks owner signatures against `WRFCOIN_CHAIN_ID` / `WRFCOIN_NETWORK_ID` and
has no default on this path; the website signs for the chain the backend reports and refuses
on a mismatch with its own build setting; this tool refuses an export that is not for chain
888/testnet. Some build and env examples in this repo still default to chain 777. They are
not changed here: set both to 888 for the live testnet, and a wrong value now stops at the
first of those three checks instead of producing proofs nobody can use.

## What has to be true, and what checks it

Every run checks these before any signature, dry runs included:

| Check | How | If not |
|---|---|---|
| Three producers on one build | Each container must be running and carry a full `org.opencontainers.image.revision` label. All three must match each other. **No revision is pinned**, so a new release needs no edit here | Stop. Mismatched builds mean a rolling upgrade is in progress |
| Required features active | `active_features` from `/transactions/oracle/pending` must list `station_active_reward_gate`, `station_owner_actions`, `station_owner_consent` and `station_registration_nonce` | Stop |
| A form this tool can build | `station_coordinates_fixed_point` must not be active. From that feature a registration needs integer coordinates or it applies as nothing, and neither the exporter nor this tool builds them yet | Stop |
| Chain identity | `/network/info` must report 888/testnet and a positive height, and the export and the signed artifact must agree | Stop |
| Trusted CLI | `--cli-sha` is required and must match. Take it from the build receipt of the release, never from the binary's own digest. Its `station build-registration` must accept `--batch` with `expected_nonce` | Stop |
| Governance key | The file must exist with mode 0600. Only the CLI reads it | Stop |
| Clocks | NTP synchronized, and the node's HTTP Date within five seconds of the host | Stop |
| Backend | `STATION_CHAIN_SYNC_ENABLED=true`, and the backend exposes the export script | Stop |
| Location | Every row sits on the 0.1 degree grid. On-chain coordinates are public forever | Stop, nothing signed |

A producer reading taken on another host (`--producer-reading NAME=REVISION@UNIX_SECONDS`)
is good for five minutes. It can't replace the direct read of the node this run submits to.
Where the key host can reach every producer, pass three `--producer` inputs instead;
staged runs require that, because a reading would go stale before the step runs.

**This tool does not schedule features and doesn't change key custody.** The default key
path is `/root/oracle-ceremony/oracle-governance.key` and its public key is
`e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00`, the same key
`chain-888.conf` lists for governance.

Default containers are `wrfcoin-testnet-backend`, `wrfcoin-testnet-node` and
`wrfcoin-testnet-postgres`; the node URL defaults to `http://127.0.0.1:8556`. A remote
node requires HTTPS.

## What a dry run touches

A dry run signs nothing and sends no POST. It reads container labels and env, public and
gated node routes, and one `SELECT` from Postgres. It also runs the export script without
`--mark-submitted`, which writes no database row but does write two short-lived files in the
backend container's `/tmp`, deleted straight after.

## What a run ends with on chain 888: always exit 3

Chain 888 uses the v2 registration format, and no route can say a given registration
applied. So a real run on 888 never prints `ACTIVATION OBSERVED`. It prints
`ACTIVATION UNVERIFIED`, a HANDOFF list, one `SYNC NOW` count and exits 3. **That is the
expected end of a good run, not a failure. Don't resubmit.**

Then read back each row, with the receipt's `transaction_ids`:

1. `GET /transactions/<id>/status` shows the transaction in a block.
2. `GET /transactions/station/registrations/<station>/owner-ledger` shows `owner_nonce`
   advanced to `expected_nonce + 1`. A v2 registration that was refused is mined as a no-op
   and leaves the nonce alone.
3. `GET /transactions/station/registrations/<station>` shows the right owner, `real`, active.
4. The backend shows the row `on_chain` once its sync has run, and the phone's status follows.

Only then record it with `--mark-reconciled` (below).

## Run one batch

### Stage one-line owner steps for N phones

Only where the key host can reach all three producers. From the installed infra checkout on the governance key host, create a new private
step directory. For 30 phones this writes four scripts: dry-run then activation
for 21 rows, followed by dry-run then activation for nine rows.

```bash
bash testnet/scripts/activate-mobile-stations.sh --cli <CLI path> --cli-sha <digest from the build receipt> \
  --producer <name1>=<container1> --producer <name2>=<container2> --producer <name3>=<container3> \
  --stage-dir /root/msr-steps-batch1 --count 30
```

Staging is offline: it writes scripts and a README without invoking Docker,
curl, the CLI or reading the governance key. The directory must be new; it is
0700 and its step files are 0700. The source checkout must stay installed at
the same path until the owner finishes.
Relative CLI/key arguments are made absolute using the staging invocation's
directory, before the owner steps change into their private directory.
Inspect the generated files, then run the one-line commands in its README,
in order:

```bash
bash /root/msr-steps-batch1/001-dry-run.sh
bash /root/msr-steps-batch1/002-activate.sh
bash /root/msr-steps-batch1/003-dry-run.sh
bash /root/msr-steps-batch1/004-activate.sh
```

`--count` is the requested total; each staged step requires its full batch count.
Each batch uses at most `--limit` (default21, maximum21). If fewer eligible rows
exist, the staged step stops before signing; the manager must inspect skipped
rows or adjust the requested total in a new directory. The next batch
requires the previous activation's full inclusion and sync (`ACTIVATION OBSERVED`, or a manager-confirmed `--mark-reconciled`). Dry-run reads
the next pending batch, verifies preconditions and the exporter's ownership
checks, and cleans its export files. It never signs or sends a POST; real CLI
signature/size validation occurs only during activation. An independent
single-batch preview is available with `--dry-run` and the usual CLI arguments.

Activation repeats preflight and export with a fresh stamp. A private attempted
marker is recorded before invocation, so a failed or successful activation
cannot be repeated from this directory. Any failure requires manager readback
before staging a new directory. This marker also prevents simultaneous owner
invocations from running the same staged activation twice. No stage generates
keys, changes DB status or automatically retries submission.

Per-row progress uses one-based indexes into the private exported batch:
`ROW 1/21: active`, `ROW 1/21: pending sync`, or `ROW 1/21: on_chain`.
The sync read checks each station's owner binding and status independently.
No station IDs, coordinates or credentials are printed. These rows are progress
evidence for the current batch; the final aggregate line still requires all rows.

From the staged infra checkout on the key host:

```bash
bash testnet/scripts/activate-mobile-stations.sh \
  --cli <CLI path> --cli-sha <digest from the build receipt> --limit 21 \
  --producer <name1>=<container1> --producer <name2>=<container2> --producer <name3>=<container3>
```

The limit defaults to21 and accepts1..21. core4#3388 measured21 realistic rows as
62,631 bytes and22 as65,609, above the64KiB artifact ceiling. Actual CLI output
size remains authoritative: the wrapper checks the artifact before submission.
Smaller limits are useful for the first batch. Other owner options are
`--governance-key`, `--governance-pubkey`, `--node-url`, `--backend-container`,
`--node-container` and `--postgres-container`; `--help` lists them.

Each real run asks for YES after preflight, before the signing window opens. Anything but YES stops it, and so does running without a terminal. In a staged step that attempt counts as used, so stage a new directory.

Preflight reads the oldest pending IDs and requires HTTP404 for each. If any
`db_only` station is already registered, it stops for manager readback/sync.
The export uses `--cli-batch-out` and a single fresh `--submitted-at`, preserves
the exact ten-field phone schema and order, and checks that exported IDs were
preflighted. It never passes `--mark-submitted` or updates the database. The
trusted CLI verifies ownership proofs and signs all rows as one batch; an
invalid row prevents submission. Only the three-field chain/network/transactions
projection goes to the node. HTTP201 and `accepted == K` are mandatory.

Normal output has this shape (numbers vary):

```text
PREFLIGHT PASS: clock, node, sync, CLI and key modes
EXPORTED: 21 rows
BUILT: 21 transactions; 62631 bytes
SUBMITTED: 21 accepted; HTTP 201
INCLUSION: 21/21 active, 0 unverified, 0 pending; attempt 1
SYNC: 21/21 on_chain; attempt 1
ACTIVATION OBSERVED: 21/21 stations active in the node registry and on_chain in the backend (observed state; NOT proof that this run's transaction applied)
```

No token, key, environment value, coordinate, raw response or tool
stderr is printed. The Operator token is read from the node container into
process memory and sent through curl config on stdin, never as a command-line
argument, exported variable or credential file. Do not enable Python tracing or
change capture behavior while running with real data.

## Window and explicit restamping

The150-second window covers stamped export, signing and submission. Inclusion
and backend sync happen after admission and can take longer. Each stamp is
checked for expiry and backward clock movement before export/build/POST. A
build older than100 seconds stops; the final POST guard is120 seconds, with a
ten-second HTTP timeout and spare admission margin. An already-expired stamp
stops even if restamping was requested. A build command times out after60
seconds, so the same guards also handle a slow export plus build.

To allow one fresh stamp and rebuild while a still-valid build is older than100
seconds, choose the fallback explicitly at invocation:

```bash
bash testnet/scripts/activate-mobile-stations.sh \
  --cli <CLI path> --cli-sha <digest from the build receipt> --limit 21 --restamp-once
```

Restamping changes every row's timestamp and signs a fresh artifact before the
first POST. There is at most one POST per invocation. A422, accepted-count
mismatch or ambiguous transport result stops for manager readback; it does not
restamp and retry a possibly admitted batch. `--submitted-at <unix-seconds>` is
an explicit diagnostic override, with the same guards; routine runs use the
fresh default.

## Wait for the batch, then export the next

After 201 the wrapper reads each station's ID, owner, `real` provenance and
active state, up to six rounds with 60-second waits, then the batch's database
`on_chain` count up to twelve rounds with 60-second waits.

**What the success line means (v1 rehearsal chains only).** `ACTIVATION OBSERVED: K/K stations active in the
node registry and on_chain in the backend` says only that those K stations are
active in the registry and registered to their owners, and that the backend
shows them `on_chain`. It is an observation of station state. It is NOT proof
that this run's transaction applied (a competing same-owner v1 registration, or
a v2 owner action, can produce the same state), and the tool never says
"applied". There is no `ACTIVATION PASS`. It does not claim multi-node
consensus or an accepted phone reading; the manager performs those checks.

A v2 batch never reaches that line: its rows are UNVERIFIED (see the Registration
format section) and the run ends with `ACTIVATION UNVERIFIED` and exit **3**.

**Manager handoff (exit 3).** The receipt below is written for every batch, so any
stop after a possible POST also leaves it; the station list is printed on exit 3 only.
- The run prints `HANDOFF: batch <batch-id>; K rows` and one
  `HANDOFF ROW i/K: <station id> owner <0x + 6 hex>... <state>` line per row.
  Station IDs are the registry's own identifiers; owners are a short prefix;
  coordinates and signatures are never printed or stored in the receipt.
- A durable receipt `<batch-id>.receipt.json` (0600, in `--receipt-dir`, default
  `./msr-receipts`; the staged steps use the staging directory) is written before
  signing, before the POST and after each poll, and survives the run. The
  coordinate-bearing working files (`cli.json`, `artifact.json`, `submit.json`)
  are still removed after the POST for privacy; the receipt plus the registry
  is what the manager reconciles against.
- The manager verifies each listed station against block/state-transition
  evidence. Only then does the owner record it, offline, with no POST:

```bash
bash testnet/scripts/activate-mobile-stations.sh --mark-reconciled <batch-id> \
  --receipt-dir <the same dir> --confirmed-rows <exact row count in the receipt>
```

  This needs no CLI, key or node. It refuses unless the count equals the
  receipt's row count, the batch is awaiting readback, and no marker exists yet;
  it then writes the staged `batch-N.complete` so the next staged batch may
  proceed, and marks the receipt `reconciled`. It never resubmits.

For N invitees, run `ceil(N/21)` batches. A staged batch's activate step stops
at exit 3 and the next staged step refuses until the batch is complete: either
the run ended with `ACTIVATION OBSERVED` (v1) or the manager's readback was
recorded with `--mark-reconciled`. Thirty invitees need two batches. The exporter
selects `db_only`, so a completed sync removes rows from the next export. Do not
run concurrent wrappers: they can select the same pending rows. If there are no
exportable rows or ownership validation skips all rows, export stops.

On any stop after a possible POST, ask the manager to read the registry/mempool
and sync state before a fresh invocation. After an inclusion or sync timeout,
wait for diagnosis; do not resubmit blindly or edit DB statuses. Before any
POST, a stopped run can be restarted after its reported cause is corrected.

## Private files and offline evidence

Every invocation uses its own0700 directory and0600 files. Linux defaults to
`/dev/shm` when available; an owner-set `TMPDIR` overrides it. Keep that override
on private RAM-backed storage for real activation data. Container export files
use the backend's `/tmp` tmpfs and are removed immediately after extraction,
before signing. Local coordinate-bearing files are unlinked immediately after
201, before long polling, and remaining files are cleaned on success, failure,
SIGINT or SIGTERM. A cleanup failure stops before signing. SIGKILL or power loss
cannot execute cleanup; the manager must inspect and remove that invocation's
private files before restarting. This procedure does not claim secure erasure
on disk-backed storage.

The offline shell entrypoint exercises fake Docker/CLI/curl/clock commands and
opens no sockets:

```bash
bash scripts/tests/test-mobile-station-activation.sh
```

The corpus includes distinct2/21-row batches, exact projection, private modes,
expired stamps, one explicit restamp, clock/health/identity failures, already
registered stations, export/build/self-verification/size failures, cleanup and
interruption, HTTP rejection/ambiguity, inclusion/sync timeouts, bad limits and
secret/coordinate output sentinels. It is automatically discovered by the
existing scripts-tests workflow. Fakes prove wrapper control flow; actual
signatures, node acceptance, deployed sync and runtime timing remain owner-only
verification. No host or live network operation was used to develop this script.

## Registration format: v1 now, v2 from `station_registration_nonce` (core4#3345)

Once core4's `station_registration_nonce` feature is scheduled and active, the
node refuses the v1 governance registration format entirely and accepts only v2,
which carries a signed `expected_nonce` equal to the station's current owner-ledger
nonce. A v1 batch built after that point is refused at submission
(`STATION_REGISTRATION_V1_REFUSED`); a v2 batch built before it is refused
(`STATION_REGISTRATION_NONCE_FEATURE_INACTIVE`). The wrapper therefore picks the
format itself.

- `--registration-format auto` (default) reads the node's `active_features`
  (`/transactions/oracle/pending`, the height the next block mines at) and builds
  v2 when `station_registration_nonce` is active, otherwise v1. So `auto` stays
  v1 until the feature has actually activated; it cannot show v2 earlier. It prints
  `FORMAT: v1|v2 registrations`. `v1` / `v2` force a format for a rehearsal.
- v2 reads each station's nonce **fresh, one row at a time, immediately before
  signing that row** (one CLI invocation per row; the signed transactions are
  merged into one submission and one POST), from
  `GET /transactions/station/registrations/{id}/owner-ledger`
  (`owner_ledger.owner_nonce`). A station the node reports as not registered
  has no ledger entry, so its first registration uses 0. Any other outcome
  (transport error, other status, unknown route, a malformed or negative
  nonce, another station's answer) **stops the run before anything is signed**:
  a guessed nonce would be mined as a silent no-op. The nonce is read again on a
  restamped rebuild.
- v2 needs a CLI whose `build-registration` accepts `expected_nonce` per batch row.
- `/readyz` and `/network/info` are public and are read
  WITHOUT an `Authorization` header. Reader-gated routes (station registry,
  owner ledger, oracle status) keep the bearer, passed through curl config on
  stdin only.

`testnet/scripts/revendor-core4-fixture.py` re-vendors core4's golden vectors
(`testnet/fixtures/core4/`) with a full-commit provenance manifest; re-run it
with `--rev` set to the core4 merge commit on main before this change merges.

## Real-CLI smoke (opt-in)

The default harness uses a fake CLI. To exercise the real pinned binary against
throwaway keys in a scratch directory (no node, no network):

```bash
WRFCOIN_REAL_CLI=/path/to/wrfcoin bash testnet/tests/test_real_cli_smoke.sh
```

It builds v1 and v2 (`--expected-nonce`) registrations and every owner-action
artifact, checks each parses with the expected kind, action, nonce and id, and
prints the binary's sha256. Without the variable it is SKIPPED with exit 77
(reported as UNVERIFIED/not checked, never as a pass or coverage).

`test_real_cli_activation.sh` (same variable) drives the script's own `build()`
and `submit_batch()` with the real CLI against a stub node: a first registration
(nonce 0), a re-registration at the ledger's reported nonce, a mixed batch, and
a stale-nonce submit that the stub refuses (HTTP 422,
`STATION_REGISTRATION_NONCE_MISMATCH`, as core4 admission does) and the script
must surface as `Stop: submission refused`, plus the read-back after a 201: a
registration the node accepted and then dropped at apply is never counted.

**The tool cannot tell which registration applied.** core4 has no
route that identifies an applied registration: the station record keeps no
registration tx id or inclusion height, the owner ledger has no last-applied
registration identity, and `/transactions/{id}/status` only says a tx is in a
block (an included v2 registration can still be an inert no-op). Nonce, ledger
and registry state are all reachable by other transactions (an owner Reactivate
consumes the nonce on a clean ledger; a competing same-owner registration
consumes nonce 0), so the tool never infers "applied" for a v2 row. Read-back
reports each row as `pending` (not in the registry), or `UNVERIFIED` (a record
exists). When no row is pending but any v2 row is UNVERIFIED, the run prints
`ACTIVATION UNVERIFIED: ...` and exits **3** (distinct from the stop code 1 and
from 0): this is NOT a pass, backend sync is not checked, and the owner hands the
list to the manager for readback (block/state-transition evidence). Never
resubmit. A v1 row (no signed nonce) with an active, owner-registered record
is reported as `station active, registered to owner (observed state; not proof
this run applied)`, because a competing v1 registration can create the same
record; only v1 batches can end with `ACTIVATION OBSERVED` and exit 0. The stub applies the nonce rule itself; docker/psql
are not involved, so `activate()` is not run whole.
