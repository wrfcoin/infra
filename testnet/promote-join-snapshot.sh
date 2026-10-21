#!/usr/bin/env bash
#
# promote-join-snapshot.sh — publish a STAGED join snapshot to the directory
# the running funnel edge serves at /srv/join (infra#1057).
#
# publish-join-snapshot.sh --stage-dir <dir> produces manifest.json +
# snapshot.tar.gz without touching anything public. This script is the only
# step that changes what /join/* serves, and it re-verifies the staged pair
# with the JOINER's own checks first (join-snapshot-restore.sh functions), so
# nothing is published that join.sh would refuse:
#   - manifest identity equals cut-pins.env (genesis, chain_id, network_id),
#     height > 11017, well-formed state_root_hex;
#   - the archive's sha256 equals the manifest's;
#   - the archive holds exactly one regular root file, wrfcoin.redb.
#
# Destination: the /srv/join mount source of the RUNNING edge (docker inspect),
# with the same refusals as the publisher: absolute, outside any checkout or
# *.releases/ tree, existing and writable. The staged dir must not be it.
#
# Write order: archive first, manifest last, each copied to a temp name in the
# destination and renamed into place, so a joiner never reads a manifest whose
# archive is not already there. After the rename, the served archive is hashed
# again against the manifest.
#
# Usage (on CT101, as root: the served dir is root-owned):
#   bash testnet/promote-join-snapshot.sh --stage-dir <dir> --dry-run   # verify + print, write nothing
#   bash testnet/promote-join-snapshot.sh --stage-dir <dir>             # verify + publish
#
# Environment (test seams): EDGE_CONTAINER (wrfcoin-testnet-funnel-edge),
# CUT_PINS_FILE (<this dir>/cut-pins.env), DOCKER_BIN (docker).
set -euo pipefail

STAGE_DIR=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --stage-dir) [ $# -ge 2 ] || { echo "ERROR: --stage-dir needs a path." >&2; exit 1; }; STAGE_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "ERROR: unknown argument '$1'. Usage: --stage-dir <dir> [--dry-run]" >&2; exit 1 ;;
  esac
done
[ -n "${STAGE_DIR}" ] || { echo "ERROR: --stage-dir <dir> is required." >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDGE_CONTAINER="${EDGE_CONTAINER:-wrfcoin-testnet-funnel-edge}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
export CUT_PINS_FILE="${CUT_PINS_FILE:-${SCRIPT_DIR}/cut-pins.env}"
# shellcheck source=testnet/join-snapshot-restore.sh disable=SC1091
. "${SCRIPT_DIR}/join-snapshot-restore.sh"
set -euo pipefail   # the sourced file sets -uo only

manifest="${STAGE_DIR}/manifest.json"
archive="${STAGE_DIR}/snapshot.tar.gz"
for f in "${manifest}" "${archive}"; do
  if [ -L "${f}" ] || [ ! -f "${f}" ]; then
    echo "ERROR: ${f} is missing or not a regular file. Refusing." >&2
    exit 1
  fi
done

# --- 1. The joiner's own checks, on the staged pair -------------------------
echo "==> Verifying the staged bundle with the joiner's checks (${CUT_PINS_FILE}) ..."
jsr_verify_manifest "${manifest}" || { echo "ERROR: staged manifest refused; nothing published." >&2; exit 1; }
jsr_verify_archive "${manifest}" "${archive}" || { echo "ERROR: staged archive refused; nothing published." >&2; exit 1; }
jsr_verify_archive_shape "${archive}" || { echo "ERROR: staged archive shape refused; nothing published." >&2; exit 1; }
m="$(cat "${manifest}")"
height="$(jsr_json_field "${m}" height)"
root="$(jsr_json_field "${m}" state_root_hex)"
sha="$(jsr_json_field "${m}" sha256)"
source_label="$(jsr_json_field "${m}" source)"
echo "    OK: height ${height}, state_root ${root}, sha256 ${sha}, source ${source_label:-<none>}"

# --- 2. Destination: exactly what the running edge serves -------------------
OUT_DIR="$("${DOCKER_BIN}" inspect -f '{{range .Mounts}}{{if eq .Destination "/srv/join"}}{{.Source}}{{end}}{{end}}' "${EDGE_CONTAINER}")" || {
  echo "ERROR: cannot inspect ${EDGE_CONTAINER}; refusing to publish to a directory no edge is known to serve." >&2
  exit 1
}
case "${OUT_DIR}" in
  /*) ;;
  "") echo "ERROR: ${EDGE_CONTAINER} has no /srv/join mount; publishing would serve nothing. Refusing." >&2; exit 1 ;;
  *)  echo "ERROR: ${EDGE_CONTAINER} reports a non-absolute /srv/join source '${OUT_DIR}'. Refusing." >&2; exit 1 ;;
esac
out_real="$(realpath -m "${OUT_DIR}")"
tree_real="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
case "${out_real}/" in
  "${tree_real}/"*|*.releases/*)
    echo "ERROR: served dir '${OUT_DIR}' (${out_real}) is inside a release/checkout tree (infra#1057)." >&2
    echo "       Recreate funnel-edge from the current docker-compose.funnel-edge.yml first. Refusing." >&2
    exit 1
    ;;
esac
# ANY git checkout/worktree (a .git dir or file) at or above either directory
# is refused, not just this one (codex round 49).
for pair in "served dir:${OUT_DIR}" "stage dir:${STAGE_DIR}"; do
  d="$(realpath -m "${pair#*:}")"
  while :; do
    # Same rule as the publisher: .git dir with HEAD, or a "gitdir:" .git file.
    if [ -f "${d}/.git/HEAD" ] || { [ -f "${d}/.git" ] && grep -q '^gitdir:' "${d}/.git" 2>/dev/null; }; then
      echo "ERROR: ${pair%%:*} '${pair#*:}' is inside a git checkout/worktree (${d}/.git). Refusing." >&2
      exit 1
    fi
    [ "${d}" = / ] && break
    d="$(dirname "${d}")"
  done
done
if [ "${out_real}" = "$(realpath -m "${STAGE_DIR}")" ]; then
  echo "ERROR: the stage dir IS the served dir; there is nothing to promote. Refusing." >&2
  exit 1
fi
if [ ! -d "${OUT_DIR}" ] || [ ! -w "${OUT_DIR}" ]; then
  echo "ERROR: served dir '${OUT_DIR}' is missing or not writable (run as root on CT101). Refusing." >&2
  exit 1
fi

if [ "${DRY_RUN}" = 1 ]; then
  echo "==> DRY RUN: would publish into ${OUT_DIR} (served by ${EDGE_CONTAINER} at /srv/join):"
  echo "    snapshot.tar.gz  <- ${archive}"
  echo "    manifest.json    <- ${manifest}   (written last)"
  for f in manifest.json snapshot.tar.gz; do
    if [ -e "${OUT_DIR}/${f}" ]; then
      echo "    currently served ${f}: sha256 $(sha256sum "${OUT_DIR}/${f}" | cut -d' ' -f1)"
    else
      echo "    currently served ${f}: <absent> (/join/${f} is 404)"
    fi
  done
  echo "    Nothing was written."
  exit 0
fi

# --- 3. Atomic publish: archive first, manifest last ------------------------
cp "${archive}" "${OUT_DIR}/snapshot.tar.gz.tmp"
chmod 0644 "${OUT_DIR}/snapshot.tar.gz.tmp"
mv -f "${OUT_DIR}/snapshot.tar.gz.tmp" "${OUT_DIR}/snapshot.tar.gz"
cp "${manifest}" "${OUT_DIR}/manifest.json.tmp"
chmod 0644 "${OUT_DIR}/manifest.json.tmp"
mv -f "${OUT_DIR}/manifest.json.tmp" "${OUT_DIR}/manifest.json"

# Post-check: what is SERVED passes the same checks.
if ! jsr_verify_archive "${OUT_DIR}/manifest.json" "${OUT_DIR}/snapshot.tar.gz" \
   || ! cmp -s "${manifest}" "${OUT_DIR}/manifest.json"; then
  echo "ERROR: the served pair does not match the staged pair after the rename." >&2
  echo "       Roll back: move ${OUT_DIR}/manifest.json out of the served dir (/join/* then returns 404)." >&2
  exit 1
fi
echo "==> Published to ${OUT_DIR}: height ${height}, sha256 ${sha}."
printf '    Check: %s\n' "curl -fsS -o /dev/null -w '%{http_code} %{content_type}\\n' http://127.0.0.1:8444/join/manifest.json"
