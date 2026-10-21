# Owner command: activate a batch of phone stations

The owner runs `testnet/scripts/activate-mobile-stations.sh` on the host with the
governance key. CT101 is the documented default. The host can be changed using the
container, node URL and key-path arguments; the wrapper does not use SSH or `pct`.
Running this command signs and submits registrations to chain 777/testnet. The
review point is before invoking it. A successful submission has no local undo.

This implements the export → build → project → submit → inclusion → backend-sync
order in the LEAD-verified
`wrfcoin/docs/plans/overnight-2026-09-24/mobile-station-activation-owner-block-v2.md`.
The earlier manual block remains the manager's source record. This wrapper
captures every tool's output privately and reports stages and counts only.

## Prepare on the chosen key host

The manager must have completed the r17 deployment and checked its image/revision
and mobile export/sync configuration. The backend must expose the CLI batch
export flags and have `STATION_CHAIN_SYNC_ENABLED=true`. The calibrated export
guard (backend#1374) is recommended: the wrapper passes `--limit 21` and enforces
the returned count itself. Invitees need the APK with quantized reveals
(mobile#362), and the backend needs the matching quantization (backend#1343).
Use the manager's deployment and CLI-staging blocks; this wrapper stages neither.
Keep activation outside the E0/redeploy/restart window.

**This tool does not schedule features.** It submits registrations only. The
`station_registration_nonce`, `station_owner_consent`, `station_owner_actions`
and `station_active_reward_gate` schedule extension (height, run-up, horizon,
entry count, signed receipt) is a separate, separately reviewed packet.

**Three-producer fence (required, fail closed).** Every run, including dry-runs,
takes exactly three `--producer NAME=CONTAINER` (or
`NAME=DOCKER_HOST::CONTAINER` for a producer on another Docker host) inputs and
reads each container's `org.opencontainers.image.revision` label BEFORE any token
read, signature or submission. It stops unless all three equal
`620902bf7b01cf09b11b2bb0ff5a22571e7cb694`; a missing label, an old revision or
a failed read on any one refuses. Three names for the same host+container are
rejected: three reads of one producer cannot establish three revisions. Endpoints are inputs, never defaults. (core4
`620902bf7` exposes no tokenless build revision: `/network/info` reports only
the crate version and `/network/upgrade` the signed notice's commit, not the
running binary's, so the image label is the reading.)

Install this script and its adjacent Python file together in the infra checkout
on the key host. It requires Bash, Python3.8+, Docker, curl, `date`, `sleep` and
`timedatectl`. NTP must report synchronized. The node's HTTP Date must be within
five seconds of the host clock; `/readyz` must return200 and `/network/info` must
report chain777/testnet and a positive height. A missing clock header stops the
command. On a host without systemd, arrange a reviewed clock-check implementation
before use; do not substitute a fake for an actual activation.

The default governance key path is
`/root/oracle-ceremony/oracle-governance.key`, mode0600. The wrapper checks its
mode; only the trusted CLI reads its contents. Its public key is the v2 block's
`e7bec166ad446314d26fb7526bfa8cec1b363b438440262fb001f7b04b20bf00`.
The staged CLI is checked against the full SHA256
`604af0308e57d9ae82b75da9b8845fb7f440e2ed55a7f15671dd92d4b0d0a3d7`, built from
core4 620902bf7 per the authoring lane (`cargo build --release`, not
byte-reproducible; that origin is not independently verified; stage that exact file).
**The owner must stage an artifact whose SHA256 matches this pin, with its build
receipt.** Two digests exist for core4 `620902bf7`, and neither build is
byte-reproducible: `604af030...` (the pin, origin of that artifact not
independently verified) and `b76a8a9aaaf8ad554ebd2786ca3ec2385e59484c483c768f64e37b26cdb1de87`
(an independent reviewer's `cargo build --release --locked --offline -p wrfcoin_cli
--bin wrfcoin` of that commit; it passed the real-CLI tests). The tool uses the
pin `604af030...`; the reviewer's build is recorded for comparison only and is
used only if the manager passes it with `--cli-sha`.
`--cli-sha` is for a replacement the manager has independently verified and trusted. Never fill it from an untrusted binary's own digest.

Default containers are `wrfcoin-testnet-backend`, `wrfcoin-testnet-node` and
`wrfcoin-testnet-postgres`; the node URL defaults to `http://127.0.0.1:8556`.
The PostgreSQL read uses database/user `wrfcoin`. `Host: 127.0.0.1` follows the
v2 block's node allowlist for loopback URLs only. For remote HTTPS URLs, curl
uses the URL's host without an override, allowing a fronting proxy to route it.
HTTP is permitted only for loopback hosts; a remote node requires HTTPS.
The owner decides whether the chosen key host can reach these containers and
this endpoint.

## Run one batch

### Stage one-line owner steps for N phones

From the installed infra checkout on the governance key host, create a new private
step directory. For 30 phones this writes four scripts: dry-run then activation
for 21 rows, followed by dry-run then activation for nine rows.

```bash
bash testnet/scripts/activate-mobile-stations.sh --cli /root/msr-cli/wrfcoin-msr-b21b0b8dc \
  --producer <name1>=<container1> --producer <name2>=<container2> --producer <name3>=<container3> \
  --stage-dir /root/msr-steps-r19 --count 30
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
bash /root/msr-steps-r19/001-dry-run.sh
bash /root/msr-steps-r19/002-activate.sh
bash /root/msr-steps-r19/003-dry-run.sh
bash /root/msr-steps-r19/004-activate.sh
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

From the staged infra checkout on CT101, after the manager's preparation:

```bash
bash testnet/scripts/activate-mobile-stations.sh \
  --cli /root/msr-cli/wrfcoin-msr-b21b0b8dc --limit 21 \
  --producer <name1>=<container1> --producer <name2>=<container2> --producer <name3>=<container3>
```

The limit defaults to21 and accepts1..21. core4#3388 measured21 realistic rows as
62,631 bytes and22 as65,609, above the64KiB artifact ceiling. Actual CLI output
size remains authoritative: the wrapper checks the artifact before submission.
Smaller limits are useful for the first batch. Other owner options are
`--governance-key`, `--governance-pubkey`, `--node-url`, `--backend-container`,
`--node-container` and `--postgres-container`; `--help` lists them.

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
  --cli /root/msr-cli/wrfcoin-msr-b21b0b8dc --limit 21 --restamp-once
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

**What the success line means.** `ACTIVATION OBSERVED: K/K stations active in the
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
  (`/transactions/oracle/status`, the height the next block mines at) and builds
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
- v2 needs a CLI whose `build-registration` accepts `expected_nonce` per batch
  row. The built-in `--cli-sha` pin below is the core4 `620902bf7` build, which
  does; the pin is always enforced and no extra flag is needed.
- `/readyz` and `/network/info` are public on core4 `620902bf7` and are read
  WITHOUT an `Authorization` header. Reader-gated routes (station registry,
  owner ledger, oracle status) keep the bearer, passed through curl config on
  stdin only.

Ordering (do not reorder): (1) core4 `620902bf7` is running on all three
producers and the CLI is staged; (2) THIS change merges, while the feature is
still unscheduled (auto keeps building v1, so nothing changes); (3) the
separate scheduling packet schedules the features; (4) `auto` stays v1 until
the activation height has passed and the node reports
`station_registration_nonce` active; only then does it print `FORMAT: v2`.
(A forced `--registration-format v2` before activation is refused by the node.) Do not run a registration
batch in the blocks around the activation height: a batch admitted just before it
can be mined after it. After activation every v1 pipeline stops working at once.

`testnet/scripts/revendor-core4-fixture.py` re-vendors core4's golden vectors
(`testnet/fixtures/core4/`) with a full-commit provenance manifest; re-run it
with `--rev` set to the core4 merge commit on main before this change merges.

## When the v2 activation run may happen (r20.2 rolling-upgrade conditions)

Per `r23/rolling-upgrade-b31-to-main-audit.md`, B3.1 to main (core4 `620902bf7`)
is rolling-safe only with these conditions. Run this script in v2 mode only
when ALL of them hold:

1. All three nodes are verified running core4 `620902bf7`. The tool enforces
   this itself (the three-producer fence above); `PROTOCOL_VERSION` is 3 on both
   B3.1 and main, so the protocol version cannot tell them apart.
2. The features are scheduled by the separate packet AND have activated
   (`GET /transactions/oracle/status` lists `station_registration_nonce` as
   active). Until then `--registration-format auto` stays on v1.
3. The first v2 registration or owner transaction is the point where rolling
   back to B3.1 stops being possible: the first non-empty owner ledger writes
   v11 checkpoints that B3.1 binaries refuse. Do not run it as a trial.

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

**The tool cannot tell which registration applied.** core4 `620902bf7` has no
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
