# WRFCoin `<release tag>`

Public testnet. Testnet tokens have no monetary value, and the network may be reset.

> Maintainer: copy this template after the public manifest staging step. Replace
> every placeholder using the staged manifest and reviewed evidence before
> publishing a GitHub Release body. Do not paste the private deployment manifest.
> Signing keys are planned after launch; until signed artifacts are actually
> published, say **not yet published** and omit unavailable download links.

## What changed

- `<User-visible change present at the source commit; include limitations.>`
- `<Compatibility or migration notes, or explicitly “None”.>`

## Source commits

| Component | Source repository | Tag | Full source commit |
| --- | --- | --- | --- |
| `<manifest artifact id>` | `<manifest repository>` | `<manifest tag>` | `<40-character manifest commit>` |

Include every distinct source, including `node-source`. Public snapshot repositories
start with one clean commit and do not include the private development history.

## Artifacts and SHA-256

| Artifact | Platform / architecture | Bytes | SHA-256 | Download |
| --- | --- | --- | --- | --- |
| `<file artifact id>` | `<validated platform>` | `<manifest size>` | `<manifest sha256>` | `<manifest url>` |

Copy file rows from `manifest.json`, cross-check against `SHA256SUMS`, and remove
this example row if no binaries are published. Git source entries have no file
checksum; list their commits above, not an invented SHA-256. Do not label a
platform supported unless execution evidence exists for this release.

Metadata assets: `manifest.json`, `SHA256SUMS`, `manifest.json.asc` (only after
successful signing/publication). Link the actual GitHub Release assets here.

## How to verify

1. Obtain the signing public key and full fingerprint from the independently
   published WRFCoin security policy / organization profile. A key delivered only
   beside the download is not an independent trust anchor. If this information or
   the signature is absent, signed verification is unavailable; do not claim it passed.
2. Download the manifest, detached signature, checksum list and chosen artifacts
   from this release. Check the full signing fingerprint against that trusted source.
3. With the verified public key available to GPG, run:

   ```sh
   gpg --verify manifest.json.asc manifest.json
   sha256sum -c SHA256SUMS
   ```

4. Confirm each downloaded filename, byte size and SHA-256 matches the **signed
   manifest** as well as the checksum list. An unsigned checksum list alone does
   not authenticate an artifact. Confirm each source tag points to its listed commit.

## Known issues and validation

- `<Known limitations, experimental features, unavailable artifacts and upgrade risks.>`
- Tested platforms: `<OS / architecture actually exercised, or UNVERIFIED>`.
- Evidence: `<source SHA, executed command/check and result; no skipped or zero-step success claims>`.
- Public download serving: `<verified evidence or UNVERIFIED>`.
