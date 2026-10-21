# Publish public download metadata

This owner-run step is required for each public release advertised on Downloads.
It stages `manifest.json` and `SHA256SUMS`, then signs the manifest, uploads the
metadata and file artifacts to an existing GitHub Release, and switches the
website metadata directory. It does not build binaries or create releases.

The existing entry point `scripts/render-release-manifest.sh --downloads` emits
the public catalog required by infra#1341. Without `--downloads`, its existing
private deployment-evidence format and checks are unchanged. Never publish the
private deployment manifest: it contains operational details. Only the explicit
public fields below enter the download catalog.

## Owner inputs

- First release tag and public release repository; create the GitHub Release
  first. This command refuses a draft release or a private release repository.
- Already-published source tags and full commits, with local checkouts containing
  those tags. Every source repository must also be public. Explicit remote tag references
  are checked before signing and uploading; annotated tags are followed to
  their commits, and a same-named branch cannot substitute for a missing tag.
- Reviewed, distributable binaries (the unsigned mobile compile proof is **not**
  a release APK), their source commits/tags, and unique filenames. Include the
  APK only once mobile#443 ships; include any CLI archives actually released.
- An existing GPG signing key in the owner's keyring/hardware setup and its full
  signing-key fingerprint. No key generation or import occurs here. Publish the
  fingerprint and public-key retrieval instructions in the security policy and
  organization profile before offering downloads. These publication decisions
  and key custody remain with the owner. A checksum or a key shipped only beside
  a download is not an independent trust anchor.
- The website directory mounted into the edge (`WRFCOIN_DOWNLOADS_DIR`, default
  `/var/lib/wrfcoin-downloads`) and permission to write it. Run the command on the
  publication host as the operator; agents must not access that host.

## Stage and inspect

Create a local spec outside the repository. Replace all example placeholders;
never put signing material in it. Example structure (add a `kind: "file"` row
only for each real artifact available for this release):

```json
{
  "repository": "wrfcoin/infra",
  "release": "OWNER_RELEASE_TAG",
  "artifacts": [
    {
      "id": "node-source",
      "kind": "git",
      "repository": "wrfcoin/core4",
      "checkout": "/path/to/core4",
      "commit": "FULL_SOURCE_COMMIT",
      "tag": "PUBLISHED_SOURCE_TAG"
    },
    {
      "id": "android",
      "kind": "file",
      "repository": "wrfcoin/mobile",
      "checkout": "/path/to/mobile",
      "commit": "FULL_SOURCE_COMMIT",
      "tag": "PUBLISHED_SOURCE_TAG",
      "path": "/path/to/release.apk"
    }
  ]
}
```

From the infra root, with a new output directory:

```bash
bash testnet/scripts/render-release-manifest.sh --downloads \
  --spec /path/to/spec.json --out /path/to/staged-release
```

Use the [GitHub Release body template](../release/RELEASE_TEMPLATE.md) during
this manifest step. Copy it to a separate draft after staging:

```bash
cp release/RELEASE_TEMPLATE.md /path/to/release-body.md
```

Fill the source table from each artifact's `repository`, `tag` and `commit`, and
the file table from `id`, `size`, `sha256` and `url` in the staged public manifest.
Record only platforms actually tested. Add user-visible changes and known issues,
remove all placeholders, and have the owner review the body before creating the
release required by the publication step. The renderer does not publish or edit
the release body. Signing keys are planned after launch; until then Downloads
remains **not yet published**, and a staged catalog is not a release.

Inspect the catalog and run `sha256sum -c SHA256SUMS` in the output directory.
Every artifact retains its source `repository` alongside its commit and tag,
including files uploaded to a different release repository. `git` artifacts
have a commit/tag and a commit URL, with `size`/`sha256` set to
`null`; files have computed byte size and SHA-256 plus their GitHub Release URL.
The staged catalog uses `published: false` and is **not published evidence**.
The publication step regenerates it with `published: true` before signing; only
successful completion makes that signed catalog available to website readers.
No signing or network commands run during staging. Requirements: Python 3.11+,
git; publication additionally needs authenticated `gh` and GPG.

## Sign, upload, and switch the website

After reviewing the bytes and independently publishing the trust anchor:

```bash
bash testnet/scripts/render-release-manifest.sh --downloads \
  --spec /path/to/spec.json --out /path/to/new-publication-receipt \
  --publish --signing-fingerprint FULL_SIGNING_KEY_FINGERPRINT \
  --website-dir /var/lib/wrfcoin-downloads
```

The command copies the input files to a private staging directory, hashes those
copies, signs `manifest.json` as `manifest.json.asc`, verifies that signature
against the requested fingerprint, then uploads files plus all three metadata
assets without overwriting existing release assets. `SHA256SUMS` uses the same
file hashes as the signed catalog; do not trust an unsigned checksum list alone.
It switches a relative `current` symlink only after upload succeeds, exposing
byte-identical metadata under both configured edges at:

- `/downloads/manifest.json`
- `/downloads/SHA256SUMS`
- `/downloads/manifest.json.asc`

Deploy the new Caddy snippets and compose mounts through the normal owner
release procedure. The mount is the parent directory, so atomic symlink changes
are visible without recreating the edge. No directory browsing is enabled.
The frontend page remains served by its normal proxy; these three exact files
come from the release directory. Before the first publication, they return 404.
After publication, fetch all three through the public website and compare them
byte-for-byte with the GitHub Release assets and local receipt. Verify the
signature and artifact checksum again. Until this check is recorded, public
serving and signing are **UNVERIFIED**.

A failed upload may leave some GitHub assets present; the website pointer stays
unchanged. Do not retry with overwrite flags. Inspect the release, reconcile
partial assets as an owner decision, and rerun with a new output directory.
A website write failure after upload also needs owner reconciliation. Keep the
previous version directories for rollback; the owner can atomically repoint
`current` to a previously verified directory. Never hand-edit a signed manifest.
