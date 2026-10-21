# Testnet Release Candidate

This procedure records exactly what a testnet release candidate would contain
and verifies what the public origin serves. It does not authorize a build,
deployment, restart, registry push, or live-state mutation. Those remain human
deploy-window actions on the approved host.

## 1. Pin reviewed source heads

Update `testnet/release-pins.env` only with full SHAs obtained from the clean
core4, backend, and frontend checkouts:

```bash
git -C $HOME/wrfcoin/core4 rev-parse HEAD
git -C $HOME/wrfcoin/backend rev-parse HEAD
git -C $HOME/wrfcoin/frontend rev-parse HEAD
```

The core4 release pin must exactly equal `WRFCOIN_CUT_CORE4_COMMIT` in
`testnet/cut-pins.env`; the renderer refuses an in-place binary upgrade. The
infra checkout cannot pin itself, so the renderer records its current HEAD and
requires that checkout to be clean and to contain the pins file it is using.

## 2. Render the release manifest locally

Arrange clean, detached-or-branch checkouts as `core4`, `backend`, `frontend`,
and `infra` below one workspace directory, each at its pinned SHA. Pass the
**same compose file set and env file the host deploys with**, including any
host-local override (for example the node container custody override that pins the node
to its AA-cut tag) and the funnel-edge file:

```bash
cd $HOME/wrfcoin-deploy/infra
bash testnet/scripts/render-release-manifest.sh \
  --workspace $HOME/wrfcoin-deploy \
  --pins testnet/release-pins.env \
  --env-file testnet/.env \
  -f testnet/docker-compose.testnet.yml \
  -f testnet/docker-compose.override.yml \
  -f testnet/docker-compose.local-paths.example.yml \
  -f /absolute/operator-state/.../ct101-release-override.yml \
  -f testnet/docker-compose.funnel-edge.yml \
  --out /tmp/wrfcoin-release-manifest.json
```

(`--compose-config FILE` accepts an already rendered
`docker compose config --format json` instead of `-f`/`--env-file`.) Rendering
is config-only; it starts, builds and pulls nothing. With neither input the
renderer is VOID (exit 2).

### 2.1 Hosts whose deployed trees are not git checkouts (node container; infra#1047)

node container deploys `core4` and `infra` as `git archive` extractions
(`core4.releases/<sha>`, `infra.releases/<sha>`), where `git rev-parse HEAD`
fails. Do not point `--workspace` at them. Build a separate **gate workspace**
of real checkouts from explicit sources instead. Use git bundles for the repos
the host has no credentials for, and the host's own backend/frontend checkouts:

```bash
bash testnet/scripts/prepare-release-gate-workspace.sh --out /root/rc-gate \
  --infra-commit <infra SHA that contains the release pins> \
  --source core4=/root/core4-rc.bundle --source infra=/root/infra-rc.bundle \
  --source backend=$HOME/wrfcoin-deploy/backend \
  --source frontend=$HOME/wrfcoin-deploy/frontend
# GATE_WORKSPACE=READY dir=/root/rc-gate core4=… backend=… frontend=… infra=…
```

The script reads each source's `origin/main` (or `main`) into
`refs/remotes/origin/main`, checks infra out at `--infra-commit`, and checks the
other three out at the pins that commit names. It fails unless every checkout is
the exact pin, clean, and on `origin/main`. Make bundles with
`git bundle create X origin/main`. Do not `git clone` such a bundle: the clone
is empty and has no `origin/main`.

Then run the renderer **from the gate workspace**
(`bash /root/rc-gate/infra/testnet/scripts/render-release-manifest.sh --workspace /root/rc-gate --pins /root/rc-gate/infra/testnet/release-pins.env …`).
Keep the deployed `-f` files and `--env-file`. Bind the deployed non-git trees to
the gate checkouts with `--release-tree`:

```bash
  --release-tree core4=$HOME/wrfcoin-deploy/core4 \
  --release-tree infra=$HOME/wrfcoin-deploy/infra
```

For each tree, every entry that `git archive HEAD` of the gate checkout produces
must exist in the deployed tree, with the same bytes, executable bit and symlink
target. That includes `export-ignore`, which is honoured the same way the
extraction did. Untracked extras, such as `.env` or a copied
`docker-compose.cut.yml`, are allowed, and are listed in
`repos.<name>.release_tree.untracked_extra`. A mismatch is RED (exit 1) and
writes no manifest. On real core4, about 10k entries take about 1 s. Nothing in
the deployed tree is trusted: the gate checkout is the reference.

### 2.2 Identity owners left on an older core4 image (`--exempt`; infra#1047)

Boot-heal custody forbids recreating `softhsm-init`, `softhsm-seed-init` and
`wrfcoin-seed`, so a node-only upgrade leaves them on the previous core4 image.
The rules above gate them in `core4`, so without an exemption `core4` can never
be `FRESH`.

A reviewed exemption file, kept with the host's operator state next to its
release override, names them. It has one line per service, and `#` comments
are allowed:

```
softhsm-init       sha256:<64-hex image id>  <40-hex org.opencontainers.image.revision>
softhsm-seed-init  sha256:<64-hex image id>  <40-hex revision>
wrfcoin-seed       sha256:<64-hex image id>  <40-hex revision>
```

Pass it with `--exempt FILE`. The exemption is fail-closed.

The run is refused (RED, exit 1, no manifest) when:
- the file is malformed or empty, or lists a service twice;
- it names any other service. `wrfcoin-node`, `oracle-attester` and every
  release service can never be exempted;
- it names a service that is not rendered and gated. A stale exemption is refused, not ignored.

The run completes, but core4 cannot be FRESH, when:
- an exempted service shares its tag with a gated service. The exemption is
  refused and the tag stays gated (`UNAVAILABLE`);
- the exempted tag's local image Id or revision label is not the declared one,
  or the revision is not an ancestor of `WRFCOIN_RC_CORE4_COMMIT`. The result
  is `STALE`;
- with `--check-running`, a `softhsm-init`/`softhsm-seed-init` container runs
  another image (`STALE`) or is missing (`UNAVAILABLE`);
- with `--check-running`, `wrfcoin-seed` **is running**, on any image (`STALE`).
  The seed is a full core4 node, so it is exempt only while it is not running:
  either exited from the exempted image, or confirmed absent. Absence counts
  only when `docker container ls -a` succeeds and lacks it; a failed inspect or
  listing is `UNAVAILABLE`, never absent. Each exempt container record carries
  `required_state` and `present`.

**The exact image Id is the anchor.** The revision label and its ancestry are
cross-checks: a label can be set by anyone at build time, but the Id is the
content-addressed image. The exemption file is a reviewed, dated artifact for
**one** release. Re-derive and re-review it for every release instead of
carrying it forward; that review is what bounds its age.

A service that passes is recorded under `images.core4.exempt` with freshness
`EXEMPT`, never `FRESH`. It is listed in the top-level `exemptions`, with the
file's sha256, and named in the summary line:
`… exempt=softhsm-init,softhsm-seed-init,wrfcoin-seed`. The exemption covers
the owners only. `wrfcoin-node` and every other gated tag must still be
`FRESH`, and a core4 group with no gated tag left is `UNAVAILABLE`.

### 2.3 Results

SHA mismatch or dirt makes the command RED. A missing repository returns VOID
(exit 2). A manifest left at `--out` by an earlier run is deleted first, so a run
that stops early never leaves an old green manifest behind.

Gate membership is fail-closed. A rendered service is gated in a group when
**any** of these holds, whatever its `build:` or `image:` (a host override may
point a service at a pre-built tag and drop its build):

1. it is a named release service (table below);
2. its image repository, with any registry host and tag removed, is a release
   repository, under any tag: `wrfcoin/native-chain`, `wrfcoin/backend-api`,
   `wrfcoin/backend`, `wrfcoin/frontend`, `wrfcoin/edge-caddy`, `wrfcoin/faucet`;
3. it builds from a release Dockerfile, or runs a tag one produces.

| group | named services (required) | release repository | Dockerfile | pin |
|---|---|---|---|---|
| `core4` | `wrfcoin-node` | `wrfcoin/native-chain` | `Dockerfile.core` | `WRFCOIN_RC_CORE4_COMMIT` |
| `backend` | `wrfcoin-backend` | `wrfcoin/backend-api` | `Dockerfile.backend-api` | `WRFCOIN_RC_BACKEND_COMMIT` |
| `backend-services` | `db-migrate`, `wrfcoin-governance`, `wrfcoin-iot`, `wrfcoin-weather-earnings` | `wrfcoin/backend` | `Dockerfile.backend` | `WRFCOIN_RC_BACKEND_COMMIT` |
| `frontend` | `wrfcoin-frontend` | `wrfcoin/frontend` | `Dockerfile.frontend` | `WRFCOIN_RC_FRONTEND_COMMIT` |
| `edge` | `funnel-edge` or `edge` | `wrfcoin/edge-caddy` | `Dockerfile.caddy` | infra HEAD, `testnet/edge/` unchanged |
| `faucet` | `wrfcoin-faucet` | `wrfcoin/faucet` | `testnet/services/faucet/Dockerfile` (matched by path) | infra HEAD, `testnet/services/faucet/` unchanged |

**The faucet is gated (infra#1121).** Until then node container ran
`wrfcoin/faucet:testnet-local` built 2026-07-02, with no revision label (July
`server.js`, infra `f650f007`), while `--check-running` reported `FRESH`,
because the faucet was in no group. `wrfcoin-faucet` is a required service and
runs under the `faucet` compose profile (infra#1057), so render with the host's
`.env` (its `COMPOSE_PROFILES` must include `faucet` or `seed`) or with
`COMPOSE_PROFILES=faucet` exported. A render without the faucet is
`UNAVAILABLE` ("wrfcoin-faucet: required service is not rendered"), never
`FRESH`.

In the repository compose set, the rules above also gate `softhsm-init`
(core4) and, when the `seed`/`full` profiles are rendered, the seed node and the
other `wrfcoin/backend` services. The following are `UNAVAILABLE`:

- a named service missing from the render;
- a gated service that builds from a Dockerfile other than its group's (for
  example `Dockerfile.backend-worker`);
- a build that maps to no group but is a release build ("unmapped release
  build"): one whose context or Dockerfile lies inside a core4, backend or
  frontend tree, or whose Dockerfile lies in infra's release Dockerfile
  directory `infra/docker/` or any subdirectory of it (as
  `infra/infra/docker/Dockerfile.<new>` or `infra/infra/docker/<dir>/Dockerfile.<new>`
  from the workspace root, or `infra/docker/…` from the infra checkout). The first kind
  is reported under the tree's group; the second under the manifest's
  `membership_problems`, which makes the manifest `UNAVAILABLE`
  (`unavailable=membership`) until the new image is given a gate.

**Boundary: what is not gated.** Two kinds of service stay outside the gate:

- Services built from infra's own `testnet/` Dockerfiles (`wrfcoin-explorer`
  from `infra/testnet/Dockerfile.explorer`, `alert-receiver`), except the
  faucet, which has its own group (above). They are not built from core4,
  backend or frontend source and are not in the release groups.
- A service with **no build** whose image is **not** a release repository and
  whose name is not a named release service, for example
  `node-b: {image: localnode:aacut}`. Nothing in the render identifies it as
  WRFCoin code (the compose files carry no role label to key on), so it is
  not gated. The named services are always gated whatever their image, so
  this only matters if a second producer or backend is added under a new name
  on a non-release image. Adding one means adding it to the named services in
  `render-release-manifest.sh` (`BASELINE_SERVICES`) in the same change.

A group may run several tags; each tag is classified, and the group takes the
worst result. Every tag is classified from read-only `docker image inspect`
(infra#991):

| image state | class | exit |
|---|---|---|
| Docker `Created` (and the `org.opencontainers.image.created` label, if set) on/after `WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE`, and `org.opencontainers.image.revision` equals the pin | `FRESH` | 0 |
| edge / faucet: revision is a commit contained in the renderer's infra HEAD **and** the image's build context (`testnet/edge/`, `testnet/services/faucet/`: what it bakes) is identical at that revision and at HEAD | `FRESH` | 0 |
| created before the minimum date (the older of Docker `Created` and the label counts; the label can never make an image look newer) | `STALE` | 1 |
| revision is a full SHA but not the pin, or (edge, faucet) not in infra HEAD or its build context changed since it | `STALE` | 1 |
| revision label missing, empty or malformed; creation time unparseable; malformed inspect output or no `sha256:` image Id; image or gated group absent; compose render failed; docker unavailable | `UNAVAILABLE` | 2 |

Any `STALE` image makes the manifest `STALE`; otherwise any `UNAVAILABLE` image
makes it `UNAVAILABLE`. Every non-`FRESH` image is named on stderr as a
`RELEASE_MANIFEST_FINDING` line and in the JSON `findings`. Missing evidence is
never green. Images built before the provenance labels existed carry no revision
label, so they classify `UNAVAILABLE` until they are rebuilt as in section 3.

`oracle-reference` is built from its own repository and is not gated; it carries
no infra provenance labels.

**Rendered configuration (infra#1056).** The render itself is also checked, not
only its images. `CORS_ORIGIN` has no compose default, so a host `.env` that
omits it renders it empty. (It is not a `:?` guard: that would break the
sync-only join command, the #762 trap.) A rendered `CORS_ORIGIN` that is empty,
loopback (`localhost`, `127.*`, `0.0.0.0`, `[::1]`), a wildcard, or not a
`scheme://host[:port]` origin is listed in the
manifest's `config_problems` and makes it `UNAVAILABLE` (`unavailable=config`),
whatever the images; `--verify` refuses a manifest whose `config_problems` is
not `[]`. The same check runs before any `up` in
`testnet/check-env-completeness.sh --env testnet/.env -f … (the deploy's file set)`.
Both gates validate the **effective rendered** value, not the literal `.env`
line. Compose is rendered with the same ordered file set, env file and process
environment, so an exported `CORS_ORIGIN`, an overlay override, or `.env`
interpolation is what gets checked. Run the pre-`up` check in the same shell,
with the same `-f` list, as the `up` itself.

## 3. Human build and deploy window

An owner reviews the manifest, performs local builds on the approved build
host, and schedules any testnet deployment or restart. Agents running this
procedure stop before that boundary. No command in this document pushes an
image or changes live state.

Release builds must carry provenance. On the build host, with the checkouts
under `WRFCOIN_ROOT` at their pinned SHAs and no uncommitted tracked changes,
export `WRFCOIN_ROOT`, source the helper, and run the build-root guard, all in
the same shell that runs the compose build:

```bash
export WRFCOIN_ROOT=$HOME/wrfcoin-deploy   # or the gate workspace; EXPORT it
source "$WRFCOIN_ROOT/infra/testnet/scripts/export-build-provenance.sh"
bash "$WRFCOIN_ROOT/infra/testnet/scripts/check-build-root.sh" \
  --service wrfcoin-backend --service db-migrate --service wrfcoin-frontend \
  --service wrfcoin-faucet \
  -- <the exact compose global args of the build: -p, --env-file, every -f>
# BUILD_ROOT=OK, then the compose build with those same args, in this same shell
```

The helper exports `WRFCOIN_{CORE4,BACKEND,FRONTEND,INFRA}_BUILD_REVISION`
(from `git rev-parse HEAD` of each checkout) and `WRFCOIN_BUILD_CREATED`. It
exports nothing if any checkout does not resolve or has uncommitted tracked
changes (a dirty tree is not the commit it would be labelled with; untracked
files such as `.env` are ignored), clears stale values from an earlier run
first, and does not change the calling shell's options.

**Opt-in storage images (infra#944, r20).** When `storage-providers` is checked
out under the root, the helper also exports `WRFCOIN_STORAGE_PROVIDERS_BUILD_REVISION`
and holds that checkout to the same exact-head, clean-tracked-tree rule; when it is
absent nothing changes. The canonical `workspace.dockerignore` now allows
`/storage-providers` so `infra/infra/docker/Dockerfile.storage` can build under
Compose. A host that already installed the previous `.dockerignore` must reinstall
the canonical one once (`install -m 0644 <infra>/testnet/workspace.dockerignore
<root>/.dockerignore`): the helper refuses a differing file.

The manifest renderer's `--storage` flag adds the `storage` group for those images
(also `--verify ... --storage` to require it). `ipfs-kubo` is upstream and never
built: the local image must carry the digest pinned by `WRFCOIN_RC_IPFS_KUBO_DIGEST`
(`sha256:<64 hex>`, from `docker buildx imagetools inspect ipfs/kubo:<tag>` on a
reviewed pull). `storage-node` is built from `storage-providers` and its revision
label must equal `WRFCOIN_RC_STORAGE_PROVIDERS_COMMIT`; that checkout is bound like
core4/backend/frontend. Both pins live in `release-pins.env`, are read only with
`--storage`, and render with the `ipfs-storage` profile active. The
`weather-ipfs-archive` worker runs the backend image, so it is already gated in
`backend-services`. Without `--storage` the output is unchanged.

**The labelled root must be the build context (infra#1077).** The compose files
build from `context: ${WRFCOIN_ROOT:-$HOME/wrfcoin-deploy}`. The old form
`WRFCOIN_ROOT=$G source …` set `WRFCOIN_ROOT` only while `source` ran, so in
the r11 window compose resolved the context to the live checkouts at the old
commits while the images were labelled with `$G`'s new revisions, and the gate
would have called them `FRESH`. Now:

- the helper exports `WRFCOIN_ROOT` (and `WRFCOIN_BUILD_ROOT`) as the root it
  labelled, which also makes the prefix form safe;
- it installs the canonical `infra/testnet/workspace.dockerignore` as
  `<root>/.dockerignore` when that file is missing, and refuses when a different
  one is present. `prepare-release-gate-workspace.sh` installs it too;
- `check-build-root.sh` refuses (`BUILD_ROOT=FAIL`, exit 1) unless
  `WRFCOIN_ROOT` is really exported as the labelled root, the root's
  `.dockerignore` is canonical, and every named service's rendered
  `build.context` (from `docker compose … config`, never printed: it holds
  secrets) resolves inside that root.

Exporting `WRFCOIN_ROOT` also changes what a later `docker compose up` in the
same shell mounts from `${WRFCOIN_ROOT}` (the override's synthetic-collector
bind). Run `up` from a fresh shell, or with `WRFCOIN_ROOT` set to the deploy
root. The compose files pass the values as build args, and the Dockerfiles
record them as `org.opencontainers.image.revision` and
`org.opencontainers.image.created`. The faucet
(`testnet/services/faucet/Dockerfile`) takes `WRFCOIN_INFRA_BUILD_REVISION`
(infra#1121). The backend images also expose the revision
to `GET /api/build` (backend#1193). A build without the helper still succeeds
(joiner, attester and CI builds pass no args), but its empty labels classify
`UNAVAILABLE`.

**The release frontend is a public build (infra#974, frontend#348/#381).**
`VITE_ENABLE_FULL_STUDIO`, `VITE_ENABLE_DEMO_SURFACES` and
`VITE_ENABLE_OPERATOR_PREVIEW` and `VITE_ENABLE_CONTRACT_SURFACES` expose
internal studio, demo, operator-preview and contract-backed
routes, so they must be empty for any public or testnet build. This is enforced
twice:

- **At build time.** `testnet/Dockerfile.frontend` runs
  `testnet/frontend-build-flags-guard.sh` before `npm run build`. With the
  default `WRFCOIN_FRONTEND_BUILD_VARIANT=public`, the build fails if any
  `VITE_ENABLE_*` is non-empty, whether it comes from the build environment or
  from any `.env` file in the frontend checkout that vite could load under any
  mode (`.env`, `.env.local`, `.env.<mode>`, `.env.<mode>.local`; only
  `*.example` is skipped), in either the `KEY=value` or the dotenv `KEY: value`
  form. The check matches the pattern, so a flag the frontend adds later is
  covered too, and any non-empty value counts, not only `true`.
  **Trap:** frontend's own `.env.example` sets
  `VITE_ENABLE_CONTRACT_SURFACES=false`. A host that copies it to `.env` gets a
  refused public build, because `false` is non-empty. Empty the value or delete
  the line; the refusal message says so. (The workspace `.dockerignore` normally
  keeps `.env*` out of the build context; the file scan is defense in depth.)
- **In the release gate.** The image records
  `org.wrfcoin.frontend.variant` and one `org.wrfcoin.frontend.*` label per
  flag. `render-release-manifest.sh` classifies the frontend image as follows:
  - `STALE` if the variant is not `public` or any flag label is non-empty;
  - `UNAVAILABLE` if it has no variant label (built before this change; rebuild
    it).

  The same check covers the flag labels by pattern.
- **Stage 1.5 is not one of these flags.** `VITE_PUBLIC_READONLY_PATHS`
  (infra#983, frontend#360) builds the public read-only stage (`/explore`,
  `/explorer`, `/map`, `/search`, station detail). The public variant may set
  it, but only to empty (off, the default) or exactly `true`. Its label,
  `org.wrfcoin.stage.public-readonly`, sits outside `org.wrfcoin.frontend.*`
  on purpose, so a Stage 1.5 image can still be FRESH. The edge's station
  reads are gated separately by `PUBLIC_READONLY_API` (default `off`). Turning
  either one on is the owner's call.
- **The faucet claim step is not one of these flags either.**
  `VITE_FAUCET_OPEN` (frontend#437 W28) decides whether `/onboarding` offers
  the faucet challenge and claim. When it is empty (off, the default), the step
  says the faucet is not funded yet. It follows the same rules: empty or exactly
  `true`, never from a `.env` file. Its label is `org.wrfcoin.stage.faucet-open`,
  outside `org.wrfcoin.frontend.*`. Turn it on in a deploy window once the
  faucet is funded; that is the owner's call.

A staging image is built only on purpose: set
`WRFCOIN_FRONTEND_BUILD_VARIANT=staging` together with the flags in the build
shell or deployment env file, and the compose override passes the variant and
all four flags through. Each flag must be empty (off, unchanged default) or
exactly `true`; `false`, `TRUE`, `1`, `on` and padded values refuse the staging
build. Non-empty switches in the **frontend source tree's** `.env*` files are
refused in staging too. Use explicit build args, or Compose inputs from the
deployment shell/env file outside that tree. No runtime environment change
can alter a compiled flag: rebuild the frontend image for each deployment.
For example, set `WRFCOIN_FRONTEND_BUILD_VARIANT=staging` and
`VITE_ENABLE_CONTRACT_SURFACES=true` in that build shell to preview the
contract-backed UI. This does not enable any backend capability. infra has no
staging compose set or host. A staging image must never be tagged or deployed
as the testnet frontend, and the release manifest refuses it if it is.

The node tag the gate checks is whatever the deployed compose set renders for
`wrfcoin-node`. In the repository files that is `wrfcoin/native-chain:testnet-local`,
which the compose build produces. If a host-local override pins the node to an
AA-cut tag (`wrfcoin/native-chain:testnet-aacut-…`), that tag is the one gated,
and it must itself be built from `infra/docker/Dockerfile.core` in a shell that
sourced the helper, from a core4 checkout at `WRFCOIN_RC_CORE4_COMMIT`;
otherwise it stays `UNAVAILABLE`.

After the build, re-run the section 2 renderer. It must print
`RELEASE_MANIFEST=FRESH mode=pre_deploy` before any deploy.

**Set the pinned snapshot signer on every host before `up` (infra#1080).**
`testnet/cut-pins.env` pins `WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS`, the attested
YubiKey 9C key recorded in `testnet/ceremony/snapshot-signer-9c/`. Every host
that runs the stack needs the same value as `WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS`
in its own `.env`: the node container node and seed, the workstation, and Mango. Copy it
from the pins file, never retype it, and confirm it with the env gate:

```bash
pin="$(sed -n 's/^WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=//p' "$INFRA/testnet/cut-pins.env" | tail -1)"
grep '^WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=' "$INFRA/testnet/.env"   # must print exactly "$pin"
# if absent or different, edit that one line of the host .env to
#   WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS=<the $pin value>
bash "$INFRA/testnet/check-env-completeness.sh" <the host's -f files> --env "$INFRA/testnet/.env"
# expect: snapshot-ingest: trusted signer list valid (1 key(s)) and matches the cut pin
```

A missing value, or one that is not set-equal to the pin, is an `ERROR` in
`check-env-completeness.sh`, and the gate exits non-zero. Don't `up` past it.
The node reads the list only at start, so a host that skips this step still
comes up. Its snapshot ingest then refuses every payload:

- an empty list returns `503 SNAPSHOT_TRUST_NOT_CONFIGURED`;
- a different key returns `422` ("signer is not in trusted signer allow-list").

The value takes effect only when the container is **recreated**. A restart
keeps the old environment.

After the deploy, run it once more with `--check-running`
(`--out /tmp/wrfcoin-release-manifest.post-deploy.json`). Every service of every
gated tag must then pass a container check:

- A long-running service's container must be running exactly its tag's image.
- A one-shot service (one another service waits on with
  `service_completed_successfully`, such as `db-migrate`) must have an exited
  container that ran exactly that image and exited 0.
- A container on an older image is `STALE` ("container … running an old image").
- A one-shot that exited non-zero is `STALE`.
- A missing or stopped long-running container is `UNAVAILABLE`, and so is a
  one-shot that is still running.

A service counts as one-shot when another service waits on it with
`service_completed_successfully`, or when it has `restart: "no"`.

**Release evidence requires the post-deploy manifest.** Attach the manifest
whose JSON has `"mode": "check_running"` and `"classification": "FRESH"`, and
whose summary line reads `RELEASE_MANIFEST=FRESH mode=check_running`. It records
each gated service's `container` and `container_image_id`. A `pre_deploy`
manifest is tag-level only: it cannot see a container that was never recreated,
and it is not post-deploy evidence, however green it is.

The manifest is unsigned, so check it before accepting it, from the infra
checkout of the release being accepted:

```bash
bash testnet/scripts/render-release-manifest.sh \
  --verify /tmp/wrfcoin-release-manifest.post-deploy.json
# options: --max-age-hours N (default 24, at most 72)
#          --pins / --cut-pins may only name this checkout's own
#          testnet/release-pins.env / testnet/cut-pins.env
```

As for a render, `--verify` uses only the verifying checkout's own pins files:
any other `--pins` or `--cut-pins` file, even a copy inside `testnet/`, is
refused (exit 1). A stale copy of an earlier release's pins therefore cannot
vouch for that release's manifest. The age window is capped at 72 h; a larger or
non-numeric `--max-age-hours` is `VOID`.

`--verify` binds the manifest to the **current** release (infra#1039): the
pins it checks against are read from the pins files, never from the manifest,
so a genuine post-deploy manifest from an earlier release candidate fails.
`RELEASE_MANIFEST_VERIFY=PASS` (exit 0) requires all of the following:

- `mode` is `check_running`, `classification` is `FRESH`, and
  `membership_problems` is `[]`;
- `generated_at` is a timezone-qualified ISO-8601 time, no older than
  `--max-age-hours` (default 24 h) and not in the future (5 min clock skew
  allowed);
- `minimum_public_build_date` equals the current
  `WRFCOIN_RC_MIN_PUBLIC_BUILD_DATE`, and the current core4 pin equals
  `WRFCOIN_CUT_CORE4_COMMIT`;
- `repos.{core4,backend,frontend}.pinned` and `.head` equal the current pins,
  and `repos.infra.head` is contained in the verifying infra checkout's HEAD;
- `repos.{core4,backend,frontend,infra}.clean` is `true`;
- every group, `faucet` included, is present and FRESH with no problems (a
  manifest from a renderer that predates infra#1121 has no `faucet` group and
  fails), and each pinned group's
  `expected_revision` equals its current pin;
- every tag is FRESH, has a `sha256:` image Id, a `revision` equal to its
  group's current pin (edge and faucet: a commit contained in the verifying
  infra HEAD with `testnet/edge/` or `testnet/services/faucet/` unchanged
  since, the renderer's own rule), a non-empty
  `services` list of names, and a non-empty `containers` list of records
  covering exactly those services;
- every `container_image_id` equals its tag's `image_id`;
- long-running containers are running, and one-shots exited 0;
- every exempt record (section 2.2) is a `core4` record marked `EXEMPT`;
- the exempt records cover exactly the identity owners listed in
  `exemptions.services`;
- each exempt record's image Id and revision equal its declaration, the
  revision is an ancestor of the current core4 pin (re-checked in
  `--workspace`'s `core4`, by default the verifying checkout's parent), and its
  containers cover its services: HSM init owners on that image, `wrfcoin-seed`
  not running;
- when the manifest has exemptions, `--verify` is given the same `--exempt FILE`.
  Its sha256 must equal the recorded one, and its entries must equal the
  declarations;
- for each `--require-release-tree NAME`, the manifest was rendered with a
  verified `--release-tree NAME=DIR`. The top-level `release_trees` lists the
  names used.

Anything else is `RELEASE_MANIFEST_VERIFY=FAIL` (exit 1), with one
`RELEASE_MANIFEST_VERIFY_FINDING` line per problem; a malformed shape (for
example `containers: ["x"]`) is a FAIL line, never a traceback. An unreadable
manifest or pins file, pins without full SHAs, or a bad `--max-age-hours` is
`VOID` (exit 2). That catches a hand-edited `mode` on a pre-deploy manifest,
whose `containers` are `null`, an edited container record, a replayed or
backdated manifest, and a tag with no services. Verify within the age window of
the post-deploy render, and attach the render and verify transcripts together
with the JSON.

### 3.1 Next app-tier window: rebuild and recreate the faucet (infra#1121)

This is an owner-window step. Agents do not run it. It is recorded here so the
next app-tier window picks it up.

The running faucet is the July image (created 2026-07-02, no revision label).
r12 §6.4 only recreated that same image. Once this gate is on the deploy's infra
checkout, the section 2 render classifies it `STALE` ("predates minimum public
build date"). In the next app-tier window, in the build shell from section 3:

1. Keep the faucet in the build. `check-build-root.sh` gets
   `--service wrfcoin-faucet`, and the compose build lists `wrfcoin-faucet`
   with the host's `-f` set and `--env-file`, so that its `COMPOSE_PROFILES`
   renders the faucet.
2. Confirm the new tag carries the infra revision before any `up`:
   `docker image inspect wrfcoin/faucet:testnet-local --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}'`
   must print the full infra SHA the helper exported, not an empty line.
3. Re-run the section 2 render. `faucet` must be `FRESH` in `pre_deploy`.
4. Recreate the container with `up -d --no-deps wrfcoin-faucet`, with the same
   file set. A restart keeps the old image.
5. Run `--check-running`. `faucet` must be `FRESH`, with the
   `wrfcoin-testnet-faucet` container on the new image Id. Then run `--verify`.

What the rebuild changes for payouts. The running file is 60,704 bytes, which
matches infra `098bde5` (#616). Its parent `f650f007` is 58,156 bytes. This is
a size match only; the file content has not been hashed.

- **Transfer signature.** The July faucet signs the v1 preimage
  (`wrfcoin_transparent_transfer_auth_v1`, with no chain domain). The deployed
  core4 pin defines only `wrfcoin_transparent_transfer_auth_v2`, which folds in
  `WRFCOIN_CHAIN_ID`/`WRFCOIN_NETWORK_ID` (#626). So a funded wallet alone
  would still not pay: the node would refuse every July-signed transfer. This
  is from reading the code, not from a live test.
- **Startup.** Main's faucet exits at startup unless `FAUCET_HIGH_WATER_MARK`
  (absolute whole-WRF mark, #908) is set. The compose file deliberately has no
  default. `check-env-completeness.sh` reports an `ERROR` when the faucet
  profile is active and the mark is unset or malformed; it never prints the
  value. Run that check with the deploy's `-f` set and `--env` before step 4.
  Otherwise the recreated container restart-loops.
- **Unchanged.** The trusted-proxy captcha exemption (#857, the backend proxy
  path that mobile uses), the balance floor check (`FAUCET_WALLET_BALANCE_FLOOR`,
  default 10 WRF after the payout), and the transfer nonce (`now_ms*10^6 +
  random`, #613) are identical in both.
- **Also new on main.** `wrf…` recipient addresses are accepted and folded to
  `0x`; the July image returns `400 INVALID_WALLET` for them. There is a
  `wrfcoin_faucet_wallet_balance` gauge (#629). Malformed daily caps fail at
  startup. The `:8080` page disables direct claims when captcha is off.

Rebuilding does not fund the faucet wallet on chain 777; that is core4#3361
(owner ruling A+B). Until it lands, a claim through the rebuilt image still
fails the balance check with the same `503 FAUCET_WALLET_BALANCE_UNAVAILABLE`
("address not found"), because that path is unchanged.

## 4. Probe the public origin after the deploy

The probe performs one bounded GET per URL. It checks the root and first
`/assets/index-*.js` build dates, the three read-only viewer routes declared by
`public_onboarding.caddy`, the join manifest's JSON content type,
`/api/capabilities`, and the backend's `/api/build` stamp, whose revision must
equal `WRFCOIN_RC_BACKEND_COMMIT`:

```bash
bash testnet/edge/probe_public_build_freshness.sh \
  --origin https://wrfcoin-testnet.taila1c049.ts.net \
  --pins testnet/release-pins.env \
  --json > /tmp/wrfcoin-public-build-freshness.json
```

`FRESH` exits 0, `STALE` exits 1, and network failure is `UNREACHABLE`/UNKNOWN
with exit 2—never a pass. Attach the probe JSON and the `check_running`
release manifest (section 3), with their command transcripts, to the release
issue.

`/api/build` and `/api/capabilities` are in the public edge allowlist
(`public_onboarding.caddy`, infra#968) as exact, GET-only paths. Siblings such
as `/api/builds` or `/api/build/x` still return the edge 404. The allowlist
only takes effect once the edge is redeployed: an edge running an older
`public_onboarding.caddy` still returns 404 for both paths, and the probe
correctly stays `STALE` until then.

## 5. Local proof commands

```bash
bash scripts/tests/test-render-release-manifest.sh
bash scripts/tests/test-prepare-release-gate-workspace.sh
bash scripts/tests/test-build-provenance.sh
bash testnet/tests/test_public_build_freshness.sh
```

The manifest test serves `docker image inspect` fixtures from
`scripts/tests/fixtures/release-manifest/` through a stub `docker` and renders
this repository's real compose files with `docker compose config`. It needs the
docker CLI with Compose v2 but no daemon.

The manifest test is discovered by the self-hosted scripts gate, and the
freshness fixture has an explicit step in that same workflow. Hosted zero-step
jobs remain VOID; do not substitute them for these local transcripts or a
nonzero-step self-hosted run.

Future work may consume the probe JSON from public-release readiness logic.
That integration is deliberately excluded while #960 and #962 own the shared
launch-readiness scripts.

## Public download publication

For every public release advertised on Downloads, follow
[Publish public download metadata](PUBLIC_RELEASE.md) after preparing reviewed
artifacts and public source tags. The owner supplies the release tag and signing
key, publishes its fingerprint independently, and runs the upload/website step.
The existing deployment manifest stays private; use the renderer's explicit
`--downloads` mode for the public artifact catalog.
