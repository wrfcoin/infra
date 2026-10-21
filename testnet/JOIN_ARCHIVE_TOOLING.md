# Offline detached join-archive tooling (Refs infra#1304)

`join-archive.py` signs a bounded, structured manifest and verifies it against
an independently delivered archive public-key pin and chain ID. It runs locally
on Linux using Python 3.8+ and OpenSSL 3 with Ed25519 support; no Python package
installation is needed. It makes no network requests and invokes no Docker,
restore, promotion, service, hardware provisioning or key-generation command.

This delivers the standalone file signer/verifier subset of #1304. The issue
remains open for hardware custody, authenticated release pins, full identity and
provenance policy, signed restore/promotion/probes, authenticated time/header
peers, quotas, durable anti-rollback floors and incident procedures. A successful
`JOIN_ARCHIVE_VERIFY=PASS` proves signature, structured manifest, chain-ID and
receipt clock validity and exact staged-file digest/length checks. It does not authorize publication or a
join, prove state correctness, or certify the supplied receipt's provenance.

## Existing source paths

Preflight at infra main `98887f3bb5188659381f1e4ff351d96c27e60a24` found:

- `testnet/publish-join-snapshot.sh` stages `snapshot.tar.gz` containing
  `wrfcoin.redb`, obtains the frozen-copy receipt and writes unsigned
  `manifest.json`. `promote-join-snapshot.sh` publishes the checked staged pair.
- `join-snapshot-restore.sh` checks unsigned manifest identity, core4 revision,
  compressed archive SHA256 and one-regular-root-member shape before creating a
  new volume. `join-testnet-sync-node.sh` invokes this restore path.
- The daily weather archive worker is separate:
  `docker-compose.weather-archive.yml` runs the backend's
  `dist/weather_ipfs_archive.cjs`. Daily ZFS snapshot timers also exist;
  neither is the join archive signer or join restore consumer.
- Core4 reserves `wrfcoin.join_archive.v1` for infra in
  `docs/security/DOMAIN_TAGS.md`. Native snapshot ingestion uses a separate
  trust boundary and does not authenticate the compressed redb tar.

Open infra PR #1198 contains the design, rather than executable signed
publication tooling. This CLI uses its reserved preimage framing, with a
separate explicit **detached schema**. It does not implement or claim compatibility
with the design's `wrfcoin.join_archive.signed.v1` base64 envelope. Existing
publication/restore tools do not consume this detached format. No existing
service, Compose file, native-ingest pin or legacy restore behavior is changed.

## Dedicated key and pin contract

The archive key must be independently held, **never the node's YubiKey PIV 9C
or producer 9A**, and never another slot on a node-accessible device. This
software-file CLI is a bounded tooling primitive and synthetic rehearsal aid;
it is not a hardware ceremony or owner approval to replace hardware custody.
The CLI cannot infer a key's custody or role from its bytes. Owner review must
establish that separation and authenticate the archive public pin before use.

`--key-file` is an unencrypted Ed25519 PEM private-key file, exactly mode 0600,
owned by the current effective user, regular, and with one hard link. Final
symlinks, special files, other permissions (including 0400), wrong algorithms,
wrong pinned key and files over 4096 bytes are refused. Validation uses the
opened descriptor; OpenSSL reads that same inherited descriptor through
`/proc/self/fd`, avoiding a pathname reopen race. The parent custody directory
must be owned by the current effective user and exactly mode 0700; the signer
enforces both against an opened directory descriptor and opens the key relative
to it. A final symlink for that directory is refused. Ancestor directory custody
remains the operator's responsibility. No secret is accepted through argv,
stdin or an environment setting. WRFCOIN join-archive private/signing-key and
secret environment names are explicitly refused even when a key file is supplied.
Errors omit input values, paths and OpenSSL diagnostics; output contains only
fixed success/failure messages. The script never prints or copies key contents.

`--public-key-file` contains exactly 64 lowercase hex characters (32-byte raw
Ed25519 public key), optionally followed by one LF. It is supplied independently
by the joiner/custodian, never read from the downloaded manifest. The signer
also requires this pin and checks its derived public key against it.

## Structured receipt and files

`--receipt` is bounded UTF-8 JSON with exactly these fields. No defaults,
unknown fields, duplicate keys or caller-provided preimage/digest are accepted.

| Fields | Type/meaning |
| --- | --- |
| `bundle_id`, `network_id` | 1–128 ASCII letters, digits, `_` or `-`; reviewed frozen-copy identity |
| `genesis_hash`, `tip_hash_hex`, `state_root_hex`, `schedule_digest` | Bare lowercase 64-hex digests |
| `core4_revision`, `infra_revision` | Full lowercase 40-hex source revisions |
| `source_image_id`, `source_image_digest` | `sha256:` plus 64 lowercase hex characters |
| `node_binary_sha256` | Bare lowercase 64-hex executable digest |
| `height`, `checkpoint_format`, `protocol_version` | Unsigned 64-bit JSON integers; booleans/floats refused |
| `created_at_utc`, `expires_at_utc` | Unsigned 64-bit Unix seconds; expiry strictly greater than creation |

Every field must come from the reviewed frozen-copy evidence. The existing
unsigned publisher's receipt is insufficient; do not manufacture missing values
or borrow them from a moving node. This primitive validates field structure and
signs the supplied metadata; it cannot establish provenance itself. Signing
refuses any creation time later than the current UTC clock and any expired
receipt. Verification refuses `now >= expires_at_utc` and creation more than
60 seconds ahead of now. The clock is local Unix UTC seconds (`time.time`), so
operators must maintain a trustworthy system clock. Tests inject a clock through
the Python `main(..., clock=...)` entrypoint; the CLI has no clock override.
These checks do not authenticate time peers or implement durable anti-rollback.
Chain ID comes from required `--chain-id` and is independently compared during
verification. Other identity/provenance fields are bound by the signature but
are not compared to release policy by this primitive.

Use an immutable, owner-controlled staging directory. `--file` names each
file included in the manifest, including required `snapshot.tar.gz`. Maximum:
32 distinct root basenames, 1–128 ASCII letters/digits/dots/underscores/hyphens,
starting with a letter/digit. Subdirectories, traversal, absolute paths and
symlinks are refused. The signer computes SHA256 and byte length of **each
listed file** and sorts records by name. Hashing streams in 1 MiB chunks and
refuses a size/mtime/ctime change during reading. Verification rehashes every
listed file and compares both digest and size. Verification walks the staged
tree relative to its opened root and requires exactly the signed root files.
It refuses every extra entry, including hidden files, symlinks, special files,
and directories (even empty ones); there is no unsigned allowlist. Keep the
manifest, detached signature, receipt and pin outside `--directory`.
Signing selects the named files; verification enforces the exact staged set.
This does not perform tar extraction. Compressed archive bytes are authenticated, not decompressed
member shape or restored chain state. Keep stage files frozen through use;
this primitive does not lock files against a concurrent writer after hashing.

## Byte contract

Manifest schema: `wrfcoin.join_archive.detached.v1`, exactly the top-level fields
`schema`, `chain_id`, `receipt`, `archive`, `files`. `archive` is
`snapshot.tar.gz`; each file record has exactly `name`, `sha256`, `size_bytes`.
The manifest is limited to 16384 bytes and written without a trailing newline.
Canonical JSON uses ASCII, sorted object keys, no insignificant whitespace,
and decimal unsigned integers. All accepted string fields are ASCII. File
records appear in ascending name order. Unknown fields, duplicate JSON keys,
noncanonical JSON and missing/duplicate files are refused.

The exact signed preimage is:

```text
ASCII("wrfcoin.join_archive.v1") || 00 || u64_be(len(manifest_bytes)) || manifest_bytes
```

Length counts bytes, not characters. There is no bincode, JSON reserialization
before signature verification, or caller-selectable domain. The detached
signature is exactly 64 raw Ed25519 bytes. The verifier checks it over the
downloaded bytes **before** parsing, then validates schema/canonical encoding,
the independently supplied chain ID, receipt clock validity, exact staged tree
and every file digest/length. No unsigned
fallback exists. Raw-manifest signatures, native-prefix signatures and a
little-endian length prefix fail.

## Local CLI usage

These commands use placeholders for already-reviewed local staging/custody
files. They neither generate a key nor authorize an owner ceremony. Keep
output paths outside the staged directory and use a new private staging directory.

```sh
python3 testnet/join-archive.py sign \
  --directory /offline/stage --file snapshot.tar.gz \
  --receipt /offline/evidence/frozen-receipt.json --chain-id 777 \
  --key-file /offline/custody/archive.pem \
  --public-key-file /offline/pins/archive.pub \
  --manifest /offline/signed/manifest.json \
  --signature /offline/signed/manifest.sig

python3 testnet/join-archive.py verify \
  --directory /offline/stage --chain-id 777 \
  --public-key-file /offline/pins/archive.pub \
  --manifest /offline/signed/manifest.json \
  --signature /offline/signed/manifest.sig
```

Exit 0 means the stated primitive checks passed; refusal exits 1, argument
errors exit 2. Outputs use exclusive creation and mode 0600; nothing existing
is overwritten. This is not a pair-publication transaction: interrupted signing
or a preexisting signature path can leave a manifest without its signature.
Verification refuses a partial pair; retry with fresh owner staging paths.
No public pin or secret is installed in a host/service by these commands.

## Tests

```sh
python3 -m pytest scripts/tests/test_join_archive.py -q
```

The existing Scripts Tests workflow discovers this suite under `scripts/tests/`.
It runs real CLI subprocesses and real OpenSSL Ed25519 operations against
temporary synthetic keys/files. Controls include tampered archive/extra file,
wrong pin/chain, metadata/signature mutation, unsigned downgrade, mode/env/
symlink/hardlink refusal, invalid schemas and integers, unsafe paths, fixed
framing bytes and independently constructed OpenSSL verification. Clock tests
cover exact expiry, future creation, the 60-second verification skew and real
CLI clock checks; tree controls include nested/hidden/unsigned entries, and
key controls include parent permissions and a symlinked parent. These prove
local tooling behavior, not hardware custody, live restore or deployment.
