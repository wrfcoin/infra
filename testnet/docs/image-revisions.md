# Exact source revisions for owner-selected testnet images

Refs infra#991, infra#1077, infra#1121. The main release Dockerfiles already
accept `ARG WRFCOIN_BUILD_REVISION` without a default. Existing generic Compose
builds can still omit it; helper and optional builds also need coverage.
`testnet/scripts/image-revisions.py prepare` emits a separate Compose JSON
overlay for **every build in the selected render**, including helper/profile
builds. Each receives the exact source SHA as `build.args.WRFCOIN_BUILD_REVISION`
and `build.labels.org.opencontainers.image.revision`, with no fallback.
Compose build labels cover recipes that do not consume the argument themselves.
Pulled third-party images receive no invented source label.

The primary source is core4 for both node/attester targets, backend for the
backend recipes, frontend for the frontend recipe, and infra for local helpers.
A separate oracle-reference checkout needs its own explicit pin. Unknown
workspace recipes, outside contexts, conflicting shared image tags, missing or
malformed pins, dirty/untracked source, or Git HEAD disagreement refuse. Both
the primary source and the recipe's checkout must be clean and pinned. A
workspace-level source recipe has an explicit mapping that needs review when
its COPY layout changes. This label is provenance metadata, not binary
reproducibility, whole-workspace input attestation or proof of runtime behavior.

## Owner adoption in the next r-step build window

This companion is not automatically added to existing r19 steps. LEAD must
stage the reviewed script and adopt the overlay in the same build's final `-f`
set. Preserve existing build-root, freshness, manifest, context-change and
retained-image exception gates. A retained image with a different revision
fails the strict comparison here; do not substitute current pins to relabel it.

Create a private `r-step-source-pins.json` from the reviewed step pins, without
sourcing shell code in the checker. Its schema is a repository-name to full
lowercase 40-hex SHA map. For r19, backend/infra/frontend come from R19_BE,
R19_IN and R19_FE, and core4 from the matching release/cut pin. No placeholders
are accepted. Additional selected source repositories need reviewed pins too.
Select the already prepared clean workspace and the exact build file/profile
set. Renders may contain secrets: keep them private and never print them.

```bash
umask 077
# Owner only: use the actual reviewed Compose arguments and private env file.
docker compose <build global arguments> config --format json > selected.json
python3 image-revisions.py prepare --root "$R19_G" \
  --pins r-step-source-pins.json --render selected.json > revision-overlay.json
# STOP on any nonzero result; never consume a partial/empty overlay.
# Append -f revision-overlay.json LAST to the same Compose arguments.
# Render that final set and run the existing build-root gate before any build.
# The existing owner build step then uses that identical final file/profile set.
```

Preparation performs Git reads only; it never builds, pushes or changes source.
Reprepare after any source/pin/file/profile change. JSON is valid Compose input;
merging this overlay preserves the other args, labels, targets and service
settings. No container-level label override is emitted.

## Owner-only read-only running check

After the authorized owner build/start step, use the same selected render and
pins, with the actual Compose project and every mandatory running local service.
One-shot db-migrate or inactive profiles should not be mandatory running names.
All observed running services whose image is built in that render, including
image-sharing aliases, are checked automatically. Unknown project services,
unmapped `wrfcoin/` images and absent mandatory services refuse.

```bash
python3 image-revisions.py check --root "$R19_G" \
  --pins r-step-source-pins.json --render selected.json --project <project> \
  --require wrfcoin-node --require wrfcoin-backend --require wrfcoin-frontend
```

Only `docker ps`, formatted container inspection and image inspection by actual
image ID are used, against the owner's selected local Docker context. Both
container and image revision must equal the pinned source. Container identity,
running status, project, service, image ID and revision are rechecked, followed
by another inventory. Reads have a 15-second command timeout, 256-container
limit and input/output size checks. Credentials, full labels, environment and
Docker error text are not emitted. A successful report is revision evidence at
those reads, not an atomic snapshot or a healthy application/deployment verdict.

Local validation uses synthetic Git checkouts and a Docker metadata transport;
a real Compose config merge runs without the Docker daemon. No running testnet,
host, registry push or image build was used to produce local evidence.
