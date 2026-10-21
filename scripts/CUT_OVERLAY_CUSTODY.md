# Node genesis overlay custody

Refs #969 and #828. Owner-run checks only; no host, node or Compose action is
performed by the checker. Actual deployed bytes have not been inspected.

`testnet/scripts/render-cut-overlay.sh` is the canonical writer of
`testnet/docker-compose.cut.yml`. `testnet/bootstrap.sh` invokes it in
`build_images` (the `--skip-build` path skips this invocation). The owner also
invokes it explicitly in `testnet/CUTOVER_RUNBOOK.md`. It reads the reviewed
`cut-pins.env` as data, never sources it, and writes the node genesis hash and
optional genesis faucet address. No pin or chain state is changed.

Release preparation currently copies the host-local overlay: r18/r19 step
`07-prepare-def.sh` copies `docker-compose.cut.yml` into the new tree. That copy
path must carry `docker-compose.cut.yml.custody.json` too and run the checker
against the staged tree's reviewed pins and writer before any consuming owner
step. Those W18-owned release files are not amended by this change. The pending
cut toolkit (#941/#942) generates other host-specific overlays; it does not
write this file. Hand edits and other writers cannot produce a valid canonical
overlay by placing a matching genesis line under another service or comment.

Each successful render writes an ignored sibling `.custody.json` with schema,
canonical writer path, and SHA256 of the writer, Python checker, complete pin
file and overlay bytes. It carries no faucet address, credentials, coordinates,
timestamp or invented operator identity. Both output files use atomic rename
individually; they are not a joint transaction. An interruption between writes
leaves a pair which must pass the checker before consumption. A record error
never prints PASS.

From the reviewed infra checkout (Python 3 and Bash required):

```bash
# Initial adoption: generate privately, compare existing bytes before adoption.
stage=$(mktemp -d)
bash testnet/scripts/render-cut-overlay.sh \
  --pins testnet/cut-pins.env --out "$stage/docker-compose.cut.yml"
cmp testnet/docker-compose.cut.yml "$stage/docker-compose.cut.yml"
# Stop if cmp fails; the owner must review the difference, never normalize it blindly.
cp "$stage/docker-compose.cut.yml.custody.json" testnet/
bash testnet/scripts/render-cut-overlay.sh --check
```

Run each line only after the preceding command succeeds. Remove the owned
temporary staging directory after adoption. For a deliberate new pin/renderer
revision, stage and review the new overlay before replacing the pair. Existing
overlays without a record now fail `--check`; it never creates a missing record
or repairs drift. Any change to the complete pin file, writer or checker
requires an explicit owner render, even if the genesis itself is unchanged.

After copying the pair into a release, from that release's infra checkout:

```bash
bash testnet/scripts/render-cut-overlay.sh --check
```

The checker first validates pin syntax and the existing genesis/faucet contract,
then compares the entire overlay to its canonical render and verifies all record
fields/checksums. Missing, malformed, duplicate-field, oversized, stale and
symlinked records fail. Symlinked pin/overlay paths also fail. Copying a pair to
a different directory is supported; paths in the record are repository-relative.
Logs name only the genesis hash and faucet status, never the faucet address.

This is local file integrity, not signed provenance or protection against an
attacker who can replace the reviewed writer and record together. Verify the
checkout through the existing release admission process. `compose-inputs.sh`
still guards overlay existence only; boot does not automatically run this
checker. The owner release/boot preflight must invoke it explicitly. It checks
this overlay, not final Compose precedence: retain the existing effective-file
set and rendered-genesis gates for any later overlays. In particular, include
the checked overlay in the Compose file set actually used by the owner.

The discovered Python gate executes `scripts/tests/test_cut_overlay_custody.py`;
the existing renderer/faucet shell fixtures retain their coverage. No SDK,
registry, packages, image rebuild, migration, feature schedule or restart is
needed for these file checks.
