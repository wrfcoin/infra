# Join the WRFCoin Testnet — Sync Node

> ⚠️ **This is a test network** — balances may be reset during development,
> and testnet WRF has no monetary value.

Welcome! This guide gets a **sync-only full node** running on your machine and
peered with the live WRFCoin testnet. A sync node follows the chain, serves a
local API, and can submit transactions — it does **not** mine or produce blocks
(only the registered reference validator does that, so there's nothing to
configure for signing and nothing that can fork the network).

> **Just want to connect a weather station?** You do **not** need to run a node
> for that. Skip to [Connecting a weather station](#connecting-a-weather-station)
> at the bottom.

---

## TL;DR — one command

For the public launch, clone over HTTPS; no GitHub SSH key is needed. First
choose the public-internet or Tailscale fallback path (step 1) and set the
published snapshot URL for a new node (step 3). From your home directory, with no existing
`wrfcoin/infra` checkout:

```bash
git clone https://github.com/wrfcoin/infra.git wrfcoin/infra && bash wrfcoin/infra/testnet/join.sh
```

`join.sh` checks prerequisites (git, Docker + Compose v2), clones
`wrfcoin/core4` next to the infra checkout, and hands off to
`join-testnet-sync-node.sh`. It is safe to re-run: existing clones are skipped
and rebuilds reuse the Docker layer cache. Extra flags pass through (e.g.
`--emulate` to force the old x86_64-under-emulation build on an arm64 Mac).

> The public repositories provide source builds. There are no prebuilt registry
> images to pull. A new node still requires a snapshot. The public
> endpoint is pending owner verification; placeholders below are not live addresses.

---

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| **Linux x86_64** | ✅ Supported | Builds natively. |
| **Intel Mac (x86_64)** | ✅ Supported | Builds natively. |
| **Apple Silicon (M1/M2/M3, arm64)** | **Native build, join still unvalidated end-to-end** | The image builds **natively on arm64** — no emulation, no opt-in, same command as everyone else (infra#763). Optionally run `bash join-testnet-sync-node.sh --preflight` first: it refuses unless Docker actually runs a native `aarch64` container, without generating `.env` or starting services. Emulation remains available as `--emulate` if a native build ever fails. Run this from a **native arm64 terminal** — a Rosetta shell reports `x86_64` and would build the slow emulated image; the script detects that and stops. |

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
3. **A reachable P2P route:** public internet once the owner publishes the
   verified endpoint, or the Tailscale fallback in step 1.
4. **git** and HTTPS access to `wrfcoin/infra` and `wrfcoin/core4`. The node
   image is **built from source** on your machine — we don't publish prebuilt
   images. Keep enough free disk space for the source, Docker build cache,
   snapshot archive and growing chain database.

---

## 1. Choose your network path

### Public internet (no Tailscale or invite)

The owner will publish the verified endpoint before Thursday's launch. Until
then `<PUBLIC_IP>` is a placeholder, and the script refuses it. In the same
shell as the join command, replace all placeholders:

```bash
export BOOTSTRAP_PEERS='/ip4/<PUBLIC_IP>/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr'
export WRFCOIN_P2P_EXTERNAL_ADDR='/ip4/<YOUR_PUBLIC_IP>/tcp/9000'
```

For DDNS, use `/dns4/<PUBLIC_HOST>/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr`
for the bootstrap and `/dns4/<YOUR_PUBLIC_HOST>/tcp/9000` for your own
advertised address. Forward TCP 9000 to your node and allow inbound traffic.
Your advertised address must be reachable by peers. Static IP, DDNS and CGNAT
status are currently unknown; DDNS alone does not make CGNAT reachable. Use
the fallback if a public route is unavailable. The real reachability guard
still runs before node startup.

### Tailscale fallback

Ask the owner for access using an **owner-created reusable auth key**. Keep it
private and follow the owner's enrollment instructions, then check `tailscale
status`. Install Tailscale and join the WRFCoin tailnet before continuing.
Set the published tailnet bootstrap instead of the public placeholder:

```bash
export BOOTSTRAP_PEERS='/ip4/<NODE_TAILNET_IP>/tcp/9000/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr'
export WRFCOIN_P2P_EXTERNAL_ADDR='/ip4/<YOUR_TAILNET_IP>/tcp/9000'
```

Replace the reference tailnet IP with the owner-published endpoint and your
own tailnet IP with the address reported by `tailscale ip -4`.
The public path does not require Tailscale or an auth key.

### Check the advertised endpoint before joining

The public TCP 9000 endpoint is planned for Thursday, 2026-10-22; the owner
fills in the real address on Wednesday after verification. Until then every
`<PUBLIC_IP>` / `<PUBLIC_HOST>` above is a placeholder, not a usable endpoint.
`WRFCOIN_P2P_EXTERNAL_ADDR` advertises **your own** node's address, without a
peer ID. `BOOTSTRAP_PEERS` supplies the reference seed's multiaddr **with** its
`/p2p/…` peer ID; do not advertise the reference address as your own.

From the infra checkout, check the owner-published reference endpoint:

```bash
bash testnet/check-p2p-external-addr.sh --require '/ip4/<PUBLIC_IP>/tcp/9000'
# Or, for the published DNS endpoint:
bash testnet/check-p2p-external-addr.sh --require '/dns4/<PUBLIC_HOST>/tcp/9000'
```

Use the bare TCP multiaddr for this check. The positional argument overrides
`WRFCOIN_P2P_EXTERNAL_ADDR`; without an argument the script checks that variable.
`--require` makes an empty address fail. The TCP dial is bounded to six seconds
by default; `--timeout SECONDS` changes the bound.

| Exit | Result | Operator action |
| --- | --- | --- |
| 0 | `PASS`: TCP accepted from this vantage point. | Continue with the snapshot and join steps, then verify chain identity, peers and sync below. A TCP connection alone is not a successful WRFCoin handshake. |
| 1 | `FAIL`: invalid address, empty address under `--require`, missing runtime proof tool, or unreachable private/tailnet address. | Correct the address, listener or route before joining. Literal angle-bracket placeholders fail validation. |
| 2 | Usage error, such as an unknown flag or nonexistent `--env-file` path. | Check the invocation. |
| 3 | `WARN`: public IP/DNS address did not accept TCP from here. | NAT hairpin can cause a false negative. Have the owner verify from an independent external network before publishing; WARN is not reachability proof. |

Do not use `--test-only --validate-only` as reachability evidence: that mode
requires `WRFCOIN_P2P_GUARD_TEST_MODE=1` and performs no dial. This guide update
performs no live probe and establishes no deployment or public-route readiness.

### Recognize public peering versus a tailnet-only route

After joining, use the local `/network/info` check in step 4. Successful peering
has the canonical genesis hash, positive `peer_count`, and advancing chain height
while catching up. At the tip, height follows newly produced blocks. Confirm
`sync_status` becomes `"synced"`; a positive peer count alone does not prove sync.

If only the Tailscale route is available, an internet-only joiner cannot reach
the reference seed: the public guard may WARN and the node may have no peers or
no sync progress. These symptoms can have other causes too. Obtain the owner's
reusable auth-key fallback privately, enroll, and use the tailnet seed and your
own tailnet advertisement from step 1. Peers and sync over that route demonstrate
**tailnet** connectivity, not public TCP 9000 reachability. Keep enrollment keys
out of commands shared in issues, screenshots and repository files.

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
parent is the Docker **build context**. The one-command path in step 3 creates
this layout for you. If you prefer a manual checkout, use:

```bash
mkdir ~/wrfcoin && cd ~/wrfcoin
git clone https://github.com/wrfcoin/infra.git
git clone https://github.com/wrfcoin/core4.git
# Layout: ~/wrfcoin/infra  and  ~/wrfcoin/core4
```

## 3. Run the join script

Keep this explicit validation setting for the current testnet and the public
chain 888. A higher local floor can reject live testnet blocks:

```bash
export WRFCOIN_MIN_WORK_FACTOR=0
```

The join script and `scripts/operator-install.sh` write
`WRFCOIN_MIN_WORK_FACTOR=0` to `testnet/.env` and export it for startup,
including when an older file or shell has a higher value. For a node launched
directly outside Compose, include the export above in its startup environment
(or `Environment=WRFCOIN_MIN_WORK_FACTOR=0` in its systemd service). A `.env`
file alone is not automatically loaded by a directly launched binary. This
setting controls validation; it does not confer producer or reward eligibility.

For a brand-new node, set the published snapshot URL supplied by the owner in the same
shell before running the command (replace the placeholder):

```bash
export WRFCOIN_JOIN_SNAPSHOT='<snapshot-url>'
```

From your home directory, if you have not already cloned infra:

```bash
git clone https://github.com/wrfcoin/infra.git wrfcoin/infra && bash wrfcoin/infra/testnet/join.sh
```

If you used the manual checkout in step 2 or are rerunning an existing checkout,
skip `git clone` and run `bash ~/wrfcoin/infra/testnet/join.sh`. The wrapper
passes `WRFCOIN_JOIN_SNAPSHOT` through to the join script. Do not start a new
node without the supplied snapshot; existing nonempty node data is retained.

The script:
- generates a local `.env` with fresh secrets (first run only),
- pins you to the canonical testnet (`chain_id 888`, genesis `0x553a37…`),
- **restores the published chain snapshot** into a brand-new node's data
  volume (see "Snapshot join" below — this is required, not an optimization),
- points you at the reference node as a bootstrap peer,
- preserves your explicit advertised P2P address (public or tailnet),
- leaves block-signing **off** (sync-only),
- builds and starts just `postgres`, `redis`, and `wrfcoin-node`.

The **first build can take 10–40 minutes** (it compiles the Rust node). Later
starts are fast.

### Public chain 888 bootstrap inputs (after the owner's cut)

Use the owner's reviewed public `cut-pins.env` for chain 888. Besides the
genesis hash (filled **after** the cut) and the genesis faucet address, it pins
every genesis declaration the cutter was started with
(`docker-compose.genesis.yml`): activation schedule, inline producer and oracle
set JSON, schedule governance keys, faucet allocation, flat reward, node-share
epoch and challenge windows, and the signing protocol version. These are public chain declarations, never signing keys. An unfilled
`cut-pins.888.env.example` is not a usable cut configuration.

The join script and `scripts/operator-install.sh` validate these declarations
from that file, write them to `.env`, and export them for Compose. Missing,
empty or placeholder pins refuse startup; a stale shell value cannot supply a
missing pin. They also write `WRFCOIN_CHAIN_ID=888`: a `.env` without it boots
as 777 under Compose's `${WRFCOIN_CHAIN_ID:-777}`, and `check-env-completeness.sh`
refuses that host. The node and seed each load `bootstrap.888.env`, which
requires every declaration at Compose interpolation time, including on
snapshot joins. Legacy
777 loads `bootstrap.777.env` with no additional environment entries.

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
Do not substitute 777's compiled pins or a guessed pre-cut hash. A configuration
render proves propagation, not successful block validation or node rewards.
The post-cut block-1 check uses `--chain-id 888` (or exported
`WRFCOIN_CHAIN_ID=888`) to expect signing **v1**; 777 retains its v2 default.

### Snapshot join — why a new node can't sync from genesis

The canonical chain contains a segment (block 11,017 and beyond) that fails
consensus re-validation on replay (core4#2806). A node that starts empty
syncs to 11,016 and then **wedges there permanently** — the failure also
graylists every peer it tried (core4#2807), so it never recovers. This is a
property of the chain's history, not of your machine.

The fix is to start from a published snapshot taken above that segment:

- `--snapshot https://<published-host>/join` fetches `manifest.json` +
  `snapshot.tar.gz`, verifies the archive's sha256 against the manifest and
  the manifest's chain identity against `cut-pins.env`, requires a height
  above 11,017 plus a canonical state root, and restores it into the fresh
  data volume before the node's first boot. The archive must contain exactly
  one regular root file named `wrfcoin.redb`; wrong-chain, malformed, linked,
  traversal, extra-file, or tampered snapshots are refused before volume
  creation.
- **Trust:** the snapshot is **hash-bound and unsigned** on this tailnet
  testnet. What you trust is `manifest.json`, served over TLS from the testnet
  edge. The archive is accepted only if its sha256 matches that manifest.
  Signing is planned after launch; public availability does not authenticate
  the manifest beyond the TLS endpoint you trust.
- The snapshot contains **only the chain database**. Your node still mints
  its own peer identity and its own secrets on first boot.
- The script refuses to start a brand-new node *without* a snapshot, naming
  core4#2806 — `--allow-full-sync` overrides if you really want to watch the
  wedge happen. Only an existing volume with a nonempty regular
  `wrfcoin.redb` skips restore; empty or malformed leftovers fail closed.
- The current snapshot URL is published in the invite that carries your
  Tailscale key (until the public funnel serves `/join/…` directly).

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

The testnet faucet runs on the seed host and is reachable **over the tailnet
only** (you joined it in step 1):

- Faucet UI: `http://wrfcoin-testnet:8080` (MagicDNS) or `http://<NODE_TAILNET_IP>:8080`

Open it in a browser, paste your wallet address, and claim. Notes:

- Use your **EVM-format (`0x…`) address** — the faucet does not yet dispense to
  native `wrf…` addresses (wrfcoin/infra#621).
- Claims are rate-limited per IP and per wallet per UTC day; if you hit a
  limit, the error says when to retry.
- If the URL doesn't respond, the operator may not have exposed the faucet on
  the tailnet yet (`FAUCET_TAILNET_BIND_ADDR` unset on the seed host) — ask in
  the testnet channel.

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

## Ops checklist — owner public-peering runbook

**Owner actions only; not performed by this change.** Public peering targets
Thursday ~19:00Z. Address type and external reachability remain unverified.

1. **Establish a public route.** Determine static IPv4, DDNS, or CGNAT status.
   Verify the current `<CT101_LAN_IP>` and forward router/firewall TCP 9000 to
   `<CT101_LAN_IP>:9000`. Under CGNAT, arrange a reachable public route or keep
   the Tailscale fallback; do not claim DDNS alone provides inbound access.
2. **Configure and publish the address.** Set the reference node's private
   `WRFCOIN_P2P_EXTERNAL_ADDR` to `/ip4/<PUBLIC_IP>/tcp/9000` or
   `/dns4/<PUBLIC_HOST>/tcp/9000`. Publish that address with
   `/p2p/12D3KooWMM7ukbQrn4BH2SjSNvyvAW2SaKUkHmDRng9KnifgYeWr` appended as the bootstrap.
   Replace the public placeholders in the example and script only after
   verification. Never commit the private environment file.
3. **Activate during Wednesday's gossip deploy.** Combine the producer restart
   with that deployment, before **Wed 21 12:00Z** chain freeze. Keep the
   Tailscale route as fallback and create/distribute a reusable enrollment key
   privately through the owner's access process. No agent restart is authorized.
4. **Verify before announcing.** From `infra/testnet`, run
   `bash check-p2p-external-addr.sh --require '/ip4/<PUBLIC_IP>/tcp/9000'`
   (or the `/dns4/<PUBLIC_HOST>/tcp/9000` form). Also verify from an
   independent external network; a NAT-hairpin WARN is not external proof.
   Record the guard result, `/network/info` canonical genesis and positive
   peer count, then increasing sync height on an external sync node. Publish
   the verified bootstrap and snapshot URL only with that evidence.

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
- **Ports:** the node listens on `8556` (local API) and `9000` (P2P). Keep 9000
  reachable over your selected public or tailnet route so peers can dial you back.

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
