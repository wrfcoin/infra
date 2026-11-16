# Check a proposed public node release

The join source pin, website source downloads and Windows installer must support every feature already signed into the chain schedule, including features that are not active yet. Protocol version alone does not establish this.

Run the read-only source preflight before building or publishing. It does not start Docker, download code, read credentials or modify a checkout:

```sh
python3 scripts/check-node-release-compatibility.py \
  --core4-repo /path/to/core4 \
  --schedule /private/path/schedule-capture.json \
  --downloads-manifest /path/to/frontend/public/downloads/manifest.json
```

The default candidate is the full commit in `testnet/cut-pins.env`. For a Windows build, pass `--candidate <full-public-commit>` and omit the source-download manifest unless those source entries intentionally describe the same release.

Use an authenticated read from an established node to capture `/network/upgrade`, plus its verified chain/network identity, without logging credentials. Wrap the response:

```json
{
  "captured_at": "<UTC ISO8601 time of capture>",
  "chain_id": "888",
  "network_id": "testnet",
  "upgrade": { "...": "the complete /network/upgrade response" }
}
```

The capture is an operator-supplied input, not independently authenticated by this script. Keep it in private release evidence, not in the public repository. The gate rejects captures older than 24 hours, future timestamps, incomplete or provisional schedules, malformed entries, and missing candidate features. Re-capture immediately before release or after any new schedule is signed. A PASS records `source-preflight-only` and `runtimeReplay: not-run`.

## Hardening parity

The release owner may repeat `--required-commit <full-reviewed-public-fix-commit>` for every required fix. The candidate must contain each commit by ancestry. Supply this list from the reviewed release checklist; do not put private commit hashes or incident descriptions into public files. Without this option the result explicitly says `hardeningReview: not-requested`.

An ancestry check does not establish behavioral equivalence or catch reverts. It intentionally refuses a cherry-picked equivalent commit until the owner reviews it and supplies the appropriate public commit. Record actual regression-test results and the exact artifact source alongside the gate result.

## Runtime acceptance still required

Before publishing new join pins:

1. Run the exact default website join command in an isolated machine/container with no access to producer state or keys.
2. Verify chain identity, convergence at a common height and continued block following on Linux and native arm64.
3. Rehearse any upcoming activation with the exact release binary, including Windows where advertised.
4. If publishing a snapshot, regenerate and verify its exact matching `core4_commit`; old snapshots remain refused. Joining from genesis is the default.
5. Update `cut-pins.env`, the matching core4 entry in `release-pins.env`, and only `node-source`/`cli-source` in the website manifest together. Preserve genesis/network identity and separately owned installer entries.

Do not run a default join in an existing producer workspace. Local source checks, hermetic script tests, hosted builds and runtime convergence are distinct evidence.
