#!/usr/bin/env bash
# Hermetic coverage for infra#763's architecture-derived pcsc-lite fetch.
#
# Dockerfile.core fetches libpcsclite1/pcscd as raw .debs, so the URL and the
# checksum are both architecture-specific. Seven lines used to hardcode
# `_amd64.deb`, which made a native arm64 build impossible: the wget succeeded
# (the amd64 files exist) and apt-get then rejected the wrong-architecture
# package.
#
# This test extracts the real shell out of Dockerfile.core and runs it against
# stubbed binaries, so it exercises the arm64 branch on an amd64 machine —
# which is the only way to cover arm64 until an arm64 builder exists. If the
# Dockerfile drifts, the extraction changes and so does this test's verdict.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${ROOT}/infra/docker/Dockerfile.core"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. no hardcoded architecture literal survives -------------------------
if grep -q '_amd64\.deb' "${DOCKERFILE}"; then
  grep -n '_amd64\.deb' "${DOCKERFILE}" >&2
  fail "Dockerfile.core still hardcodes _amd64.deb; the arm64 build is blocked"
fi

# --- 2. both architectures carry a distinct pinned checksum ----------------
# This file cannot prove a checksum is *correct* — asserting a pinned value
# against itself is a tautology. It proves only that the two architectures do
# not share a value, which is what a copy-paste of the amd64 pin into the arm64
# slot looks like. Correctness against the Debian pool is
# test-dockerfile-core-deb-checksums.sh, which requires the network.
for arg in LIBPCSCLITE1_SHA256_AMD64 PCSCD_SHA256_AMD64 \
           LIBPCSCLITE1_SHA256_ARM64 PCSCD_SHA256_ARM64; do
  grep -q "^ARG ${arg}=" "${DOCKERFILE}" || fail "missing pinned checksum ARG: ${arg}"
done

pin() { sed -n "s/^ARG $1=//p" "${DOCKERFILE}"; }
[ "$(pin LIBPCSCLITE1_SHA256_AMD64)" != "$(pin LIBPCSCLITE1_SHA256_ARM64)" ] \
  || fail "libpcsclite1 amd64 and arm64 checksums are identical — one arch is pinned to the other's package"
[ "$(pin PCSCD_SHA256_AMD64)" != "$(pin PCSCD_SHA256_ARM64)" ] \
  || fail "pcscd amd64 and arm64 checksums are identical — one arch is pinned to the other's package"

# --- 3. extract the real logic out of the Dockerfile ------------------------
# ARG defaults become shell assignments; the fetch block is taken verbatim
# between the dpkg derivation and the cleanup. Continuations are *joined*, not
# stripped — that is what Docker does, and stripping them instead would split
# `apt-get install`'s arguments into separate commands.
{
  sed -n 's/^ARG \(PCSC_LITE_VERSION=.*\)$/\1/p' "${DOCKERFILE}"
  sed -n 's/^ARG \(LIBPCSCLITE1_SHA256_[A-Z0-9]*=.*\)$/\1/p' "${DOCKERFILE}"
  sed -n 's/^ARG \(PCSCD_SHA256_[A-Z0-9]*=.*\)$/\1/p' "${DOCKERFILE}"
  awk '/debArch="\$\(dpkg --print-architecture\)"/{f=1} f{print} /^ *rm -f "libpcsclite1_/{if(f) exit}' \
    "${DOCKERFILE}" | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}'
} > "${TMP}/fetch.sh"

grep -q 'dpkg --print-architecture' "${TMP}/fetch.sh" || fail "extraction missed the arch derivation"
grep -q 'wget' "${TMP}/fetch.sh" || fail "extraction missed the download"

# --- 4. stub the binaries the block calls ----------------------------------
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --print-architecture ] && { echo "${MOCK_DPKG_ARCH:?}"; exit 0; }
exit 1
EOF
cat > "${TMP}/bin/wget" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in http*) printf '%s\n' "$a" >> "${MOCK_WGET_LOG}" ;; esac; done
EOF
cat > "${TMP}/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
cat >> "${MOCK_SHA_LOG}"   # record "<checksum>  <filename>" pairs, assert nothing
EOF
cat > "${TMP}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in ./*) printf '%s\n' "$a" >> "${MOCK_APT_LOG}" ;; esac; done
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "${TMP}/bin/apt-mark"
chmod +x "${TMP}/bin"/*

run_arch() {
  MOCK_DPKG_ARCH="$1" \
  MOCK_WGET_LOG="${TMP}/wget.$1" MOCK_SHA_LOG="${TMP}/sha.$1" MOCK_APT_LOG="${TMP}/apt.$1" \
  PATH="${TMP}/bin:${PATH}" bash "${TMP}/fetch.sh" >/dev/null 2>&1
}

# --- 5. amd64 keeps working (the production path) ---------------------------
: > "${TMP}/wget.amd64"; : > "${TMP}/sha.amd64"; : > "${TMP}/apt.amd64"
run_arch amd64 || fail "amd64 branch exited nonzero"
grep -q 'libpcsclite1_2\.3\.3-1_amd64\.deb$' "${TMP}/wget.amd64" || fail "amd64 did not fetch the amd64 libpcsclite1"
grep -q 'pcscd_2\.3\.3-1_amd64\.deb$'       "${TMP}/wget.amd64" || fail "amd64 did not fetch the amd64 pcscd"
grep -q '_arm64\.deb' "${TMP}/wget.amd64" && fail "amd64 build fetched an arm64 package"
grep -q "$(pin LIBPCSCLITE1_SHA256_AMD64)  libpcsclite1_2.3.3-1_amd64.deb" "${TMP}/sha.amd64" \
  || fail "amd64 did not pair the amd64 checksum with the amd64 file"

# --- 6. arm64 resolves to arm64 URLs and arm64 checksums --------------------
: > "${TMP}/wget.arm64"; : > "${TMP}/sha.arm64"; : > "${TMP}/apt.arm64"
run_arch arm64 || fail "arm64 branch exited nonzero"
grep -q 'libpcsclite1_2\.3\.3-1_arm64\.deb$' "${TMP}/wget.arm64" || fail "arm64 did not fetch the arm64 libpcsclite1"
grep -q 'pcscd_2\.3\.3-1_arm64\.deb$'       "${TMP}/wget.arm64" || fail "arm64 did not fetch the arm64 pcscd"
grep -q '_amd64\.deb' "${TMP}/wget.arm64" && fail "arm64 build fetched an amd64 package — this is infra#763"
grep -q "$(pin LIBPCSCLITE1_SHA256_ARM64)  libpcsclite1_2.3.3-1_arm64.deb" "${TMP}/sha.arm64" \
  || fail "arm64 did not pair the arm64 checksum with the arm64 file"
grep -q './libpcsclite1_2.3.3-1_arm64.deb' "${TMP}/apt.arm64" || fail "arm64 did not install the arm64 package"

# --- 7. an unpinned architecture fails closed, before any download ----------
: > "${TMP}/wget.riscv64"; : > "${TMP}/sha.riscv64"; : > "${TMP}/apt.riscv64"
if run_arch riscv64; then
  fail "unpinned architecture built successfully; it must fail closed"
fi
[ -s "${TMP}/wget.riscv64" ] && fail "unpinned architecture downloaded a package before failing"

echo "PASS: Dockerfile.core derives the .deb architecture (amd64 + arm64 verified, unpinned fails closed)"
