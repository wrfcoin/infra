#!/usr/bin/env bash
# Join-snapshot path (infra#587 / core4#2806): a brand-new node cannot
# full-sync this chain, so the snapshot publish/verify/restore path IS the
# join path. These tests pin its fail-closed properties:
#
#   - the restore verifier refuses a wrong-chain manifest, a tampered or
#     truncated archive, an unverifiable manifest, and an existing volume;
#   - the joiner script refuses a brand-new node without a snapshot, with
#     core4#2806 named in the refusal;
#   - the publisher restarts the seed on every exit path, gates on chain
#     identity BEFORE stopping anything, ships only wrfcoin.redb (never
#     peer identity / HSM / equivocation state), and publishes atomically;
#   - the funnel edge serves exactly the two artifact paths, rate-limited;
#   - the served directory is outside the release tree, and the publisher
#     writes exactly the directory the running edge mounts, which Compose
#     resolved (inline comments, interpolation, empty overrides) (infra#1057).
#
# Function-level tests run against real fixtures with a stub docker on PATH.
# What this canNOT check, stated plainly: a real end-to-end restore into a
# real Docker volume, or the funnel actually serving bytes. Those need a
# Docker daemon and a live edge.
#
# Run: bash scripts/tests/test-join-snapshot.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESTORE="${REPO}/testnet/join-snapshot-restore.sh"
JOINER="${REPO}/testnet/join-testnet-sync-node.sh"
PUBLISHER="${REPO}/testnet/publish-join-snapshot.sh"
CADDY_SNIPPET="${REPO}/testnet/edge/public_onboarding.caddy"
FUNNEL_COMPOSE="${REPO}/testnet/docker-compose.funnel-edge.yml"

fails=0
assertions=0
REAL_FINDMNT="$(command -v findmnt)" || { echo "FAIL: findmnt (util-linux) is required" >&2; exit 1; }
check() {
  local name="$1" ; shift
  assertions=$((assertions + 1))
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: join-snapshot-check-forwards-argv
  if "$@"; then
    printf '  ok    %s\n' "$name"
  else
    printf '  FAIL  %s\n' "$name"
    fails=$((fails + 1))
  fi
}

# The publisher and promoter refuse any directory under a git checkout
# (infra#1057, codex round 49), so the fixture base must not have one above it.
# A shared /tmp can (a stray /tmp/.git repo from another process would make
# every fixture look "inside a checkout"): pick the first clean base, or fail
# loudly rather than report guard refusals as product failures.
in_checkout() { local d; d="$(realpath -m "$1")"; while :; do
  { [ -f "${d}/.git/HEAD" ] || { [ -f "${d}/.git" ] && grep -q '^gitdir:' "${d}/.git" 2>/dev/null; }; } && return 0
  [ "${d}" = / ] && return 1; d="$(dirname "${d}")"; done; }
TMP=""
for base in "${TMPDIR:-/tmp}" /dev/shm /var/tmp; do
  if [ -d "${base}" ] && [ -w "${base}" ] && ! in_checkout "${base}"; then
    TMP="$(mktemp -d -p "${base}")" && break
  fi
done
[ -n "${TMP}" ] || { echo "FAIL: no writable fixture base outside every git checkout (tried \$TMPDIR, /dev/shm, /var/tmp)" >&2; exit 1; }
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: a pins file, a matching manifest+archive pair, and a stub docker
# that records its argv and answers "volume inspect" per a control file.
# ---------------------------------------------------------------------------
GENESIS="6ad436386cfc6c746146f6ef2f9d32ddb7a93f18efd3635606abd27c9ca17db8"
# The core4 build the join snapshot was produced by (manifest core4_commit) vs
# the one cut-pins.env makes a joiner build. Equal in the good fixture.
CORE4_COMMIT="1111111111111111111111111111111111111111"
OTHER_CORE4="2222222222222222222222222222222222222222"
STATE_ROOT="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat > "${TMP}/pins.env" <<EOF
WRFCOIN_CUT_GENESIS_HASH=${GENESIS}
WRFCOIN_CUT_CHAIN_ID=777
WRFCOIN_CUT_NETWORK_ID=testnet
WRFCOIN_CUT_CORE4_COMMIT=${CORE4_COMMIT}
EOF

printf 'not-a-real-redb-but-bytes-are-bytes' > "${TMP}/wrfcoin.redb"
tar czf "${TMP}/snapshot.tar.gz" -C "${TMP}" wrfcoin.redb
SHA="$(sha256sum "${TMP}/snapshot.tar.gz" | cut -d' ' -f1)"

write_manifest() {
  # write_manifest <path> <genesis> <chain> <network> <sha>
  cat > "$1" <<EOF
{
  "file": "snapshot.tar.gz",
  "sha256": "$5",
  "size_bytes": 42,
  "height": 16416,
  "state_root_hex": "${STATE_ROOT}",
  "genesis_hash": "0x$2",
  "chain_id": "$3",
  "network_id": "$4",
  "core4_commit": "${MANIFEST_CORE4-${CORE4_COMMIT}}",
  "created_utc": "2026-08-16T00:00:00Z",
  "source": "ct101-seed"
}
EOF
}
write_manifest "${TMP}/manifest-good.json" "${GENESIS}" 777 testnet "${SHA}"

mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_STUB_LOG:?}"
case "$1 $2" in
  "volume inspect") [ "${DOCKER_STUB_VOLUME_EXISTS:-0}" = "1" ] && exit 0 || exit 1 ;;
  "volume create")  exit 0 ;;
  "volume rm")      exit 0 ;;
  "run --rm")       exit "${DOCKER_STUB_RUN_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/docker"
export DOCKER_STUB_LOG="${TMP}/docker.log"

# Load the restore functions under the fixture pins + stub docker.
export CUT_PINS_FILE="${TMP}/pins.env"
export DOCKER_BIN="${TMP}/bin/docker"
# shellcheck source=/dev/null
. "${RESTORE}"

echo "== restore verifier: manifest identity is fail-closed =="

check "good manifest passes" \
  jsr_verify_manifest "${TMP}/manifest-good.json"

write_manifest "${TMP}/manifest-genesis.json" "deadbeef${GENESIS:8}" 777 testnet "${SHA}"
genesis_mismatch_refused() { ! jsr_verify_manifest "${TMP}/manifest-genesis.json" 2>/dev/null; }
check "wrong genesis refused" genesis_mismatch_refused

write_manifest "${TMP}/manifest-chain.json" "${GENESIS}" 778 testnet "${SHA}"
chain_mismatch_refused() { ! jsr_verify_manifest "${TMP}/manifest-chain.json" 2>/dev/null; }
check "wrong chain_id refused" chain_mismatch_refused

write_manifest "${TMP}/manifest-network.json" "${GENESIS}" 777 mainnet "${SHA}"
network_mismatch_refused() { ! jsr_verify_manifest "${TMP}/manifest-network.json" 2>/dev/null; }
check "wrong network_id refused" network_mismatch_refused

missing_manifest_refused() { ! jsr_verify_manifest "${TMP}/no-such-manifest.json" 2>/dev/null; }
check "missing manifest refused" missing_manifest_refused

cp "${TMP}/manifest-good.json" "${TMP}/manifest-low-height.json"
sed -i 's/"height": 16416/"height": 11017/' "${TMP}/manifest-low-height.json"
low_height_refused() { ! jsr_verify_manifest "${TMP}/manifest-low-height.json" 2>/dev/null; }
check "height at the unreplayable boundary refused" low_height_refused

cp "${TMP}/manifest-good.json" "${TMP}/manifest-no-root.json"
sed -i '/state_root_hex/d' "${TMP}/manifest-no-root.json"
missing_root_refused() { ! jsr_verify_manifest "${TMP}/manifest-no-root.json" 2>/dev/null; }
check "manifest without state root refused" missing_root_refused

# core4 version guard (r20.2 audit C3): a joiner builds the core4 that
# cut-pins.env pins, so a snapshot produced by a DIFFERENT core4 build cannot be
# imported. Refuse it up front, naming the mid-upgrade situation.
write_manifest "${TMP}/manifest-oldver.json" "${GENESIS}" 777 testnet "${SHA}"
sed -i "s/${CORE4_COMMIT}/${OTHER_CORE4}/" "${TMP}/manifest-oldver.json"
version_mismatch_refused() {
  ! jsr_verify_manifest "${TMP}/manifest-oldver.json" 2>"${TMP}/ver.err" \
    && grep -q "mid-upgrade" "${TMP}/ver.err" \
    && grep -q "${OTHER_CORE4}" "${TMP}/ver.err" && grep -q "${CORE4_COMMIT}" "${TMP}/ver.err"
}
check "snapshot from a different core4 build refused, naming the mid-upgrade" version_mismatch_refused

cp "${TMP}/manifest-good.json" "${TMP}/manifest-nover.json"
sed -i '/core4_commit/d' "${TMP}/manifest-nover.json"
no_version_refused() {
  ! jsr_verify_manifest "${TMP}/manifest-nover.json" 2>"${TMP}/ver.err" && grep -q "no core4_commit" "${TMP}/ver.err"
}
check "snapshot manifest without core4_commit refused (cannot prove the build)" no_version_refused

legacy_override_allows_only_absence() {
  WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT=1 jsr_verify_manifest "${TMP}/manifest-nover.json" 2>/dev/null \
    && ! WRFCOIN_JOIN_ALLOW_UNVERSIONED_SNAPSHOT=1 jsr_verify_manifest "${TMP}/manifest-oldver.json" 2>/dev/null
}
check "legacy override admits an unversioned manifest but never a mismatched one" legacy_override_allows_only_absence

cp "${TMP}/manifest-good.json" "${TMP}/manifest-badver.json"
sed -i "s/${CORE4_COMMIT}/not-a-sha/" "${TMP}/manifest-badver.json"
malformed_version_refused() { ! jsr_verify_manifest "${TMP}/manifest-badver.json" 2>/dev/null; }
check "malformed core4_commit refused" malformed_version_refused

echo "== restore verifier: archive integrity =="

check "matching sha256 passes" \
  jsr_verify_archive "${TMP}/manifest-good.json" "${TMP}/snapshot.tar.gz"

printf 'tampered' >> "${TMP}/snapshot-tampered.tar.gz.pre" 2>/dev/null || true
cp "${TMP}/snapshot.tar.gz" "${TMP}/snapshot-tampered.tar.gz"
printf 'x' >> "${TMP}/snapshot-tampered.tar.gz"
tampered_refused() { ! jsr_verify_archive "${TMP}/manifest-good.json" "${TMP}/snapshot-tampered.tar.gz" 2>/dev/null; }
check "tampered archive refused" tampered_refused

: > "${TMP}/snapshot-empty.tar.gz"
empty_refused() { ! jsr_verify_archive "${TMP}/manifest-good.json" "${TMP}/snapshot-empty.tar.gz" 2>/dev/null; }
check "empty archive refused" empty_refused

write_manifest "${TMP}/manifest-nosha.json" "${GENESIS}" 777 testnet ""
no_sha_refused() { ! jsr_verify_archive "${TMP}/manifest-nosha.json" "${TMP}/snapshot.tar.gz" 2>/dev/null; }
check "manifest without sha256 refused" no_sha_refused

echo "== restore verifier: archive shape is exact and regular =="
check "single regular root wrfcoin.redb passes shape gate" \
  jsr_verify_archive_shape "${TMP}/snapshot.tar.gz"

printf 'extra' > "${TMP}/peer_identity.key"
tar czf "${TMP}/snapshot-extra.tar.gz" -C "${TMP}" wrfcoin.redb peer_identity.key
extra_member_refused() { ! jsr_verify_archive_shape "${TMP}/snapshot-extra.tar.gz" 2>/dev/null; }
check "extra archive member refused" extra_member_refused

ln -s wrfcoin.redb "${TMP}/redb-link"
tar czf "${TMP}/snapshot-symlink.tar.gz" -C "${TMP}" --transform='s/^redb-link$/wrfcoin.redb/' redb-link
symlink_member_refused() { ! jsr_verify_archive_shape "${TMP}/snapshot-symlink.tar.gz" 2>/dev/null; }
check "symlink wrfcoin.redb refused" symlink_member_refused

tar czf "${TMP}/snapshot-traversal.tar.gz" -C "${TMP}" --transform='s|^wrfcoin.redb$|../wrfcoin.redb|' wrfcoin.redb 2>/dev/null
traversal_member_refused() { ! jsr_verify_archive_shape "${TMP}/snapshot-traversal.tar.gz" 2>/dev/null; }
check "traversal member refused" traversal_member_refused

echo "== restore into volume: never clobbers, restores only fresh =="

existing_volume_refused() {
  ! DOCKER_STUB_VOLUME_EXISTS=1 jsr_restore_into_volume "${TMP}/snapshot.tar.gz" "testnet_node-data" 2>/dev/null
}
check "existing volume refused" existing_volume_refused

fresh_volume_restores() {
  : > "${DOCKER_STUB_LOG}"
  DOCKER_STUB_VOLUME_EXISTS=0 jsr_restore_into_volume "${TMP}/snapshot.tar.gz" "testnet_node-data" >/dev/null 2>&1 || return 1
  grep -q "volume create testnet_node-data" "${DOCKER_STUB_LOG}" || return 1
  # The unpack container mounts the volume at /data, the archive dir ro, and
  # asserts wrfcoin.redb landed — that assertion is the difference between a
  # restore and an empty volume that full-syncs into the #2806 wedge.
  grep -q -- "-v testnet_node-data:/data" "${DOCKER_STUB_LOG}" || return 1
  grep -q "test -s /data/wrfcoin.redb" "${DOCKER_STUB_LOG}" || return 1
}
check "fresh volume: create + unpack + redb assertion" fresh_volume_restores

failed_unpack_cleans_up() {
  : > "${DOCKER_STUB_LOG}"
  if DOCKER_STUB_VOLUME_EXISTS=0 DOCKER_STUB_RUN_RC=1 jsr_restore_into_volume "${TMP}/snapshot.tar.gz" "testnet_node-data" 2>/dev/null; then
    return 1
  fi
  # a half-written volume must not survive to be mistaken for a node
  grep -q "volume rm testnet_node-data" "${DOCKER_STUB_LOG}"
}
check "failed unpack removes the half-written volume" failed_unpack_cleans_up

echo "== end to end: the joiner's restore entry point verifies sha256 BEFORE any volume (owner ruling: hash-bound, unsigned) =="

# join.sh -> join-testnet-sync-node.sh -> `bash join-snapshot-restore.sh
# --base-url <url>` (or --manifest/--archive for a local dir). Run that exact
# entry point as a subprocess, over file:// (the same curl --proto path as
# https), and require that a bad archive never reaches `volume create`.
E2E="${TMP}/e2e"
mkdir -p "${E2E}/good" "${E2E}/tampered" "${E2E}/swapped"
cp "${TMP}/snapshot.tar.gz" "${E2E}/good/snapshot.tar.gz"
cp "${TMP}/manifest-good.json" "${E2E}/good/manifest.json"
# Tampered: the published archive with bytes altered after the manifest was cut.
cp "${TMP}/snapshot.tar.gz" "${E2E}/tampered/snapshot.tar.gz"
printf 'x' >> "${E2E}/tampered/snapshot.tar.gz"
cp "${TMP}/manifest-good.json" "${E2E}/tampered/manifest.json"
# Mismatch: a perfectly well-formed archive (one regular wrfcoin.redb) from a
# DIFFERENT state, served beside the good manifest. Shape and identity pass;
# only the hash binding can catch it.
mkdir -p "${E2E}/other"
printf 'a-different-database' > "${E2E}/other/wrfcoin.redb"
tar czf "${E2E}/swapped/snapshot.tar.gz" -C "${E2E}/other" wrfcoin.redb
cp "${TMP}/manifest-good.json" "${E2E}/swapped/manifest.json"

run_restore_e2e() {
  : > "${DOCKER_STUB_LOG}"
  DOCKER_STUB_VOLUME_EXISTS=0 bash "${RESTORE}" "$@" --volume testnet_node-data > "${E2E}/out.log" 2>&1
}

e2e_good_restores() {
  run_restore_e2e --base-url "file://${E2E}/good" || return 1
  grep -q "volume create testnet_node-data" "${DOCKER_STUB_LOG}"
}
check "e2e positive control: matching manifest+archive restores" e2e_good_restores

e2e_refused_before_volume() {
  # $@: restore source args. Must fail, name the sha256 mismatch, create nothing.
  if run_restore_e2e "$@"; then return 1; fi
  grep -q "sha256 mismatch" "${E2E}/out.log" || return 1
  ! grep -qE "volume create|^run " "${DOCKER_STUB_LOG}"
}
check "e2e: tampered archive (URL) refused before any volume is created" \
  e2e_refused_before_volume --base-url "file://${E2E}/tampered"
check "e2e: manifest/archive mismatch (URL) refused before any volume is created" \
  e2e_refused_before_volume --base-url "file://${E2E}/swapped"
check "e2e: manifest/archive mismatch (local dir) refused before any volume is created" \
  e2e_refused_before_volume --manifest "${E2E}/swapped/manifest.json" --archive "${E2E}/swapped/snapshot.tar.gz"

mkdir -p "${E2E}/oldver"
cp "${TMP}/snapshot.tar.gz" "${E2E}/oldver/snapshot.tar.gz"
cp "${TMP}/manifest-oldver.json" "${E2E}/oldver/manifest.json"
e2e_version_refused_before_volume() {
  if run_restore_e2e --base-url "file://${E2E}/oldver"; then return 1; fi
  grep -q "mid-upgrade" "${E2E}/out.log" || return 1
  ! grep -qE "volume create|^run " "${DOCKER_STUB_LOG}"
}
check "e2e: snapshot from a different core4 build (URL) refused before any volume is created" \
  e2e_version_refused_before_volume

# --base-url must verify the manifest BEFORE downloading the (large) archive: a
# mismatched manifest must not cost a download. A logging curl shim in front of
# the real one records every URL fetched.
mkdir -p "${TMP}/curlshim"
REAL_CURL="$(command -v curl)"
cat > "${TMP}/curlshim/curl" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${CURL_SHIM_LOG:?}"
exec "${REAL_CURL}" "\$@"
SHIM
chmod +x "${TMP}/curlshim/curl"
export CURL_SHIM_LOG="${TMP}/curl-shim.log"
fetched_urls() { sed -n 's/.*file:\/\/\([^ ]*\).*/\1/p' "${CURL_SHIM_LOG}"; }
e2e_no_archive_fetch_on_bad_manifest() {
  : > "${CURL_SHIM_LOG}"
  if PATH="${TMP}/curlshim:${PATH}" run_restore_e2e --base-url "file://${E2E}/oldver"; then return 1; fi
  fetched_urls | grep -q "/oldver/manifest.json" || { echo "    (manifest was not fetched)" >&2; return 1; }
  ! fetched_urls | grep -q "snapshot.tar.gz"
}
check "e2e: a mismatched manifest is refused with NO archive fetch (--base-url)" \
  e2e_no_archive_fetch_on_bad_manifest
e2e_good_manifest_fetches_both() {
  : > "${CURL_SHIM_LOG}"
  PATH="${TMP}/curlshim:${PATH}" run_restore_e2e --base-url "file://${E2E}/good" || return 1
  fetched_urls | grep -q "/good/manifest.json" && fetched_urls | grep -q "/good/snapshot.tar.gz"
}
check "e2e: positive control, a matching manifest still fetches the archive" \
  e2e_good_manifest_fetches_both

swapped_shape_is_valid() { jsr_verify_archive_shape "${E2E}/swapped/snapshot.tar.gz" 2>/dev/null; }
check "mismatch fixture is well-formed (so only the hash can refuse it)" swapped_shape_is_valid

check "join.sh reaches this entry point (join.sh -> join-testnet-sync-node.sh -> join-snapshot-restore.sh)" \
  bash -c "grep -q 'join-testnet-sync-node.sh' '${REPO}/testnet/join.sh' && grep -q 'bash \"\${SCRIPT_DIR}/join-snapshot-restore.sh\"' '${JOINER}'"

durable_volume_passes() { DOCKER_STUB_RUN_RC=0 jsr_volume_has_durable_state "testnet_node-data" >/dev/null 2>&1; }
check "existing volume with nonempty regular redb is durable" durable_volume_passes

malformed_volume_refused() { ! DOCKER_STUB_RUN_RC=1 jsr_volume_has_durable_state "testnet_node-data" >/dev/null 2>&1; }
check "empty or malformed existing volume is not durable" malformed_volume_refused

echo "== joiner script: brand-new node without a snapshot is refused =="

check "fresh-node guard names core4#2806" \
  grep -q "core4#2806" "${JOINER}"

check "guard offers --snapshot and --allow-full-sync" \
  bash -c "grep -q -- '--snapshot' '${JOINER}' && grep -q -- '--allow-full-sync' '${JOINER}'"

guard_before_compose_up() {
  # the refusal must run BEFORE compose can create an empty node
  local guard_line up_line
  guard_line="$(grep -n "no '\${node_data_volume}' volume" "${JOINER}" | head -1 | cut -d: -f1)"
  up_line="$(grep -n "up -d --build postgres" "${JOINER}" | head -1 | cut -d: -f1)"
  [ -n "${guard_line}" ] && [ -n "${up_line}" ] && [ "${guard_line}" -lt "${up_line}" ]
}
check "fresh-node guard precedes compose up" guard_before_compose_up

check "joiner delegates restore to join-snapshot-restore.sh" \
  grep -q "join-snapshot-restore.sh" "${JOINER}"

check "joiner validates durable state before ignoring snapshot" \
  grep -q 'jsr_volume_has_durable_state "${node_data_volume}"' "${JOINER}"

echo "== publisher: identity gate, seed custody, per-node exclusions, atomicity =="

identity_gate_before_stop() {
  local gate_line stop_line
  gate_line="$(grep -n "Publishing this snapshot would poison every joiner" "${PUBLISHER}" | head -1 | cut -d: -f1)"
  stop_line="$(grep -n "stop -t 30" "${PUBLISHER}" | head -1 | cut -d: -f1)"
  [ -n "${gate_line}" ] && [ -n "${stop_line}" ] && [ "${gate_line}" -lt "${stop_line}" ]
}
check "identity gate runs before the seed is stopped" identity_gate_before_stop

check "publisher binds selected volume to seed container mount" \
  grep -q 'mounted_volume=.*inspect' "${PUBLISHER}"

check "publisher requires height above 11017 and canonical state root" \
  bash -c "grep -q 'snapshot_height.*-le 11017' '${PUBLISHER}' && grep -q 'state_root_hex' '${PUBLISHER}'"

check "manifest receipt comes from the frozen-copy node, not a live read" \
  bash -c "grep -q 'FROZEN=\"\$(verify_json /state/snapshot' '${PUBLISHER}' && ! grep -q 'post_state_root' '${PUBLISHER}'"

# Execute the publisher end-to-end against a disposable mounted database and
# deterministic API receipts. These controls make the custody checks
# load-bearing rather than merely grepping for their presence.
PUB="${TMP}/publisher"
mkdir -p "${PUB}/bin" "${PUB}/mount" "${PUB}/out"
printf 'disposable-redb' > "${PUB}/mount/wrfcoin.redb"
# Stub node model (infra#1061): three distinct state holders.
#   - LIVE SEED (host :8557): read before the stop, as a pre-check only.
#   - PRODUCER (:8556): must never be read.
#   - FROZEN COPY: what `docker stop` froze. The throwaway verifier node
#     (`docker run` / `docker exec`) serves THIS, independent of whatever the
#     restarted live seed does afterwards.
cat > "${PUB}/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PUBLISH_DOCKER_LOG:?}"
S="${PUBLISH_STATE:?}"
case "${1:-}" in
  inspect)
    target="${*: -1}"
    if [ "${target}" = wrfcoin-testnet-funnel-edge ]; then
      [ "${PUBLISH_EDGE_MISSING:-0}" = 1 ] && exit 1
      printf '%s\n' "${PUBLISH_EDGE_JOIN_SOURCE?}"
    elif [ -d "${S}/ctr/${target}" ]; then
      # a registered container (by ID): running state or its owner label
      case "${3:-}" in
        '{{.State.Running}}') printf '%s\n' "${PUBLISH_VERIFIER_RUNNING:-true}" ;;
        *wrfcoin.join-verify.owner*) cat "${S}/ctr/${target}/owner" ;;
        *) exit 1 ;;
      esac
    elif [[ "${target}" =~ ^[0-9a-f]{64}$ ]]; then
      exit 1   # unknown container ID
    elif [ "${target}" = wrfcoin-testnet-node ] && [[ "${3:-}" == *'.Source'* ]]; then
      # --from-snapshot: the live node's /app/data mount source
      printf '%s\n' "${PUBLISH_NODE_DATA_SOURCE-}"
    elif [ "${3:-}" = '{{.State.Running}}' ]; then
      printf '%s\n' "${PUBLISH_SEED_RUNNING:-true}"
    elif [ "${3:-}" = '{{index .Config.Labels "org.opencontainers.image.revision"}}' ]; then
      printf '%s\n' "${PUBLISH_CORE4_REVISION-1111111111111111111111111111111111111111}"
    elif [ "${3:-}" = '{{.Image}}' ]; then
      printf '%s\n' "${PUBLISH_SEED_IMAGE-sha256:1111111111111111111111111111111111111111111111111111111111111111}"
    elif [ "${3:-}" = '{{range .Config.Env}}{{println .}}{{end}}' ]; then
      printf '%s\n' WRFCOIN_CHAIN_ID=777 WRFCOIN_NETWORK_ID=testnet WRFCOIN_READER_TOKEN=test-token \
        WRFCOIN_OPERATOR_TOKEN=super-secret-operator-token WRFCOIN_P2P_ENABLED=true \
        WRFCOIN_P2P_NODE_ROLE=validator WRFCOIN_P2P_BOOTSTRAP=/ip4/198.51.100.1/tcp/9001 \
        WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY=super-secret-signer ALLOW_UNENCRYPTED_STORAGE=true \
        WRFCOIN_HSM_PIN=super-secret-hsm-pin WRFCOIN_HSM_MODE=pkcs11 DATABASE_URL=postgres://super-secret@db/x
    else
      printf '%s\n' "${PUBLISH_MOUNTED_VOLUME:-testnet_seed-data}"
    fi ;;
  volume) printf '%s\n' "${PUBLISH_MOUNTPOINT:?}" ;;
  port)
    [ -n "${PUBLISH_SEED_PORT_LINE-127.0.0.1:8557}" ] && printf '%s\n' "${PUBLISH_SEED_PORT_LINE-127.0.0.1:8557}"
    printf '%s\n' '[::1]:8557' ;;
  stop)
    touch "${S}/seed-down"
    [ -n "${PUBLISH_STOP_SLEEP:-}" ] && sleep "${PUBLISH_STOP_SLEEP}"
    if [ "${PUBLISH_SEED_ADVANCE_ON_STOP:-0}" = 1 ]; then
      h="$(cat "${S}/seed-height")"; printf '%s' "$((h + 1))" > "${S}/seed-height"
    fi
    # Freeze: the durable state at stop time (overridable: durable state that
    # differs from what the live API showed).
    printf '%s' "${PUBLISH_FROZEN_HEIGHT:-$(cat "${S}/seed-height")}" > "${S}/frozen-height"
    exit "${PUBLISH_STOP_RC:-0}" ;;
  start)
    rm -f "${S}/seed-down"
    [ -n "${PUBLISH_POST_HEIGHT:-}" ] && printf '%s' "${PUBLISH_POST_HEIGHT}" > "${S}/seed-height"
    exit "${PUBLISH_START_RC:-0}" ;;
  run)
    # Container registry model: ${S}/ctr/<id>/{name,owner}. Like docker: a name
    # conflict exits 125 and creates nothing; the cidfile is written at create.
    name=""; owner=""; cidfile=""
    for ((k = 1; k <= $#; k++)); do
      n=$((k + 1))
      case "${!k}" in
        --env-file) cp "${!n}" "${S}/verify-env.capture" ;;
        --name) name="${!n}" ;;
        --cidfile) cidfile="${!n}" ;;
        --label) owner="${!n#wrfcoin.join-verify.owner=}" ;;
      esac
    done
    mkdir -p "${S}/ctr"
    if [ "${PUBLISH_RUN_MODE:-}" = collision ]; then
      # a FOREIGN container already holds this name (created by someone else)
      f="$(printf 'f%.0s' $(seq 1 64))"; mkdir -p "${S}/ctr/${f}"
      printf '%s' "${name}" > "${S}/ctr/${f}/name"; printf '%s' foreign > "${S}/ctr/${f}/owner"
      echo "docker: Error response from daemon: Conflict. The container name \"/${name}\" is already in use" >&2
      exit 125
    fi
    id="$(printf '%064x' "$(( $(date +%s%N) % 1000000007 ))")"
    mkdir -p "${S}/ctr/${id}"; printf '%s' "${name}" > "${S}/ctr/${id}/name"; printf '%s' "${owner}" > "${S}/ctr/${id}/owner"
    printf '%s\n' "${id}" >> "${S}/created"
    case "${PUBLISH_RUN_MODE:-}" in
      start-fail) printf '%s' "${id}" > "${cidfile}"; exit 125 ;;   # created, start failed
      ambiguous)  exit 0 ;;                                         # created, no cidfile
      ambiguous-fail) exit 1 ;;                                     # created, no cidfile, nonzero
    esac
    printf '%s' "${id}" > "${cidfile}"
    exit "${PUBLISH_RUN_RC:-0}" ;;
  ps)
    want="${*: -1}"; want="${want#label=wrfcoin.join-verify.owner=}"
    for d in "${S}"/ctr/*/; do [ -d "${d}" ] || continue
      [ "$(cat "${d}owner")" = "${want}" ] && basename "${d}"; done
    exit 0 ;;
  exec)
    [ -d "${S}/ctr/${3:-}" ] || { echo "no such container: ${3:-}" >&2; exit 1; }
    cat > "${S}/exec-stdin" || true
    [ "${PUBLISH_VERIFIER_HANG:-0}" = 1 ] && exec sleep 60
    boot="$(cat "${S}/verifier-boot-fails" 2>/dev/null || printf 0)"
    if [ "${boot}" -gt 0 ]; then printf '%s' "$((boot - 1))" > "${S}/verifier-boot-fails"; exit 7; fi
    url="${*: -1}"
    h="$(cat "${S}/frozen-height")"
    if [ "${PUBLISH_FROZEN_DRIFT:-0}" = 1 ]; then
      n="$(cat "${S}/frozen-reads" 2>/dev/null || printf 0)"; printf '%s' "$((n + 1))" > "${S}/frozen-reads"
      [ "${n}" -ge 1 ] && h=$((h + 1))
    fi
    case "${url}" in
      http://127.0.0.1:8556/network/info)
        printf '{"genesis_hash":"0x%s","chain_id":"%s","network_id":"testnet","chain_height":%s}\n' \
          "${PUBLISH_GENESIS:?}" "${PUBLISH_FROZEN_CHAIN:-777}" "${h}" ;;
      http://127.0.0.1:8556/state/snapshot)
        printf '{"height":%s,"state_root_hex":"%s"}\n' "${h}" "${PUBLISH_FROZEN_ROOT:-${PUBLISH_STATE_ROOT:?}}" ;;
      *) exit 22 ;;
    esac ;;
  rm)
    # like docker: accepts an ID or a NAME, so a name-based removal really
    # would delete a foreign container that holds that name
    x="${*: -1}"
    if [ -d "${S}/ctr/${x}" ]; then rm -rf "${S}/ctr/${x}"; else
      for d in "${S}"/ctr/*/; do [ -d "${d}" ] && [ "$(cat "${d}name")" = "${x}" ] && rm -rf "${d}"; done
    fi ;;
esac
exit 0
EOF
cat > "${PUB}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
S="${PUBLISH_STATE:?}"
printf '%s\n' "${url}" >> "${PUBLISH_CURL_LOG:?}"
cat > /dev/null || true
[ "${PUBLISH_LIVE_HANG:-0}" = 1 ] && exec sleep 60
case "${url}" in
  http://127.0.0.1:8557/*)
    [ -e "${S}/seed-down" ] && exit 7
    height="$(cat "${S}/seed-height")"; root="${PUBLISH_STATE_ROOT:?}" ;;
  http://127.0.0.1:8556/*)
    height="${PUBLISH_PRODUCER_HEIGHT:-20000}"; root="${PUBLISH_PRODUCER_ROOT:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" ;;
  *) exit 7 ;;
esac
case "${url}" in
  */network/info)
    printf '{"genesis_hash":"0x%s","chain_id":"777","network_id":"testnet","chain_height":%s}\n' \
      "${PUBLISH_GENESIS:?}" "${height}" ;;
  */state/snapshot)
    printf '{"height":%s,"state_root_hex":"%s"}\n' "${height}" "${root}" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${PUB}/bin/docker" "${PUB}/bin/curl"

run_publisher() {
  # The source is explicit since the seed was retired (infra#1090): seed-mode
  # cases get --from-seed unless they pass --from-snapshot themselves, or ask
  # for no mode flag at all (PUBLISH_NO_MODE=1, the refusal cases).
  local -a mode=()
  if [[ " $* " != *" --from-snapshot "* && -z "${PUBLISH_NO_MODE:-}" ]]; then mode=(--from-seed); fi
  local st="${PUB}/state"
  rm -rf "${st}"; mkdir -p "${st}"
  : > "${PUB}/docker.log"; : > "${PUB}/curl.log"
  printf '%s' "${PUBLISH_HEIGHT:-16416}" > "${st}/seed-height"
  printf '%s' "${PUBLISH_VERIFIER_BOOT_FAILS:-0}" > "${st}/verifier-boot-fails"
  # --from-snapshot never stops anything, so the frozen state is the snapshot's
  # from the start (a `stop` overwrites this in seed mode).
  printf '%s' "${PUBLISH_FROZEN_HEIGHT:-${PUBLISH_HEIGHT:-16416}}" > "${st}/frozen-height"
  if [ -n "${PUBLISH_PRESEED_FOREIGN:-}" ]; then
    mkdir -p "${st}/ctr/${PUBLISH_PRESEED_FOREIGN}"
    printf '%s' other-run > "${st}/ctr/${PUBLISH_PRESEED_FOREIGN}/name"
    printf '%s' 0123456789abcdef0123456789abcdef > "${st}/ctr/${PUBLISH_PRESEED_FOREIGN}/owner"
  fi
  env -u NODE_API PATH="${PUBLISH_PATH:-${PUB}/bin:${PATH}}" DOCKER_BIN="${PUB}/bin/docker" \
    PUBLISH_STATE="${st}" PUBLISH_DOCKER_LOG="${PUB}/docker.log" PUBLISH_CURL_LOG="${PUB}/curl.log" \
    PUBLISH_MOUNTPOINT="${PUB}/mount" \
    PUBLISH_GENESIS="${GENESIS}" PUBLISH_STATE_ROOT="${STATE_ROOT}" \
    WRFCOIN_READER_TOKEN=test-token CUT_PINS_FILE="${PUBLISH_PINS:-${TMP}/pins.env}" \
    SEED_API_TIMEOUT="${SEED_API_TIMEOUT:-2}" VERIFY_BOOT_TIMEOUT="${VERIFY_BOOT_TIMEOUT:-20}" \
    VERIFY_POLL_INTERVAL="${VERIFY_POLL_INTERVAL:-1}" VERIFY_REQUEST_TIMEOUT="${VERIFY_REQUEST_TIMEOUT:-2}" \
    PUBLISH_EDGE_JOIN_SOURCE="${PUBLISH_EDGE_JOIN_SOURCE-${PUB}/out}" \
    ${NODE_API:+NODE_API="${NODE_API}"} \
    FINDMNT_BIN="${PUBLISH_FINDMNT:-${PUB}/bin/findmnt}" REAL_FINDMNT="${REAL_FINDMNT}" \
    FINDMNT_TABLE="${PUBLISH_FINDMNT_TABLE:-${PUB}/findmnt.table}" \
    "${PUBLISH_WRAP[@]}" bash "${PUBLISHER}" "${mode[@]}" "$@"
}
PUBLISH_WRAP=()
# Verifier ownership helpers (codex round 14): the run's own containers are the
# IDs the stub created; each must be removed BY ID, and nothing by name.
created_ids() { cat "${PUB}/state/created" 2>/dev/null; }
owned_verifiers_removed() {
  local id
  for id in $(created_ids); do
    grep -qx "rm -f ${id}" "${PUB}/docker.log" && [ ! -d "${PUB}/state/ctr/${id}" ] || return 1
  done
  ! grep -qE '^rm -f wrfcoin-join-verify-' "${PUB}/docker.log"
}
fresh_out() { rm -f "${PUB}/out/manifest.json" "${PUB}/out/snapshot.tar.gz"; }

publisher_success_receipt() {
  fresh_out
  run_publisher >/dev/null 2>&1 || return 1
  grep -q "\"state_root_hex\": \"${STATE_ROOT}\"" "${PUB}/out/manifest.json" || return 1
  jsr_verify_archive_shape "${PUB}/out/snapshot.tar.gz"
}
check "publisher fixture emits an exact database receipt" publisher_success_receipt

publisher_records_core4_commit() {
  fresh_out
  run_publisher >/dev/null 2>&1 || return 1
  grep -q "\"core4_commit\": \"1111111111111111111111111111111111111111\"" "${PUB}/out/manifest.json"
}
check "publisher records the source container's core4 build in the manifest" publisher_records_core4_commit

publisher_refuses_unlabelled_source() {
  fresh_out
  if PUBLISH_CORE4_REVISION= run_publisher >/dev/null 2>&1; then return 1; fi
  if PUBLISH_CORE4_REVISION=abc123 run_publisher >/dev/null 2>&1; then return 1; fi
  [ ! -e "${PUB}/out/manifest.json" ]
}
check "publisher refuses a source with no full-SHA core4 revision label" publisher_refuses_unlabelled_source

publisher_wrong_volume_refused_before_stop() {
  fresh_out
  if PUBLISH_MOUNTED_VOLUME=wrong-volume run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log"
}
check "publisher refuses an independently selected volume before stop" publisher_wrong_volume_refused_before_stop

publisher_boundary_height_refused_before_stop() {
  fresh_out
  if PUBLISH_HEIGHT=11017 run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log"
}
check "publisher refuses height 11017 (live pre-check) before stop" publisher_boundary_height_refused_before_stop

publisher_stopped_seed_left_down() {
  fresh_out
  if PUBLISH_SEED_RUNNING=false run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -qE '^(stop|start) ' "${PUB}/docker.log" && [ ! -e "${PUB}/out/manifest.json" ]
}
check "publisher refuses a stopped seed and never starts it" publisher_stopped_seed_left_down

echo "== receipt is the FROZEN COPY's, read from an isolated throwaway node (infra#1061) =="

publisher_binds_receipt_to_seed() {
  # Producer ahead with a different root: never read, never in the manifest.
  fresh_out
  PUBLISH_HEIGHT=16416 PUBLISH_PRODUCER_HEIGHT=20000 run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16416,' "${PUB}/out/manifest.json" || return 1
  grep -q "\"state_root_hex\": \"${STATE_ROOT}\"" "${PUB}/out/manifest.json" || return 1
  ! grep -q ':8556/' "${PUB}/curl.log"
}
check "producer and seed differ: producer never read, manifest is the copy's" \
  publisher_binds_receipt_to_seed

publisher_binds_to_copy_not_live() {
  # codex round 8 negative control: the durable state frozen at stop DIFFERS
  # from what the live API showed, yet the restarted seed answers exactly the
  # pre-stop values. Two live reads would agree; the manifest must still be
  # the copy's (16300 / cccc...), never the live 16416 / aaaa....
  local croot=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  fresh_out
  PUBLISH_HEIGHT=16416 PUBLISH_FROZEN_HEIGHT=16300 PUBLISH_FROZEN_ROOT="${croot}" \
    run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16300,' "${PUB}/out/manifest.json" \
    && grep -q "\"state_root_hex\": \"${croot}\"" "${PUB}/out/manifest.json" \
    && ! grep -q "${STATE_ROOT}" "${PUB}/out/manifest.json"
}
check "different-at-copy but equal-after-restart: manifest binds to the COPY" publisher_binds_to_copy_not_live

publisher_block_at_stop_binds_copy() {
  # A block lands between the live pre-check and the stop: the copy is at
  # 16417, and that is what the manifest says.
  fresh_out
  PUBLISH_SEED_ADVANCE_ON_STOP=1 run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16417,' "${PUB}/out/manifest.json"
}
check "race: block lands before the stop -> manifest is the copy's height" publisher_block_at_stop_binds_copy

publisher_restart_drift_irrelevant() {
  fresh_out
  PUBLISH_POST_HEIGHT=16999 run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16416,' "${PUB}/out/manifest.json"
}
check "restarted seed syncing forward does not leak into the manifest" publisher_restart_drift_irrelevant

publisher_verifier_is_isolated() {
  fresh_out
  run_publisher > "${PUB}/run.out" 2>&1 || return 1
  local runline envc="${PUB}/state/verify-env.capture"
  runline="$(grep '^run ' "${PUB}/docker.log")"
  [ "$(created_ids | wc -l)" = 1 ] || return 1
  grep -qE -- '--cidfile [^ ]+ ' <<<"${runline}" && grep -qE -- '--label wrfcoin\.join-verify\.owner=[0-9a-f]{32} ' <<<"${runline}" || return 1
  for flag in '--network none' '--read-only' '--cap-drop ALL' 'no-new-privileges:true' \
      '--entrypoint /usr/local/bin/wrfcoin-node' \
      'sha256:1111111111111111111111111111111111111111111111111111111111111111'; do
    grep -qF -- "${flag}" <<<"${runline}" || { echo "missing ${flag}" >&2; return 1; }
  done
  ! grep -qE -- ' (-p|--publish|--network host|--privileged)' <<<"${runline}" || return 1
  for kv in WRFCOIN_P2P_PROFILE=disabled WRFCOIN_P2P_ENABLED=false WRFCOIN_SYNC_ONLY=1 \
      WRFCOIN_API_HOST=127.0.0.1 WRFCOIN_CHAIN_ID=777 ALLOW_UNENCRYPTED_STORAGE=true; do
    grep -qx "${kv}" "${envc}" || { echo "env missing ${kv}" >&2; return 1; }
  done
  ! grep -qE '^(WRFCOIN_P2P_NODE_ROLE|WRFCOIN_P2P_BOOTSTRAP|WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY)=' "${envc}" || return 1
  [ "$(grep -c '^WRFCOIN_P2P_ENABLED=' "${envc}")" = 1 ] || return 1
  # removed by EXACT name, and no secret reached the operator's terminal
  owned_verifiers_removed || return 1
  ! grep -qE 'super-secret|test-token' "${PUB}/run.out" || return 1
  grep -q '^Authorization: Bearer test-token$' "${PUB}/state/exec-stdin" && ! grep -q 'test-token' "${PUB}/docker.log"
}
check "verifier: seed image, no network, P2P off, sync-only, cloned env, owned-ID teardown, no secret leak" \
  publisher_verifier_is_isolated

publisher_refuses_frozen() {
  # $1 = description only; env set by caller. Refuse, no manifest, verifier removed, seed restarted.
  fresh_out
  if run_publisher >/dev/null 2>&1; then return 1; fi
  [ ! -e "${PUB}/out/manifest.json" ] && grep -q '^start ' "${PUB}/docker.log" && owned_verifiers_removed
}
frozen_drift_refused()      { ( export PUBLISH_FROZEN_DRIFT=1; publisher_refuses_frozen ); }
frozen_wrong_chain_refused() { ( export PUBLISH_FROZEN_CHAIN=778; publisher_refuses_frozen ); }
frozen_low_height_refused() { ( export PUBLISH_FROZEN_HEIGHT=11017; publisher_refuses_frozen ); }
frozen_bad_root_refused()   { ( export PUBLISH_FROZEN_ROOT=not-a-root; publisher_refuses_frozen ); }
verifier_exits_refused()    { ( export PUBLISH_VERIFIER_BOOT_FAILS=99 PUBLISH_VERIFIER_RUNNING=false; publisher_refuses_frozen ); }
verifier_never_answers()    { ( export PUBLISH_VERIFIER_BOOT_FAILS=99 VERIFY_BOOT_TIMEOUT=3; publisher_refuses_frozen ); }
verifier_run_fails()        { ( export PUBLISH_RUN_RC=125; publisher_refuses_frozen ); }
no_image_id_refused()       { ( export PUBLISH_SEED_IMAGE=wrfcoin/native-chain:testnet-local; publisher_refuses_frozen ); }
check "frozen copy whose state moves between reads (not isolated) -> refused" frozen_drift_refused
check "frozen copy with the wrong chain identity -> refused" frozen_wrong_chain_refused
check "frozen copy at height 11017 -> refused" frozen_low_height_refused
check "frozen copy with a malformed state root -> refused" frozen_bad_root_refused
check "verifier node exits before answering -> refused" verifier_exits_refused
check "verifier never answers -> refused at the deadline, removed" verifier_never_answers
check "verifier fails to start -> refused" verifier_run_fails
check "seed image not resolvable to an exact sha256 ID -> refused" no_image_id_refused

verifier_slow_boot_publishes() {
  fresh_out
  PUBLISH_VERIFIER_BOOT_FAILS=2 run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16416,' "${PUB}/out/manifest.json"
}
check "verifier answers after a few polls -> published" verifier_slow_boot_publishes

echo "== verifier container ownership (codex round 14) =="

verifier_collision_spares_foreign() {
  # A FOREIGN container already holds the verifier's name: run exits 125.
  # The publisher must refuse, restart the seed, and leave the foreign one alone.
  fresh_out
  if PUBLISH_RUN_MODE=collision run_publisher >/dev/null 2>&1; then return 1; fi
  local f; f="$(printf 'f%.0s' $(seq 1 64))"
  [ -d "${PUB}/state/ctr/${f}" ] || { echo "foreign container was removed" >&2; return 1; }
  ! grep -qE "^rm -f (${f}|wrfcoin-join-verify-)" "${PUB}/docker.log" \
    && [ ! -e "${PUB}/out/manifest.json" ] && grep -q '^start ' "${PUB}/docker.log"
}
check "name collision (run exits 125): foreign container survives, refused, seed restarted" verifier_collision_spares_foreign

verifier_start_failure_removes_own() {
  # Created (cidfile written) but start failed: remove OUR container by ID.
  fresh_out
  if PUBLISH_RUN_MODE=start-fail run_publisher >/dev/null 2>&1; then return 1; fi
  [ "$(created_ids | wc -l)" = 1 ] && owned_verifiers_removed && [ ! -e "${PUB}/out/manifest.json" ]
}
check "failed start: own container removed by ID, refused" verifier_start_failure_removes_own

verifier_ambiguous_create_adopted() {
  # run exits 0 but writes no cidfile: adopt the single container with THIS
  # run's nonce, use it, and remove it by ID.
  fresh_out
  PUBLISH_RUN_MODE=ambiguous run_publisher >/dev/null 2>&1 || return 1
  grep -q '"height": 16416,' "${PUB}/out/manifest.json" && [ "$(created_ids | wc -l)" = 1 ] && owned_verifiers_removed
}
check "ambiguous create (exit 0, no cidfile): adopted by owner label, used, removed by ID" verifier_ambiguous_create_adopted

verifier_ambiguous_failure_cleaned() {
  # run exits nonzero AND writes no cidfile, yet a container exists: refuse,
  # and still remove it, found by this run's label, by ID.
  fresh_out
  if PUBLISH_RUN_MODE=ambiguous-fail run_publisher >/dev/null 2>&1; then return 1; fi
  [ "$(created_ids | wc -l)" = 1 ] && owned_verifiers_removed && [ ! -e "${PUB}/out/manifest.json" ]
}
check "ambiguous failed create (nonzero, no cidfile): refused, own container removed by label+ID" verifier_ambiguous_failure_cleaned

verifier_foreign_labelled_untouched() {
  # A container with ANOTHER run's owner label exists: it is never adopted or removed.
  fresh_out
  local st="${PUB}/state" o; o="$(printf 'e%.0s' $(seq 1 64))"
  PUBLISH_PRESEED_FOREIGN="${o}" run_publisher >/dev/null 2>&1 || return 1
  [ -d "${st}/ctr/${o}" ] && ! grep -qx "rm -f ${o}" "${PUB}/docker.log"
}
check "another run's labelled container is neither adopted nor removed" verifier_foreign_labelled_untouched

publisher_manifest_is_hash_bound() {
  # The manifest must carry the sha256 of the exact archive published beside
  # it, plus the identity and receipt fields a joiner verifies.
  rm -f "${PUB}/out/manifest.json" "${PUB}/out/snapshot.tar.gz"
  run_publisher >/dev/null 2>&1 || return 1
  local want got k
  want="$(sha256sum "${PUB}/out/snapshot.tar.gz" | cut -d' ' -f1)"
  got="$(jsr_json_field "$(cat "${PUB}/out/manifest.json")" sha256)"
  [ -n "${got}" ] && [ "${got}" = "${want}" ] || return 1
  for k in height state_root_hex genesis_hash chain_id network_id; do
    grep -q "\"${k}\":" "${PUB}/out/manifest.json" || return 1
  done
  jsr_verify_manifest "${PUB}/out/manifest.json" >/dev/null 2>&1 \
    && jsr_verify_archive "${PUB}/out/manifest.json" "${PUB}/out/snapshot.tar.gz" >/dev/null 2>&1
}
check "published manifest's sha256 == published archive; joiner verifier accepts the pair" \
  publisher_manifest_is_hash_bound
publisher_refuses_node_api() {
  rm -f "${PUB}/out/manifest.json"
  if NODE_API=http://127.0.0.1:8556 run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log" && ! grep -q ':8556/' "${PUB}/curl.log"
}
check "NODE_API (old producer override) is refused before any read or stop" publisher_refuses_node_api

publisher_refuses_unpublished_seed_api() {
  if PUBLISH_SEED_PORT_LINE='' run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log" && [ ! -s "${PUB}/curl.log" ]
}
check "seed publishes no IPv4 API port -> refused, no guessed address" publisher_refuses_unpublished_seed_api

echo "== bounded requests and validated knobs (codex round 8, P2) =="

# elapsed_under <seconds> <fn...>: fn must FAIL (refuse), within the bound.
refuses_within() {
  local bound="$1" t0 rc; shift
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: join-snapshot-refuses-within-forwards-argv
  t0="$(date +%s)"; "$@"; rc=$?
  [ "${rc}" -ne 0 ] && [ "$(( $(date +%s) - t0 ))" -lt "${bound}" ]
}
live_hang() { fresh_out; PUBLISH_LIVE_HANG=1 SEED_API_TIMEOUT=2 run_publisher >/dev/null 2>&1; }
check "live seed request that never finishes is cut off (stub ignores --max-time) and refused" \
  refuses_within 15 live_hang
live_hang_no_stop() { ! grep -q '^stop ' "${PUB}/docker.log"; }
check "... and the seed is never stopped" live_hang_no_stop

verifier_hang() { fresh_out; PUBLISH_VERIFIER_HANG=1 VERIFY_BOOT_TIMEOUT=4 VERIFY_REQUEST_TIMEOUT=2 run_publisher >/dev/null 2>&1; }
check "verifier request that never finishes: bounded by the wall-clock deadline, refused" \
  refuses_within 20 verifier_hang
verifier_hang_cleaned() {
  [ "$(created_ids | wc -l)" = 1 ] && owned_verifiers_removed && grep -q '^start ' "${PUB}/docker.log"
}
check "... and the verifier is removed by its owned ID, the seed restarted" verifier_hang_cleaned

# A REAL curl against a REAL server that accepts the TCP connection and never
# answers: proves --connect-timeout/--max-time/timeout bound the live read,
# not just a stub's cooperation.
real_curl_hang() {
  local rbin="${PUB}/realbin" port pid rc t0
  mkdir -p "${rbin}"; ln -sf "${PUB}/bin/docker" "${rbin}/docker"
  python3 - > "${PUB}/hang.port" <<'PYH' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(8)
print(s.getsockname()[1], flush=True)
conns = []
end = time.time() + 30
s.settimeout(0.5)
while time.time() < end:
    try:
        c, _ = s.accept(); conns.append(c)
    except socket.timeout:
        pass
PYH
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${PUB}/hang.port" ] && break; sleep 0.3; done
  port="$(cat "${PUB}/hang.port")"
  [ -n "${port}" ] || { kill "${pid}" 2>/dev/null; return 1; }
  fresh_out; t0="$(date +%s)"
  PUBLISH_PATH="${rbin}:${PATH}" PUBLISH_SEED_PORT_LINE="127.0.0.1:${port}" SEED_API_TIMEOUT=2 \
    run_publisher >/dev/null 2>&1; rc=$?
  kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
  [ "${rc}" -ne 0 ] && [ "$(( $(date +%s) - t0 ))" -lt 15 ] && ! grep -q '^stop ' "${PUB}/docker.log"
}
check "real curl vs a server that connects and never answers: refused within 15s, no stop" real_curl_hang

knob_refused() {
  # $1=VAR $2=value: refused before any docker call.
  fresh_out
  if ( export "$1=$2"; run_publisher ) >/dev/null 2>&1; then
    return 1
  fi
  ! grep -qE '^(stop|run|port) ' "${PUB}/docker.log"
}
for bad in "SEED_API_TIMEOUT 0" "VERIFY_BOOT_TIMEOUT -5" "VERIFY_POLL_INTERVAL abc" "VERIFY_REQUEST_TIMEOUT 1.5"; do
  # shellcheck disable=SC2086
  check "invalid ${bad% *}='${bad#* }' refused before any docker action" knob_refused ${bad}
done

echo "== seed recovery is armed BEFORE the stop (codex round 8, P3) =="

stop_failure_restarts() {
  fresh_out
  if PUBLISH_STOP_RC=1 run_publisher >/dev/null 2>&1; then return 1; fi
  # an ambiguous stop (nonzero, seed possibly down) must still be followed by a start
  awk '/^stop /{s=1} s && /^start /{ok=1} END{exit !ok}' "${PUB}/docker.log" \
    && ! grep -q '^run ' "${PUB}/docker.log" && [ ! -e "${PUB}/out/manifest.json" ]
}
check "docker stop fails -> seed restarted anyway, nothing copied or published" stop_failure_restarts

start_failure_retried() {
  fresh_out
  if PUBLISH_START_RC=1 run_publisher >/dev/null 2>&1; then return 1; fi
  [ "$(grep -c '^start ' "${PUB}/docker.log")" -ge 2 ] && [ ! -e "${PUB}/out/manifest.json" ]
}
check "docker start fails after copy -> retried on exit, not published" start_failure_retried

term_during_stop_restarts() {
  fresh_out
  # Truncate BEFORE backgrounding: the poll below must never see the previous
  # test's `stop` line and signal a publisher that has not reached the stop.
  : > "${PUB}/docker.log"
  PUBLISH_STOP_SLEEP=2 run_publisher >/dev/null 2>&1 &
  local pid=$! _ ppid=""
  for _ in $(seq 1 100); do grep -q '^stop ' "${PUB}/docker.log" 2>/dev/null && break; sleep 0.1; done
  grep -q '^stop ' "${PUB}/docker.log" || { wait "${pid}"; return 1; }
  # Signal the publisher itself (the bash running the script), not the wrapper.
  # (it now carries its explicit mode flag: `bash <publisher> --from-seed`)
  ppid="$(pgrep -f "^bash ${PUBLISHER} --from-seed\$" | head -1)"
  [ -n "${ppid}" ] || { wait "${pid}"; return 1; }
  kill -TERM "${ppid}"
  wait "${pid}" 2>/dev/null
  awk '/^stop /{s=1} s && /^start /{ok=1} END{exit !ok}' "${PUB}/docker.log" \
    && ! grep -q '^run ' "${PUB}/docker.log" && [ ! -e "${PUB}/out/manifest.json" ]
}
check "SIGTERM while the seed is stopping -> seed restarted, nothing published" term_during_stop_restarts
check "trap restarts the seed on every exit path" \
  bash -c "grep -q '^trap cleanup EXIT' '${PUBLISHER}' && grep -A4 'cleanup()' '${PUBLISHER}' | grep -q 'start'"

archive_ships_only_redb() {
  # exactly one tar member, and it is wrfcoin.redb — peer_identity.key, hsm/
  # and equivocation_evidence.redb must never appear in the archive command
  grep -q 'tar czf .* wrfcoin.redb$' "${PUBLISHER}" || return 1
  ! grep -E 'tar czf.*(peer_identity|hsm|equivocation)' "${PUBLISHER}"
}
check "archive ships only wrfcoin.redb" archive_ships_only_redb

check "publish is atomic (.tmp then mv into place)" \
  bash -c "grep -q 'snapshot.tar.gz.tmp' '${PUBLISHER}' && grep -q 'manifest.json.tmp' '${PUBLISHER}'"

manifest_published_after_archive() {
  local a m
  a="$(grep -n 'OUT_DIR}/snapshot.tar.gz"$' "${PUBLISHER}" | head -1 | cut -d: -f1)"
  m="$(grep -n 'OUT_DIR}/manifest.json"$' "${PUBLISHER}" | head -1 | cut -d: -f1)"
  [ -n "${a}" ] && [ -n "${m}" ] && [ "${a}" -lt "${m}" ]
}
check "manifest lands after the archive it describes" manifest_published_after_archive

echo "== funnel edge: exact join routes, rate-limited, read-only mount =="

check "snippet admits exactly the two artifact paths" \
  bash -c "grep -q 'path /join/manifest.json /join/snapshot.tar.gz' '${CADDY_SNIPPET}'"

check "join route is GET-only" \
  bash -c "grep -B1 'path /join/manifest.json' '${CADDY_SNIPPET}' | grep -q 'method GET'"

check "join paths are rate-limited" \
  bash -c "grep -A4 'zone join_snapshot' '${CADDY_SNIPPET}' | grep -q '/join/\*'"

echo "== join artifacts live outside the release tree (infra#1057) =="

# The mount source is checked on the RENDERED compose model, not by grep:
# compose resolves relative bind sources against the project dir, which on
# CT101 is infra.releases/<sha>/testnet. A real render is the only way to see
# the path the edge would actually mount.
render_join_source() {
  # $1: optional --env-file override; env WRFCOIN_JOIN_SNAPSHOT_DIR passes through.
  local env_file="${1:-${REPO}/testnet/.env.testnet.example}"
  WRFCOIN_FUNNEL_ORIGIN=https://fixture.invalid \
    bash "${REPO}/testnet/tests/render-testnet-compose.sh" \
      --env-file "${env_file}" \
      -f "${REPO}/testnet/docker-compose.testnet.yml" \
      -f "${REPO}/testnet/docker-compose.override.yml" \
      -f "${FUNNEL_COMPOSE}" \
      config --format json > "${TMP}/render.json" 2> "${TMP}/render.err" || return 1
  python3 - "${TMP}/render.json" <<'PYJ'
import json, sys
svc = json.load(open(sys.argv[1]))["services"]["funnel-edge"]
hits = [v for v in svc.get("volumes", []) if v.get("target") == "/srv/join"]
if len(hits) != 1 or hits[0].get("type") != "bind" or not hits[0].get("read_only"):
    sys.exit(1)
print(hits[0]["source"])
PYJ
}

# The compose default (rendered with the variable unset) must sit outside
# the tree; this is the path a fresh edge recreate mounts.
join_mount_default_outside_tree() {
  local src
  src="$(unset WRFCOIN_JOIN_SNAPSHOT_DIR; render_join_source)" || return 1
  case "${src}" in /*) ;; *) return 1 ;; esac
  case "${src}/" in "${REPO}/"*|*.releases/*|*/testnet/join-snapshots/) return 1 ;; esac
  [ "${src}" = /var/lib/wrfcoin-testnet-join/public ]
}
check "rendered /srv/join source defaults outside the release tree" \
  join_mount_default_outside_tree

check "legacy in-tree join-snapshots dir is gone" \
  bash -c "[ ! -e '${REPO}/testnet/join-snapshots' ] && ! grep -q 'join-snapshots:/srv/join' '${FUNNEL_COMPOSE}'"

check "publisher parses no env file for its destination (Compose is the only resolver)" \
  bash -c "! grep -q 'WRFCOIN_JOIN_SNAPSHOT_DIR=' '${PUBLISHER}' && ! grep -qE '^[^#]*OUT_DIR=\"\\$\\{OUT_DIR' '${PUBLISHER}'"

# Path agreement: render compose from an env-file variant, hand the rendered
# /srv/join source to the (stub) running edge, run the publisher with that
# same env file and a DIFFERENT decoy in the process-visible places a naive
# parser would read, and require the artifacts to land exactly in the
# rendered source. $1 = env-file body appended to the example; $2 = extra
# env assignments for the render + publisher (may be empty).
agree_with_render() {
  local body="$1" extra="${2:-}" envf="${TMP}/agree.env" src
  { cat "${REPO}/testnet/.env.testnet.example"; printf '%s\n' "${body}"; } > "${envf}"
  # The eval'd text is this function's own fixture assignments (test-controlled,
  # never external input); one reviewed marker per eval.
  # dynamic-payload-reviewed: join-snapshot-agree-render-env
  src="$(unset WRFCOIN_JOIN_SNAPSHOT_DIR; eval "export ${extra:-_NOOP=1}"; render_join_source "${envf}")" || return 1
  case "${src}" in "${TMP}"/*) ;; *) echo "rendered '${src}' outside fixture" >&2; return 1 ;; esac
  mkdir -p "${src}"; rm -f "${src}/manifest.json" "${src}/snapshot.tar.gz"
  # dynamic-payload-reviewed: join-snapshot-agree-publish-env
  (unset WRFCOIN_JOIN_SNAPSHOT_DIR; eval "export ${extra:-_NOOP=1}"
   PUBLISH_EDGE_JOIN_SOURCE="${src}" ENV_FILE="${envf}" run_publisher) >/dev/null 2>&1 || return 1
  [ -s "${src}/manifest.json" ] && [ -s "${src}/snapshot.tar.gz" ] || return 1
  printf '%s\n' "${src}" > "${TMP}/agree.src"
}

agree_inline_comment() {
  agree_with_render "WRFCOIN_JOIN_SNAPSHOT_DIR=${TMP}/join-comment # operator note" || return 1
  [ "$(cat "${TMP}/agree.src")" = "${TMP}/join-comment" ]
}
check "path agreement: env-file inline comment" agree_inline_comment

agree_interpolation() {
  agree_with_render "JOIN_BASE_FIXTURE=${TMP}/join-base
WRFCOIN_JOIN_SNAPSHOT_DIR=\${JOIN_BASE_FIXTURE}/public" || return 1
  [ "$(cat "${TMP}/agree.src")" = "${TMP}/join-base/public" ]
}
check "path agreement: env-file interpolation" agree_interpolation

agree_process_env_wins() {
  agree_with_render "WRFCOIN_JOIN_SNAPSHOT_DIR=${TMP}/join-decoy-file" \
    "WRFCOIN_JOIN_SNAPSHOT_DIR=${TMP}/join-process" || return 1
  [ "$(cat "${TMP}/agree.src")" = "${TMP}/join-process" ] && [ ! -e "${TMP}/join-decoy-file/manifest.json" ]
}
check "path agreement: process env overrides env file" agree_process_env_wins

empty_override_follows_compose() {
  # Explicitly empty process variable + env file naming a decoy: whatever
  # Compose renders (the shared default), the publisher must follow the edge
  # and never write the decoy.
  local envf="${TMP}/empty.env" src
  { cat "${REPO}/testnet/.env.testnet.example"; printf 'WRFCOIN_JOIN_SNAPSHOT_DIR=%s\n' "${TMP}/join-decoy-empty"; } > "${envf}"
  src="$(WRFCOIN_JOIN_SNAPSHOT_DIR='' render_join_source "${envf}")" || return 1
  [ "${src}" != "${TMP}/join-decoy-empty" ] || return 1
  mkdir -p "${TMP}/join-decoy-empty"
  # Exit status is irrelevant here (the rendered default is usually not
  # writable in a sandbox); what matters is that the decoy is never written.
  (WRFCOIN_JOIN_SNAPSHOT_DIR='' PUBLISH_EDGE_JOIN_SOURCE="${src}" ENV_FILE="${envf}" run_publisher) >/dev/null 2>&1 || :
  [ ! -e "${TMP}/join-decoy-empty/manifest.json" ]
}
check "path agreement: explicitly empty override never falls back to the env file" \
  empty_override_follows_compose

publisher_refuses_edge() {
  # $1: the /srv/join source the running edge reports; must be refused before stop.
  if PUBLISH_EDGE_JOIN_SOURCE="$1" run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log"
}
check "publisher refuses an edge still mounting the checkout tree, before stop" \
  publisher_refuses_edge "${REPO}/testnet/join-snapshots"
check "publisher refuses an edge mounting under *.releases/, before stop" \
  publisher_refuses_edge "${TMP}/wrfcoin-deploy/infra.releases/abc123/testnet/join-snapshots"
check "publisher refuses a relative mount source, before stop" \
  publisher_refuses_edge "join-snapshots"
check "publisher refuses an edge with no /srv/join mount, before stop" \
  publisher_refuses_edge ""
check "publisher refuses a missing mount directory, before stop" \
  publisher_refuses_edge "${TMP}/does-not-exist"

publisher_refuses_absent_edge() {
  if PUBLISH_EDGE_MISSING=1 run_publisher >/dev/null 2>&1; then return 1; fi
  ! grep -q '^stop ' "${PUB}/docker.log"
}
check "publisher refuses when the edge container is absent, before stop" publisher_refuses_absent_edge

echo "== --from-snapshot: no-restart source (a ZFS snapshot of the live node's volume) =="

# Layout mirrors CT101: tank/docker is mounted at /mnt/tank-docker, and its
# snapshots are readable at /mnt/tank-docker/.zfs/snapshot/<name>/...
ZFS_MNT="${PUB}/tank-docker"
NODE_DATA="${ZFS_MNT}/docker-data/volumes/testnet_node-data/_data"
SNAP_REDB="${ZFS_MNT}/.zfs/snapshot/join-t1/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb"
SEEDVOL_SNAP_REDB="${ZFS_MNT}/.zfs/snapshot/join-t1/docker-data/volumes/testnet_seed-data/_data/wrfcoin.redb"
mkdir -p "${NODE_DATA}" "$(dirname "${SNAP_REDB}")" "$(dirname "${SEEDVOL_SNAP_REDB}")" "${PUB}/stage"
printf 'live-node-redb-changing' > "${NODE_DATA}/wrfcoin.redb"
printf 'redb-fixture' > "${SNAP_REDB}"
printf 'seed-volume-redb' > "${SEEDVOL_SNAP_REDB}"
export PUBLISH_NODE_DATA_SOURCE="${NODE_DATA}"

# findmnt: the REAL kernel mount table, with the fixture's two ZFS mounts
# overlaid (the live dataset, and one read-only snapshot of it) ONLY where the
# kernel reports no deeper mount. So a genuine bind/overmount made inside the
# fixture (see the unshare case below) is seen exactly as the kernel reports it.
cat > "${PUB}/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
path=""
while [ $# -gt 0 ]; do case "$1" in -T) path="$2"; shift 2 ;; *) shift ;; esac; done
real="$("${REAL_FINDMNT:?}" -n -P -T "${path}" -o TARGET,SOURCE,FSTYPE,FS-OPTIONS)" || exit 1
rt=""; [[ "${real}" =~ ^TARGET=\"([^\"]*)\" ]] && rt="${BASH_REMATCH[1]}"
best=""; bestline=""
while IFS='|' read -r t src fs opts; do
  [ -n "${t}" ] || continue
  case "${path}/" in
    "${t}"/*) if [ "${#t}" -gt "${#best}" ]; then best="${t}"
                bestline="TARGET=\"${t}\" SOURCE=\"${src}\" FSTYPE=\"${fs}\" FS-OPTIONS=\"${opts}\""; fi ;;
  esac
done < "${FINDMNT_TABLE:?}"
if [ -n "${best}" ] && [ "${#rt}" -le "${#best}" ]; then printf '%s\n' "${bestline}"; else printf '%s\n' "${real}"; fi
EOF
chmod +x "${PUB}/bin/findmnt"
write_table() { # write_table <file> [extra lines...]: the CT101 shape, plus extras
  local f="$1"; shift
  printf '%s\n' "${ZFS_MNT}|tank/docker|zfs|rw,xattr,noacl" \
    "${ZFS_MNT}/.zfs/snapshot/join-t1|tank/docker@join-t1|zfs|ro,xattr,noacl" "$@" > "${f}"
}
write_table "${PUB}/findmnt.table"

fresh_stage() { rm -f "${PUB}/stage/manifest.json" "${PUB}/stage/snapshot.tar.gz"; fresh_out; }
nothing_live_touched() {
  # no stop/start of anything, and no live API read at all
  ! grep -qE '^(stop|start|restart|kill|pause) ' "${PUB}/docker.log" && [ ! -s "${PUB}/curl.log" ]
}

snapshot_stage_succeeds() {
  fresh_stage
  PUBLISH_SEED_RUNNING=false run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" \
    > "${PUB}/run.out" 2>&1 || { cat "${PUB}/run.out" >&2; return 1; }
  nothing_live_touched || { echo "    (touched something live)" >&2; return 1; }
  # staged, NOT served
  [ -s "${PUB}/stage/manifest.json" ] && [ -s "${PUB}/stage/snapshot.tar.gz" ] || return 1
  [ ! -e "${PUB}/out/manifest.json" ] && [ ! -e "${PUB}/out/snapshot.tar.gz" ] || return 1
  grep -q '"source": "ct101-node-zfs:join-t1"' "${PUB}/stage/manifest.json" || return 1
  grep -q "\"state_root_hex\": \"${STATE_ROOT}\"" "${PUB}/stage/manifest.json" || return 1
  # the archive is the SNAPSHOT's bytes, not the live file's
  [ "$(tar xzOf "${PUB}/stage/snapshot.tar.gz" wrfcoin.redb)" = redb-fixture ] || return 1
  jsr_verify_manifest "${PUB}/stage/manifest.json" 2>/dev/null \
    && jsr_verify_archive "${PUB}/stage/manifest.json" "${PUB}/stage/snapshot.tar.gz" \
    && jsr_verify_archive_shape "${PUB}/stage/snapshot.tar.gz" || return 1
  grep -q 'Staged (NOT served' "${PUB}/run.out"
}
check "snapshot + stage: bundle staged from the snapshot bytes, nothing served, nothing stopped, no live read" \
  snapshot_stage_succeeds

snapshot_verifier_from_node() {
  fresh_stage
  run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" > "${PUB}/run.out" 2>&1 || return 1
  local envc="${PUB}/state/verify-env.capture"
  # image and env come from the NODE container (the one that wrote the bytes)
  grep -qx "inspect -f {{.Image}} wrfcoin-testnet-node" "${PUB}/docker.log" || return 1
  ! grep -qE '^inspect .*wrfcoin-testnet-seed$' "${PUB}/docker.log" || return 1
  grep -qF -- '--network none' <<<"$(grep '^run ' "${PUB}/docker.log")" || return 1
  for kv in WRFCOIN_P2P_ENABLED=false WRFCOIN_SYNC_ONLY=1 WRFCOIN_CHAIN_ID=777 WRFCOIN_READER_TOKEN=test-token; do
    grep -qx "${kv}" "${envc}" || { echo "    (env missing ${kv})" >&2; return 1; }
  done
  # the producer's HSM config/PIN, operator token and DB URL never reach the verifier
  ! grep -qE '^(WRFCOIN_HSM_[A-Z_]*|WRFCOIN_OPERATOR_TOKEN|DATABASE_URL|WRFCOIN_P2P_BOOTSTRAP|WRFCOIN_SNAPSHOT_SIGNER_PRIVATE_KEY)=' "${envc}" || return 1
  owned_verifiers_removed && ! grep -q 'super-secret' "${PUB}/run.out"
}
check "snapshot mode: verifier runs the node's image, isolated, with HSM/operator/DB env stripped" \
  snapshot_verifier_from_node

snapshot_refused() {
  # $1: expected stderr fragment; rest: publisher args. Refused, nothing staged or served, nothing live touched, no verifier.
  local want="$1"; shift
  fresh_stage
  if run_publisher "$@" > "${PUB}/run.out" 2>&1; then echo "    (was not refused)" >&2; return 1; fi
  grep -qF -- "${want}" "${PUB}/run.out" || { echo "    (expected '${want}'; got: $(grep ERROR "${PUB}/run.out" | head -1))" >&2; return 1; }
  [ ! -e "${PUB}/stage/manifest.json" ] && [ ! -e "${PUB}/out/manifest.json" ] && nothing_live_touched
}
check "snapshot mode: the LIVE file (its mount is the live dataset, not <ds>@<snap>) is refused" \
  snapshot_refused "is not <dataset>@<snapshot>" --from-snapshot "${NODE_DATA}/wrfcoin.redb" --stage-dir "${PUB}/stage"
check "snapshot mode: a relative snapshot path is refused" \
  snapshot_refused "not an absolute path" --from-snapshot "tank-docker/.zfs/snapshot/join-t1/x/wrfcoin.redb" --stage-dir "${PUB}/stage"
check "snapshot mode: '..' in the path is refused (not canonical)" \
  snapshot_refused "not canonical" --from-snapshot "${ZFS_MNT}/.zfs/snapshot/join-t1/../join-t1/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb" --stage-dir "${PUB}/stage"
check "snapshot mode: a snapshot of ANOTHER volume (seed's) is refused: not the verifier container's" \
  snapshot_refused "must be of that container's volume" --from-snapshot "${SEEDVOL_SNAP_REDB}" --stage-dir "${PUB}/stage"
check "snapshot mode: a missing snapshot file is refused" \
  snapshot_refused "does not resolve" --from-snapshot "${ZFS_MNT}/.zfs/snapshot/nope/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb" --stage-dir "${PUB}/stage"
no_node_mount_refused() { PUBLISH_NODE_DATA_SOURCE="" snapshot_refused "must be of that container's volume" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"; }
check "snapshot mode: node container without an /app/data mount is refused" no_node_mount_refused

no_stage_writes_nothing() {
  # codex round 49: snapshot mode without --stage-dir must not fall through
  # into the served-directory branch. Refused before ANY docker call.
  fresh_stage; : > "${PUB}/docker.log"
  if run_publisher --from-snapshot "${SNAP_REDB}" > "${PUB}/run.out" 2>&1; then return 1; fi
  grep -q 'requires --stage-dir' "${PUB}/run.out" || return 1
  [ -z "$(ls -A "${PUB}/out")" ] && [ ! -s "${PUB}/docker.log" ] && [ ! -e "${PUB}/stage/manifest.json" ]
}
check "snapshot mode without --stage-dir: refused before any docker call; served dir untouched" no_stage_writes_nothing

echo "== snapshot provenance comes from the kernel mount table (codex round 49) =="
# (a) An ORDINARY directory named .zfs, checked by the REAL findmnt: it sits on
#     the test host's ext4/tmpfs, so it is not a ZFS snapshot, whatever it is called.
PLAIN="${TMP}/plain-host"
mkdir -p "${PLAIN}/.zfs/snapshot/s1/docker-data/volumes/testnet_node-data/_data" "${PLAIN}/docker-data/volumes/testnet_node-data/_data"
printf 'redb-fixture' > "${PLAIN}/.zfs/snapshot/s1/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb"
printf 'live' > "${PLAIN}/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb"
plain_zfs_dir_refused() {
  PUBLISH_FINDMNT="${REAL_FINDMNT}" PUBLISH_NODE_DATA_SOURCE="${PLAIN}/docker-data/volumes/testnet_node-data/_data" \
    snapshot_refused "not a ZFS snapshot" \
    --from-snapshot "${PLAIN}/.zfs/snapshot/s1/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb" --stage-dir "${PUB}/stage"
}
check "ordinary directory named .zfs (REAL findmnt) is refused" plain_zfs_dir_refused

# (b) codex's reproduction: the snapshot's _data ANCESTOR is a symlink to the
#     LIVE node data. The final component is a regular file; the path is not canonical.
LINKSNAP="${ZFS_MNT}/.zfs/snapshot/join-t1/docker-data/volumes/testnet_link-data"
mkdir -p "${LINKSNAP}"; ln -sfn "${NODE_DATA}" "${LINKSNAP}/_data"
ancestor_link_refused() {
  snapshot_refused "not canonical" --from-snapshot "${LINKSNAP}/_data/wrfcoin.redb" --stage-dir "${PUB}/stage" || return 1
  [ ! -e "${PUB}/stage/snapshot.tar.gz" ]
}
check "ancestor symlink to the LIVE data dir is refused; live bytes are not archived" ancestor_link_refused

# (c) A REAL bind mount of the live data dir over the snapshot's _data, made
#     in a private user+mount namespace (no root). The kernel reports the bind
#     as the deepest mount; its source is not <dataset>@<snapshot>.
BIND_T="${ZFS_MNT}/.zfs/snapshot/join-t1/docker-data/volumes/testnet_node-data/_data"
bind_skipped=0
if unshare -rm true 2>/dev/null; then
  real_bind_refused() {
    local rc=0
    PUBLISH_WRAP=(unshare -rm bash -c 'mount --bind "$1" "$2" || exit 97; shift 2; exec "$@"' _ "${NODE_DATA}" "${BIND_T}")
    snapshot_refused "not a ZFS snapshot" --from-snapshot "${BIND_T}/wrfcoin.redb" --stage-dir "${PUB}/stage" || rc=1
    PUBLISH_WRAP=()
    grep -qF "(${BIND_T})" "${PUB}/run.out" || { echo "    (refusal does not name the bind mount)" >&2; rc=1; }
    [ "$(cat "${BIND_T}/wrfcoin.redb")" = redb-fixture ] || rc=1   # namespace gone: fixture intact
    return "${rc}"
  }
  check "REAL bind mount of the live dir over the snapshot path (unshare) is refused" real_bind_refused
else
  bind_skipped=1
  echo "  SKIP  REAL bind-mount case: unprivileged user namespaces unavailable on this host (not counted; emulated case below still runs)"
fi
echo "  real_bind_case_skipped=${bind_skipped}"
emulated_bind_refused() {
  write_table "${PUB}/findmnt.bind" "${BIND_T}|tank/docker[/docker-data/volumes/testnet_node-data/_data]|zfs|rw,xattr"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.bind" snapshot_refused "is not <dataset>@<snapshot>" \
    --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"
}
check "emulated bind of the live dataset over the snapshot path (source ds[/sub], rw) is refused" emulated_bind_refused
rw_snapshot_refused() {
  printf '%s\n' "${ZFS_MNT}|tank/docker|zfs|rw" "${ZFS_MNT}/.zfs/snapshot/join-t1|tank/docker@join-t1|zfs|rw" > "${PUB}/findmnt.rw"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.rw" snapshot_refused "is not read-only" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"
}
check "snapshot mount that is not read-only is refused" rw_snapshot_refused
other_dataset_refused() {
  printf '%s\n' "${ZFS_MNT}|tank/docker|zfs|rw" "${ZFS_MNT}/.zfs/snapshot/join-t1|tank/other@join-t1|zfs|ro" > "${PUB}/findmnt.other"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.other" snapshot_refused "must be of that container's volume" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"
}
check "snapshot of a DIFFERENT dataset than the node volume's is refused" other_dataset_refused
live_is_bind_refused() {
  write_table "${PUB}/findmnt.livebind" "${NODE_DATA}|tank/docker[/elsewhere]|zfs|rw"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.livebind" snapshot_refused "must be of that container's volume" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"
}
check "node data dir that is itself a bind mount is refused" live_is_bind_refused
wrong_root_refused() {
  printf '%s\n' "${ZFS_MNT}|tank/docker|zfs|rw" "${ZFS_MNT}/.zfs/snapshot/join-t1/docker-data|tank/docker@join-t1|zfs|ro" > "${PUB}/findmnt.root"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.root" snapshot_refused "is not the snapshot root" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage"
}
check "a <ds>@<snap> mount that is not at <m>/.zfs/snapshot/<snap> is refused" wrong_root_refused
ELSEWHERE="${PUB}/elsewhere"
ELSE_REDB="${ELSEWHERE}/.zfs/snapshot/join-t1/docker-data/volumes/testnet_node-data/_data/wrfcoin.redb"
mkdir -p "$(dirname "${ELSE_REDB}")"; printf 'redb-fixture' > "${ELSE_REDB}"
foreign_root_refused() {
  # A correctly shaped read-only tank/docker@join-t1 snapshot, but rooted under a
  # mount point other than the one holding the node's data dir.
  write_table "${PUB}/findmnt.elsewhere" "${ELSEWHERE}/.zfs/snapshot/join-t1|tank/docker@join-t1|zfs|ro,xattr"
  PUBLISH_FINDMNT_TABLE="${PUB}/findmnt.elsewhere" snapshot_refused "is not ${ZFS_MNT}/.zfs/snapshot/join-t1" \
    --from-snapshot "${ELSE_REDB}" --stage-dir "${PUB}/stage"
}
check "a snapshot root under a DIFFERENT mount point than the node volume's is refused" foreign_root_refused
check "positive control: the CT101-shaped mounts pass provenance and stage" snapshot_stage_succeeds

echo "== --stage-dir: never the served dir, never in a release tree =="
check "stage dir == the edge's served dir is refused (that would be a publish)" \
  snapshot_refused "staging there IS publishing" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/out"
mkdir -p "${PUB}/out-link-target"; ln -sfn "${PUB}/out" "${PUB}/out-alias"
check "stage dir that is a symlink is refused" \
  snapshot_refused "a symlink" --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/out-alias"
check "stage dir inside the checkout tree is refused" \
  snapshot_refused "inside a release/checkout tree" --from-snapshot "${SNAP_REDB}" --stage-dir "${REPO}/testnet/join-snapshots"
mkdir -p "${TMP}/wrfcoin-deploy/infra.releases/abc/stage"
check "stage dir under *.releases/ is refused" \
  snapshot_refused "inside a release/checkout tree" --from-snapshot "${SNAP_REDB}" --stage-dir "${TMP}/wrfcoin-deploy/infra.releases/abc/stage"
OTHER_CO="${TMP}/other-checkout"; mkdir -p "${OTHER_CO}/.git" "${OTHER_CO}/deep/stage"; printf 'ref: refs/heads/main\n' > "${OTHER_CO}/.git/HEAD"
STRAY="${TMP}/stray-dotgit"; mkdir -p "${STRAY}/.git" "${STRAY}/stage"
stray_dotgit_is_not_a_checkout() {
  fresh_stage
  run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${STRAY}/stage" >"${PUB}/run.out" 2>&1 \
    || { tail -3 "${PUB}/run.out" >&2; return 1; }
  [ -s "${STRAY}/stage/manifest.json" ]
}
check "a stray EMPTY .git directory is not a checkout (git does not treat it as one)" stray_dotgit_is_not_a_checkout
check "stage dir inside a DIFFERENT checkout (.git dir) is refused" \
  snapshot_refused "inside a git checkout/worktree" --from-snapshot "${SNAP_REDB}" --stage-dir "${OTHER_CO}/deep/stage"
OTHER_WT="${TMP}/other-worktree"; mkdir -p "${OTHER_WT}/stage"; printf 'gitdir: /elsewhere/.git/worktrees/x\n' > "${OTHER_WT}/.git"
check "stage dir inside a git WORKTREE (.git file) is refused" \
  snapshot_refused "inside a git checkout/worktree" --from-snapshot "${SNAP_REDB}" --stage-dir "${OTHER_WT}/stage"
served_in_checkout_refused() {
  mkdir -p "${OTHER_CO}/served"
  if PUBLISH_EDGE_JOIN_SOURCE="${OTHER_CO}/served" run_publisher >"${PUB}/run.out" 2>&1; then return 1; fi
  grep -q 'inside a git checkout/worktree' "${PUB}/run.out" && ! grep -q '^stop ' "${PUB}/docker.log"
}
check "seed mode: an edge serving from a different checkout is refused before stop" served_in_checkout_refused
check "relative stage dir is refused" \
  snapshot_refused "must be an absolute path" --from-snapshot "${SNAP_REDB}" --stage-dir "stage"
check "unknown argument is refused" \
  snapshot_refused "unknown argument" --from-snapshot "${SNAP_REDB}" --stage "${PUB}/stage"

echo "== --from-snapshot: the frozen-copy receipt still gates everything =="
snapshot_frozen_refused() {
  fresh_stage
  if run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" >/dev/null 2>&1; then return 1; fi
  [ ! -e "${PUB}/stage/manifest.json" ] && nothing_live_touched && owned_verifiers_removed
}
( export PUBLISH_FROZEN_CHAIN=778; snapshot_frozen_refused ) && r=0 || r=1
check "snapshot mode: wrong chain in the copy -> refused, nothing staged" test "${r}" = 0
( export PUBLISH_FROZEN_HEIGHT=11017; snapshot_frozen_refused ) && r=0 || r=1
check "snapshot mode: copy at height 11017 -> refused" test "${r}" = 0
( export PUBLISH_VERIFIER_BOOT_FAILS=99 PUBLISH_VERIFIER_RUNNING=false; snapshot_frozen_refused ) && r=0 || r=1
check "snapshot mode: the copy does not boot (crash-inconsistent image) -> refused" test "${r}" = 0
( export PUBLISH_FROZEN_DRIFT=1; snapshot_frozen_refused ) && r=0 || r=1
check "snapshot mode: copy state moves between reads -> refused" test "${r}" = 0

echo "== promote-join-snapshot.sh: verify the staged pair with the joiner's checks, then publish =="
PROMOTE="${REPO}/testnet/promote-join-snapshot.sh"
run_promote() {
  env PATH="${PUB}/bin:${PATH}" DOCKER_BIN="${PUB}/bin/docker" CUT_PINS_FILE="${PROMOTE_PINS:-${TMP}/pins.env}" \
    PUBLISH_STATE="${PUB}/state" PUBLISH_DOCKER_LOG="${PUB}/docker.log" \
    PUBLISH_EDGE_JOIN_SOURCE="${PUBLISH_EDGE_JOIN_SOURCE-${PUB}/out}" \
    bash "${PROMOTE}" "$@" > "${PUB}/promote.out" 2>&1
}
stage_good() {
  fresh_stage
  run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" >/dev/null 2>&1
}

promote_dry_run_writes_nothing() {
  stage_good || return 1
  run_promote --stage-dir "${PUB}/stage" --dry-run || { cat "${PUB}/promote.out" >&2; return 1; }
  grep -q 'DRY RUN: would publish into' "${PUB}/promote.out" && grep -q 'Nothing was written' "${PUB}/promote.out" || return 1
  [ -z "$(ls -A "${PUB}/out")" ]
}
check "promote --dry-run: verifies, names the served dir, writes nothing" promote_dry_run_writes_nothing

promote_publishes() {
  stage_good || return 1
  run_promote --stage-dir "${PUB}/stage" || { cat "${PUB}/promote.out" >&2; return 1; }
  cmp -s "${PUB}/stage/manifest.json" "${PUB}/out/manifest.json" \
    && cmp -s "${PUB}/stage/snapshot.tar.gz" "${PUB}/out/snapshot.tar.gz" || return 1
  [ ! -e "${PUB}/out/manifest.json.tmp" ] && [ ! -e "${PUB}/out/snapshot.tar.gz.tmp" ] || return 1
  [ "$(stat -c %a "${PUB}/out/manifest.json")" = 644 ] && [ "$(stat -c %a "${PUB}/out/snapshot.tar.gz")" = 644 ]
}
check "promote: served pair == staged pair, no temp files left, world-readable" promote_publishes

promote_order_archive_first() {
  grep -n 'mv -f' "${PROMOTE}" | head -1 | grep -q 'snapshot.tar.gz' \
    && grep -n 'mv -f' "${PROMOTE}" | tail -1 | grep -q 'manifest.json'
}
check "promote: archive renamed into place before the manifest" promote_order_archive_first

promote_refused() {
  # $1 expected message; stage is prepared by the caller. Served dir stays empty.
  local want="$1"; shift
  rm -f "${PUB}/out/manifest.json" "${PUB}/out/snapshot.tar.gz"
  if run_promote "$@"; then echo "    (was not refused)" >&2; return 1; fi
  grep -qF -- "${want}" "${PUB}/promote.out" || { echo "    (expected '${want}'; got: $(grep ERROR "${PUB}/promote.out" | head -1))" >&2; return 1; }
  [ ! -e "${PUB}/out/manifest.json" ] && [ ! -e "${PUB}/out/snapshot.tar.gz" ]
}
promote_tampered() { stage_good && printf 'x' >> "${PUB}/stage/snapshot.tar.gz" && promote_refused "sha256 mismatch" --stage-dir "${PUB}/stage"; }
check "promote refuses a staged archive altered after staging" promote_tampered
promote_wrong_chain() { stage_good && sed -i 's/"chain_id": "777"/"chain_id": "778"/' "${PUB}/stage/manifest.json" && promote_refused "chain_id mismatch" --stage-dir "${PUB}/stage"; }
check "promote refuses a staged manifest for another chain" promote_wrong_chain
promote_extra_member() {
  stage_good || return 1
  local d="${PUB}/extra"; mkdir -p "${d}"; printf 'redb-fixture' > "${d}/wrfcoin.redb"; printf k > "${d}/peer_identity.key"
  tar czf "${PUB}/stage/snapshot.tar.gz" -C "${d}" wrfcoin.redb peer_identity.key
  sed -i "s/\"sha256\": \"[0-9a-f]*\"/\"sha256\": \"$(sha256sum "${PUB}/stage/snapshot.tar.gz" | cut -d' ' -f1)\"/" "${PUB}/stage/manifest.json"
  promote_refused "exactly one root member" --stage-dir "${PUB}/stage"
}
check "promote refuses an archive carrying per-node material, even when hash-bound" promote_extra_member
promote_stage_is_served() { stage_good && cp "${PUB}/stage/"* "${PUB}/out-link-target/" && PUBLISH_EDGE_JOIN_SOURCE="${PUB}/out-link-target" promote_refused "stage dir IS the served dir" --stage-dir "${PUB}/out-link-target"; }
check "promote refuses when the stage dir is the served dir" promote_stage_is_served
promote_in_tree() { stage_good && PUBLISH_EDGE_JOIN_SOURCE="${REPO}/testnet/join-snapshots" promote_refused "inside a release/checkout tree" --stage-dir "${PUB}/stage"; }
check "promote refuses an edge still serving from the checkout tree" promote_in_tree
promote_served_in_checkout() { stage_good && mkdir -p "${OTHER_CO}/served" && PUBLISH_EDGE_JOIN_SOURCE="${OTHER_CO}/served" promote_refused "inside a git checkout/worktree" --stage-dir "${PUB}/stage"; }
check "promote refuses a served dir inside a different checkout" promote_served_in_checkout
promote_stage_in_worktree() {
  stage_good || return 1
  cp "${PUB}/stage/manifest.json" "${PUB}/stage/snapshot.tar.gz" "${OTHER_WT}/stage/"
  promote_refused "inside a git checkout/worktree" --stage-dir "${OTHER_WT}/stage"
}
check "promote refuses a stage dir inside a git worktree (.git file)" promote_stage_in_worktree
promote_no_edge() { stage_good && PUBLISH_EDGE_MISSING=1 promote_refused "cannot inspect" --stage-dir "${PUB}/stage"; }
check "promote refuses when the edge container is absent" promote_no_edge
promote_missing_stage() { rm -rf "${PUB}/stage-empty"; mkdir -p "${PUB}/stage-empty"; promote_refused "missing or not a regular file" --stage-dir "${PUB}/stage-empty"; }
check "promote refuses an empty stage dir" promote_missing_stage

echo "== handoff: the produced bundle is consumed by the REAL joiner chain (infra#774 e2e) =="
# Produce against the COMMITTED cut-pins.env (not the test pins), promote into
# a served dir, then run the #774 joiner e2e with that served dir as its
# snapshot source: join.sh -> join-testnet-sync-node.sh -> join-snapshot-restore.sh
# must restore exactly these bytes before starting the node.
handoff_to_joiner() {
  fresh_stage
  # The frozen copy is the COMMITTED chain: its stub /network/info reports the
  # committed pins' genesis and chain, not this file's private 777 fixture.
  local GENESIS PUBLISH_FROZEN_CHAIN
  GENESIS="$(sed -n 's/^WRFCOIN_CUT_GENESIS_HASH=//p' "${REPO}/testnet/cut-pins.env")"
  PUBLISH_FROZEN_CHAIN="$(sed -n 's/^WRFCOIN_CUT_CHAIN_ID=//p' "${REPO}/testnet/cut-pins.env")"
  export PUBLISH_FROZEN_CHAIN
  # The source container's build is the committed pin, so the manifest's
  # core4_commit equals it and the joiner's version guard passes.
  PUBLISH_CORE4_REVISION="$(sed -n 's/^WRFCOIN_CUT_CORE4_COMMIT=//p' "${REPO}/testnet/cut-pins.env")" \
    PUBLISH_PINS="${REPO}/testnet/cut-pins.env" \
    run_publisher --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" >/dev/null 2>&1 || return 1
  PROMOTE_PINS="${REPO}/testnet/cut-pins.env" run_promote --stage-dir "${PUB}/stage" || return 1
  # A clean environment: this file exports its own DOCKER_BIN/CUT_PINS_FILE stubs.
  env -i PATH="${PATH}" HOME="${HOME}" JOIN_E2E_SNAPSHOT_DIR="${PUB}/out" JOIN_E2E_ONLY_PUBLISHED=1 \
    bash "${REPO}/scripts/tests/test-join-sh-e2e.sh" > "${PUB}/handoff.out" 2>&1 \
    || { tail -20 "${PUB}/handoff.out" >&2; return 1; }
  # The published manifest names the committed pin (the join e2e swaps it for its
  # fixture commit, so this is where the real publisher output is held to it).
  grep -q "\"core4_commit\": \"$(sed -n 's/^WRFCOIN_CUT_CORE4_COMMIT=//p' "${REPO}/testnet/cut-pins.env")\"" "${PUB}/out/manifest.json" || return 1
  grep -q 'ok    happy path (PUBLISHED bundle' "${PUB}/handoff.out" \
    && grep -q 'ok    happy path (PUBLISHED bundle over file:// URL' "${PUB}/handoff.out"
}
check "publisher -> promote -> join.sh e2e restores the published bundle (dir and URL)" handoff_to_joiner

echo "== the source is explicit: no default mode (infra#1057 follow-up; seed retired by #1090) =="
no_mode_refused() {
  fresh_out; : > "${PUB}/docker.log"
  if PUBLISH_NO_MODE=1 run_publisher > "${PUB}/run.out" 2>&1; then return 1; fi
  grep -q 'no source given' "${PUB}/run.out" && [ ! -s "${PUB}/docker.log" ] && [ ! -e "${PUB}/out/manifest.json" ]
}
check "no source flag: refused before any docker call; nothing published" no_mode_refused
stage_only_no_mode_refused() {
  fresh_stage; : > "${PUB}/docker.log"
  if PUBLISH_NO_MODE=1 run_publisher --stage-dir "${PUB}/stage" > "${PUB}/run.out" 2>&1; then return 1; fi
  grep -q 'no source given' "${PUB}/run.out" && [ ! -s "${PUB}/docker.log" ]
}
check "--stage-dir alone (no source flag): refused before any docker call" stage_only_no_mode_refused
both_modes_refused() {
  fresh_stage; : > "${PUB}/docker.log"
  if PUBLISH_NO_MODE=1 run_publisher --from-seed --from-snapshot "${SNAP_REDB}" --stage-dir "${PUB}/stage" > "${PUB}/run.out" 2>&1; then return 1; fi
  grep -q 'mutually exclusive' "${PUB}/run.out" && [ ! -s "${PUB}/docker.log" ]
}
check "--from-seed with --from-snapshot: refused before any docker call" both_modes_refused
explicit_seed_still_works() {
  fresh_out
  PUBLISH_NO_MODE=1 run_publisher --from-seed >/dev/null 2>&1 || return 1
  grep -q '^stop ' "${PUB}/docker.log" && [ -s "${PUB}/out/manifest.json" ]
}
check "--from-seed (explicit legacy mode) still runs the seed stop-copy-start" explicit_seed_still_works

echo ""
echo "${assertions} assertions, ${fails} failures"
[ "${fails}" -eq 0 ]
