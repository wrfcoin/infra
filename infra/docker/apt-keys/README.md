# Pinned apt signing keys

Keys that Dockerfiles in this directory install instead of fetching at build time.

## yubico-stable-ppa.asc

`ppa:yubico/stable` signing key, used by `Dockerfile.core` for `ykcs11` and `yubico-piv-tool` (infra#1016).

| | |
|---|---|
| UID | Launchpad PPA for Yubico |
| Algorithm | RSA 4096, created 2024-05-03 (1714716106) |
| Fingerprint | `990B D85D 1C4F 411A BC0E  CE8D FA4E C8F2 EE58 CE0B` |
| File SHA-256 | `05e109492dfdef1245211c060a955e3db7fbe392c3377b6df984040281f16ce3` |

**Why it is checked in.** `add-apt-repository ppa:...` resolves the key through the Launchpad REST API (`api.launchpad.net`). That host is unreachable from this network and from CT102, so the build could not complete there. The package host, `ppa.launchpadcontent.net`, is reachable.

**Provenance (2026-09-23).** Three independent paths agree on the fingerprint:

1. The PPA's own `dists/noble/Release.gpg` and `InRelease` on `ppa.launchpadcontent.net` carry an issuer-fingerprint subpacket naming `990BD85D1C4F411ABC0ECE8DFA4EC8F2EE58CE0B`.
2. The Launchpad API answers `signing_key_fingerprint: 990BD85D1C4F411ABC0ECE8DFA4EC8F2EE58CE0B` for `~yubico/+archive/ubuntu/stable`. This was a read-only GET from a host on a different network, where the API is reachable.
3. This file was fetched from `keyserver.ubuntu.com` by that full fingerprint (`/pks/lookup?op=get&options=mr&search=0x990BD85D…`) and stored byte-for-byte. `gpgv` against this key alone reports a good signature on both `Release` and `InRelease`.

The PPA also still carries a second signature, from Launchpad's legacy 2012 1024-bit key `3653 E210 64B1 9D13 4466  702E 43D5 C495 32CB A1A9`. That key is deliberately **not** pinned: apt needs one valid signature, and a 1024-bit RSA key should not be a trust root.

**Checks.**
- `scripts/tests/test-dockerfile-core-yubico-key-pin.sh` (hermetic) recomputes the fingerprint from the key packet and matches this file against the `YUBICO_PPA_KEY_SHA256` build ARG.
- `scripts/tests/test-dockerfile-core-yubico-ppa-signature.sh` (network) verifies the live InRelease against this key only.
- The build itself runs `sha256sum -c` on the copied key before apt uses it.

**Rotation.** If Launchpad rotates the PPA key, the signature test fails first. Fetch the new key by fingerprint and re-derive the three provenance checks above. Then update this file, the checksum ARG and `EXPECTED_FPR` in the hermetic test together.
