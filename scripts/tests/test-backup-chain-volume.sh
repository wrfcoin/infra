#!/usr/bin/env bash
# infra#1115: testnet/backup.sh must find the node's chain-data volume in
# Docker-volume mode. `docker compose config --format json` emits each service
# volume as an OBJECT ({"type","source","target"}), not a "src:dst" string, and
# `source` is the unprefixed compose key while the real Docker volume is
# project-prefixed (testnet_node-data). The script must resolve the real name
# from the running container's Mounts, fall back to the compose config in
# either shape, and never swallow the parser's stderr.
#
# Offline: `docker` and `zfs` are PATH shims fed from fixture JSON. Only the
# chain-data step is asserted; the postgres/redis steps fail against the shim.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="${BACKUP_UNDER_TEST:-${ROOT}/testnet/backup.sh}"
FIX="${ROOT}/scripts/tests/fixtures/backup-chain-volume"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=()
check() { local name="$1"; shift; echo "$name"; if ! "$@"; then FAILED+=("$name"); echo "  CASE FAILED: $name" >&2; fi; }

mkdir -p "$TMP/bin"
# Force Docker-volume mode even on a host that has tank/blockchain.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/zfs"
cat > "$TMP/bin/docker" <<'SHIM'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_DOCKER_CALLS"
args=" $* "
case "$args" in
  *" inspect "*" wrfcoin-testnet-node "*)
    if [[ -n "${FAKE_MOUNTS:-}" ]]; then cat "$FAKE_MOUNTS"
    else echo "Error: No such object: wrfcoin-testnet-node" >&2; exit 1; fi ;;
  *" compose "*" config --format json "*)
    [[ -n "${FAKE_COMPOSE_JSON:-}" ]] && cat "$FAKE_COMPOSE_JSON" || exit 1 ;;
  *" run --rm -v "*":/source:ro -v "*":/backup alpine tar "*)
    # docker run --rm -v VOL:/source:ro -v DEST:/backup alpine tar czf ...
    dest="${6%:/backup}"
    head -c 4096 /dev/urandom > "$dest/blockchain-data.tar.gz" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$TMP/bin/docker" "$TMP/bin/zfs"

run() { # extra env assignments...
  rm -rf "$TMP/backups"; : > "$TMP/calls"
  env PATH="$TMP/bin:$PATH" FAKE_DOCKER_CALLS="$TMP/calls" BACKUP_DIR="$TMP/backups" \
    REDIS_PASSWORD=unused COMPOSE_FILE="$TMP/compose.yml" "$@" bash "$BACKUP" < /dev/null > "$TMP/out" 2>&1
  DEST="$(find "$TMP/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)/"
}

copied_volume() { # expected volume name
  grep -q -- "run --rm -v $1:/source:ro " "$TMP/calls" || { echo "    volume $1 was not copied" >&2; grep 'run --rm' "$TMP/calls" >&2; cat "$TMP/out" >&2; return 1; }
  grep -q 'Blockchain data: OK' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  [[ -s "${DEST}blockchain-data.tar.gz" ]] || return 1
  ! grep -q 'could not determine volume name' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
}

running_container_mounts_win() {
  # The compose JSON is deliberately absent: the running container is the source of truth.
  run FAKE_MOUNTS="$FIX/inspect-mounts.json"
  copied_volume testnet_node-data
}

compose_object_shape_resolves_prefixed_name() {
  run FAKE_COMPOSE_JSON="$FIX/compose-config-object.json"
  copied_volume testnet_node-data
}

compose_string_shape_is_tolerated() {
  # Also proves selection is by target (/app/data), not by index [0] (a bind mount).
  run FAKE_COMPOSE_JSON="$FIX/compose-config-string.json"
  copied_volume testnet_node-data
}

parser_stderr_is_not_swallowed() {
  printf '{"services": {"wrfcoin-node": {"volumes": [' > "$TMP/broken.json"
  run FAKE_COMPOSE_JSON="$TMP/broken.json"
  grep -q 'could not determine volume name' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  grep -qiE 'json|decode|expecting' "$TMP/out" || { echo "    parser error was swallowed" >&2; cat "$TMP/out" >&2; return 1; }
  ! grep -q -- 'run --rm' "$TMP/calls" || return 1
}

no_data_mount_is_an_error() {
  printf '{"name":"testnet","services":{"wrfcoin-node":{"volumes":[{"type":"bind","source":"/x","target":"/etc/other"}]}}}' > "$TMP/nodata.json"
  run FAKE_COMPOSE_JSON="$TMP/nodata.json"
  grep -q 'could not determine volume name' "$TMP/out" || { cat "$TMP/out" >&2; return 1; }
  grep -q '/app/data' "$TMP/out" || { echo "    error does not name the data dir" >&2; cat "$TMP/out" >&2; return 1; }
  ! grep -q -- 'run --rm' "$TMP/calls" || return 1
}

[[ -f "$BACKUP" ]] || { echo "BACKUP_CHAIN_VOLUME_TESTS=FAIL $BACKUP missing" >&2; exit 1; }
check running_container_mounts_win running_container_mounts_win
check compose_object_shape_resolves_prefixed_name compose_object_shape_resolves_prefixed_name
check compose_string_shape_is_tolerated compose_string_shape_is_tolerated
check parser_stderr_is_not_swallowed parser_stderr_is_not_swallowed
check no_data_mount_is_an_error no_data_mount_is_an_error

if [[ ${#FAILED[@]} -gt 0 ]]; then echo "BACKUP_CHAIN_VOLUME_TESTS=FAIL cases: ${FAILED[*]}" >&2; exit 1; fi
echo BACKUP_CHAIN_VOLUME_TESTS=PASS
