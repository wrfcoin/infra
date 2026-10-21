#!/usr/bin/env bash
# Verifies Dockerfile.core's pinned pcsc-lite checksums against the actual
# Debian pool, for every architecture the Dockerfile claims to support.
#
# Its companion, test-dockerfile-core-arch-derivation.sh, is hermetic and
# therefore cannot do this: checking a pinned value against the same file it
# was read from is a tautology. This one fetches the real .deb and hashes it,
# so a wrong or transposed pin is a failure rather than a silent pass.
#
# Requires network. If the pool is unreachable it exits 77 (skip) and says
# UNVERIFIED — never PASS, because a skip that reads as success is how a broken
# gate survives.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.core"
POOL="https://deb.debian.org/debian/pool/main/p/pcsc-lite"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

pin() { sed -n "s/^ARG $1=//p" "${DOCKERFILE}"; }
version="$(pin PCSC_LITE_VERSION)"
[ -n "${version}" ] || { echo "FAIL: PCSC_LITE_VERSION not found in Dockerfile.core" >&2; exit 1; }

if ! curl -sfI --max-time 20 "${POOL}/" >/dev/null 2>&1 \
   && ! curl -sfI --max-time 20 "${POOL}/libpcsclite1_${version}_amd64.deb" >/dev/null 2>&1; then
  echo "UNVERIFIED: ${POOL} unreachable — pinned checksums NOT checked (this is not a pass)"
  exit 77
fi

rc=0
for arch in amd64 arm64; do
  upper="$(printf '%s' "${arch}" | tr '[:lower:]' '[:upper:]')"
  for pkg in libpcsclite1 pcscd; do
    case "${pkg}" in
      libpcsclite1) expected="$(pin "LIBPCSCLITE1_SHA256_${upper}")" ;;
      pcscd)        expected="$(pin "PCSCD_SHA256_${upper}")" ;;
    esac
    if [ -z "${expected}" ]; then
      echo "FAIL: no pinned checksum for ${pkg} ${arch}" >&2; rc=1; continue
    fi

    file="${TMP}/${pkg}_${version}_${arch}.deb"
    if ! curl -sfL --max-time 120 -o "${file}" "${POOL}/${pkg}_${version}_${arch}.deb"; then
      echo "FAIL: ${pkg}_${version}_${arch}.deb not downloadable from the pool" >&2; rc=1; continue
    fi

    actual="$(sha256sum "${file}" | cut -d' ' -f1)"
    if [ "${actual}" != "${expected}" ]; then
      echo "FAIL: ${pkg} ${arch} checksum mismatch" >&2
      echo "        pinned: ${expected}" >&2
      echo "        actual: ${actual}" >&2
      rc=1; continue
    fi

    # The filename is not authority for the architecture; the control field is.
    if command -v dpkg-deb >/dev/null 2>&1; then
      declared="$(dpkg-deb -f "${file}" Architecture 2>/dev/null || echo '')"
      if [ "${declared}" != "${arch}" ]; then
        echo "FAIL: ${pkg}_${version}_${arch}.deb declares Architecture=${declared}" >&2
        rc=1; continue
      fi
    fi

    echo "  OK  ${pkg} ${arch}  ${actual}"
  done
done

[ "${rc}" -eq 0 ] || { echo "FAIL: pinned checksums do not match the Debian pool" >&2; exit 1; }
echo "PASS: all pinned pcsc-lite ${version} checksums match the Debian pool (amd64 + arm64)"
