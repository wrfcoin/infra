#!/usr/bin/env bash
#
# join.sh — bootstrap wrapper for joining the WRFCoin testnet (infra#600).
#
# Collapses the manual pre-steps of JOIN_TESTNET.md into one idempotent command:
# checks prerequisites, clones the two required repos side by side (skipping
# anything already present), then hands off to join-testnet-sync-node.sh.
#
# Usage — no invite, key or account needed (the repos are public):
#
#   git clone https://github.com/wrfcoin/infra.git wrfcoin/infra \
#     && bash wrfcoin/infra/testnet/join.sh
#
# With no flags this starts a sync-only node that dials the public seed
# pinned in cut-pins.env, syncs chain 888 from genesis (no snapshot), and needs
# only outbound connections (no port forward, no Tailscale).
#
# Re-running is safe: existing clones and running services are left alone
# (the underlying compose build reuses the Docker layer cache, so a re-run
# after the first build is fast).
#
# Options are passed through to join-testnet-sync-node.sh (e.g. --emulate to
# force the old x86_64-under-emulation build on an arm64 Mac, --bootstrap
# <multiaddr> to override the reference node). Apple Silicon builds natively
# by default and needs no flag.
#
# NOTE: there are no prebuilt images to pull (publishing images to a registry
# is deliberately prohibited); the node is built from source on this machine.
#
set -euo pipefail

# Help must work without a checkout, pins, network access or Docker.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      printf '%s\n' \
        'Usage: bash testnet/join.sh [options]' \
        'Prepare the infra/core4 checkouts and start a sync-only testnet node.' \
        'Options are forwarded to testnet/join-testnet-sync-node.sh.' \
        '  -h, --help              Print this help without starting setup.' \
        '  --emulate               Use the x86_64 emulation build.' \
        '  --bootstrap <multiaddr> Override the bootstrap peer (default: the pinned public seed).' \
        '  --snapshot <url|dir>    Optional: start from a verified snapshot instead of genesis.' \
        'See testnet/JOIN_TESTNET.md for prerequisites and operator guidance.'
      exit 0
      ;;
  esac
done

INFRA_GIT_SSH="git@github.com:wrfcoin/infra.git"
INFRA_GIT_HTTPS="https://github.com/wrfcoin/infra.git"
CORE4_GIT_SSH="git@github.com:wrfcoin/core4.git"
CORE4_GIT_HTTPS="https://github.com/wrfcoin/core4.git"

# --- Chain-identity pins, from ONE named place (infra#764) -----------------
# testnet/cut-pins.env is the single source of truth for which commit the node
# is built from and which chain it joins. It is sourced, never duplicated here:
# a constant with two copies is a constant that drifts, which is exactly
# core4#2705 (runbook still says 51eb1a4a; the cut has since moved twice, to
  # 67d07852, 23e8d62a and now deb5a3c5, and the runbook trails every one).
#
# Changing the cut is a one-line edit in that file, not a hunt through scripts.
CUT_PINS_FILE="${CUT_PINS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/cut-pins.env}"
if [ ! -f "${CUT_PINS_FILE}" ]; then
  echo "ERROR: cut pins file not found at ${CUT_PINS_FILE}." >&2
  echo "       It carries the core4 commit this node is built from; refusing to" >&2
  echo "       guess one. Is the infra checkout complete?" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${CUT_PINS_FILE}"

: "${WRFCOIN_CUT_CORE4_COMMIT:?cut-pins.env does not define WRFCOIN_CUT_CORE4_COMMIT}"

# The pinned default, and the ONLY copy of it in this script. The override
# warning below compares against this variable rather than a literal, so the
# two can never disagree.
CORE4_PIN_DEFAULT="${WRFCOIN_CUT_CORE4_COMMIT}"
CORE4_PIN="${CORE4_PIN:-${CORE4_PIN_DEFAULT}}"


say()  { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# --- Prerequisite checks --------------------------------------------------
command -v git >/dev/null 2>&1 || die "git is required. Install git and re-run."

if ! command -v docker >/dev/null 2>&1; then
  die "Docker is required. Install Docker Desktop (macOS) or Docker Engine (Linux) and re-run."
fi
if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose v2 is required ('docker compose version' failed). Update Docker and re-run."
fi
if ! docker info >/dev/null 2>&1; then
  die "Docker is installed but the daemon is not reachable. Start Docker and re-run."
fi

# --- Resolve the root layout (<infra checkout> + <root>/core4) -------------
# When run from inside a checkout (the normal path), the infra repo is wherever
# this script lives — whatever the directory is called — and core4 goes next to
# it. When run standalone (e.g. a future curl | bash), set up ./wrfcoin/.
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "${SCRIPT_SOURCE}" ] && [ -f "${SCRIPT_SOURCE}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_SOURCE}")" && pwd)"   # .../<infra>/testnet
  INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"                  # .../<infra>
  ROOT="$(cd "${INFRA_DIR}/.." && pwd)"                        # .../
else
  ROOT="${PWD}/wrfcoin"
  mkdir -p "${ROOT}"
  INFRA_DIR="${ROOT}/infra"
fi
say "WRFCoin root: ${ROOT}"

clone_repo() {
  # clone_repo <target-dir> <ssh-url> <https-url> <label>
  local target="$1" ssh_url="$2" https_url="$3" label="$4"
  if [ -d "${target}/.git" ]; then
    say "${label}: already cloned at ${target} — skipping (git pull manually to update)."
    return 0
  fi
  if [ -e "${target}" ]; then
    die "${target} exists but is not a git checkout. Move it aside and re-run."
  fi
  say "${label}: cloning into ${target} ..."
  # HTTPS first: the repos are public, and a newcomer has no GitHub SSH key.
  # An SSH-first clone could stop at an interactive host-key prompt. SSH stays
  # as a non-interactive fallback (BatchMode) for networks that block HTTPS.
  if ! git clone "${https_url}" "${target}"; then
    say "${label}: HTTPS clone failed, retrying over SSH ..."
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" git clone "${ssh_url}" "${target}" \
      || die "Could not clone ${label} from ${https_url}. Check your internet connection and re-run."
  fi
}

# infra only needs cloning in standalone mode — in-checkout, we're inside it.
if [ ! -d "${INFRA_DIR}/.git" ]; then
  clone_repo "${INFRA_DIR}" "${INFRA_GIT_SSH}" "${INFRA_GIT_HTTPS}" "wrfcoin/infra"
fi
clone_repo "${ROOT}/core4" "${CORE4_GIT_SSH}" "${CORE4_GIT_HTTPS}" "wrfcoin/core4"

# --- Pin core4 to the cut commit, and be loud about it (infra#764) ---------
#
# This runs for BOTH paths, and that matters: clone_repo SKIPS an existing
# checkout ("already cloned — skipping"), so pinning only the fresh clone would
# leave the far more common case — an operator who cloned days ago and re-runs —
# silently building whatever they happen to have.
# Returns non-zero on every refusal in addition to calling die(). die() exits
# today, but a guard whose correctness depends on a helper's exit semantics
# breaks silently the day that helper changes — and this one decides which
# source revision the node is built from. Caller checks the status too.
check_core4_pin() {
  local dir="$1" pin="$2" head short_head short_pin
  git -C "${dir}" rev-parse --git-dir >/dev/null 2>&1 \
    || { die "${dir} is not a git checkout — cannot verify the core4 pin."; return 1; }

  if ! git -C "${dir}" cat-file -e "${pin}^{commit}" 2>/dev/null; then
    say "core4: fetching ${pin} ..."
    git -C "${dir}" fetch --quiet origin "${pin}" 2>/dev/null \
      || git -C "${dir}" fetch --quiet --all 2>/dev/null || true
  fi
  git -C "${dir}" cat-file -e "${pin}^{commit}" 2>/dev/null \
    || { die "core4 commit ${pin} not found after fetching. Wrong CORE4_PIN, or no access?"; return 1; }

  head="$(git -C "${dir}" rev-parse HEAD)"
  short_head="$(git -C "${dir}" rev-parse --short=8 HEAD)"
  short_pin="$(git -C "${dir}" rev-parse --short=8 "${pin}")"

  if [ "${head}" = "$(git -C "${dir}" rev-parse "${pin}")" ]; then
    say "core4 pinned at ${short_pin} — matches the cut."
    return 0
  fi

  # A dirty tree would build something no commit describes. Say so before
  # touching it, and never discard an operator's work silently.
  if ! git -C "${dir}" diff --quiet HEAD 2>/dev/null; then
    die "core4 at ${dir} has uncommitted changes (HEAD ${short_head}).
       Refusing to move it to the cut commit ${short_pin} — your work would be
       in the build but not in any commit, so nobody could reproduce the node.
       Commit or stash, then re-run. To build your tree as-is: CORE4_PIN=${short_head}"
    return 1
  fi

  say "core4: at ${short_head}, cut is ${short_pin} — checking out the cut commit."
  git -C "${dir}" checkout --quiet --detach "${pin}" \
    || { die "Could not check out core4 ${pin}."; return 1; }
  say "core4 pinned at ${short_pin}."
}

check_core4_pin "${ROOT}/core4" "${CORE4_PIN}" \
  || die "core4 pin check failed — refusing to build a node of unknown provenance."

if [ "${CORE4_PIN}" != "${CORE4_PIN_DEFAULT}" ]; then
  warn "CORE4_PIN is overridden to ${CORE4_PIN}."
  warn "cut-pins.env pins ${CORE4_PIN_DEFAULT}; this node will NOT be built from it."
fi

# Provenance an operator can read afterwards without re-running anything and
# without reading this script:
#   cat infra/testnet/.core4-commit
# Machine-local and gitignored — it describes this checkout, not the repo.
printf '%s\n' "$(git -C "${ROOT}/core4" rev-parse HEAD)" > "${INFRA_DIR}/testnet/.core4-commit"
say "Recorded build provenance: ${INFRA_DIR}/testnet/.core4-commit"

# --- Build-cache hint (there are deliberately no prebuilt images) -----------
if docker image inspect wrfcoin/native-chain:testnet-local >/dev/null 2>&1; then
  say "Node image already built locally — the compose build will reuse the layer cache."
else
  say "First build compiles the Rust node from source (~30-60 min on x86_64; longer under arm64 emulation)."
fi

# --- Hand off to the real join script --------------------------------------
JOIN_SCRIPT="${INFRA_DIR}/testnet/join-testnet-sync-node.sh"
[ -f "${JOIN_SCRIPT}" ] || die "join-testnet-sync-node.sh not found at ${JOIN_SCRIPT} — is the infra clone complete?"
say "Handing off to join-testnet-sync-node.sh ..."
exec bash "${JOIN_SCRIPT}" --root "${ROOT}" "$@"
