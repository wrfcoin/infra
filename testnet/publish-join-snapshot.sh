#!/usr/bin/env bash
#
# publish-join-snapshot.sh — produce and stage the self-serve join snapshot
# (infra#587, phase 1). Run ON CT101 from the deploy checkout's testnet/ dir.
#
# WHY: core4#2806 — fresh full-sync wedges permanently at block 11,016, so a
# published snapshot taken above the poisoned segment is the only way a new
# node can join. This script is the producer side; join-snapshot-restore.sh
# is the consumer side; the funnel edge serves the artifact over HTTPS at
# /join/manifest.json + /join/snapshot.tar.gz.
#
# What it does, in order:
#   1. Reads the live node's /network/info and REFUSES to publish unless the
#      chain identity equals testnet/cut-pins.env exactly. A wrong-chain
#      snapshot poisons every joiner; identity is checked before anything
#      else happens.
#   2. Stops the SEED container just long enough to copy wrfcoin.redb out of
#      its volume (a redb copied mid-write is not a snapshot, it is a
#      corruption lottery). Downtime is the copy, not the compression —
#      measured ~2s on the 2026-08-16 follower restore.
#   3. Restarts the seed (also on any error, via trap), then compresses,
#      hashes, and writes manifest.json + snapshot.tar.gz ATOMICALLY into the
#      serving directory (write to temp names, mv into place) so a joiner can
#      never fetch a half-written artifact.
#
# WHERE it writes (infra#1057): the host directory the RUNNING funnel edge
# bind-mounts at /srv/join, read from `docker inspect`. The script does not
# parse WRFCOIN_JOIN_SNAPSHOT_DIR or any env file itself: Compose already
# resolved that variable (inline comments, interpolation, empty overrides)
# when it created the edge, so the mount it produced is the only answer that
# cannot disagree with what is served. The directory must live OUTSIDE the
# release tree. The old ./join-snapshots mount resolved into
# infra.releases/<sha>, so the next release flip served an empty directory.
# An edge still on such a mount is refused, before the seed is touched:
# recreate funnel-edge from the current compose first.
#
# WHOSE receipt (infra#1061): the manifest's height and state root describe
# the FROZEN COPY that is shipped, never a live node. After the stop-copy-
# start, the script boots a throwaway node on a scratch copy of those exact
# bytes and reads /network/info and /state/snapshot from it. That node:
#   - runs the seed's exact image ID with the seed's own env (same identity,
#     storage-encryption and policy settings);
#   - has every WRFCOIN_P2P_* dropped, WRFCOIN_P2P_PROFILE=disabled and
#     WRFCOIN_SYNC_ONLY=1, so it neither dials, listens nor produces;
#   - runs with --network none, a read-only rootfs, all capabilities dropped
#     and no published port, and is queried by `docker exec` on loopback;
#   - must return the same receipt twice (static), and is addressed and
#     removed only by the container ID it created (--cidfile), after its
#     per-run owner label is re-confirmed; never by name.
# Two live receipts are NOT proof: a restarted seed can load different
# durable state and sync back to the same tip before it first answers. The
# live seed is only read BEFORE the stop, as an early identity/height gate.
# (No offline reader exists: core4 replay_verify does a full replay from
# genesis and prints no machine-readable root.)
#
# The archive contains exactly wrfcoin.redb. Per-node material —
# peer_identity.key, hsm/, equivocation_evidence.redb — is NEVER included:
# shipping a peer identity would make every joiner the same peer, and
# shipping signing material would be key disclosure.
#
# NO-RESTART SOURCE (infra#1057 follow-up): --from-snapshot <path>
#   The seed has been down since 2026-09-13 and the producer must never be
#   stopped, so the stop-copy-start above has no safe target. Instead, the
#   source can be wrfcoin.redb inside a ZFS SNAPSHOT of the live node's data
#   volume (on CT101: /mnt/tank-docker/.zfs/snapshot/<snap>/docker-data/
#   volumes/testnet_node-data/_data/wrfcoin.redb). A ZFS snapshot is atomic
#   and immutable, so the copy is a point-in-time, crash-consistent image.
#   Nothing is stopped, started or written on the live side. Whether that
#   image is a usable database is not assumed: the same isolated frozen-copy
#   node boots it and must answer the receipt, or nothing is published.
#   In this mode:
#   - --stage-dir is REQUIRED: snapshot mode never writes the served dir;
#   - provenance comes from the kernel mount table (findmnt), not the path
#     spelling: the path is canonical (no symlinked component); the mount that
#     holds it is zfs, source exactly <dataset>@<snap>, read-only, rooted at
#     <m>/.zfs/snapshot/<snap>; and NODE_CONTAINER's /app/data is on that same
#     <dataset> mounted at <m>, at the same relative path (the snapshot is
#     bound to the container whose image and env boot it);
#   - the verifier runs NODE_CONTAINER's image ID and its env, minus every
#     WRFCOIN_P2P_*, WRFCOIN_HSM_*, token other than the reader token,
#     DATABASE_URL/REDIS_URL and the snapshot signer key;
#   - no live API is read. Identity, height and root come only from the
#     frozen-copy receipt.
#
# STAGING (--stage-dir <dir>): write the bundle to <dir> instead of the edge's
# served directory. <dir> must be absolute, outside any checkout or release
# tree, and must not be the directory the edge serves. Nothing public changes;
# testnet/promote-join-snapshot.sh verifies the staged pair and publishes it.
#
# Usage (on CT101). A source flag is REQUIRED; there is no default mode:
#   bash testnet/publish-join-snapshot.sh \
#     --from-snapshot /mnt/tank-docker/.zfs/snapshot/<snap>/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb \
#     --stage-dir /var/lib/wrfcoin-testnet-join/staging          # normal: no restart, staged only
#   bash testnet/publish-join-snapshot.sh --from-seed             # legacy: seed stop-copy-start
#     (the seed is RETIRED since infra#1090; only after re-enabling the seed profile)
#
# Environment overrides (defaults fit the CT101 deploy checkout):
#   SEED_CONTAINER  wrfcoin-testnet-seed
#   SEED_VOLUME     testnet_seed-data
#   (NODE_API is REFUSED if set: it used to name the producer, infra#1061)
#   SEED_API_TIMEOUT       10 s wall-clock cap per live seed API request
#   VERIFY_BOOT_TIMEOUT   600 s wall-clock deadline for the frozen-copy node
#   VERIFY_POLL_INTERVAL    2 s between frozen-copy readiness polls
#   VERIFY_REQUEST_TIMEOUT 10 s cap per frozen-copy request (never past the deadline)
#   EDGE_CONTAINER  wrfcoin-testnet-funnel-edge  (its /srv/join mount source
#                   IS the output directory; there is no separate override)
#   CUT_PINS_FILE   <this dir>/cut-pins.env
#   ENV_FILE        <this dir>/.env (source for WRFCOIN_READER_TOKEN)
#   NODE_CONTAINER  wrfcoin-testnet-node  (--from-snapshot only: image + env
#                   for the verifier; inspected, never stopped or touched)
#   DOCKER_BIN      docker                        (test seam)
set -euo pipefail

SOURCE_SNAPSHOT=""
STAGE_DIR=""
FROM_SEED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-seed)     FROM_SEED=1; shift ;;
    --from-snapshot) [ $# -ge 2 ] || { echo "ERROR: --from-snapshot needs a path." >&2; exit 1; }; SOURCE_SNAPSHOT="$2"; shift 2 ;;
    --stage-dir)     [ $# -ge 2 ] || { echo "ERROR: --stage-dir needs a path." >&2; exit 1; }; STAGE_DIR="$2"; shift 2 ;;
    *) echo "ERROR: unknown argument '$1'. See the header of this script." >&2; exit 1 ;;
  esac
done
# The source is chosen EXPLICITLY (infra#1057 follow-up, after #1090 retired the
# seed): --from-snapshot is the normal mode; the old seed stop-copy-start runs
# only with --from-seed (kept for a rollback that re-enables the seed profile).
# No mode, or both, is refused before anything is read or inspected.
if [ "${FROM_SEED}" = 1 ] && [ -n "${SOURCE_SNAPSHOT}" ]; then
  echo "ERROR: --from-seed and --from-snapshot are mutually exclusive. Refusing." >&2
  exit 1
fi
if [ "${FROM_SEED}" = 0 ] && [ -z "${SOURCE_SNAPSHOT}" ]; then
  echo "ERROR: no source given. Use --from-snapshot <zfs snapshot path to wrfcoin.redb> --stage-dir <dir>" >&2
  echo "       (the seed is retired, infra#1090). The legacy seed stop-copy-start needs an explicit" >&2
  echo "       --from-seed, and only makes sense if the seed profile has been re-enabled. Refusing." >&2
  exit 1
fi
# Snapshot mode only ever STAGES: publication is promote-join-snapshot.sh's job
# (codex round 49). Refused before anything is read, inspected or written.
if [ -n "${SOURCE_SNAPSHOT}" ] && [ -z "${STAGE_DIR}" ]; then
  echo "ERROR: --from-snapshot requires --stage-dir <dir>. Snapshot mode never writes the served" >&2
  echo "       directory; publish the staged bundle with promote-join-snapshot.sh. Refusing." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_CONTAINER="${NODE_CONTAINER:-wrfcoin-testnet-node}"
SEED_CONTAINER="${SEED_CONTAINER:-wrfcoin-testnet-seed}"
SEED_VOLUME="${SEED_VOLUME:-testnet_seed-data}"
SEED_API_TIMEOUT="${SEED_API_TIMEOUT:-10}"
VERIFY_BOOT_TIMEOUT="${VERIFY_BOOT_TIMEOUT:-600}"
VERIFY_POLL_INTERVAL="${VERIFY_POLL_INTERVAL:-2}"
VERIFY_REQUEST_TIMEOUT="${VERIFY_REQUEST_TIMEOUT:-10}"
for knob in SEED_API_TIMEOUT VERIFY_BOOT_TIMEOUT VERIFY_POLL_INTERVAL VERIFY_REQUEST_TIMEOUT; do
  if ! [[ "${!knob}" =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "ERROR: ${knob}='${!knob}' must be a positive integer number of seconds." >&2
    exit 1
  fi
done
if [ -n "${NODE_API:-}" ]; then
  echo "ERROR: NODE_API is no longer honoured (infra#1061): it pointed the receipt at the producer" >&2
  echo "       while the archive ships the seed's database. The receipt now comes from" >&2
  echo "       ${SEED_CONTAINER:-wrfcoin-testnet-seed}'s own published API port. Unset NODE_API." >&2
  exit 1
fi
EDGE_CONTAINER="${EDGE_CONTAINER:-wrfcoin-testnet-funnel-edge}"
CUT_PINS_FILE="${CUT_PINS_FILE:-${SCRIPT_DIR}/cut-pins.env}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
SEED_DATA_DEST="${SEED_DATA_DEST:-/app/data}"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

# shellcheck source=/dev/null
. "${CUT_PINS_FILE}"
: "${WRFCOIN_CUT_GENESIS_HASH:?cut-pins.env does not define WRFCOIN_CUT_GENESIS_HASH}"
: "${WRFCOIN_CUT_CHAIN_ID:?cut-pins.env does not define WRFCOIN_CUT_CHAIN_ID}"
: "${WRFCOIN_CUT_NETWORK_ID:?cut-pins.env does not define WRFCOIN_CUT_NETWORK_ID}"

json_field() {
  printf '%s' "$1" \
    | tr ',{}' '\n' \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" \
    | head -1
}

reader_token="${WRFCOIN_READER_TOKEN:-}"
if [ -z "${reader_token}" ] && [ -f "${ENV_FILE}" ]; then
  reader_token="$(sed -n 's/^[[:space:]]*WRFCOIN_READER_TOKEN=//p' "${ENV_FILE}" | tail -1 | tr -d '"' | tr -d "'")"
fi
if [ -z "${reader_token}" ]; then
  echo "ERROR: WRFCOIN_READER_TOKEN is required to bind the archive to canonical /state/snapshot evidence." >&2
  exit 1
fi

tree_real="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
# refuse_in_tree <dir> <label>: a directory under this checkout or any
# *.releases/ tree vanishes (or goes empty) on the next release flip.
refuse_in_tree() {
  local real
  real="$(realpath -m "$1")"
  case "${real}/" in
    "${tree_real}/"*|*.releases/*)
      echo "ERROR: $2 '$1' (${real}) is inside a release/checkout tree." >&2
      echo "       The next release flip would serve an empty directory (infra#1057). Refusing." >&2
      exit 1
      ;;
  esac
  refuse_checkout_ancestor "$1" "$2"
}
# refuse_checkout_ancestor <dir> <label>: ANY git checkout or worktree (a .git
# directory or file) at or above <dir>, not just this one (codex round 49).
refuse_checkout_ancestor() {
  local d
  d="$(realpath -m "$1")"
  while :; do
    # A checkout is what git itself recognises: a .git DIRECTORY holding HEAD,
    # or a .git FILE pointing elsewhere (worktree/submodule: "gitdir: ...").
    # A stray empty .git directory is not a checkout.
    if [ -f "${d}/.git/HEAD" ] || { [ -f "${d}/.git" ] && grep -q '^gitdir:' "${d}/.git" 2>/dev/null; }; then
      echo "ERROR: $2 '$1' is inside a git checkout/worktree (${d}/.git). Operator artifacts must" >&2
      echo "       live outside every checkout (infra#1057). Refusing." >&2
      exit 1
    fi
    [ "${d}" = / ] && break
    d="$(dirname "${d}")"
  done
}

# --- 0. Output directory: exactly what the running edge serves ------------
if [ -n "${STAGE_DIR}" ]; then
  # Staging writes nothing the edge serves. The edge is inspected only to
  # refuse staging INTO the served directory (that would be a publish).
  case "${STAGE_DIR}" in
    /*) ;;
    *) echo "ERROR: --stage-dir '${STAGE_DIR}' must be an absolute path. Refusing." >&2; exit 1 ;;
  esac
  refuse_in_tree "${STAGE_DIR}" "stage dir"
  if [ ! -d "${STAGE_DIR}" ] || [ ! -w "${STAGE_DIR}" ] || [ -L "${STAGE_DIR}" ]; then
    echo "ERROR: stage dir '${STAGE_DIR}' is missing, a symlink, or not writable. Refusing." >&2
    exit 1
  fi
  served="$("${DOCKER_BIN}" inspect -f '{{range .Mounts}}{{if eq .Destination "/srv/join"}}{{.Source}}{{end}}{{end}}' "${EDGE_CONTAINER}" 2>/dev/null)" || served=""
  if [ -n "${served}" ] && [ "$(realpath -m "${served}")" = "$(realpath -m "${STAGE_DIR}")" ]; then
    echo "ERROR: --stage-dir is the directory ${EDGE_CONTAINER} serves at /srv/join; staging there IS publishing." >&2
    echo "       Stage elsewhere and use promote-join-snapshot.sh. Refusing." >&2
    exit 1
  fi
  OUT_DIR="${STAGE_DIR}"
else
OUT_DIR="$("${DOCKER_BIN}" inspect -f '{{range .Mounts}}{{if eq .Destination "/srv/join"}}{{.Source}}{{end}}{{end}}' "${EDGE_CONTAINER}")" || {
  echo "ERROR: cannot inspect ${EDGE_CONTAINER}; refusing to publish to a directory no edge is known to serve." >&2
  exit 1
}
case "${OUT_DIR}" in
  /*) ;;
  "")
    echo "ERROR: ${EDGE_CONTAINER} has no /srv/join mount; publishing would serve nothing. Refusing." >&2
    exit 1
    ;;
  *)
    echo "ERROR: ${EDGE_CONTAINER} reports a non-absolute /srv/join source '${OUT_DIR}'. Refusing." >&2
    exit 1
    ;;
esac
out_real="$(realpath -m "${OUT_DIR}")"
case "${out_real}/" in
  "${tree_real}/"*|*.releases/*)
    echo "ERROR: join snapshot dir '${OUT_DIR}' (${out_real}) is inside a release/checkout tree." >&2
    echo "       The next release flip would serve an empty directory (infra#1057)." >&2
    echo "       Recreate funnel-edge from the current docker-compose.funnel-edge.yml first. Refusing." >&2
    exit 1
    ;;
esac
refuse_checkout_ancestor "${OUT_DIR}" "join snapshot dir"
if [ ! -d "${OUT_DIR}" ] || [ ! -w "${OUT_DIR}" ]; then
  echo "ERROR: join snapshot dir '${OUT_DIR}' is missing or not writable; refusing before touching the seed." >&2
  exit 1
fi
fi

expected_genesis="0x${WRFCOIN_CUT_GENESIS_HASH#0x}"
live_height=""
if [ -z "${SOURCE_SNAPSHOT}" ]; then
SOURCE_CONTAINER="${SEED_CONTAINER}"
SOURCE_LABEL="ct101-seed"
# --- 1a. The seed: running, and its OWN API address -----------------------
seed_running="$("${DOCKER_BIN}" inspect -f '{{.State.Running}}' "${SEED_CONTAINER}")" || seed_running=""
if [ "${seed_running}" != "true" ]; then
  # stop/start below would otherwise START a seed an operator deliberately
  # left down (e.g. rc0926: the seed stays down until it is on the release
  # image), and copy a database that has not followed the chain.
  echo "ERROR: ${SEED_CONTAINER} is not running (State.Running='${seed_running:-<unknown>}')." >&2
  echo "       Refusing: this script must not start a stopped seed or ship its stale database." >&2
  exit 1
fi
seed_port_line="$("${DOCKER_BIN}" port "${SEED_CONTAINER}" 8556/tcp | grep -E '^[0-9.]+:[0-9]+$' | head -1)" || seed_port_line=""
if [ -z "${seed_port_line}" ]; then
  echo "ERROR: ${SEED_CONTAINER} publishes no IPv4 host port for its API (8556/tcp)." >&2
  echo "       The receipt must come from the seed itself; refusing to guess an address." >&2
  exit 1
fi
seed_host="${seed_port_line%:*}"
[ "${seed_host}" = "0.0.0.0" ] && seed_host=127.0.0.1
SEED_API="http://${seed_host}:${seed_port_line##*:}"

# Every request is bounded twice: curl's own connect/total timeouts, and an
# outer `timeout` that also covers a server that accepts and never answers.
# The bearer header goes over stdin, never argv.
curl_json() {
  printf 'Authorization: Bearer %s\n' "${reader_token}" \
    | timeout -k 2 "$((SEED_API_TIMEOUT + 1))" \
      curl -fsS --connect-timeout "${SEED_API_TIMEOUT}" --max-time "${SEED_API_TIMEOUT}" \
      -H @- "${SEED_API}$1"
}

# --- 1b. Live pre-check: wrong chain or too low refuses BEFORE any stop ----
# This does not produce the manifest's receipt (see step 4); it only avoids
# stopping the seed for a snapshot that could never be published.
echo "==> Reading the seed's chain identity from ${SEED_API}/network/info ..."
INFO="$(curl_json /network/info)" || {
  echo "ERROR: seed API unreachable at ${SEED_API}; refusing to snapshot a chain I cannot identify." >&2
  exit 1
}
live_genesis="0x$(json_field "${INFO}" genesis_hash | sed 's/^0x//')"
live_chain="$(json_field "${INFO}" chain_id)"
live_network="$(json_field "${INFO}" network_id)"
live_height="$(json_field "${INFO}" chain_height)"
SNAPSHOT="$(curl_json /state/snapshot)" || {
  echo "ERROR: authenticated canonical state snapshot unavailable; refusing an unbound archive." >&2
  exit 1
}
snapshot_height="$(json_field "${SNAPSHOT}" height)"
state_root="$(json_field "${SNAPSHOT}" state_root_hex)"

if [ "${live_genesis}" != "${expected_genesis}" ] \
  || [ "${live_chain}" != "${WRFCOIN_CUT_CHAIN_ID}" ] \
  || [ "${live_network}" != "${WRFCOIN_CUT_NETWORK_ID}" ]; then
  echo "ERROR: live chain identity does not match ${CUT_PINS_FILE}:" >&2
  echo "         genesis  expected ${expected_genesis}, live ${live_genesis}" >&2
  echo "         chain_id expected '${WRFCOIN_CUT_CHAIN_ID}', live '${live_chain}'" >&2
  echo "         network  expected '${WRFCOIN_CUT_NETWORK_ID}', live '${live_network}'" >&2
  echo "       Either the pins are stale (core4#2705 class) or this host runs a different chain." >&2
  echo "       Publishing this snapshot would poison every joiner. Refusing." >&2
  exit 1
fi
if ! [[ "${live_height}" =~ ^[0-9]+$ ]] || ! [[ "${snapshot_height}" =~ ^[0-9]+$ ]] \
  || [ "${live_height}" != "${snapshot_height}" ] || [ "${snapshot_height}" -le 11017 ]; then
  echo "ERROR: canonical receipt height must be present, agree across endpoints, and be above 11017" >&2
  echo "       network=${live_height:-<missing>} snapshot=${snapshot_height:-<missing>}; refusing." >&2
  exit 1
fi
if ! [[ "${state_root}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: canonical /state/snapshot returned a missing or malformed state_root_hex." >&2
  exit 1
fi
echo "    live pre-check OK: ${expected_genesis} chain '${live_chain}' network '${live_network}' height ${live_height}"

# --- 2. Locate the seed's redb ---------------------------------------------
mountpoint="$("${DOCKER_BIN}" volume inspect -f '{{ .Mountpoint }}' "${SEED_VOLUME}")" || {
  echo "ERROR: volume '${SEED_VOLUME}' not found. Set SEED_VOLUME to the seed's data volume." >&2
  exit 1
}
mounted_volume="$("${DOCKER_BIN}" inspect -f "{{range .Mounts}}{{if eq .Destination \"${SEED_DATA_DEST}\"}}{{.Name}}{{end}}{{end}}" "${SEED_CONTAINER}")" || {
  echo "ERROR: cannot inspect seed container '${SEED_CONTAINER}' to bind its database volume." >&2
  exit 1
}
if [ "${mounted_volume}" != "${SEED_VOLUME}" ]; then
  echo "ERROR: ${SEED_CONTAINER} mounts '${mounted_volume:-<none>}' at ${SEED_DATA_DEST}, not SEED_VOLUME '${SEED_VOLUME}'." >&2
  echo "       Refusing to label an independently selected database with this seed's receipt." >&2
  exit 1
fi
redb_path="${mountpoint}/wrfcoin.redb"
if [ ! -s "${redb_path}" ]; then
  echo "ERROR: ${redb_path} missing or empty — is SEED_VOLUME the right volume?" >&2
  exit 1
fi
else
# --- 1-2 (--from-snapshot). An immutable ZFS snapshot of NODE_CONTAINER's volume
# Nothing live is read, stopped or written: the node container is only
# inspected (its data mount, image ID and env).
SOURCE_CONTAINER="${NODE_CONTAINER}"
# Provenance is established from the KERNEL's mount table, not from the path
# spelling (codex round 49: an ordinary directory named .zfs, an ancestor
# symlink to the live volume, or a bind mount of the live directory at
# .../.zfs/snapshot/x/... all spell like a snapshot and would archive LIVE
# bytes). Required, in order:
#   1. the path is canonical: realpath -e of it is itself, so no component is
#      a symlink and there is no ./.. or doubled slash;
#   2. the mount that contains it (findmnt -T: the DEEPEST mount, so any
#      overmount or bind below the snapshot root is what gets checked) is
#      fstype zfs, source exactly <dataset>@<snap> (no [/subdir] bind marker),
#      superblock read-only, mounted at <m>/.zfs/snapshot/<snap>;
#   3. NODE_CONTAINER's /app/data source is on that same <dataset>, mounted at
#      <m> (source exactly <dataset>: not a bind), and the snapshot path is
#      that directory's wrfcoin.redb relative to <m>.
# The frozen-copy boot below stays a separate gate: provenance says the bytes
# are an immutable image of the node's volume, the boot says they open.
# mount_of <path>: sets M_TARGET M_SOURCE M_FSTYPE M_FSOPTS, or fails.
mount_of() {
  local line
  line="$("${FINDMNT_BIN}" -n -P -T "$1" -o TARGET,SOURCE,FSTYPE,FS-OPTIONS 2>/dev/null)" || return 1
  [[ "${line}" =~ ^TARGET=\"([^\"]*)\"\ SOURCE=\"([^\"]*)\"\ FSTYPE=\"([^\"]*)\"\ FS-OPTIONS=\"([^\"]*)\"$ ]] || return 1
  M_TARGET="${BASH_REMATCH[1]}"; M_SOURCE="${BASH_REMATCH[2]}"
  M_FSTYPE="${BASH_REMATCH[3]}"; M_FSOPTS="${BASH_REMATCH[4]}"
}
snap_refuse() {
  echo "ERROR: --from-snapshot '${SOURCE_SNAPSHOT}': $1" >&2
  echo "       Only wrfcoin.redb inside a read-only ZFS snapshot of ${NODE_CONTAINER}'s own volume" >&2
  echo "       is a safe no-restart source; anything else may be LIVE bytes. Refusing." >&2
  exit 1
}
case "${SOURCE_SNAPSHOT}" in
  /*/wrfcoin.redb) ;;
  *) snap_refuse "not an absolute path to a file named wrfcoin.redb" ;;
esac
snap_canon="$(realpath -e -- "${SOURCE_SNAPSHOT}" 2>/dev/null)" || snap_refuse "path does not resolve"
[ "${snap_canon}" = "${SOURCE_SNAPSHOT}" ] \
  || snap_refuse "path is not canonical (resolves to '${snap_canon}'): a symlinked component or ./.. is not allowed"
mount_of "${SOURCE_SNAPSHOT}" || snap_refuse "cannot read its mount from ${FINDMNT_BIN}"
snap_target="${M_TARGET}"; snap_source="${M_SOURCE}"
[ "${M_FSTYPE}" = zfs ] || snap_refuse "it is on a '${M_FSTYPE}' filesystem (${M_TARGET}), not a ZFS snapshot"
[[ "${snap_source}" =~ ^([A-Za-z0-9._/:-]+)@([A-Za-z0-9._:-]+)$ ]] \
  || snap_refuse "its mount source '${snap_source}' is not <dataset>@<snapshot> (a live dataset or a bind mount)"
snap_dataset="${BASH_REMATCH[1]}"; snap_name="${BASH_REMATCH[2]}"
[[ ",${M_FSOPTS}," == *,ro,* ]] || snap_refuse "its mount ${snap_target} is not read-only (${M_FSOPTS})"
case "${snap_target}" in
  */.zfs/snapshot/"${snap_name}") ;;
  *) snap_refuse "its mount ${snap_target} is not the snapshot root <m>/.zfs/snapshot/${snap_name}" ;;
esac
case "${SOURCE_SNAPSHOT}" in
  "${snap_target}"/*) ;;
  *) snap_refuse "path is not under its own mount ${snap_target}" ;;
esac
node_data_source="$("${DOCKER_BIN}" inspect -f "{{range .Mounts}}{{if eq .Destination \"${SEED_DATA_DEST}\"}}{{.Source}}{{end}}{{end}}" "${NODE_CONTAINER}")" || {
  echo "ERROR: cannot inspect '${NODE_CONTAINER}' to bind the snapshot to its data volume." >&2
  exit 1
}
[ -n "${node_data_source}" ] || snap_refuse "${NODE_CONTAINER} has no ${SEED_DATA_DEST} mount; it must be of that container's volume"
live_canon="$(realpath -e -- "${node_data_source}" 2>/dev/null)" \
  || snap_refuse "${NODE_CONTAINER}'s data dir '${node_data_source}' does not resolve; it must be of that container's volume"
mount_of "${live_canon}" || snap_refuse "cannot read the mount of ${NODE_CONTAINER}'s data dir"
live_target="${M_TARGET}"
if [ "${M_FSTYPE}" != zfs ] || [ "${M_SOURCE}" != "${snap_dataset}" ]; then
  snap_refuse "${NODE_CONTAINER}'s data dir is on '${M_SOURCE}' (${M_FSTYPE}), not dataset '${snap_dataset}'; it must be of that container's volume"
fi
[ "${snap_target}" = "${live_target%/}/.zfs/snapshot/${snap_name}" ] \
  || snap_refuse "snapshot root ${snap_target} is not ${live_target%/}/.zfs/snapshot/${snap_name}; it must be of that container's volume"
case "${live_canon}" in
  "${live_target%/}"/*) live_rel="${live_canon#"${live_target%/}"/}" ;;
  *) snap_refuse "${NODE_CONTAINER}'s data dir is not under its dataset mount; it must be of that container's volume" ;;
esac
[ "${SOURCE_SNAPSHOT#"${snap_target}"/}" = "${live_rel}/wrfcoin.redb" ] \
  || snap_refuse "it is '${SOURCE_SNAPSHOT#"${snap_target}"/}' in the snapshot, not ${live_rel}/wrfcoin.redb; it must be of that container's volume"
redb_path="${SOURCE_SNAPSHOT}"
if [ -L "${redb_path}" ] || [ ! -f "${redb_path}" ] || [ ! -s "${redb_path}" ] || [ ! -r "${redb_path}" ]; then
  echo "ERROR: ${redb_path} is missing, empty, unreadable or not a regular file. Refusing." >&2
  exit 1
fi
SOURCE_LABEL="ct101-node-zfs:${snap_name}"
echo "==> Source: ZFS snapshot ${snap_dataset}@${snap_name} (read-only) of ${NODE_CONTAINER}'s volume (no container is stopped)"
fi

workdir="$(mktemp -d)"
seed_stopped=0
# Verifier ownership (codex round 14): the throwaway container is addressed ONLY
# by the ID this run created (docker run --cidfile), and removed only after its
# per-run owner label is re-confirmed. A name is never used to remove anything:
# a name collision (docker run exits 125) must leave a foreign container alone.
verify_nonce=""
verifier_cid=""
verify_owner_label="wrfcoin.join-verify.owner"
# owned_verifier <id>: true only if <id> carries THIS run's owner label.
owned_verifier() {
  [ -n "${verify_nonce}" ] && [[ "$1" =~ ^[0-9a-f]{64}$ ]] || return 1
  [ "$("${DOCKER_BIN}" inspect -f "{{index .Config.Labels \"${verify_owner_label}\"}}" "$1" 2>/dev/null)" = "${verify_nonce}" ]
}
# remove_owned_verifiers: the recorded ID plus any container labelled with this
# run's nonce (an ambiguous create), each removed by ID after the label check.
remove_owned_verifiers() {
  [ -n "${verify_nonce}" ] || return 0
  local ids id rc=0
  ids="$("${DOCKER_BIN}" ps -aq --no-trunc --filter "label=${verify_owner_label}=${verify_nonce}" 2>/dev/null)" || ids=""
  for id in ${verifier_cid} ${ids}; do
    if owned_verifier "${id}"; then
      "${DOCKER_BIN}" rm -f "${id}" >/dev/null 2>&1 || { rc=1; echo "WARN: could not remove owned verifier container ${id}." >&2; }
    fi
  done
  return "${rc}"
}
cleanup() {
  # The seed comes back up on EVERY exit path. A snapshot script that can
  # leave the seed down after a failed copy is an outage generator.
  if [ "${seed_stopped}" = "1" ]; then
    "${DOCKER_BIN}" start "${SEED_CONTAINER}" >/dev/null 2>&1 || \
      echo "WARN: could not restart ${SEED_CONTAINER} — start it manually NOW." >&2
  fi
  # The frozen-copy node: removed by owned ID only (never by name).
  remove_owned_verifiers || \
    echo "WARN: remove leftovers with: docker ps -aq --no-trunc --filter label=${verify_owner_label}=${verify_nonce}" >&2
  rm -rf "${workdir}"
}
trap cleanup EXIT
# A signal must still restart the seed: exit, and let the EXIT trap run.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -n "${SOURCE_SNAPSHOT}" ]; then
# --- 3 (--from-snapshot). Copy from the immutable snapshot; nothing stops ----
cp "${redb_path}" "${workdir}/wrfcoin.redb"
frozen_sha="$(sha256sum "${workdir}/wrfcoin.redb" | cut -d' ' -f1)"
if [ "$(sha256sum "${redb_path}" | cut -d' ' -f1)" != "${frozen_sha}" ]; then
  echo "ERROR: the copy differs from the snapshot it was read from; a ZFS snapshot cannot change. Refusing." >&2
  exit 1
fi
# The mount checked above must still be what was read (no swap in between).
if ! mount_of "${redb_path}" || [ "${M_TARGET}" != "${snap_target}" ] || [ "${M_SOURCE}" != "${snap_source}" ] \
   || [ "${M_FSTYPE}" != zfs ] || [[ ",${M_FSOPTS}," != *,ro,* ]]; then
  echo "ERROR: the snapshot mount changed while it was being copied; refusing." >&2
  exit 1
fi
echo "    copied from snapshot; frozen copy sha256 ${frozen_sha}"
else
# --- 3. Stop-copy-start (downtime = the cp only) ----------------------------
# Recovery is armed BEFORE the stop: a stop that times out, fails or is
# interrupted may still have stopped the seed, and must still restart it.
echo "==> Stopping ${SEED_CONTAINER} for the copy ..."
seed_stopped=1
if ! "${DOCKER_BIN}" stop -t 30 "${SEED_CONTAINER}" >/dev/null; then
  echo "ERROR: 'docker stop ${SEED_CONTAINER}' failed; not copying a possibly-live database. Restarting it." >&2
  exit 1
fi
cp "${redb_path}" "${workdir}/wrfcoin.redb"
if "${DOCKER_BIN}" start "${SEED_CONTAINER}" >/dev/null; then
  seed_stopped=0
else
  echo "ERROR: 'docker start ${SEED_CONTAINER}' failed after the copy; retrying on exit. Not publishing." >&2
  exit 1
fi
frozen_sha="$(sha256sum "${workdir}/wrfcoin.redb" | cut -d' ' -f1)"
echo "    seed restarted; frozen copy sha256 ${frozen_sha}"
fi

# --- 3b. Receipt from the FROZEN COPY, on an isolated throwaway node -------
seed_image="$("${DOCKER_BIN}" inspect -f '{{.Image}}' "${SOURCE_CONTAINER}")" || seed_image=""
if ! [[ "${seed_image}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "ERROR: cannot resolve ${SOURCE_CONTAINER}'s exact image ID (got '${seed_image}'); refusing." >&2
  exit 1
fi
# The core4 build that produced this state: the source container's image revision
# label (the same label UPGRADE_RUNBOOK.md reads). Recorded in the manifest so a
# joiner can refuse a snapshot from a different build than its cut pin (r20.2
# audit C3). No guess: an unlabelled source is refused.
core4_commit="$("${DOCKER_BIN}" inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${SOURCE_CONTAINER}")" || core4_commit=""
if ! [[ "${core4_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: ${SOURCE_CONTAINER} has no full-SHA org.opencontainers.image.revision label (got '${core4_commit}'); refusing to publish a snapshot whose core4 build cannot be named." >&2
  exit 1
fi
verify_env="${workdir}/verify.env"
verify_data="${workdir}/verify-data"
seed_env_raw="${workdir}/seed.env.raw"
if ! ( umask 077; "${DOCKER_BIN}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${SOURCE_CONTAINER}" > "${seed_env_raw}" ); then
  echo "ERROR: cannot read ${SOURCE_CONTAINER}'s environment; refusing to boot the copy under a guessed identity." >&2
  exit 1
fi
# --from-snapshot clones the PRODUCER's env, which also carries its HSM
# configuration/PINs, operator/oracle/contributor tokens and database URLs.
# A sync-only, network-less verifier needs none of them (infra#818: sync-only
# starts without a signing HSM); only the reader token is kept, for the receipt.
strip_extra='^$'
if [ -n "${SOURCE_SNAPSHOT}" ]; then
  strip_extra='^(WRFCOIN_HSM_[A-Z0-9_]*|WRFCOIN_OPERATOR_TOKEN|WRFCOIN_ORACLE_TOKEN|WRFCOIN_CONTRIBUTOR_TOKEN|DATABASE_URL|REDIS_URL|WRFCOIN_REQUIRE_PRODUCER_AUTH)='
fi
( umask 077
  grep -vE '^(WRFCOIN_P2P_[A-Z0-9_]*|WRFCOIN_SYNC_ONLY|WRFCOIN_DATA_DIR|WRFCOIN_API_HOST|WRFCOIN_API_PORT|WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY)=' \
    "${seed_env_raw}" | grep -vE "${strip_extra}" > "${verify_env}" || true
  printf '%s\n' \
    WRFCOIN_P2P_PROFILE=disabled WRFCOIN_P2P_ENABLED=false WRFCOIN_SYNC_ONLY=1 \
    WRFCOIN_DATA_DIR=/app/data WRFCOIN_API_HOST=127.0.0.1 WRFCOIN_API_PORT=8556 \
    >> "${verify_env}" )
if ! grep -q '^WRFCOIN_CHAIN_ID=' "${verify_env}"; then
  echo "ERROR: could not clone ${SOURCE_CONTAINER}'s environment; refusing to boot the copy under a guessed identity." >&2
  exit 1
fi
# The node writes beside its database (evidence store, checkpoints), so it
# gets a SCRATCH copy; the shipped bytes are never mounted.
mkdir -p "${verify_data}"
cp "${workdir}/wrfcoin.redb" "${verify_data}/wrfcoin.redb"
chmod 0777 "${verify_data}"; chmod 0666 "${verify_data}/wrfcoin.redb"
verify_nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
if ! [[ "${verify_nonce}" =~ ^[0-9a-f]{32}$ ]]; then
  verify_nonce=""; echo "ERROR: could not draw a verifier ownership nonce; refusing." >&2; exit 1
fi
verify_cidfile="${workdir}/verify.cid"   # private (mktemp -d is 0700); must not pre-exist for --cidfile
verifier_label_name="wrfcoin-join-verify-${verify_nonce:0:12}"
echo "==> Booting ${verifier_label_name} on the frozen copy (no network, P2P disabled, sync-only) ..."
run_rc=0
"${DOCKER_BIN}" run -d --cidfile "${verify_cidfile}" --name "${verifier_label_name}" \
    --label "${verify_owner_label}=${verify_nonce}" \
    --network none --read-only \
    --tmpfs /tmp:noexec,nosuid,size=64m --tmpfs /app/logs:noexec,nosuid,size=64m \
    --cap-drop ALL --security-opt no-new-privileges:true \
    --env-file "${verify_env}" -v "${verify_data}:/app/data" \
    --entrypoint /usr/local/bin/wrfcoin-node \
    "${seed_image}" >/dev/null || run_rc=$?
cid_read="$(cat "${verify_cidfile}" 2>/dev/null || true)"
if [[ "${cid_read}" =~ ^[0-9a-f]{64}$ ]] && owned_verifier "${cid_read}"; then
  verifier_cid="${cid_read}"
elif [ "${run_rc}" = 0 ]; then
  # Ambiguous create: run reported success but left no usable cidfile.
  # Adopt only an unambiguous single container carrying THIS run's nonce.
  label_ids="$("${DOCKER_BIN}" ps -aq --no-trunc --filter "label=${verify_owner_label}=${verify_nonce}" 2>/dev/null)" || label_ids=""
  if [ "$(printf '%s\n' "${label_ids}" | grep -cE '^[0-9a-f]{64}$')" = 1 ] && owned_verifier "${label_ids}"; then
    verifier_cid="${label_ids}"
  fi
fi
if [ "${run_rc}" != 0 ] || [ -z "${verifier_cid}" ]; then
  echo "ERROR: could not start an owned frozen-copy verifier (docker run exit ${run_rc}); refusing publication." >&2
  echo "       Only containers labelled ${verify_owner_label}=<this run> are removed; nothing else is touched." >&2
  exit 1
fi

verify_deadline=$((SECONDS + VERIFY_BOOT_TIMEOUT))
# verify_json <path>: one bounded request to the verifier's loopback API.
verify_json() {
  local left="$((verify_deadline - SECONDS))" t
  [ "${left}" -gt 0 ] || return 124
  t="${VERIFY_REQUEST_TIMEOUT}"; [ "${left}" -lt "${t}" ] && t="${left}"
  printf 'Authorization: Bearer %s\n' "${reader_token}" \
    | timeout -k 2 "$((t + 1))" "${DOCKER_BIN}" exec -i "${verifier_cid}" \
      curl -fsS --connect-timeout "${t}" --max-time "${t}" -H @- "http://127.0.0.1:8556$1"
}
FROZEN=""
until FROZEN="$(verify_json /state/snapshot 2>/dev/null)"; do
  if [ "$("${DOCKER_BIN}" inspect -f '{{.State.Running}}' "${verifier_cid}" 2>/dev/null)" != "true" ]; then
    echo "ERROR: the frozen-copy node exited before answering; the copy does not boot. Refusing." >&2
    exit 1
  fi
  if [ "$((verify_deadline - SECONDS))" -le 0 ]; then
    echo "ERROR: the frozen-copy node gave no receipt within ${VERIFY_BOOT_TIMEOUT}s; refusing publication." >&2
    exit 1
  fi
  sleep "${VERIFY_POLL_INTERVAL}"
done
FROZEN_INFO="$(verify_json /network/info 2>/dev/null)" || {
  echo "ERROR: the frozen-copy node answered /state/snapshot but not /network/info; refusing." >&2
  exit 1
}
sleep "${VERIFY_POLL_INTERVAL}"
FROZEN_AGAIN="$(verify_json /state/snapshot 2>/dev/null)" || FROZEN_AGAIN=""

snapshot_height="$(json_field "${FROZEN}" height)"
state_root="$(json_field "${FROZEN}" state_root_hex)"
frozen_info_height="$(json_field "${FROZEN_INFO}" chain_height)"
frozen_genesis="0x$(json_field "${FROZEN_INFO}" genesis_hash | sed 's/^0x//')"
if [ "${frozen_genesis}" != "${expected_genesis}" ] \
  || [ "$(json_field "${FROZEN_INFO}" chain_id)" != "${WRFCOIN_CUT_CHAIN_ID}" ] \
  || [ "$(json_field "${FROZEN_INFO}" network_id)" != "${WRFCOIN_CUT_NETWORK_ID}" ]; then
  echo "ERROR: the frozen copy's chain identity does not match ${CUT_PINS_FILE}; refusing." >&2
  exit 1
fi
if ! [[ "${snapshot_height}" =~ ^[0-9]+$ ]] || [ "${frozen_info_height}" != "${snapshot_height}" ] \
  || [ "${snapshot_height}" -le 11017 ] || ! [[ "${state_root}" =~ ^[0-9a-f]{64}$ ]]; then
  echo "ERROR: frozen-copy receipt must agree across endpoints, be above 11017 and carry a canonical root" >&2
  echo "       (network=${frozen_info_height:-<missing>} snapshot=${snapshot_height:-<missing>}); refusing." >&2
  exit 1
fi
if [ "$(json_field "${FROZEN_AGAIN}" height)" != "${snapshot_height}" ] \
  || [ "$(json_field "${FROZEN_AGAIN}" state_root_hex)" != "${state_root}" ]; then
  echo "ERROR: the isolated frozen-copy node's state moved between reads; it is not isolated. Refusing." >&2
  exit 1
fi
if [ "$(sha256sum "${workdir}/wrfcoin.redb" | cut -d' ' -f1)" != "${frozen_sha}" ]; then
  echo "ERROR: the frozen copy changed during verification; refusing." >&2
  exit 1
fi
if remove_owned_verifiers; then verifier_cid=""; verify_nonce=""; fi
rm -rf "${verify_data}" "${verify_env}" "${seed_env_raw}"
if [ -n "${live_height}" ] && [ "${snapshot_height}" != "${live_height}" ]; then
  echo "    note: live seed read ${live_height} before the stop; the frozen copy loads at ${snapshot_height}."
fi
echo "    frozen-copy receipt: height ${snapshot_height}, state_root ${state_root}; compressing ..."

# --- 4. Compress, hash, manifest, atomic publish ----------------------------
tar czf "${workdir}/snapshot.tar.gz" -C "${workdir}" wrfcoin.redb
sha256="$(sha256sum "${workdir}/snapshot.tar.gz" | cut -d' ' -f1)"
size_bytes="$(stat -c '%s' "${workdir}/snapshot.tar.gz")"
created_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "${workdir}/manifest.json" <<MANIFEST
{
  "file": "snapshot.tar.gz",
  "sha256": "${sha256}",
  "size_bytes": ${size_bytes},
  "height": ${snapshot_height},
  "state_root_hex": "${state_root}",
  "genesis_hash": "${expected_genesis}",
  "chain_id": "${WRFCOIN_CUT_CHAIN_ID}",
  "network_id": "${WRFCOIN_CUT_NETWORK_ID}",
  "core4_commit": "${core4_commit}",
  "created_utc": "${created_utc}",
  "source": "${SOURCE_LABEL}"
}
MANIFEST

# Archive first, manifest last: a joiner that reads the new manifest must
# find the archive it describes already in place, never the reverse.
mv "${workdir}/snapshot.tar.gz" "${OUT_DIR}/snapshot.tar.gz.tmp"
mv "${OUT_DIR}/snapshot.tar.gz.tmp" "${OUT_DIR}/snapshot.tar.gz"
mv "${workdir}/manifest.json" "${OUT_DIR}/manifest.json.tmp"
mv "${OUT_DIR}/manifest.json.tmp" "${OUT_DIR}/manifest.json"

if [ -n "${STAGE_DIR}" ]; then
  echo "==> Staged (NOT served; nothing public changed):"
else
  echo "==> Published:"
fi
echo "    ${OUT_DIR}/snapshot.tar.gz  (${size_bytes} bytes, sha256 ${sha256})"
echo "    ${OUT_DIR}/manifest.json    (height ${snapshot_height}, ${created_utc}, source ${SOURCE_LABEL})"
if [ -n "${STAGE_DIR}" ]; then
  echo "    Next: bash testnet/promote-join-snapshot.sh --stage-dir ${OUT_DIR} --dry-run, then without --dry-run."
else
  echo "    Serve path: /join/manifest.json + /join/snapshot.tar.gz via the funnel edge"
  echo "    (funnel-edge must mount this same directory at /srv/join)."
fi
