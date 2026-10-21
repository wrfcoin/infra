# Publishing the join snapshot (infra#587, infra#1057)

A brand-new node cannot full-sync this chain (core4#2806), so self-serve joining
depends on a published snapshot at `/join/manifest.json` and `/join/snapshot.tar.gz`.
This page covers where that snapshot is produced, where it is stored, and which
steps need the owner present.

## Where things live

| What | Where | Why |
|---|---|---|
| Producer | **node container**, from the deployed infra tree (`$HOME/wrfcoin-deploy/infra/testnet`) | The publisher copies `wrfcoin.redb` out of the `wrfcoin-testnet-seed` container's volume and reads the node API on `127.0.0.1`. Only node container has both. |
| Served directory | `WRFCOIN_JOIN_SNAPSHOT_DIR`, default **`/var/lib/wrfcoin-testnet-join/public`** | Outside `infra.releases/`, so a release flip leaves it in place. It follows the sibling `/srv/status` mount (`/var/lib/wrfcoin-testnet-uptime/public`): a dedicated `/var/lib/<unit>/public` directory that holds only public, served bytes. It is not under `operator-state/`, because that directory holds `.env` secrets and must never be bind-mounted into a public edge. |
| Edge mount | `funnel-edge`: `${WRFCOIN_JOIN_SNAPSHOT_DIR:-/var/lib/wrfcoin-testnet-join/public}:/srv/join:ro` | Compose is the only thing that resolves this variable, including inline comments, interpolation and empty overrides. |
| Publisher destination | the **running** `funnel-edge` container's `/srv/join` mount source (`docker inspect`) | The publisher parses no env file. It writes where the edge actually serves, so the two cannot disagree. `scripts/tests/test-join-snapshot.sh` checks this against real `docker compose config` renders. |

**Not build runner.** build runner is the `gh-runner` CI container. It has no seed, no chain data and no
node API, so the snapshot cannot be produced there. Nothing needs building either: the
publisher is a shell script, and the edge keeps its existing image. Only the edge's bind
mount changes.

A missing or empty directory makes `/join/*` return 404. That fail-closed default comes from
the Caddyfile (`public_onboarding.caddy`, `@join_artifacts`) and is unchanged.

## Trust model: hash-bound, unsigned (owner ruling, 2026-09-26)

For the **tailnet testnet**, the join snapshot is **hash-bound and unsigned**. There is no
signing key. The owner ruled this during the infra#1061 work.

**The trust root is `manifest.json`, served over TLS by the testnet edge** at its `*.ts.net`
origin, which uses a Tailscale-issued certificate. Everything else hangs off that manifest.
A joiner (`join.sh` → `join-testnet-sync-node.sh` → `join-snapshot-restore.sh`) checks all of
the following **before any Docker volume is created**, and refuses on the first failure:

- `sha256` of the downloaded `snapshot.tar.gz` equals the manifest's `sha256`. This catches a
  tampered or truncated archive, or an archive that doesn't match its manifest.
- The archive holds exactly one regular root file, `wrfcoin.redb`: no links, extra members or
  traversal.
- `genesis_hash`, `chain_id` and `network_id` equal `cut-pins.env`.
- `core4_commit` equals `WRFCOIN_CUT_CORE4_COMMIT` in `cut-pins.env`. The publisher writes it
  from the source container's `org.opencontainers.image.revision` label and refuses a source
  without a full-SHA label. A joiner builds the pinned core4, so a snapshot produced by a
  different build is refused with "the network is mid-upgrade; retry after the new join
  snapshot is published". A legacy manifest without the field is refused too, unless the
  joiner sets `WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT=1` (never overrides a mismatch).
  After a core4 upgrade, republish the snapshot from the upgraded node before moving the pin.
- `height > 11017`, and `state_root_hex` is well formed.

The producer binds the manifest to the bytes. `publish-join-snapshot.sh` writes the archive's
`sha256` together with the `height` and `state_root_hex` **of the frozen copy itself**, plus the
genesis and chain identity (infra#1061). Those values are read from a throwaway node that boots
on a scratch copy of exactly those bytes, not from any live node. Two live reads before and after
a restart are not proof: a restarted seed can load different durable state and sync back to the
same tip before it first answers.

What this does **not** defend against: anyone who can change what the edge serves can
replace the manifest and archive together. That is exactly the gap a signature closes.
**Signing must be revisited before any public join.** Note that the edge is reached through
Tailscale Funnel, so `/join/*` can already be *downloaded* from the public internet, even
though joining the P2P network still requires the tailnet.

`WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS` (infra#979, plumbed by #1000) governs core4's signed
`/state/snapshot` **ingest**. That is a different mechanism, and this archive never passes
through it.

## No-restart source: a ZFS snapshot of the live node's volume (infra#1057)

The stop-copy-start flow below needs a running seed. On node container the seed has been
down since 2026-09-13 (its database is 13 days behind), and the producer must never
be stopped. The publisher therefore also takes an **immutable ZFS snapshot** as its
source. Nothing live is stopped, started or written:

| Step | Command | Who | Public effect |
|---|---|---|---|
| a | On the Proxmox host: `zfs snapshot tank/docker@join-<UTC>` | **owner** (host root) | none; atomic, instant |
| b | On node container: `install -d -m 0700 /var/lib/wrfcoin-testnet-join/staging` | **owner** (root) | none |
| c | On node container: `bash testnet/publish-join-snapshot.sh --from-snapshot /mnt/tank-docker/.zfs/snapshot/join-<UTC>/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb --stage-dir /var/lib/wrfcoin-testnet-join/staging` | owner (reads a secret) | none: the bundle is **staged**, not served |
| d | `bash testnet/promote-join-snapshot.sh --stage-dir /var/lib/wrfcoin-testnet-join/staging --dry-run` | agent or owner | none |
| e | `bash testnet/promote-join-snapshot.sh --stage-dir /var/lib/wrfcoin-testnet-join/staging` | **owner** (root; changes `/join/*`) | `/join/*` 404 → 200 |

What `--from-snapshot` enforces:

- `--stage-dir` is required. Snapshot mode never writes the served directory, and without
  it the publisher refuses before any Docker call.
- Provenance comes from the **kernel mount table** (`findmnt -T`), not from how the path is
  spelled:
  - The path must be canonical (`realpath -e` of it is itself), so no component may be a
    symlink.
  - The deepest mount holding the file must be `zfs`, with source exactly `<dataset>@<snap>`
    (a bind mount shows up as `<dev>[/subdir]` and is refused), a **read-only** superblock,
    and a mount point of `<m>/.zfs/snapshot/<snap>`.
  - `wrfcoin-testnet-node`'s `/app/data` must sit on that same `<dataset>`, mounted at `<m>`,
    at the same relative path.

  On node container that is `tank/docker@<snap>` at `/mnt/tank-docker/.zfs/snapshot/<snap>` (ro)
  against `tank/docker` at `/mnt/tank-docker`, as checked read-only on 2026-09-27. The mount
  is re-checked after the copy.
- Refused: an ordinary directory named `.zfs`, an ancestor symlink to the live volume, a
  bind mount or overmount of the live directory, a read-write mount, and another dataset.
- The copy is hashed against the snapshot file.
- The **same isolated frozen-copy node** as the seed flow must boot the bytes and answer the
  receipt twice. A ZFS snapshot is crash-consistent, not quiesced: if redb could not open
  that image, the verifier fails and nothing is staged.
- The verifier env is the node's, minus every `WRFCOIN_P2P_*`, `WRFCOIN_HSM_*`, the
  operator/oracle/contributor tokens, `DATABASE_URL`/`REDIS_URL`,
  `WRFCOIN_REQUIRE_PRODUCER_AUTH` and the snapshot signer key. The reader token is kept for
  the receipt.
- No live API is read. Identity, height and root come only from the frozen-copy receipt.

`--stage-dir` must be absolute and a real directory (not a symlink). It must not be the
directory the edge serves. It must also sit outside `*.releases/` and outside **every** git
checkout or worktree: a `.git` directory or file at or above it is refused. The same checkout
check applies to the served directory, in the publisher and in `promote-join-snapshot.sh`.
`promote-join-snapshot.sh` re-runs the **joiner's own checks** (`join-snapshot-restore.sh`) on
the staged pair (identity against `cut-pins.env`, sha256, one-regular-file shape), then
publishes it: archive first, manifest last, each renamed into place. It then re-hashes the
served pair.

`scripts/tests/test-join-snapshot.sh` also hands a publisher-produced, promoted bundle to
the #774 joiner e2e (`scripts/tests/test-join-sh-e2e.sh`, `JOIN_E2E_SNAPSHOT_DIR`). The real
`join.sh` chain must restore it, from a dir and over a URL.

## Prechecks (read-only)

1. **The seed is running on the release image.** The rc0926 runbook keeps `wrfcoin-seed`
   down until it is on the release image. The publisher now refuses a stopped seed, so it
   cannot start one that was deliberately left down. Until the seed is on the release image,
   publishing is blocked, and that is correct.
2. **The seed is near the producer's tip (freshness, not correctness).** The script enforces
   the receipt itself (infra#1061):
   - The live seed's own API (found via `docker port`, normally `127.0.0.1:8557`; never the
     producer on 8556) is read **before** the stop, only as an early identity and height gate.
     `NODE_API` is refused if set.
   - The manifest's receipt comes from the **frozen copy**. After the copy, the script runs a
     throwaway node from the seed's exact image ID, with the seed's own env minus every
     `WRFCOIN_P2P_*`, and with `WRFCOIN_P2P_PROFILE=disabled`, `WRFCOIN_SYNC_ONLY=1`,
     `--network none`, a read-only rootfs, all capabilities dropped and no published port. It
     boots on a scratch copy of those bytes, is queried by `docker exec` on loopback, must answer
     the same receipt twice, and is addressed and removed **only by the container ID it created** (`docker run --cidfile`), after re-checking its per-run owner label `wrfcoin.join-verify.owner=<nonce>`. It is never removed by name, so a name collision leaves a foreign container alone.
   - Every request has a connect and total timeout plus an outer `timeout`, and the throwaway
     boot has a wall-clock deadline (`VERIFY_BOOT_TIMEOUT`, default 600 s).
   - Seed recovery is armed before `docker stop`, so a failed or interrupted stop still
     restarts the seed.

   What the script cannot judge is whether the seed is *current*. A seed far behind the
   producer publishes a correct but old snapshot, which joiners must sync forward from. Compare
   the authed `/state/snapshot` `height` on 8556 and 8557 first. Read the token into a variable
   and never print it.

## Flow

| # | Step | Who |
|---|---|---|
| 1 | Pick the directory. Leave `WRFCOIN_JOIN_SNAPSHOT_DIR` empty to use the default, or set an absolute path outside `$HOME/wrfcoin-deploy` in the deploy `.env`. | agent or owner |
| 2 | On node container, create the directory as root: `install -d -m 0755 /var/lib/wrfcoin-testnet-join/public` | **owner** (host root) |
| 3 | Recreate `funnel-edge` so it mounts the new source (see "Deploy-window delta" in the PR). `/join/*` stays 404 until step 4. This must happen **before** step 4: an edge still on the old in-tree mount makes the publisher refuse. | **owner** (public edge change) |
| 4 | **Legacy seed flow only** (the seed is retired since infra#1090; the normal path is the no-restart section above). With the seed profile re-enabled, run the prechecks above, then run `bash testnet/publish-join-snapshot.sh --from-seed` from the deployed infra tree. The publisher has no default mode: without `--from-snapshot` or `--from-seed` it refuses. It stops the seed for the copy (seconds), then boots the isolated frozen-copy node, which can take minutes on a long chain, and reads `WRFCOIN_READER_TOKEN` from `.env`. If it is SIGKILLed, list leftovers with `docker ps -a --no-trunc --filter label=wrfcoin.join-verify.owner` and read each one's label value before removing it **by ID**. Never remove by name. | **owner** (stops a live container, reads a secret) |
| 5 | Check loopback first: `curl -fsS http://127.0.0.1:8444/join/manifest.json`. Then check public: `testnet/edge/probe_public_build_freshness.sh --origin https://wrfcoin-testnet.taila1c049.ts.net` must print `PUBLIC_BUILD_FRESHNESS=FRESH`. | agent or owner |
| 6 | Re-publish before each invite wave. Later release flips need no action, because the directory is outside the tree. | owner |

The publisher refuses, before touching the seed, when the edge container is absent or has no `/srv/join` mount, or when its mount source:

- is relative;
- resolves inside its own checkout or release tree;
- sits under any `*.releases/` directory;
- is missing or not writable.
