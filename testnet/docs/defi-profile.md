# Optional read/quote DeFi simulator (Refs #943)

The `defi` profile packages `defi-protocols` revision
`b71a90b1322d83b8368ebc9fe2376768e2d4e7ac`. ADR 0001 and ADR 0002 in that
repository authorize a standalone, noncustodial simulator for the testnet phase.
It serves two fixture pools and deterministic quotes. Every supported response
identifies `simulated: true`, `custodial: false`, and `settlement: "none"`.
Portfolio is unavailable (501); swap, transfer, deposit and withdrawal are absent.
This profile does not connect to node state, hold keys, or move balances.

The overlay is `testnet/docker-compose.defi.yml`. Without `--profile defi`, the
service is absent. The overlay forwards `DEFI_NODE_URL` to the existing backend
relay, but leaves it empty by default. The owner must explicitly set
`DEFI_NODE_URL=http://wrfcoin-defi:7100` when enabling the simulator. The existing
relay supplies pools and quotes; portfolio remains honestly unavailable. Its
optional healthy dependency permits normal backend operation without this profile.
Compose 2.20 or later is required for `depends_on.required: false`.

## Cache-first image preparation

Run from the infra checkout, with the pinned DeFi repository beside it. Python
3.11+, Docker, existing `rust:1.88-bookworm` and
`gcr.io/distroless/cc-debian12:nonroot` images, at the exact index digests pinned in the Dockerfile, and a populated public crates.io
sparse cache are prerequisites. If any required input is absent, STOP; this
procedure never installs tools or fetches crates. Observe the sprint's memory and
heavy-job admission rules before building.

```bash
python3 scripts/prepare-defi-build.py --source ../defi-protocols
docker image inspect \
  rust:1.88-bookworm@sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0 \
  gcr.io/distroless/cc-debian12:nonroot@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
docker build --pull=false --network=none \
  --build-arg DEFI_REVISION=b71a90b1322d83b8368ebc9fe2376768e2d4e7ac \
  -t wrfcoin/defi-node:testnet-simulator-b71a90b1322d testnet/services/defi
```

The preparation script reads immutable Git objects, selected public index metadata
and lockfile-checksummed crate archives. It excludes working-tree changes and Cargo
credentials. `.cache/manifest.json` records the source revision, hashes, byte count
and absent archives; `.cache/` is ignored by Git. Missing optional/dev archives are
reported: only a successful `--offline --locked` runtime build proves they are
unneeded. An existing output directory is refused; archive the old prepared context
and use a fresh one when rebuilding. The Docker context includes only that prepared
cache, the Dockerfile and the small Rust health probe. Build networking is disabled;
Cargo uses three jobs. The legacy Docker builder works without buildx.

## Owner activation and verification

Include the DeFi overlay in the owner's existing reviewed Compose file list,
preserving the base, override, cut and other profile files. Render the effective
configuration first. Select `--profile defi` and the explicit `DEFI_NODE_URL` above.
Use a backend image containing the merged DeFi router and its API mount; a stale
image cannot gain that route from an environment setting.
Build only `wrfcoin-defi` (the overlay's build also uses network `none`), or use the
prepared image command above. For a cached legacy builder without buildx, set
`DOCKER_BUILDKIT=0` for the Compose build. Owner startup must use `--no-build --pull never` and
target the simulator and backend; follow the existing owner procedure for backend
recreation and dependencies. Do not start the entire stack just to enable this
profile. This document is packaging guidance, not a lane deployment instruction.

The daemon binds port 7100 on the internal Compose network, with no host-published
port, persistent custody volume or privileged access. The distroless runtime uses
UID 65532, a read-only filesystem, dropped capabilities and no new privileges.
Its health executable makes a bounded local `GET /health`, rejects non-200,
truncated and oversized status lines, and needs no shell or curl.

Confirm healthy status and the revision image label. Through the existing backend
API, check `/api/defi/pools` and `/api/defi/pools/1/quote` (POST with
`{"amount_in":"100000000","direction":"a_to_b"}`). Confirm simulator flags
and the unavailable portfolio response before presenting results to users.
Disable by clearing the backend target and recreating it under the owner's normal
procedure, then stop/remove only the simulator and omit its profile/overlay.
There is no migration, genesis update or feature schedule change.

For a local disposable runtime proof, first prepare the image above, then run
`python3 scripts/tests/test-defi-runtime.py`. This additionally requires an existing
`node:24-alpine` image as its HTTP client. It never builds/pulls or starts the base
stack; it creates a uniquely named internal network and simulator, makes requests
through that container's network namespace, and removes them on exit. The regular
Python suites cover real default/enabled Compose rendering, cache integrity and the
health executable; the explicit runtime proof is separate from CI's static gates.
