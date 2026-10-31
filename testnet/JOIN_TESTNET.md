# Join the WRFCoin Testnet — Sync Node

> ⚠️ **This is a test network** — balances may be reset during development,
> and testnet WRF has no monetary value.

Welcome! This guide gets a **sync-only full node** running on your machine and
peered with the live WRFCoin testnet (chain **888**). A sync node follows the
chain, serves a local API, and can submit transactions — it does **not** mine
or produce blocks (only the registered producer nodes do that, so there's
nothing to configure for signing and nothing that can fork the network).

You need no invite, no account, no key and no port forwarding. The node dials
out to the public seed and syncs from genesis.

> **Just want to connect a weather station?** You do **not** need to run a node
> for that. Skip to [Connecting a weather station](#connecting-a-weather-station)
> at the bottom.

---

## TL;DR — one command (Linux or macOS)

From your home directory, with Docker running and no existing
`wrfcoin/infra` checkout:

```bash
git clone https://github.com/wrfcoin/infra.git wrfcoin/infra && bash wrfcoin/infra/testnet/join.sh
```

That is all. With no flags, `join.sh`:

- checks prerequisites (git, Docker + Compose v2),
- clones `wrfcoin/core4` next to the infra checkout over HTTPS and pins it to
  the commit in `testnet/cut-pins.env`,
- hands off to `join-testnet-sync-node.sh`, which bootstraps from the public
  seed `/dns4/seed.wrfcoin.com/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr`
  (pinned in `testnet/cut-pins.env`), syncs chain 888 **from genesis**, and
  uses **outbound connections only**.

It is safe to re-run: existing clones are skipped and rebuilds reuse the Docker
layer cache. Extra flags pass through (e.g. `--emulate` to force the
x86_64-under-emulation build on an arm64 Mac).

> The public repositories provide source builds. There are no prebuilt registry
> images to pull: the first run compiles the node on your machine.

---

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| **Linux x86_64** | ✅ Supported | Builds natively. |
| **Intel Mac (x86_64)** | ✅ Supported | Builds natively. |
| **Apple Silicon (M1/M2/M3, arm64)** | **Native build, join still unvalidated end-to-end** | The image builds **natively on arm64** — no emulation, no opt-in, same command as everyone else (infra#763). Optionally run `bash join-testnet-sync-node.sh --preflight` first: it refuses unless Docker actually runs a native `aarch64` container, without generating `.env` or starting services. Emulation remains available as `--emulate` if a native build ever fails. Run this from a **native arm64 terminal** — a Rosetta shell reports `x86_64` and would build the slow emulated image; the script detects that and stops. |
| **Windows** | Preview installer | Not this Docker guide. Use the native [Windows node preview 3 installer](https://github.com/wrfcoin/core4/releases/tag/v888-windows-preview-3) (v0.3.0, unsigned, so SmartScreen warns; check its SHA-256 first) and the [Windows node guide](https://github.com/wrfcoin/core4/blob/main/docs/operator/windows-node.md). WSL is not the intended Windows route. |

> **Validation status:** this guide has been validated on Linux x86_64. The
> Apple-Silicon preflight is an executable local environment check, but the
> first physical Mac join remains unverified. It must show a completed build,
> `/network/info` with the canonical genesis hash and `peer_count > 0`, and
> subsequent sync before this status can change.

---

## What you need

1. **A computer that stays on** (a Mac mini, a Linux box, an old laptop). 8 GB
   RAM is comfortable; the first build is CPU-heavy but sync itself is light.
2. **Docker** with Compose v2 — verify with `docker compose version`.
   - macOS: install Docker Desktop.
3. **Outbound internet access** to the seed on TCP port 9000. Nothing inbound:
   no router port forward, no static IP, no Tailscale.
4. **git** and HTTPS access to github.com. The node image is **built from
   source** on your machine — we don't publish prebuilt images. Keep enough free
   disk space for the source, the Docker build cache and the growing chain
   database.

---

## 1. Network: outbound is enough

The default bootstrap peer is the public seed pinned in
[`cut-pins.env`](cut-pins.env) (`WRFCOIN_CUT_BOOTSTRAP`) and listed in
[`seeds.txt`](seeds.txt):

```
/dns4/seed.wrfcoin.com/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr
```

A **sync-only node only dials out**. It finds the seed, downloads blocks and
follows the chain without anyone needing to reach it, so you do not set
`WRFCOIN_P2P_EXTERNAL_ADDR` and you do not forward any port. The join prints
`Sync-only, outbound connections only` when it takes this path.

Optional quick check that your network lets you out on port 9000 (from the
infra checkout; a public DNS name that does not answer reports `WARN`, exit 3):

```bash
bash testnet/check-p2p-external-addr.sh /dns4/seed.wrfcoin.com/tcp/9000
```

### Optional: let peers dial you back

If you *can* accept inbound TCP 9000 (router forward or a public IP), you can
advertise it so other nodes may also connect to you:

```bash
export WRFCOIN_P2P_EXTERNAL_ADDR='/ip4/<YOUR_PUBLIC_IP>/tcp/9000'   # or /dns4/<YOUR_HOST>/tcp/9000
```

Replace the placeholder with your own address (the script refuses a value that
still contains `<…>`). The join script saves it to `testnet/.env` and dials it
**after** the node is listening. For a sync-only node a failed dial is only a
**warning** (a NAT hairpin can cause a false negative); syncing is unaffected.

### When inbound reachability IS required

Inbound reachability is required only for roles that other nodes dial:

- **Bonded / serving nodes** — anything with `WRFCOIN_SERVICE_ID` set (for
  example a bonded snapshot server, see [Node-pay service identity](#node-pay-service-identity)).
  The join script refuses to start such a node without
  `WRFCOIN_P2P_EXTERNAL_ADDR`, and exits non-zero if the address does not
  accept TCP once the node is up.
- **Producer and reference nodes** (team-operated, not started by this guide).
  The node's Compose startup guard refuses an empty advertised address for any
  node that is not `WRFCOIN_SYNC_ONLY=1` without a service ID.

Running a sync node does not itself grant producer, bond or reward eligibility.

### Tailscale (optional, not needed to join)

Some team testers also have tailnet access. If you were given it and want to
peer over the tailnet, pass a tailnet bootstrap (a `100.64.0.0/10` address or a
`*.ts.net` name); the script then advertises your `tailscale ip -4` address
automatically. Peers and sync over that route show **tailnet** connectivity,
not public reachability. Keep enrollment keys out of issues, screenshots and
repository files.

### What bond and receipt gossip means

In current core4 source, successful admission through `POST /node/bonds/submit`
or `POST /node/receipts/submit` queues the signed transaction for gossip when
P2P support is enabled and initialized. Refused submissions are not gossiped.
This allows an admitted submission on a non-producing node to propagate toward
a producer; it does not guarantee delivery, inclusion or a reward. Older node
builds may only admit locally. The owner must deploy the updated binary before
operators can rely on the new behavior; this guide does not verify that rollout.

The [node-share operations guide](https://github.com/wrfcoin/core4/blob/main/docs/architecture/ADR-003-node-share-operations.md)
explains that `admitted=true` remains pending until canonical readback reports
`status=INCLUDED,included=true`, and even inclusion does not establish matured
payout. Running a sync node does not itself grant producer or reward eligibility.

## 2. Choose a checkout layout

The node image is built from the Rust sources in `core4/`, with the build
recipe in `infra/`. They must sit side-by-side under one parent folder — that
parent is the Docker **build context**. The one-command path creates this
layout for you. If you prefer a manual checkout, use:

```bash
mkdir ~/wrfcoin && cd ~/wrfcoin
git clone https://github.com/wrfcoin/infra.git
git clone https://github.com/wrfcoin/core4.git
# Layout: ~/wrfcoin/infra  and  ~/wrfcoin/core4
```

## 3. Run the join script

From your home directory, if you have not already cloned infra:

```bash
git clone https://github.com/wrfcoin/infra.git wrfcoin/infra && bash wrfcoin/infra/testnet/join.sh
```

If you used the manual checkout in step 2 or are rerunning an existing checkout,
skip `git clone` and run `bash ~/wrfcoin/infra/testnet/join.sh`.

The script:
- generates a local `.env` with fresh secrets (first run only),
- pins you to the canonical testnet (`chain_id 888`, genesis `0x553a37…`),
- points you at the public seed as the bootstrap peer,
- on a brand-new node, **syncs from genesis** (a snapshot is optional; see
  "Optional: start from a snapshot" below),
- runs outbound-only unless you set `WRFCOIN_P2P_EXTERNAL_ADDR` (step 1),
- leaves block-signing **off** (sync-only),
- builds and starts just `postgres`, `redis`, and `wrfcoin-node`.

The **first build can take 10–40 minutes** (it compiles the Rust node). Later
starts are fast.

The join script and `scripts/operator-install.sh` write
`WRFCOIN_MIN_WORK_FACTOR=0` to `testnet/.env` and export it for startup,
including when an older file or shell has a higher value; a higher local floor
can reject live testnet blocks. For a node launched directly outside Compose,
export `WRFCOIN_MIN_WORK_FACTOR=0` in its startup environment (or
`Environment=WRFCOIN_MIN_WORK_FACTOR=0` in its systemd service). A `.env` file
alone is not automatically loaded by a directly launched binary. This setting
controls validation; it does not confer producer or reward eligibility.

### Chain 888 bootstrap inputs

`testnet/cut-pins.env` pins chain 888: the genesis hash, the genesis faucet
address, and every genesis declaration the cutter was started with
(`docker-compose.genesis.yml`): activation schedule, inline producer and oracle
set JSON, schedule governance keys, faucet allocation, flat reward, node-share
epoch and challenge windows, and the signing protocol version. These are public
chain declarations, never signing keys. `cut-pins.888.env.example` is an
unfilled template, not a usable configuration.

The join script and `scripts/operator-install.sh` validate these declarations
from that file, write them to `.env`, and export them for Compose. Missing,
empty or placeholder pins refuse startup; a stale shell value cannot supply a
missing pin. They also write `WRFCOIN_CHAIN_ID=888`: a `.env` without it boots
as the retired chain 777 under Compose's `${WRFCOIN_CHAIN_ID:-777}`, and
`check-env-completeness.sh` refuses that host. The node and seed each load
`bootstrap.888.env`, which requires every declaration at Compose interpolation
time.

For a manually managed startup, pass the node the same explicit environment
the join script exports (the producer and oracle sets stay inline JSON).
Start with the `.env` prepared by setup/join; validate the public pins before
launching a binary directly. A zero genesis hash is reserved for the separate
owner cutter procedure and is refused here:

```bash
# Validates every declaration, writes them to .env, and prints KEY=VALUE lines
# (WRFCOIN_CHAIN_ID=888 first); exits 1 on any missing or placeholder pin.
bootstrap="$(python3 scripts/chain-identity.py --pins ./cut-pins.env --bootstrap-env .env)" || exit 1
while IFS='=' read -r key value; do export "${key}=${value}"; done <<< "$bootstrap"
export WRFCOIN_MIN_WORK_FACTOR=0
```

Keep every bootstrap declaration in direct-binary or systemd startup
environments too: a `.env` file alone is not automatically loaded by a binary.
Do not substitute 777's compiled pins or a guessed hash. A configuration render
proves propagation, not successful block validation or node rewards. The
block-1 check uses `--chain-id 888` (or exported `WRFCOIN_CHAIN_ID=888`) to
expect signing **v1**.

### Optional: start from a snapshot

Chain 888 replays cleanly from genesis, so **no snapshot is needed**. If you
are given a snapshot (a base URL or local directory holding `manifest.json` +
`snapshot.tar.gz`), you may start from it instead to skip the initial sync:

```bash
bash ~/wrfcoin/infra/testnet/join.sh --snapshot <base-url-or-dir>
# or: export WRFCOIN_JOIN_SNAPSHOT=<base-url-or-dir>
```

- The script verifies the archive's sha256 against the manifest and the
  manifest's chain identity against `cut-pins.env`, requires a canonical state
  root, and restores it into the fresh data volume before the node's first
  boot. The archive must contain exactly one regular root file named
  `wrfcoin.redb`; wrong-chain, malformed, linked, traversal, extra-file, or
  tampered snapshots are refused before volume creation.
- **Trust:** the snapshot is **hash-bound and unsigned**. What you trust is the
  `manifest.json` and wherever you fetched it from; the archive is accepted
  only if its sha256 matches that manifest.
- The snapshot contains **only the chain database**. Your node still mints its
  own peer identity and its own secrets on first boot.
- Only an existing volume with a nonempty regular `wrfcoin.redb` skips the
  snapshot path; empty or malformed leftovers fail closed.

> **Retired chain 777 only:** on the pre-launch chain 777 a snapshot was
> *required*, because a full sync wedged at block 11,016 (core4#2806/#2807).
> The script still refuses a snapshot-less brand-new node when the pins name
> chain 777 (`--allow-full-sync` overrides). None of this applies to chain 888.

## 4. Confirm you're on the chain

When it finishes it prints your node's identity. You can re-check any time:

```bash
curl -s http://localhost:8556/network/info | jq '{genesis_hash, chain_height, peer_count, sync_status}'
```

You're healthy when:
- `genesis_hash` is `0x553a3758386d9631037d7469686acb4a121ced81dcf5cde256e2d05667c5f332`
  — this is the chain-identity check; a different value means you're on the
  wrong chain (the node will refuse to peer in that case),
- `peer_count` ≥ 1,
- `chain_height` climbs over time and `sync_status` becomes `"synced"`.

Watch it catch up:
```bash
watch -n5 'curl -s http://localhost:8556/network/info | jq .chain_height'
```

## See what your node is doing

Inspect your local node today (install `jq` to format the response):

```bash
curl -s localhost:8556/network/info | jq
```

During launch week, the local status page at `http://localhost:8556/dashboard`
is planned with [core4#3599](https://github.com/wrfcoin/core4/issues/3599).
Use it once that change is available in your node build; it is not available
in every pinned build yet.

For Prometheus, the node exposes `GET /metrics` on port 8556. This endpoint
requires a valid Reader-role bearer token; keep the token private and configure
it through Prometheus's credential file, never in a shared screenshot or URL.

---

## Getting test WRF (faucet)

You do not need a node to get test WRF. Use the public faucet on the website:
open <https://wrfcoin.com>, choose **Get started**, and use **Fund Your Wallet**
(see the [public quickstart](https://github.com/wrfcoin/docs/blob/main/testnet/quickstart.md),
section 2). Follow the displayed amount, cooldown and caps; a pending request
is not a confirmed payment.

Team testers with tailnet access may also see the faucet UI on the seed host's
tailnet address (`http://wrfcoin-testnet:8080`); that route is not needed by,
or available to, public joiners.

---

## Operating the node

```bash
cd ~/wrfcoin/infra/testnet

# logs
docker compose -f docker-compose.testnet.yml logs -f wrfcoin-node

# stop / start (keeps chain data)
docker compose -f docker-compose.testnet.yml stop wrfcoin-node
docker compose -f docker-compose.testnet.yml start wrfcoin-node

# update to latest code
git -C ~/wrfcoin/core4 pull && git -C ~/wrfcoin/infra pull
bash join-testnet-sync-node.sh        # rebuilds + restarts
```

To stay current, `git pull` both repos and re-run the script periodically.

For public node-status guidance, see the
[public node-status guide](https://github.com/wrfcoin/docs/blob/main/testnet/node-status.md).
For operator help, use [testnet support](https://github.com/wrfcoin/testnet-support).

---

## Seed operators

The public seed is published: it is `WRFCOIN_CUT_BOOTSTRAP` in
[`cut-pins.env`](cut-pins.env) and the entry in [`seeds.txt`](seeds.txt)
(`bash check-seeds.sh` refuses a mismatch between the two). Changing the seed
is a one-line edit to `cut-pins.env` plus the matching `seeds.txt` line. The
pre-launch owner runbook for publishing it (chain-777-era placeholders) is in
this file's git history.

---

## Notes & known limitations

- **Apple Silicon (M1/M2/M3) Macs:** the node image now builds **natively on
  arm64** — `Dockerfile.core` derives the package architecture instead of
  hardcoding `amd64` (infra#763), and both base images are multi-arch. There is
  no emulation and no opt-in flag: run the same command everyone else runs.
  Run it from a **native arm64 terminal** — a Rosetta shell reports `x86_64`,
  which would build the slow emulated image; the script detects that and stops
  rather than letting it happen quietly.
  Optionally run `bash join-testnet-sync-node.sh --preflight` first; it must
  print that Docker answered `aarch64`.
  **What is and isn't proven:** the node binary is confirmed to compile and link
  for `aarch64-unknown-linux-gnu`, and every package in the image has an arm64
  build. A full arm64 *image* has not yet been built on real hardware — the
  first one will be the Mac mini itself. If it fails, `--emulate` restores the
  old x86_64-under-emulation path (slow, ~30–60 min) so you are not stuck.
  A successful preflight is not an end-to-end join: run the full command, record
  the canonical genesis hash, `peer_count > 0`, and sync progress. This script
  starts a **sync-only** node and cannot prove validator/oracle membership;
  that requires the separate signer and membership ceremony on the physical
  Mac mini.
- **Storage is unencrypted** (`ALLOW_UNENCRYPTED_STORAGE=true`). Fine for
  testnet; do not reuse this config for anything holding real value.
- **You can't accidentally fork or attack the chain.** Your node isn't in the
  validator set, so even if it tried to produce a block, no one would accept it.
- **Ports:** the node listens on `8556` (local API, bound to localhost) and
  `9000` (P2P). A sync-only node needs **no inbound** access to 9000; forward
  it only if you set `WRFCOIN_P2P_EXTERNAL_ADDR` or run a serving role.

---

## Connecting a weather station

Running a node and contributing weather data are separate activities; you can
participate in either or both.

1. Open [wrfcoin.com](https://wrfcoin.com) and choose **Connect a station**, or
   go directly to [Connect a station](https://wrfcoin.com/connect-station).
2. Follow the wallet sign-in and provider setup prompts shown by the public flow.
   Enter provider credentials only in that flow; never paste them into a public
   issue, shell command, or screenshot.
3. Check the status returned by the flow. Registration alone does not establish
   active ingestion or rewards; follow any pending or unavailable status shown.

For help, open a [testnet support issue](https://github.com/wrfcoin/testnet-support)
with the error message and non-sensitive steps to reproduce it. Report security
concerns privately to security@wrfcoin.com.

This guide update does not establish a successful live registration, ingestion,
or reward payout.

## Verify what you download

Once a public release is published, obtain `manifest.json`, `manifest.json.asc`
and `SHA256SUMS` from that GitHub Release; the website also serves the same
metadata at `/downloads/manifest.json`, `/downloads/manifest.json.asc` and
`/downloads/SHA256SUMS`. Until publication, those files may be unavailable.

Before trusting a download, obtain the release public key and verify its full
fingerprint against the security policy and organization profile, independently
of the downloaded files. Verify `gpg --verify manifest.json.asc manifest.json`.
For a file artifact, compare its SHA-256 and size with the signed manifest, then
run `sha256sum -c SHA256SUMS` alongside the downloaded file(s). For a source
checkout, compare the full commit and tag with the signed `kind: "git"` entry;
a Git commit identifier is not an archive SHA-256. Do not install an artifact
whose signature or hash does not match. Missing artifacts are not published yet.

The [public release procedure](PUBLIC_RELEASE.md) describes owner signing and
publication. This catalog does not replace the separate join-snapshot trust
checks performed by the node join script.

## Node-pay service identity

For a bonded snapshot server, set `WRFCOIN_SERVICE_ID` to the bond's
`service_alias`, e.g. `node-ws`, in the node's operator environment before its
next planned restart. The Compose default is empty; an empty value does not
identify a bonded server. The receipt's server alias must match this setting.

After the planned restart, with your existing operator bearer and node URL,
check that the returned value equals the bond's alias:

```bash
printf 'Authorization: Bearer %s\n' "${WRFCOIN_OPERATOR_TOKEN}" | curl --fail --silent --show-error --header @- "${NODE_API_URL}/network/snapshot-sync/receipts" | jq -er '.server_id'
```

This checks the server identity only; it does not prove receipt inclusion or payment.
