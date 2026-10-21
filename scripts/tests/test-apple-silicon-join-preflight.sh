#!/usr/bin/env bash
# Hermetic coverage for the arm64 join seam.
#
# Originally (infra#590) this covered the amd64-emulation gate: on Apple Silicon
# the node image was x86_64, so the script warned and required an opt-in.
#
# infra#763 removed the reason for that. Dockerfile.core now derives the .deb
# architecture instead of hardcoding amd64, so arm64 builds natively. The
# contract this file protects is therefore inverted: an arm64 operator must get
# the NATIVE path by default, without knowing to ask, and emulation survives
# only as an explicit --emulate fallback.
#
# The assertion that matters most is that the native path never sets
# DOCKER_DEFAULT_PLATFORM=linux/amd64 — that single export is what silently
# reintroduces the 40-minute emulated build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
JOIN_SCRIPT="${ROOT}/testnet/join-testnet-sync-node.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/root/core4" "${TMP}/bin"

cat > "${TMP}/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -m) echo "${MOCK_UNAME_ARCH:-arm64}" ;;
  -s) echo "${MOCK_UNAME_OS:-Darwin}" ;;
esac
EOF
# The mock answers by platform: a `--platform linux/amd64` run is the emulation
# seam, a bare run is the native seam. Conflating the two is exactly how a
# native-path regression would hide, so they must not share a response.
#
# It must also honour DOCKER_DEFAULT_PLATFORM the way real docker does. An
# earlier version of this mock inspected only the argv, which made it blind to
# `export DOCKER_DEFAULT_PLATFORM=linux/amd64` — the precise line that used to
# force emulation, and the one this file most needs to catch. The env var is
# logged alongside the argv so assertions can see both.
cat > "${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = run ]; then
  [ -z "${MOCK_DOCKER_LOG:-}" ] || \
    printf 'DOCKER_DEFAULT_PLATFORM=%s ARGV=%s\n' "${DOCKER_DEFAULT_PLATFORM:-}" "$*" >> "${MOCK_DOCKER_LOG}"
  case "$*" in
    *"--platform linux/amd64"*) printf '%s\n' "${MOCK_EMULATED_ARCH:-x86_64}"; exit 0 ;;
  esac
  if [ "${DOCKER_DEFAULT_PLATFORM:-}" = "linux/amd64" ]; then
    printf '%s\n' "${MOCK_EMULATED_ARCH:-x86_64}"; exit 0
  fi
  printf '%s\n' "${MOCK_NATIVE_ARCH:-aarch64}"
  exit 0
fi
exit 1
EOF
cat > "${TMP}/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  status) echo '100.64.0.1 wrfcoin-testnet' ;;
  ip) echo '100.64.0.9' ;;
esac
EOF
# Not translated unless a test says so.
cat > "${TMP}/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[ "${2:-}" = sysctl.proc_translated ] && { echo "${MOCK_PROC_TRANSLATED:-0}"; exit 0; }
exit 1
EOF
chmod +x "${TMP}/bin"/*

run_preflight() {
  PATH="${TMP}/bin:${PATH}" bash "${JOIN_SCRIPT}" --root "${TMP}/root" --preflight "$@"
}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# --- 1. arm64 default is native, with no opt-in and no prompt --------------
# Deliberately no --yes and stdin closed: if the operator has to know to ask,
# the acceptance criterion is not met.
log="${TMP}/docker.native"; : > "${log}"
native_output="$(MOCK_DOCKER_LOG="${log}" run_preflight </dev/null 2>&1)" \
  || fail "arm64 native preflight exited nonzero without --yes"
grep -Fq 'native arm64 build, no emulation' <<<"${native_output}" \
  || fail "native path did not report a native arm64 build"
grep -Fq 'Preflight complete' <<<"${native_output}" \
  || fail "native preflight did not complete"

# The regression that matters: nothing on the native path may pin amd64, by
# flag or by environment. Both are checked because only the flag was checked
# once, and that version passed a mutation that re-added the env export.
if grep -q -- '--platform linux/amd64' "${log}"; then
  fail "native arm64 path invoked docker with --platform linux/amd64 — emulation reintroduced"
fi
if grep -q 'DOCKER_DEFAULT_PLATFORM=linux/amd64' "${log}"; then
  fail "native arm64 path exported DOCKER_DEFAULT_PLATFORM=linux/amd64 — emulation reintroduced"
fi

# --- 2. native RED control: a non-arm64 answer must refuse ------------------
if MOCK_NATIVE_ARCH=x86_64 run_preflight </dev/null >/dev/null 2>&1; then
  fail "native preflight accepted a non-arm64 Docker probe"
fi
red_native="$(MOCK_NATIVE_ARCH=x86_64 run_preflight </dev/null 2>&1 || true)"
grep -Fq "Docker did not run a native arm64 container (got 'x86_64')" <<<"${red_native}" \
  || fail "native RED control did not name the wrong architecture"

# --- 3. --emulate is still available, and still asks -----------------------
log="${TMP}/docker.emulate"; : > "${log}"
emulate_output="$(MOCK_DOCKER_LOG="${log}" ASSUME_YES=1 run_preflight --emulate </dev/null 2>&1)" \
  || fail "--emulate preflight exited nonzero with ASSUME_YES=1"
grep -Fq 'Docker Desktop linux/amd64 emulation answered x86_64.' <<<"${emulate_output}" \
  || fail "--emulate did not probe the amd64 emulation seam"
grep -q -- '--platform linux/amd64' "${log}" \
  || fail "--emulate did not actually exercise the amd64 platform"

# Declining the confirmation must abort rather than silently emulate.
if printf 'n\n' | PATH="${TMP}/bin:${PATH}" bash "${JOIN_SCRIPT}" \
     --root "${TMP}/root" --preflight --emulate >/dev/null 2>&1; then
  fail "--emulate proceeded after the operator declined"
fi

# --- 4. --emulate RED control ----------------------------------------------
if MOCK_EMULATED_ARCH=aarch64 ASSUME_YES=1 run_preflight --emulate </dev/null >/dev/null 2>&1; then
  fail "--emulate accepted a non-amd64 Docker probe"
fi
red_emul="$(MOCK_EMULATED_ARCH=aarch64 ASSUME_YES=1 run_preflight --emulate </dev/null 2>&1 || true)"
grep -Fq "Docker could not execute a linux/amd64 container (got 'aarch64')" <<<"${red_emul}" \
  || fail "--emulate RED control did not name the wrong architecture"

# --- 5. a Rosetta shell reports x86_64 -------------------------------------
# It must be caught rather than treated as a native amd64 host, or the operator
# this epic exists for silently gets the emulated build on arm64 hardware.
if MOCK_UNAME_ARCH=x86_64 MOCK_PROC_TRANSLATED=1 run_preflight </dev/null >/dev/null 2>&1; then
  fail "Rosetta shell was accepted silently as a native x86_64 host"
fi
rosetta="$(MOCK_UNAME_ARCH=x86_64 MOCK_PROC_TRANSLATED=1 run_preflight </dev/null 2>&1 || true)"
grep -Fq 'running under Rosetta' <<<"${rosetta}" \
  || fail "Rosetta shell was not identified as such"

# --yes must NOT wave the Rosetta check through. This is the case the first
# version of this file missed: the warning printed and the script proceeded
# anyway, so the check read as satisfied. --yes is the flag that lives in
# muscle memory, so the operator most likely to pass it is the one who most
# needs stopping. Only --emulate may proceed here.
if MOCK_UNAME_ARCH=x86_64 MOCK_PROC_TRANSLATED=1 ASSUME_YES=1 \
     run_preflight </dev/null >/dev/null 2>&1; then
  fail "--yes / ASSUME_YES=1 bypassed the Rosetta check — it must not"
fi
if MOCK_UNAME_ARCH=x86_64 MOCK_PROC_TRANSLATED=1 \
     run_preflight --yes </dev/null >/dev/null 2>&1; then
  fail "--yes bypassed the Rosetta check — it must not"
fi

# --emulate IS the deliberate opt-in, so it must still get through on Rosetta.
MOCK_UNAME_ARCH=x86_64 MOCK_PROC_TRANSLATED=1 run_preflight --emulate </dev/null >/dev/null 2>&1 \
  || fail "--emulate no longer proceeds on a Rosetta shell — the escape hatch is gone"

# A genuine x86_64 host must still pass cleanly, and must still execute the
# amd64 probe rather than assuming it.
log="${TMP}/docker.x86"; : > "${log}"
x86_output="$(MOCK_DOCKER_LOG="${log}" MOCK_UNAME_ARCH=x86_64 MOCK_UNAME_OS=Linux \
  run_preflight </dev/null 2>&1)" || fail "a genuine x86_64 Linux host no longer passes preflight"
grep -Fq 'Docker Desktop linux/amd64 emulation answered x86_64.' <<<"${x86_output}" \
  || fail "x86_64 preflight stopped executing the amd64 probe"

echo 'PASS: arm64 gets the native path by default; --emulate remains an explicit, confirmed fallback'
