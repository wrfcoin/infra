#!/usr/bin/env bash
# Hermetic coverage for infra#1016: Dockerfile.core installs the Yubico PPA from
# a CHECKED-IN signing key rather than `add-apt-repository`, whose key lookup
# goes through api.launchpad.net (unreachable from this network and CT102).
#
# What this proves, with no network:
#   1. No `add-apt-repository` instruction survives in Dockerfile.core, so the
#      build cannot silently regress to the Launchpad API.
#   2. The checked-in key file's SHA-256 equals the ARG the build verifies it
#      against, so the in-build `sha256sum -c` cannot drift from the file.
#   3. The key file's OpenPGP v4 fingerprint (computed here from the key
#      packet itself, no gpg needed) is the one Launchpad publishes for
#      ppa:yubico/stable. That value is fixed below, and its provenance is in
#      infra/docker/apt-keys/README.md. A swapped key file fails here even if
#      someone also updates the checksum ARG to match it.
#   4. The apt source is `signed-by=` the exact path the key is COPYed to.
#
# Whether the pinned key actually signs the live PPA is checked by
# test-dockerfile-core-yubico-ppa-signature.sh, which needs the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.core"
KEYFILE="${ROOT}/infra/docker/apt-keys/yubico-stable-ppa.asc"
EXPECTED_FPR="990BD85D1C4F411ABC0ECE8DFA4EC8F2EE58CE0B"
KEY_DEST="/usr/share/keyrings/yubico-stable-ppa.asc"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -f "${KEYFILE}" ] || fail "missing ${KEYFILE}"

# 1. no build-time Launchpad key lookup (comment lines are allowed to mention it)
if grep -vE '^[[:space:]]*#' "${DOCKERFILE}" | grep -q 'add-apt-repository'; then
  fail "Dockerfile.core still runs add-apt-repository (needs api.launchpad.net, infra#1016)"
fi

# 2. checksum ARG matches the file
pinned="$(sed -n 's/^ARG YUBICO_PPA_KEY_SHA256=//p' "${DOCKERFILE}")"
[ -n "${pinned}" ] || fail "ARG YUBICO_PPA_KEY_SHA256 not found in Dockerfile.core"
actual="$(sha256sum "${KEYFILE}" | cut -d' ' -f1)"
[ "${pinned}" = "${actual}" ] || fail "key checksum ARG ${pinned} != file ${actual}"

# 3. fingerprint of the primary key packet
fpr="$(python3 - "${KEYFILE}" <<'PY'
import base64, hashlib, sys
lines = open(sys.argv[1]).read().splitlines()
start = lines.index('-----BEGIN PGP PUBLIC KEY BLOCK-----') + 1
end = lines.index('-----END PGP PUBLIC KEY BLOCK-----')
body = lines[start:end]
body = body[body.index('') + 1:]                      # skip armor headers
data = base64.b64decode(''.join(l for l in body if not l.startswith('=')))
tag = data[0]
if tag & 0x40:                                        # new-format header
    t, l0 = tag & 0x3f, data[1]
    if l0 < 192: n, off = l0, 2
    elif l0 < 224: n, off = ((l0 - 192) << 8) + data[2] + 192, 3
    else: n, off = int.from_bytes(data[2:6], 'big'), 6
else:                                                 # old-format header
    t, lt = (tag >> 2) & 0x0f, tag & 3
    size = {0: 1, 1: 2, 2: 4}[lt]
    n, off = int.from_bytes(data[1:1 + size], 'big'), 1 + size
if t != 6:
    sys.exit(f'first packet is tag {t}, not a public key (6)')
pkt = data[off:off + n]
if pkt[0] != 4:
    sys.exit(f'key packet version {pkt[0]}, expected v4')
print(hashlib.sha1(b'\x99' + len(pkt).to_bytes(2, 'big') + pkt).hexdigest().upper())
PY
)" || fail "could not parse ${KEYFILE}"
[ "${fpr}" = "${EXPECTED_FPR}" ] || fail "key fingerprint ${fpr} != expected ${EXPECTED_FPR}"

# 4. the key is copied where the apt source says it is
grep -qE "^COPY infra/infra/docker/apt-keys/yubico-stable-ppa\.asc ${KEY_DEST}\$" "${DOCKERFILE}" \
  || fail "Dockerfile.core does not COPY the key to ${KEY_DEST}"
grep -qF "[signed-by=${KEY_DEST}] https://ppa.launchpadcontent.net/yubico/stable/ubuntu" "${DOCKERFILE}" \
  || fail "Yubico apt source is not signed-by ${KEY_DEST}"

echo "PASS: Dockerfile.core pins the Yubico PPA key (fpr ${fpr}, sha256 ${actual}); no add-apt-repository"
