# DRAFT r20 IPFS owner steps

Refs #944. Local render evidence only. This packet does not authorize
deployment and executes no startup command. CR-2 reviews it. This is an r20
packet: r19 is deployed (10-05) without storage, so the r19 stage below only
renders the daemon pair for a later owner decision.

Merged prerequisites (cite, do not wait for): infra#1174 and infra#1177
(the named `storage-node`, `ipfs-kubo`, `weather-ipfs-archive` services and
profiles), backend#1423 (archive worker; includes the #1421 work), backend#1439
plus infra#1241 (mock storage retired; `wrfcoin-storage` is gone from main's
compose files), and storage-providers#82 (the daemon client). This packet adds
neither a daemon definition nor a profile. The only new compose file is a tail
override of the existing worker's environment. Include it only in the selected
owner's compose chain. The ordinary testnet chain is unchanged.

The backend switch is **`WRFCOIN_WEATHER_ARCHIVE_ENABLED`**: empty means off;
only exactly `true` runs the archive worker. **`WRFCOIN_STORAGE_NODE_URL`** is
`http://storage-node:7001`, consumed by the merged storage-providers client.
The tail overlay pins that endpoint and keeps `ENABLE_REAL_STORAGE=false`.
That older switch operates a different multi-provider client, including paid
providers; it does not redirect the mock to storage-node.

The legacy `/storage/*` HTTP contract (the retired mock) had no compatible
env-only adapter and no longer exists. The first real backend consumer here is
the released-weather archive worker. The planner's r20 check that the base has
no `wrfcoin-storage` is a regression guard: it refuses only if the retired mock
ever reappears; on current main it passes without proving anything further.

Remaining before either owner phase: reviewed r20 image/pin inputs, including
a cached backend image containing `dist/weather_ipfs_archive.cjs` and a daemon
built from reviewed storage-providers source. Coordinate revision-label/pin
verification with SOL-K's Round16 checker. Do not substitute an image's tag for
its reviewed source revision. Build/cache preparation belongs to the owner's
release procedure; commands below never build or pull images.

For r20 also require: migration `0028_weather_archive_day_index` successfully
applied after the release table migration, healthy PostgreSQL, writable uid/gid
1001:1001 receipt storage, and owner runtime evidence. The index build blocks
table writes during its migration transaction. Stop if any item lacks evidence.
The planner checks rendered migration wiring, not database execution, image
contents, running state or approval.

Compose chain scope: the planner's `-f` set (testnet, override, weather-archive,
storage-owner) is a subset of the live chain, which also includes
`docker-compose.local-paths.yml` and others. The printed commands name their
services and use `--no-deps`, so nothing else is recreated. Checked against main:
`docker-compose.local-paths.yml` defines none of `ipfs-kubo`, `storage-node` or
`weather-ipfs-archive`. Never add a bare `up` to this chain. The owner must use
the same compose project name as the live stack: the planner prints `-p testnet`
on every command (its `PROJECT` constant); do not override it with
`COMPOSE_PROJECT_NAME` or a different `-p`.

From the reviewed infra checkout, generate the r19 draft with the existing
deployment env file (never copy it into source or an evidence directory):

```sh
python3 scripts/plan-storage-owner.py --env-file /private/owner.env --stage r19
```

`STORAGE_OWNER=PASS render-only` means the model is valid, not that storage runs.
After owner authorization and the release prerequisites, execute the printed
named-only `up` for `ipfs-kubo storage-node`; then the printed bounded read-only
health probe from the existing backend. It must report `STORAGE_HEALTH=PASS`.
The probe reads `/health` once with a five-second timeout. If it fails, stop:
do not enable the worker or use synthetic traffic as an availability proof.
No broad `up` or synthetic profile invocation is part of this procedure.

For r20, after the remaining prerequisites, generate the explicit switch plan:

```sh
python3 scripts/plan-storage-owner.py --env-file /private/owner.env --stage r20 --archive-enable true
```

Repeat the printed storage health probe before executing the final named worker
startup. `--no-deps` requires the owner to verify the migration/DB/storage barriers
first; it deliberately prevents unplanned dependency startup. Every printed
invocation carries the exact archive value and clears inherited `COMPOSE_PROFILES`.
Both existing profiles are specified to keep cross-profile dependencies valid;
explicit targets and `--no-deps` select only the named service(s). No other
service, node, collector or funded operation is selected.

After normal released data arrives, verify a fresh durable per-day CID receipt
and its available IPFS bytes using the existing archive contract. Empty data or
a healthy container alone is not archival proof. Retain receipts and private
Kubo volume together under the reviewed backup policy. Kubo has no host API port
or Internet/P2P route: remote replication is not provided.

If the worker fails, stop only `weather-ipfs-archive` using the same compose
chain; retain both receipt and Kubo volumes. Restore the switch to empty in the
next owner plan. The retired mock does not exist as a fallback. Actual startup,
volume permissions, PostgreSQL query plans, Kubo persistence and the first CID
remain owner-run checks, unverified by this draft.
