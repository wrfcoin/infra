#!/usr/bin/env bash
# Hermetic guard for infra#1021: Dockerfile.core's Rust BUILDER must not carry a
# newer glibc than its ubuntu RUNTIME.
#
# A binary linked on a newer glibc can import a versioned symbol (GLIBC_2.40,
# GLIBC_2.41, ...) the runtime's libc does not export. It builds cleanly and fails
# only when the container starts ("version `GLIBC_2.xx' not found"). The #1021
# review measured launch_api already requiring GLIBC_2.39 against the runtime's
# 2.39, so there is zero margin to spend.
#
# What this proves, with no network and no docker:
#   1. The builder tag names its Debian release explicitly (`-bookworm`, `-trixie`,
#      ...). A bare `rust:X-slim` silently changes release when upstream moves its
#      default, which is exactly how #1021 went from bookworm to trixie.
#   2. glibc(builder release) <= glibc(runtime release), from the table below.
#      An unknown release fails closed: add it to the table deliberately.
#   3. Both runtime stages keep the in-build `ldd` linkage guard, which checks the
#      REAL binaries against the REAL runtime libc. That guard must match
#      "not found", because ldd exits 0 even when a symbol version is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.core"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# glibc shipped by each base release (upstream stable versions).
glibc_of() {
  case "$1" in
    bullseye) echo 2.31 ;;
    bookworm) echo 2.36 ;;
    trixie)   echo 2.41 ;;
    22.04|jammy) echo 2.35 ;;
    24.04|noble) echo 2.39 ;;
    *) return 1 ;;
  esac
}
# Version compare: true if $1 <= $2.
ver_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

builder_from="$(grep -E '^FROM rust:[^ ]+ AS builder-base' "${DOCKERFILE}" || true)"
[ -n "${builder_from}" ] || fail "no 'FROM rust:... AS builder-base' line in Dockerfile.core"
builder_tag="$(printf '%s\n' "${builder_from}" | sed -E 's/^FROM rust:([^@ ]+).*/\1/')"
builder_rel="$(printf '%s\n' "${builder_tag}" | sed -nE 's/.*-(bullseye|bookworm|trixie)$/\1/p')"
[ -n "${builder_rel}" ] || fail "builder tag rust:${builder_tag} does not name a Debian release; pin e.g. rust:X-slim-bookworm"

runtime_from="$(grep -E '^FROM ubuntu:[^ ]+ AS runtime-deps' "${DOCKERFILE}" || true)"
[ -n "${runtime_from}" ] || fail "no 'FROM ubuntu:... AS runtime-deps' line in Dockerfile.core"
runtime_rel="$(printf '%s\n' "${runtime_from}" | sed -E 's/^FROM ubuntu:([^@ ]+).*/\1/')"

b="$(glibc_of "${builder_rel}")" || fail "unknown builder release '${builder_rel}': add its glibc to glibc_of()"
r="$(glibc_of "${runtime_rel}")" || fail "unknown runtime release '${runtime_rel}': add its glibc to glibc_of()"
ver_le "${b}" "${r}" || fail "builder rust:${builder_tag} (${builder_rel}, glibc ${b}) is NEWER than runtime ubuntu:${runtime_rel} (glibc ${r}); binaries may need symbols the runtime lacks"

for bin in /usr/local/bin/oracle_attester /usr/local/bin/wrfcoin-node; do
  grep -qF "ldd ${bin}" "${DOCKERFILE}" || fail "runtime linkage guard for ${bin} is missing"
done
[ "$(grep -c "grep -q 'not found'" "${DOCKERFILE}")" -ge 2 ] \
  || fail "linkage guards must match ldd's 'not found' text (ldd exits 0 on a missing version)"

echo "PASS: builder rust:${builder_tag} glibc ${b} <= runtime ubuntu:${runtime_rel} glibc ${r}; ldd linkage guards present in both runtime stages"
