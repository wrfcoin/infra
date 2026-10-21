#!/usr/bin/env bash
#
# join-snapshot-restore.sh — verify and restore a published join snapshot into
# a fresh node-data volume (infra#587, phase 1).
#
# WHY THIS EXISTS: core4#2806 — the canonical chain contains a segment
# (block 11,017+) that fails consensus re-validation on replay, so a node that
# starts empty and full-syncs from genesis wedges PERMANENTLY at 11,016. A
# state snapshot taken above the poisoned segment is the only working way to
# bring up a new node. The 2026-08-16 follower restore is the empirical proof
# of this path (restored at 16,273, tracked tip; core4#2798 fixed
# sync-from-restored-tip).
#
# The snapshot is a tar.gz containing exactly one file, wrfcoin.redb — the
# chain database. It deliberately contains NO per-node material: no
# peer_identity.key, no hsm/, no equivocation_evidence.redb. The node mints
# its own identity on first boot.
#
# TRUST (owner ruling, 2026-09-26): for the tailnet testnet the snapshot is
# HASH-BOUND and UNSIGNED. The trust root is manifest.json served over TLS by
# the testnet edge; the archive is bound to it by sha256 (check 2 below).
# Signing must be revisited before any public join. See
# testnet/JOIN_SNAPSHOT_PUBLISH.md "Trust model".
#
# Verification is fail-closed and happens BEFORE anything touches Docker:
#   1. manifest.json's genesis_hash / chain_id / network_id must equal the
#      pins in testnet/cut-pins.env (the single chain-identity source). A
#      snapshot for another chain is refused by name, not restored and left
#      to fork.
#   2. The archive's sha256 must equal the manifest's. A truncated or
#      tampered download is refused before it can become a corrupt datadir.
#   3. The target volume must not already exist. This script bootstraps new
#      nodes; it never clobbers an existing datadir.
#
# Usage:
#   bash join-snapshot-restore.sh --base-url https://<host>/join --volume testnet_node-data
#   bash join-snapshot-restore.sh --manifest m.json --archive snap.tar.gz --volume testnet_node-data
#
# Test seams (used by scripts/tests/test-join-snapshot.sh, harmless otherwise):
#   CUT_PINS_FILE  — alternate pins file
#   DOCKER_BIN     — alternate docker command
#   Sourcing this file loads the functions without running main.
set -uo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
JSR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUT_PINS_FILE="${CUT_PINS_FILE:-${JSR_SCRIPT_DIR}/cut-pins.env}"

# Pull one scalar out of a small JSON document without requiring jq (same
# contract as join-testnet-sync-node.sh: quotes optional so 777 and "777"
# compare equal — a JSON rendering difference is not a different chain).
jsr_json_field() {
  printf '%s' "$1" \
    | tr ',{}' '\n' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" \
    | head -1
}

jsr_load_pins() {
  if [ ! -f "${CUT_PINS_FILE}" ]; then
    echo "ERROR: cut pins file not found at ${CUT_PINS_FILE}; refusing to verify a snapshot against nothing." >&2
    return 1
  fi
  # shellcheck source=/dev/null
  . "${CUT_PINS_FILE}"
  : "${WRFCOIN_CUT_GENESIS_HASH:?cut-pins.env does not define WRFCOIN_CUT_GENESIS_HASH}"
  : "${WRFCOIN_CUT_CHAIN_ID:?cut-pins.env does not define WRFCOIN_CUT_CHAIN_ID}"
  : "${WRFCOIN_CUT_NETWORK_ID:?cut-pins.env does not define WRFCOIN_CUT_NETWORK_ID}"
  : "${WRFCOIN_CUT_CORE4_COMMIT:?cut-pins.env does not define WRFCOIN_CUT_CORE4_COMMIT}"
}

# jsr_verify_manifest <manifest-path>
# Fail-closed identity check: the manifest must name exactly the chain the
# pins describe. Missing fields fail, they do not default.
jsr_verify_manifest() {
  local manifest_path="$1" manifest genesis chain network height state_root
  jsr_load_pins || return 1
  if [ ! -s "${manifest_path}" ]; then
    echo "ERROR: manifest missing or empty at ${manifest_path}." >&2
    return 1
  fi
  manifest="$(cat "${manifest_path}")"
  genesis="$(jsr_json_field "${manifest}" genesis_hash)"
  chain="$(jsr_json_field "${manifest}" chain_id)"
  network="$(jsr_json_field "${manifest}" network_id)"
  height="$(jsr_json_field "${manifest}" height)"
  state_root="$(jsr_json_field "${manifest}" state_root_hex)"

  # Node-side reports 0x-prefixed, pins store bare — one normalisation, here.
  local expected_genesis="0x${WRFCOIN_CUT_GENESIS_HASH#0x}"
  genesis="0x${genesis#0x}"

  local ok=1
  if [ "${genesis}" = "0x" ] || [ "${genesis}" != "${expected_genesis}" ]; then
    echo "ERROR: snapshot manifest genesis_hash mismatch — expected ${expected_genesis}, manifest says '${genesis}'." >&2
    ok=0
  fi
  if [ -z "${chain}" ] || [ "${chain}" != "${WRFCOIN_CUT_CHAIN_ID}" ]; then
    echo "ERROR: snapshot manifest chain_id mismatch — expected '${WRFCOIN_CUT_CHAIN_ID}', manifest says '${chain}'." >&2
    ok=0
  fi
  if [ -z "${network}" ] || [ "${network}" != "${WRFCOIN_CUT_NETWORK_ID}" ]; then
    echo "ERROR: snapshot manifest network_id mismatch — expected '${WRFCOIN_CUT_NETWORK_ID}', manifest says '${network}'." >&2
    ok=0
  fi
  if ! [[ "${height}" =~ ^[0-9]+$ ]] || [ "${height:-0}" -le 11017 ]; then
    echo "ERROR: snapshot manifest height must be an integer above 11017; manifest says '${height}'." >&2
    ok=0
  fi
  if ! [[ "${state_root}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: snapshot manifest state_root_hex is missing or malformed." >&2
    ok=0
  fi
  # core4 build guard (r20.2 rolling-upgrade audit C3). A joiner builds the core4
  # that cut-pins.env pins; a snapshot written by a DIFFERENT core4 build may not
  # import into it (checkpoint format / state layout). The manifest records the
  # producing build (the source container's image revision label).
  local snapshot_core4
  snapshot_core4="$(jsr_json_field "${manifest}" core4_commit)"
  if [ -z "${snapshot_core4}" ]; then
    if [ "${WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT:-0}" = "1" ]; then
      echo "WARN: snapshot manifest carries no core4_commit; WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT=1, importing without a version check." >&2
    else
      echo "ERROR: snapshot manifest carries no core4_commit, so it cannot be shown to match the pinned core4 build (${WRFCOIN_CUT_CORE4_COMMIT})." >&2
      echo "       The network may be mid-upgrade: retry after a snapshot published by the new version is available." >&2
      echo "       (Only for a legacy snapshot you know matches the pin: WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT=1.)" >&2
      return 1
    fi
  elif ! [[ "${snapshot_core4}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: snapshot manifest core4_commit is not a full 40-hex SHA: '${snapshot_core4}'." >&2
    return 1
  elif [ "${snapshot_core4}" != "${WRFCOIN_CUT_CORE4_COMMIT}" ]; then
    echo "ERROR: snapshot was produced by core4 ${snapshot_core4}, but ${CUT_PINS_FILE} pins core4 ${WRFCOIN_CUT_CORE4_COMMIT}." >&2
    echo "       The network is mid-upgrade; retry after the new join snapshot is published (or after cut-pins.env catches up). Not restoring it." >&2
    return 1
  fi
  if [ "${ok}" != "1" ]; then
    echo "       This snapshot is for a DIFFERENT chain than ${CUT_PINS_FILE} describes. Not restoring it." >&2
    return 1
  fi
  return 0
}

# jsr_verify_archive_shape <archive-path>
# The public artifact contract is deliberately narrow: one regular file at
# the archive root, with the exact name wrfcoin.redb. Validate before Docker
# volume creation so links, traversal paths, and extra per-node material never
# reach a volume even when the archive checksum matches its manifest.
jsr_verify_archive_shape() {
  local archive_path="$1" names verbose
  names="$(tar tzf "${archive_path}" 2>/dev/null)" || {
    echo "ERROR: snapshot archive is not a readable tar.gz." >&2
    return 1
  }
  if [ "${names}" != "wrfcoin.redb" ]; then
    echo "ERROR: snapshot archive must contain exactly one root member named wrfcoin.redb." >&2
    return 1
  fi
  verbose="$(tar tvzf "${archive_path}" 2>/dev/null)" || return 1
  if [ "$(printf '%s\n' "${verbose}" | wc -l)" -ne 1 ] || [ "${verbose#?}" = "${verbose}" ] || [ "${verbose:0:1}" != "-" ]; then
    echo "ERROR: snapshot archive member wrfcoin.redb must be a regular file, not a link or special entry." >&2
    return 1
  fi
  return 0
}

jsr_volume_has_durable_state() {
  local volume="$1"
  "${DOCKER_BIN}" run --rm -v "${volume}:/data:ro" alpine:3.20 \
    sh -ec 'test -f /data/wrfcoin.redb && test ! -L /data/wrfcoin.redb && test -s /data/wrfcoin.redb'
}

# jsr_verify_archive <manifest-path> <archive-path>
# The manifest's sha256 is the integrity contract for the (much larger)
# archive fetched separately.
jsr_verify_archive() {
  local manifest_path="$1" archive_path="$2" manifest expected actual
  if [ ! -s "${archive_path}" ]; then
    echo "ERROR: snapshot archive missing or empty at ${archive_path}." >&2
    return 1
  fi
  manifest="$(cat "${manifest_path}")"
  expected="$(jsr_json_field "${manifest}" sha256)"
  if [ -z "${expected}" ]; then
    echo "ERROR: manifest carries no sha256; refusing an unverifiable archive." >&2
    return 1
  fi
  actual="$(sha256sum "${archive_path}" | cut -d' ' -f1)"
  if [ "${actual}" != "${expected}" ]; then
    echo "ERROR: snapshot sha256 mismatch — manifest says ${expected}, downloaded file is ${actual}." >&2
    echo "       Truncated download or tampering; not restoring it." >&2
    return 1
  fi
  return 0
}

# jsr_restore_into_volume <archive-path> <volume-name>
# Creates the volume and unpacks the snapshot into it. Refuses to touch a
# volume that already exists — an existing datadir is an existing node.
jsr_restore_into_volume() {
  local archive_path="$1" volume="$2" archive_dir archive_file
  if "${DOCKER_BIN}" volume inspect "${volume}" >/dev/null 2>&1; then
    echo "ERROR: volume '${volume}' already exists. This script bootstraps NEW nodes only." >&2
    echo "       To re-bootstrap deliberately: stop the node, 'docker volume rm ${volume}', re-run." >&2
    return 1
  fi
  archive_dir="$(cd "$(dirname "${archive_path}")" && pwd)"
  archive_file="$(basename "${archive_path}")"
  "${DOCKER_BIN}" volume create "${volume}" >/dev/null || return 1
  if ! "${DOCKER_BIN}" run --rm \
      -v "${volume}:/data" \
      -v "${archive_dir}:/src:ro" \
      alpine:3.20 \
      sh -ec "tar xzf /src/${archive_file} -C /data && test -s /data/wrfcoin.redb"; then
    echo "ERROR: unpack failed (or the archive does not contain wrfcoin.redb)." >&2
    echo "       Removing the half-written volume so the next attempt starts clean." >&2
    "${DOCKER_BIN}" volume rm "${volume}" >/dev/null 2>&1 || true
    return 1
  fi
  echo "==> Snapshot restored into volume '${volume}'."
  return 0
}

jsr_main() {
  local base_url="" manifest_path="" archive_path="" volume="" tmpdir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base-url) base_url="$2"; shift 2 ;;
      --manifest) manifest_path="$2"; shift 2 ;;
      --archive)  archive_path="$2"; shift 2 ;;
      --volume)   volume="$2"; shift 2 ;;
      -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "Unknown arg: $1" >&2; return 1 ;;
    esac
  done
  if [ -z "${volume}" ]; then
    echo "ERROR: --volume is required." >&2
    return 1
  fi
  if [ -n "${base_url}" ]; then
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' EXIT
    echo "==> Fetching join snapshot from ${base_url} ..."
    manifest_path="${tmpdir}/manifest.json"
    archive_path="${tmpdir}/snapshot.tar.gz"
    curl -fsSL --proto '=https,file' -o "${manifest_path}" "${base_url%/}/manifest.json" || {
      echo "ERROR: could not fetch ${base_url%/}/manifest.json." >&2; return 1; }
    # Manifest first, verified, THEN the (large) archive: a manifest for another
    # chain or another core4 build must not cost a download.
    jsr_verify_manifest "${manifest_path}" || return 1
    curl -fsSL --proto '=https,file' -o "${archive_path}" "${base_url%/}/snapshot.tar.gz" || {
      echo "ERROR: could not fetch ${base_url%/}/snapshot.tar.gz." >&2; return 1; }
  fi
  if [ -z "${manifest_path}" ] || [ -z "${archive_path}" ]; then
    echo "ERROR: provide either --base-url, or both --manifest and --archive." >&2
    return 1
  fi
  jsr_verify_manifest "${manifest_path}" || return 1
  jsr_verify_archive "${manifest_path}" "${archive_path}" || return 1
  jsr_verify_archive_shape "${archive_path}" || return 1
  jsr_restore_into_volume "${archive_path}" "${volume}" || return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  jsr_main "$@"
fi
