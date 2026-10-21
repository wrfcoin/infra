# Owner-run advisory reference scoring (Refs infra#972)

This packet enables the existing backend `ReferenceShadowScorer` hook. After a
normal reveal is accepted by core4 and finalized locally, the hook requests
`/v1/residuals` from oracle-reference and inserts an observational
`reference_scores` row. These steps submit no commitments, reveals, transfers,
reward claims or schedule entries. Only the owner runs the Docker commands.

Prepare after the reviewed backend image is deployed with `REFERENCE_SHADOW=0`.
Use a deploy window: enabling recreates the backend and starts the sidecar.
The sidecar may consume up to 2 GiB RAM and uses a 10 GB model cache. Its normal
model/data requests can transfer substantial data: prepare the cache separately
under the owner's network budget. The packet never builds or pulls images.
Scoring can add up to the configured reference timeout to each reveal; failures
remain advisory and do not reverse reveal finalization or change rewards.

The owner must review the actual backend and sidecar source/image pair before
installing. Backend bands v3 and `second_worst` are required here. The flag probe
works from `/app/backend` in both the source API and slim bundle images without
importing the scorer or starting another API process. Both images ship `pg` at
that package root. Bands v3 is checked on newly persisted rows; fold-rule
provenance comes from the owner-reviewed source/image pair. Source parity alone does not establish
deployed consensus parity: pressure/reference-source pairing and the feature
schedule need separate science/owner review. This packet collects plumbing
evidence only, suitable for that later review; it never authorizes enforcement.

1. Stage this reviewed infra checkout on the deployment host. Copy
   `owner-config.example.json` outside Git, e.g. into an owner-only directory;
   set its mode to 0600. Set `compose_files` to the **complete ordered original
   deployment inputs**, including host and image overrides, then append the
   shipped `docker-compose.reference-shadow.yml` last. This last overlay is
   required byte for byte. Keep the base Compose first. Do not copy environment
   values into the packet. Owner inputs and generated receipts stay outside Git.
2. Put both owner-reviewed, already-cached immutable image IDs (`sha256:` plus
   64 hex digits) in the config. Existing backend must run that same backend
   image, healthy, with the flag off and the original input-set config hash.
   Its `reference_scores` table must already exist. These steps never migrate
   or seed the database. If preparation stops, complete the reviewed app/image
   deployment separately, then use a new attempt receipt.
3. Invoke the three scripts below from the infra checkout. Paths are absolute;
   each receipt/evidence path must be new. Keep the same config and receipt for
   all three steps. Step 01 leaves the flag off. Run step 02 within 30 minutes.
   Step 02 waits up to 60 seconds for the two containers to become healthy;
   a timeout may leave started containers behind. Inspect privately and retry
   the enable step in the same window, or perform the original-set rollback.
4. Wait for **normal accepted station reveals**; the packet never manufactures
   traffic. Then run 03. Zero new persisted scores is STOP. Existing rows,
   healthy containers, unavailable reference data or unjoined/non-finalized rows
   cannot satisfy the proof. The hook covers the backend commit/reveal path;
   traffic exclusively using another ingest path will not create these rows.
   Check that path before waiting. Do not infer a sidecar/scorer failure from
   an idle reveal pipeline.

```bash
bash testnet/owner-steps/reference-shadow/01-prepare.sh /private/config.json /private/attempt-01.json
bash testnet/owner-steps/reference-shadow/02-enable.sh /private/config.json /private/attempt-01.json
bash testnet/owner-steps/reference-shadow/03-record.sh /private/config.json /private/attempt-01.json /private/result-01.json
```

Preparation snapshots the score-table max ID and database timestamp. Recording
requires every newly added row to have matching station/commitment identity,
`revealed` status, a timestamp after the baseline, bands v3, a recognized tier
and at least one actual reference residual. The verification connection uses
`BEGIN READ ONLY`, a 5-second statement timeout and a 3-second connect timeout.
It writes only private local aggregate receipts; the existing hook durably
writes the score table. No station IDs, coordinates, readings, residuals,
environment arrays or Docker health-log bodies are exported. The receipt
records input digests, effective Compose hashes, time and aggregate tier counts.
Score-table contents remain private. A recording retry needs a new result path;
the baseline and prior results are never overwritten.

Disable/rollback in a separate owner deploy action: use the identical original
ordered Compose files **without** the shadow overlay, and recreate only
`wrfcoin-backend` with `up -d --no-deps --no-build --pull never wrfcoin-backend`.
Verify its process has `REFERENCE_SHADOW=0`. The original environment must also
leave that flag off. Keep persisted score rows and evidence. Stop the sidecar
only if it is solely owned by this observation window. This package installs
no boot-heal input or timer; it cannot enable itself after a reboot.

Local acceptance uses the actual CLI with Docker/DB doubles, including a real
Node execution of the read-only SQL transport. Actual owner installation,
reference data availability and first durable live score remain unverified
until step 03 succeeds on the deployment host.
