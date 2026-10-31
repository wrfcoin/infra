#!/usr/bin/env bash
#
# join-testnet-sync-node.sh — one-command join for the WRFCoin public testnet.
#
# Brings up a SYNC-ONLY full node (Postgres + Redis + wrfcoin-node) that dials
# the public seed (cut-pins.env WRFCOIN_CUT_BOOTSTRAP) over the internet and
# syncs chain 888 from genesis. It does NOT produce blocks: an
# external node is not in the chain's validator set, so the network never
# accepts blocks from it — it only follows the chain and can submit txs.
#
# Prerequisites (see JOIN_TESTNET.md for the full walkthrough):
#   1. Docker Desktop / Docker Engine with Compose v2 (`docker compose version`).
#   2. Outbound internet access to the seed (TCP 9000). A sync-only node needs
#      NO inbound route, port forward or Tailscale. Set WRFCOIN_P2P_EXTERNAL_ADDR
#      only if you want peers to dial you back; it is then checked AFTER the
#      node is listening and a failure is a warning. A serving role
#      (WRFCOIN_SERVICE_ID set, e.g. a bonded snapshot server) MUST advertise a
#      reachable address and is refused without one.
#   3. Both repos checked out under ONE root dir (this is the build context):
#         <root>/infra/      (this repo)
#         <root>/core4/      (the Rust node sources)
#
# Platform support:
#   SUPPORTED   : Linux x86_64, Intel macOS.
#   SUPPORTED   : Apple Silicon (arm64) macOS — builds a NATIVE arm64 image.
#                 The image no longer hardcodes amd64 packages (infra#763), so
#                 no emulation is involved and no opt-in is required.
#
#   The native arm64 image has not yet been validated end-to-end on real
#   hardware — it is the default because it is the fast and correct path, not
#   because it has been proven in production. --emulate remains as a fallback
#   if a native build ever fails.
#
# Usage:
#   bash join-testnet-sync-node.sh [--root <WRFCOIN_ROOT>] [--bootstrap <multiaddr>] [--snapshot <url|dir>] [--emulate] [--yes] [--preflight]
#
#   --root       Dir containing infra/ and core4/. Default: parent of this repo.
#   --bootstrap  Override the bootstrap peer multiaddr. Default: the public seed
#                pinned in cut-pins.env (WRFCOIN_CUT_BOOTSTRAP,
#                /dns4/seed.wrfcoin.com/tcp/9000/p2p/...). Also via BOOTSTRAP_PEERS.
#   --snapshot   OPTIONAL. Base URL (or local dir) of a join snapshot
#                (manifest.json + snapshot.tar.gz) to start from instead of
#                syncing chain 888 from genesis. Also via WRFCOIN_JOIN_SNAPSHOT.
#                Existing nodes (a non-empty data volume) never touch it.
#                (Retired chain 777 only: a snapshot was REQUIRED there,
#                because full sync wedged at block 11,016, core4#2806.)
#   --allow-full-sync
#                Retired chain 777 only: start a brand-new 777 node without a
#                snapshot anyway. Chain 888 syncs from genesis without it.
#   --emulate    Force the x86_64 image under emulation instead of building
#                natively (also via EMULATE=1). Only meaningful on arm64, where
#                it is a deliberate fallback: slow (~30-60 min) and not the
#                supported path.
#   --yes        Skip the interactive confirmation that --emulate asks for
#                (also via ASSUME_YES=1). Not needed for a native build.
#                It suppresses EXACTLY that one prompt. It does NOT bypass the
#                Rosetta check: a Rosetta shell reports x86_64, so --yes there
#                would silently buy the 40-minute emulated build on arm64
#                hardware. Use --emulate if that is what you want.
#   --preflight  Validate the platform seam without generating .env, building,
#                or starting services. Probes whichever seam this run would
#                actually use: native by default, amd64 emulation under
#                --emulate.
#
set -euo pipefail

# --- Canonical live-testnet identity, from ONE named place -----------------
# testnet/cut-pins.env is the single source of truth, shared with join.sh.
# These constants used to be literals here AND in that script; a constant with
# two copies is a constant that drifts, which is core4#2705 exactly (the cut
# runbook still declares 51eb1a4a, two cuts stale). Changing the cut is
# a one-line edit in that file.
CUT_PINS_FILE="${CUT_PINS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cut-pins.env}"
if [ ! -f "${CUT_PINS_FILE}" ]; then
  echo "ERROR: cut pins file not found at ${CUT_PINS_FILE}." >&2
  echo "       It carries this chain's genesis hash and identity; refusing to" >&2
  echo "       guess them. Is the infra checkout complete?" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "${CUT_PINS_FILE}"

: "${WRFCOIN_CUT_GENESIS_HASH:?cut-pins.env does not define WRFCOIN_CUT_GENESIS_HASH}"
: "${WRFCOIN_CUT_CHAIN_ID:?cut-pins.env does not define WRFCOIN_CUT_CHAIN_ID}"
: "${WRFCOIN_CUT_NETWORK_ID:?cut-pins.env does not define WRFCOIN_CUT_NETWORK_ID}"
: "${WRFCOIN_CUT_BOOTSTRAP:?cut-pins.env does not define WRFCOIN_CUT_BOOTSTRAP}"

# The public seed, from cut-pins.env. Never a placeholder: a newcomer running
# the one documented command with no flags must reach a real peer.
DEFAULT_BOOTSTRAP="${WRFCOIN_CUT_BOOTSTRAP}"
TESTNET_GENESIS_HASH="${WRFCOIN_CUT_GENESIS_HASH}"

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../infra/testnet
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"                  # .../infra
WRFCOIN_ROOT="$(cd "${INFRA_DIR}/.." && pwd)"               # .../  (build context)
BOOTSTRAP_PEERS="${BOOTSTRAP_PEERS:-${DEFAULT_BOOTSTRAP}}"
ASSUME_YES="${ASSUME_YES:-0}"
EMULATE="${EMULATE:-0}"
PREFLIGHT=0
SNAPSHOT_SOURCE="${WRFCOIN_JOIN_SNAPSHOT:-}"
ALLOW_FULL_SYNC="${ALLOW_FULL_SYNC:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      WRFCOIN_ROOT="$(cd "$2" && pwd)"; shift 2 ;;
    --bootstrap) BOOTSTRAP_PEERS="$2"; shift 2 ;;
    --snapshot)  SNAPSHOT_SOURCE="$2"; shift 2 ;;
    --allow-full-sync) ALLOW_FULL_SYNC=1; shift ;;
    --emulate)   EMULATE=1; shift ;;
    --yes|-y)    ASSUME_YES=1; shift ;;
    --preflight) PREFLIGHT=1; shift ;;
    -h|--help)   sed -n '3,/^set -euo pipefail/p' "$0" | sed -n 's/^# \{0,1\}//p'; exit 0 ;;
    *)           echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Refuse template addresses before generating configuration or invoking Docker.
if [ "${PREFLIGHT}" != "1" ] && [[ "${BOOTSTRAP_PEERS}" == *'<'* || "${BOOTSTRAP_PEERS}" == *'>'* ]]; then
  echo "ERROR: BOOTSTRAP_PEERS / --bootstrap still contains a <placeholder>." >&2
  echo "       Unset it to use the pinned public seed (${WRFCOIN_CUT_BOOTSTRAP})," >&2
  echo "       or replace the placeholder with a real multiaddr." >&2
  exit 1
fi
if [ "${PREFLIGHT}" != "1" ] && [[ "${WRFCOIN_P2P_EXTERNAL_ADDR:-}" == *'<'* || "${WRFCOIN_P2P_EXTERNAL_ADDR:-}" == *'>'* ]]; then
  echo "ERROR: WRFCOIN_P2P_EXTERNAL_ADDR still contains a <placeholder>." >&2
  echo "       A sync-only node does not need it: unset it, or set your real address." >&2
  exit 1
fi

cd "${SCRIPT_DIR}"

echo "==> WRFCoin testnet sync-node join"
echo "    build context : ${WRFCOIN_ROOT}"
echo "    bootstrap peer: ${BOOTSTRAP_PEERS}"

# --- Sanity: build context must contain infra/ and core4/ ---
if [ ! -d "${WRFCOIN_ROOT}/core4" ]; then
  echo "ERROR: ${WRFCOIN_ROOT}/core4 not found." >&2
  echo "       The node image builds from core4 Rust sources. Clone wrfcoin/core4" >&2
  echo "       next to this infra repo, or pass --root <dir containing infra/ + core4/>." >&2
  exit 1
fi

# --- Platform / architecture guard ---------------------------------------
# The node image builds natively on both amd64 and arm64: Dockerfile.core derives
# the .deb architecture rather than hardcoding amd64 (infra#763), and both base
# images are multi-arch indexes. An arm64 operator therefore gets a native build
# by default, with no opt-in and no emulation.
#
# --emulate keeps the old x86_64-under-emulation path. It is retained rather than
# deleted because the native arm64 image has not yet been validated end-to-end on
# real hardware; if a native build ever fails, the operator needs a way through
# that does not require editing this script. It is a fallback, not the default.
ARCH="$(uname -m 2>/dev/null || echo unknown)"
OS="$(uname -s 2>/dev/null || echo unknown)"

probe_amd64_emulation() {
  echo "==> Probing Docker Desktop linux/amd64 emulation ..."
  EMULATED_ARCH="$(docker run --rm --platform linux/amd64 alpine:3.20 uname -m 2>/dev/null || true)"
  if [ "${EMULATED_ARCH}" != "x86_64" ]; then
    echo "ERROR: Docker could not execute a linux/amd64 container (got '${EMULATED_ARCH:-no output}')." >&2
    echo "       Enable Docker Desktop's x86/amd64 emulation, then re-run this preflight." >&2
    exit 1
  fi
  echo "==> Docker Desktop linux/amd64 emulation answered x86_64."
}

probe_native_arm64() {
  echo "==> Probing native linux/arm64 execution ..."
  NATIVE_ARCH="$(docker run --rm alpine:3.20 uname -m 2>/dev/null || true)"
  if [ "${NATIVE_ARCH}" != "aarch64" ] && [ "${NATIVE_ARCH}" != "arm64" ]; then
    echo "ERROR: Docker did not run a native arm64 container (got '${NATIVE_ARCH:-no output}')." >&2
    echo "       Expected aarch64. If DOCKER_DEFAULT_PLATFORM is pinned to linux/amd64" >&2
    echo "       in your environment, unset it — this host builds arm64 natively now." >&2
    echo "       To build the x86_64 image under emulation on purpose, pass --emulate." >&2
    exit 1
  fi
  echo "==> Docker answered ${NATIVE_ARCH}: native arm64 build, no emulation."
}

case "${ARCH}" in
  arm64|aarch64)
    if [ "${EMULATE}" = "1" ]; then
      echo "" >&2
      echo "  ============================================================" >&2
      echo "  --emulate: building the x86_64 image under EMULATION." >&2
      echo "  This is the fallback path, not the supported one. Expect a" >&2
      echo "  slow first build (~30-60 min) and every restart after." >&2
      echo "  A native arm64 build is the default — drop --emulate for it." >&2
      echo "  ============================================================" >&2
      if [ "${ASSUME_YES}" != "1" ]; then
        printf "  Proceed with the emulated build? [y/N] " >&2
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "${reply}" in
          y|Y|yes|YES) echo "  Proceeding under emulation (you asked)." >&2 ;;
          *) echo "  Aborted. Drop --emulate to build natively." >&2; exit 2 ;;
        esac
      else
        echo "  --yes given: proceeding under emulation." >&2
      fi
      export DOCKER_DEFAULT_PLATFORM="${DOCKER_DEFAULT_PLATFORM:-linux/amd64}"
      probe_amd64_emulation
    else
      echo "==> arm64 detected (${OS} ${ARCH}): building a native arm64 image."
      # Do not pin DOCKER_DEFAULT_PLATFORM — native is what we want. If the
      # environment already pins amd64, that silently reintroduces emulation,
      # so say so rather than letting a 40-minute build start unexplained.
      if [ "${DOCKER_DEFAULT_PLATFORM:-}" = "linux/amd64" ]; then
        echo "WARN: DOCKER_DEFAULT_PLATFORM=linux/amd64 is set in your environment." >&2
        echo "      That forces the slow emulated build. Unset it for the native path," >&2
        echo "      or pass --emulate if you meant to emulate." >&2
      fi
      probe_native_arm64
    fi
    ;;
  x86_64|amd64)
    # A Rosetta shell on Apple Silicon reports x86_64, so this branch can be
    # reached on the very hardware the native path exists for. Left undetected,
    # that operator silently gets the slow emulated build and no explanation —
    # the exact failure this epic set out to remove.
    if [ "${OS}" = "Darwin" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
      echo "" >&2
      echo "  ============================================================" >&2
      echo "  This shell is running under Rosetta (reports x86_64) on an" >&2
      echo "  Apple Silicon Mac. Building here produces the EMULATED x86_64" >&2
      echo "  image: slow (~30-60 min) and slow again on every restart." >&2
      echo "  For the fast native arm64 build, re-run this script from a" >&2
      echo "  native arm64 terminal (not a Rosetta one)." >&2
      echo "  Pass --emulate to build the x86_64 image here on purpose." >&2
      echo "  --yes does NOT bypass this check." >&2
      echo "  ============================================================" >&2
      # Deliberately gated on --emulate ONLY, not on --yes.
      #
      # --emulate means "I intend to build the x86_64 image", so honour it.
      # --yes means "don't ask me routine questions", and this is not a routine
      # question: it is the difference between a 3-minute native build and a
      # 40-minute emulated one, decided by which terminal was opened. --yes is
      # the flag that lives in muscle memory, so the operator most likely to
      # pass it is exactly the one who most needs to be stopped here.
      #
      # Non-interactive runs fail CLOSED: with no /dev/tty, `reply` stays empty
      # and falls to the abort arm. A scripted run on Rosetta stops and names
      # --emulate rather than hanging on a prompt or silently emulating.
      if [ "${EMULATE}" != "1" ]; then
        printf "  Continue with the emulated build anyway? [y/N] " >&2
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "${reply}" in
          y|Y|yes|YES) echo "  Proceeding under Rosetta (you asked)." >&2 ;;
          *) echo "  Aborted. Re-run from a native arm64 terminal, or pass --emulate." >&2; exit 2 ;;
        esac
      fi
    fi
    ;;
  *)
    echo "WARN: unrecognized architecture '${ARCH}' — proceeding, but only" >&2
    echo "      x86_64 and arm64 are supported." >&2
    ;;
esac

# --preflight is a claim about the seam this run would actually use. On x86_64
# that is the amd64 seam, and a Rosetta shell reports x86_64 on Apple Silicon —
# so the probe must execute here too rather than being skipped as "native".
if [ "${PREFLIGHT}" = "1" ] && { [ "${ARCH}" = "x86_64" ] || [ "${ARCH}" = "amd64" ]; }; then
  probe_amd64_emulation
fi

# Only an explicit tailnet bootstrap (a 100.64.0.0/10 address or a *.ts.net
# name) selects automatic Tailscale advertising. The default public seed never
# does: a sync-only node over the internet needs no advertised address at all.
bootstrap_is_tailnet() {
  case "$1" in
    /ip4/100.6[4-9].*|/ip4/100.[7-9][0-9].*|/ip4/100.1[01][0-9].*|/ip4/100.12[0-7].*) return 0 ;;
    /dns4/*.ts.net/*|/dns/*.ts.net/*) return 0 ;;
    *) return 1 ;;
  esac
}
TS_IP=""
if bootstrap_is_tailnet "${BOOTSTRAP_PEERS}"; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -1 || true)"
fi

if [ "${PREFLIGHT}" = "1" ]; then
  echo "==> Preflight complete: no .env was generated and no services were started."
  echo "    This proves only the local Docker platform seam; it does not prove"
  echo "    build success, P2P peering, sync, or oracle participation."
  exit 0
fi

# --- Generate .env on first run ---
if [ ! -f .env ]; then
  echo "==> Generating .env (secrets) via setup-env.sh ..."
  bash setup-env.sh
fi

# --- Helper: idempotently set KEY=VALUE in .env ---
# Validate from the file itself, so an inherited declaration cannot conceal a
# missing cut pin. The helper prints only the four selected public assignments.
bootstrap="$(python3 "${SCRIPT_DIR}/scripts/chain-identity.py" --pins "${CUT_PINS_FILE}" --bootstrap-env .env)" || exit 1
if [ -n "${bootstrap}" ]; then
  while IFS='=' read -r key value; do export "${key}=${value}"; done <<< "${bootstrap}"
fi

set_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" .env; then
    # portable in-place edit (GNU + BSD/macOS sed)
    sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "${key}" "${val}" >> .env
  fi
}

echo "==> Configuring sync-only testnet node ..."
set_env BOOTSTRAP_PEERS "${BOOTSTRAP_PEERS}"
set_env WRFCOIN_NETWORK_ID "${WRFCOIN_CUT_NETWORK_ID}"
set_env WRFCOIN_CHAIN_ID "${WRFCOIN_CUT_CHAIN_ID}"
set_env WRFCOIN_MIN_WORK_FACTOR "0"
# Compose gives exported values precedence over .env. Pin both so a stale
# shell cannot raise the testnet validation floor and reject live blocks.
export WRFCOIN_MIN_WORK_FACTOR=0
set_env WRFCOIN_GENESIS_HASH "${TESTNET_GENESIS_HASH}"
set_env ALLOW_UNENCRYPTED_STORAGE "true"          # testnet only — no encryption-at-rest
set_env WRFCOIN_SYNC_ONLY "1"                     # never create/use a block-signing token
set_env WRFCOIN_HSM_PIN ""                        # no signing secret on a sync-only node
if [ -n "${WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS:-}" ]; then
  set_env WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS "${WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS}"
fi
operator_external_addr="${WRFCOIN_P2P_EXTERNAL_ADDR:-}"
if [ -z "${operator_external_addr}" ] && [ -f .env ]; then
  operator_external_addr="$(sed -n 's/^[[:space:]]*WRFCOIN_P2P_EXTERNAL_ADDR=//p' .env | tail -1 | tr -d '"' | tr -d "'")"
fi
# A serving role (WRFCOIN_SERVICE_ID, e.g. a bonded snapshot server) is dialed
# by other nodes, so it must advertise a reachable address. A plain sync-only
# node only dials out and may advertise nothing.
service_id="${WRFCOIN_SERVICE_ID:-}"
if [ -z "${service_id}" ] && [ -f .env ]; then
  service_id="$(sed -n 's/^[[:space:]]*WRFCOIN_SERVICE_ID=//p' .env | tail -1 | tr -d '"' | tr -d "'")"
fi
if [ -n "${operator_external_addr}" ]; then
  echo "==> Preserving operator-supplied WRFCOIN_P2P_EXTERNAL_ADDR."
  # Persist it, so a later plain `docker compose up` advertises the same address.
  set_env WRFCOIN_P2P_EXTERNAL_ADDR "${operator_external_addr}"
elif [ -n "${TS_IP}" ]; then
  set_env WRFCOIN_P2P_EXTERNAL_ADDR "/ip4/${TS_IP}/tcp/9000"
  operator_external_addr="/ip4/${TS_IP}/tcp/9000"
elif [ -n "${service_id}" ]; then
  echo "ERROR: WRFCOIN_SERVICE_ID='${service_id}' marks a serving node, which other nodes dial." >&2
  echo "       It must advertise a reachable P2P address. Set WRFCOIN_P2P_EXTERNAL_ADDR" >&2
  echo "       (e.g. /ip4/<your public IP>/tcp/9000) with TCP 9000 forwarded to this host." >&2
  echo "       A plain sync-only node needs none of this: unset WRFCOIN_SERVICE_ID." >&2
  exit 1
else
  set_env WRFCOIN_P2P_EXTERNAL_ADDR ""
  echo "==> Sync-only, outbound connections only: no advertised P2P address."
  echo "    No port forwarding is needed to follow the chain. To let peers dial you"
  echo "    back too, set WRFCOIN_P2P_EXTERNAL_ADDR and re-run (see JOIN_TESTNET.md)."
fi
export WRFCOIN_P2P_EXTERNAL_ADDR="${operator_external_addr}"
export WRFCOIN_ROOT

# The advertised address, if any, is dialed only AFTER the node is up (below).
# Before `compose up` nothing listens on it, so the pre-start dial this used
# to do could never pass on a first join (it aborted every fresh join).

# --- Optional snapshot for brand-new nodes (infra#587) ---------------------
# A missing volume means a new node. Chain 888 syncs from genesis by default;
# a snapshot, when given, is verified and restored instead.
# Retired chain 777 only: full-sync from genesis wedged PERMANENTLY at block
# 11,016 (core4#2806: canonical block 11,017 fails PoP quorum re-validation
# on replay; core4#2807: the failure then graylists every peer until sync
# starves). The only working bootstrap is a published snapshot taken above
# the poisoned segment — proven by the 2026-08-16 follower restore
# (core4#2798 makes a restored tip sync forward correctly).
#
# Volume naming follows Compose v2: <project>_node-data, where the project
# defaults to this directory's basename. COMPOSE_PROJECT_NAME (env or .env)
# overrides it, so honor that too.
compose_project="${COMPOSE_PROJECT_NAME:-}"
if [ -z "${compose_project}" ] && [ -f .env ]; then
  compose_project="$(sed -n 's/^[[:space:]]*COMPOSE_PROJECT_NAME=//p' .env | tail -1 | tr -d '"' | tr -d "'")"
fi
if [ -z "${compose_project}" ]; then
  compose_project="$(basename "${SCRIPT_DIR}" | tr '[:upper:]' '[:lower:]')"
fi
node_data_volume="${compose_project}_node-data"
DOCKER_BIN="${DOCKER_BIN:-docker}"
# shellcheck source=/dev/null
. "${SCRIPT_DIR}/join-snapshot-restore.sh"

if ! "${DOCKER_BIN}" volume inspect "${node_data_volume}" >/dev/null 2>&1; then
  if [ -n "${SNAPSHOT_SOURCE}" ]; then
    echo "==> Brand-new node: restoring the join snapshot into '${node_data_volume}' ..."
    if [ -d "${SNAPSHOT_SOURCE}" ]; then
      bash "${SCRIPT_DIR}/join-snapshot-restore.sh" \
        --manifest "${SNAPSHOT_SOURCE}/manifest.json" \
        --archive "${SNAPSHOT_SOURCE}/snapshot.tar.gz" \
        --volume "${node_data_volume}"
    else
      bash "${SCRIPT_DIR}/join-snapshot-restore.sh" \
        --base-url "${SNAPSHOT_SOURCE}" \
        --volume "${node_data_volume}"
    fi
  elif [ "${WRFCOIN_CUT_CHAIN_ID}" != "777" ]; then
    echo "==> Brand-new node: syncing from genesis on chain ${WRFCOIN_CUT_CHAIN_ID} (no snapshot needed)."
  elif [ "${ALLOW_FULL_SYNC}" = "1" ]; then
    echo "WARN: --allow-full-sync on a brand-new node. On the current chain this" >&2
    echo "      WILL wedge at block 11,016 (core4#2806). You asked; proceeding." >&2
  else
    echo "ERROR: this is a brand-new node (no '${node_data_volume}' volume) and no" >&2
    echo "       snapshot was given. Full sync from genesis wedges PERMANENTLY at" >&2
    echo "       block 11,016 on this chain (core4#2806) — an empty node cannot join" >&2
    echo "       by syncing. Pass --snapshot <url|dir> (see JOIN_TESTNET.md," >&2
    echo "       'Snapshot join'), or --allow-full-sync to proceed anyway with the" >&2
    echo "       wedge understood." >&2
    exit 1
  fi
else
  if ! jsr_volume_has_durable_state "${node_data_volume}" >/dev/null 2>&1; then
    echo "ERROR: volume '${node_data_volume}' exists but has no nonempty regular wrfcoin.redb." >&2
    echo "       Refusing to mistake an empty or malformed leftover for an existing node." >&2
    echo "       No data was changed. Inspect/remove the volume deliberately, then retry the verified snapshot restore." >&2
    exit 1
  fi
  if [ -n "${SNAPSHOT_SOURCE}" ]; then
    echo "==> Existing node data found in '${node_data_volume}' — ignoring --snapshot (it bootstraps new nodes only)."
  fi
fi

echo "==> Building + starting postgres, redis, wrfcoin-node (first build can take a while) ..."
docker compose -f docker-compose.testnet.yml -f docker-compose.override.yml \
  up -d --build postgres redis wrfcoin-node

echo "==> Waiting for the node API ..."
ready=0
for _ in $(seq 1 90); do
  if curl -sf http://localhost:8556/readyz >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done

# Pull one scalar out of /network/info without requiring jq — macOS operators
# frequently do not have it, and the previous code degraded to `cat`, which is
# how the identity check ended up being "read two hex strings yourself".
#
# The quotes are optional in the pattern on purpose: `"chain_id": 777` and
# `"chain_id": "777"` both parse to 777 and both compare equal here. That is
# deliberate — this compares chain IDENTITY, and a representation change is not
# a different chain, so rejecting the numeric form would be a false alarm. The
# quoting DOES matter inside the node, where genesis metadata is compared by
# exact equality with no coercion; that is a separate surface and not something
# a shell script can enforce.
json_field() {
  printf '%s' "$1" \
    | tr ',' '\n' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" \
    | head -1
}

echo ""
if [ "${ready}" = "1" ]; then
  echo "=== Node is up. Chain identity / sync status: ==="
  INFO="$(curl -s http://localhost:8556/network/info)"
  printf '%s' "${INFO}" \
    | (jq '{network_id, chain_id, genesis_hash, chain_height, peer_count, sync_status}' 2>/dev/null || cat)
  echo ""

  # ---------------------------------------------------------------------
  # Compare, do not print and hope.
  #
  # This used to echo "Expected genesis_hash: 0x…" and invite the operator to
  # eyeball two 64-character hex strings at 2am. Now it is an assertion.
  #
  # Belt and braces, and the braces are not redundant:
  #   * launch_api refuses to start on a genesis mismatch, but that guard sits
  #     inside `#[cfg(feature = "p2p")]` (main.rs:1747, and the code says so:
  #     "Gated on `feature = "p2p"` because genesis divergence only matters for
  #     a peering node"). It is compiled in today — Dockerfile.core builds
  #     --features "full-mining,p2p,hsm" — but a build without that feature
  #     would silently lose it. This check does not depend on a cargo feature.
  #   * chain_id / network_id ARE compared at runtime, in two places, and this
  #     script is deliberately more permissive than both:
  #         native-chain/src/bin/launch_api/routes/oracle.rs:640
  #         native-chain/src/bin/launch_api/routes/station.rs:97
  #     Both are `request.chain_id != node_chain_id || request.network_id !=
  #     node_network_id`, rejecting on mismatch. `chain_id` is a String
  #     (helpers.rs:1017), so those are exact string comparisons with NO
  #     numeric coercion — 777 and "777" are NOT equal there.
  #
  #     This script treats them as equal, on purpose. It reads /network/info
  #     without jq, and 777 vs "777" is a JSON-rendering difference, not a
  #     different chain. The node is the authority; the script is a friendlier
  #     early warning that must not refuse a join over a quoting artifact. The
  #     direction of the divergence is the safe one for refusing but not for
  #     reassuring: a node serving a numeric chain_id would PASS here and still
  #     have its oracle and station registrations rejected by the node. If that
  #     ever happens, the node's rejection is correct and this check is the
  #     thing that was too kind — not the other way round.
  #
  #     Startup does check identity, but it fails open: main.rs:1609 calls
  #     assert_startup_protocol_compatibility, which reaches
  #     ChainIdentity::from_genesis_metadata (chain_binding.rs:863) — so it DOES
  #     have a production caller. It returns None for a genesis that predates
  #     #2123, and None is accepted (the test at chain_binding.rs:1448 is named
  #     `startup_accepts_genesis_without_a_recorded_identity`). Refusing there
  #     would refuse every existing node, so failing open is deliberate — which
  #     is exactly why an explicit check belongs here.
  # ---------------------------------------------------------------------
  actual_genesis="$(json_field "${INFO}" genesis_hash)"
  actual_chain="$(json_field "${INFO}" chain_id)"
  actual_network="$(json_field "${INFO}" network_id)"

  # The node reports 0x-prefixed; cut-pins.env stores it bare. One
  # representation, normalised at the comparison rather than stored twice.
  expected_genesis="0x${TESTNET_GENESIS_HASH#0x}"
  actual_genesis="0x${actual_genesis#0x}"

  identity_ok=1
  if [ -z "${actual_genesis}" ] || [ "${actual_genesis}" != "${expected_genesis}" ]; then
    echo "ERROR: genesis_hash mismatch." >&2
    echo "         expected ${expected_genesis}" >&2
    echo "         node says ${actual_genesis:-<could not read it>}" >&2
    identity_ok=0
  fi
  if [ "${actual_chain}" != "${WRFCOIN_CUT_CHAIN_ID}" ]; then
    echo "ERROR: chain_id mismatch — expected '${WRFCOIN_CUT_CHAIN_ID}', node says '${actual_chain}'." >&2
    identity_ok=0
  fi
  if [ "${actual_network}" != "${WRFCOIN_CUT_NETWORK_ID}" ]; then
    echo "ERROR: network_id mismatch — expected '${WRFCOIN_CUT_NETWORK_ID}', node says '${actual_network}'." >&2
    identity_ok=0
  fi

  if [ "${identity_ok}" != "1" ]; then
    echo "" >&2
    echo "This node is NOT on the chain ${CUT_PINS_FILE} describes. It is running," >&2
    echo "and it will happily stay running — that is why this is checked here." >&2
    echo "" >&2
    echo "  (a) Wrong genesis: you generated one instead of importing the canonical" >&2
    echo "      one. Stop the node, remove its data volume, and re-run." >&2
    echo "  (b) The CHAIN moved and the pins are stale — e.g. the cut was retaken" >&2
    echo "      at a different commit (core4#2705). Then the node is right and" >&2
    echo "      testnet/cut-pins.env needs updating, which is one line." >&2
    echo "" >&2
    echo "  Stop it with:  docker compose -f docker-compose.testnet.yml stop wrfcoin-node" >&2
    exit 1
  fi

  echo "Chain identity verified against ${CUT_PINS_FILE}:"
  echo "  genesis_hash ${expected_genesis}"
  echo "  chain_id     '${actual_chain}'    network_id '${actual_network}'"
  if [ -f "${SCRIPT_DIR}/.core4-commit" ]; then
    echo "  built from core4 $(cut -c1-8 < "${SCRIPT_DIR}/.core4-commit")"
  fi
  echo ""
  echo "peer_count > 0 and a rising chain_height mean you are syncing. NOTE:"
  echo "height 0 shortly after joining is normal — blocks are up to 4h apart."
  echo "Watch sync:  watch -n5 'curl -s http://localhost:8556/network/info | jq .chain_height'"
  echo "Logs:        docker compose -f docker-compose.testnet.yml logs -f wrfcoin-node"

  # Optional inbound check, now that the node is listening. A sync-only node
  # does not need inbound reachability, so a failure here is a WARNING; only a
  # serving role (WRFCOIN_SERVICE_ID) is refused.
  if [ -n "${WRFCOIN_P2P_EXTERNAL_ADDR}" ]; then
    echo ""
    echo "==> Checking that your advertised address accepts TCP (optional for sync-only) ..."
    p2p_rc=0
    bash "${SCRIPT_DIR}/check-p2p-external-addr.sh" "${WRFCOIN_P2P_EXTERNAL_ADDR}" || p2p_rc=$?
    if [ "${p2p_rc}" != "0" ]; then
      if [ -n "${service_id}" ]; then
        echo "ERROR: serving node '${service_id}' advertises ${WRFCOIN_P2P_EXTERNAL_ADDR}, which did not" >&2
        echo "       accept TCP. Other nodes cannot reach it. Fix the address or port forward." >&2
        exit 1
      fi
      echo "WARNING: ${WRFCOIN_P2P_EXTERNAL_ADDR} did not accept TCP from here (a NAT hairpin can" >&2
      echo "         cause this). Syncing is unaffected: this node dials out to the seed." >&2
      echo "         Peers just cannot dial you back. Fix it or unset WRFCOIN_P2P_EXTERNAL_ADDR." >&2
    fi
  fi
else
  echo "Node API did not become ready in ~3 min. Check logs:" >&2
  echo "  docker compose -f docker-compose.testnet.yml logs --tail=80 wrfcoin-node" >&2
  exit 1
fi
