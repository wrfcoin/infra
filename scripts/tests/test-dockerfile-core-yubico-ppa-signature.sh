#!/usr/bin/env bash
# Network companion to test-dockerfile-core-yubico-key-pin.sh (infra#1016).
#
# The hermetic test proves the checked-in key is the one we MEANT to pin. This
# one proves that key still signs the live PPA: it fetches the noble InRelease
# from ppa.launchpadcontent.net (the package host, reachable here, unlike
# api.launchpad.net) and verifies it with gpgv against ONLY the pinned key. If
# Launchpad rotates the PPA key, this fails before a real image build does.
#
# Requires network and gpgv. If either is missing it exits 77 and says
# UNVERIFIED, never PASS (the same convention as
# test-dockerfile-core-deb-checksums.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYFILE="${ROOT}/infra/docker/apt-keys/yubico-stable-ppa.asc"
URL="https://ppa.launchpadcontent.net/yubico/stable/ubuntu/dists/noble/InRelease"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

command -v gpgv >/dev/null 2>&1 || { echo "UNVERIFIED: gpgv not installed; PPA signature NOT checked (this is not a pass)"; exit 77; }
if ! curl -sf --max-time 30 -o "${TMP}/InRelease" "${URL}"; then
  echo "UNVERIFIED: ${URL} unreachable; PPA signature NOT checked (this is not a pass)"
  exit 77
fi

# gpgv wants a binary keyring; dearmor with python so gpg itself is not needed.
python3 - "${KEYFILE}" "${TMP}/key.gpg" <<'PY'
import base64, sys
lines = open(sys.argv[1]).read().splitlines()
body = lines[lines.index('-----BEGIN PGP PUBLIC KEY BLOCK-----') + 1:lines.index('-----END PGP PUBLIC KEY BLOCK-----')]
body = body[body.index('') + 1:]
open(sys.argv[2], 'wb').write(base64.b64decode(''.join(l for l in body if not l.startswith('='))))
PY

# InRelease also carries a signature from Launchpad's legacy 1024-bit key,
# which we deliberately do not pin, so gpgv's exit status is non-zero for the
# missing key. The pass condition is a GOODSIG from the pinned key and no BADSIG.
gpgv --status-fd 1 --keyring "${TMP}/key.gpg" "${TMP}/InRelease" >"${TMP}/status" 2>"${TMP}/stderr" || true
if grep -q '^\[GNUPG:\] BADSIG' "${TMP}/status"; then
  cat "${TMP}/stderr" >&2; echo "FAIL: BAD signature on ${URL}" >&2; exit 1
fi
if ! grep -q '^\[GNUPG:\] VALIDSIG 990BD85D1C4F411ABC0ECE8DFA4EC8F2EE58CE0B' "${TMP}/status"; then
  cat "${TMP}/stderr" >&2; echo "FAIL: ${URL} is not validly signed by the pinned key 990BD85D...EE58CE0B" >&2; exit 1
fi
echo "PASS: live noble InRelease is validly signed by the pinned Yubico PPA key"
