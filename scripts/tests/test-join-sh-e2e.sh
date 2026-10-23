#!/usr/bin/env bash
# test-join-sh-e2e.sh — infra#774: the joiner path, end to end, hermetically.
#
# Runs the REAL testnet/join.sh, which execs the REAL
# join-testnet-sync-node.sh, which runs the REAL join-snapshot-restore.sh and
# check-p2p-external-addr.sh, inside a throwaway workspace laid out like an
# operator's:
#
#   <ws>/infra   a git repo holding a copy of this checkout's testnet/
#   <ws>/core4   a local git repo whose history contains the pinned commit
#
# Only `docker`, `curl` and `tailscale` are stubs on PATH. `git`, the pins
# files, the scripts and the snapshot fixture are real, and the P2P self-dial
# goes to a real listener on loopback. There is no host and no network.
# The docker stub is an emulator, not a yes-machine (codex round 26): named
# volumes are directories, `run` resolves its -v mounts and REALLY executes
# the container's `sh -ec` script (so the snapshot is actually extracted and
# its bytes are asserted), and any command it does not recognise fails.
#
# Why the core4 pin is re-pointed: a hermetic run cannot fetch
# 9ef92a235 from GitHub. The workspace copy of cut-pins.env therefore has
# ONLY its WRFCOIN_CUT_CORE4_COMMIT line replaced with a commit of the local
# fixture repo. Genesis, chain id, network id and bootstrap are the
# committed values, byte for byte. The committed core4 pin is checked
# separately: it is well formed, it agrees with release-pins.env, and it is
# resolvable in a core4 checkout when CORE4_DIR is given (explicit SKIP
# otherwise).
#
# What it proves:
#   - join.sh checks out the cut commit and records it in .core4-commit;
#   - the joined node's .env carries the cut genesis/chain/network and the
#     pinned seed (BOOTSTRAP_PEERS == WRFCOIN_CUT_BOOTSTRAP), sync-only;
#   - the snapshot is restored (sha256 against the manifest: hash-bound)
#     BEFORE the node is started, and a tampered, mismatched or wrong-chain
#     snapshot is refused before any volume or container exists;
#   - a node answering with a different genesis/chain/network is refused;
#   - join.sh refuses a missing/unfetchable pin, a dirty core4 tree, and a
#     pins file without the core4 line.
# And, because a gate that cannot fail is not a gate (#769), the same e2e is
# run against MUTATED copies of join.sh, join-testnet-sync-node.sh and
# join-snapshot-restore.sh, and must go red on each one.
#
# Run: bash scripts/tests/test-join-sh-e2e.sh      (CORE4_DIR=<core4 checkout> optional)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_PINS="${REPO}/testnet/cut-pins.env"
RELEASE_PINS="${REPO}/testnet/release-pins.env"

fails=0
assertions=0
check() {
  local name="$1"; shift
  assertions=$((assertions + 1))
  # Forwards its own argv; no caller passes it a Compose render (grepped, infra#1107).
  # dynamic-payload-reviewed: join-sh-e2e-check-forwards-argv
  if "$@"; then printf '  ok    %s\n' "${name}"; else printf '  FAIL  %s\n' "${name}"; fails=$((fails + 1)); fi
}

TMP="$(mktemp -d)"
LISTENER_PID=""
cleanup() { [ -n "${LISTENER_PID}" ] && kill "${LISTENER_PID}" 2>/dev/null; rm -rf "${TMP}"; }
trap cleanup EXIT

pin_value() { sed -n "s/^$1=//p" "$2" | tail -1; }
CUT_CORE4="$(pin_value WRFCOIN_CUT_CORE4_COMMIT "${REAL_PINS}")"
CUT_GENESIS="$(pin_value WRFCOIN_CUT_GENESIS_HASH "${REAL_PINS}")"
CUT_CHAIN="$(pin_value WRFCOIN_CUT_CHAIN_ID "${REAL_PINS}")"
CUT_NETWORK="$(pin_value WRFCOIN_CUT_NETWORK_ID "${REAL_PINS}")"
CUT_BOOTSTRAP="$(pin_value WRFCOIN_CUT_BOOTSTRAP "${REAL_PINS}")"
# The public template is shell-quoted; inspect it without executing its contents.
CUT_BOOTSTRAP="${CUT_BOOTSTRAP#\"}"
CUT_BOOTSTRAP="${CUT_BOOTSTRAP%\"}"
# Happy paths supply an operator-selected synthetic endpoint, never a public placeholder.
TEST_BOOTSTRAP="${CUT_BOOTSTRAP//<N5_PUBLIC_IP>/192.0.2.44}"

echo "== committed cut-pins.env is well formed and consistent =="
check "core4 commit is a full 40-hex SHA" bash -c "[[ '${CUT_CORE4}' =~ ^[0-9a-f]{40}$ ]]"
check "genesis hash is 64-hex, unprefixed" bash -c "[[ '${CUT_GENESIS}' =~ ^[0-9a-f]{64}$ ]]"
check "chain id is a decimal string" bash -c "[[ '${CUT_CHAIN}' =~ ^[0-9]+$ ]]"
check "network id is set" bash -c "[ -n '${CUT_NETWORK}' ]"
check "bootstrap is /ip4|dns4/<host>/tcp/<port>/p2p/<peer id>" \
  bash -c "[[ '${CUT_BOOTSTRAP}' =~ ^/(ip4|dns4)/[^/]+/tcp/[0-9]{1,5}/p2p/12D3KooW[1-9A-HJ-NP-Za-km-z]{44}$ ]]"
check "exactly one assignment per pin (no drifted duplicate)" bash -c "
  for k in WRFCOIN_CUT_CORE4_COMMIT WRFCOIN_CUT_GENESIS_HASH WRFCOIN_CUT_CHAIN_ID WRFCOIN_CUT_NETWORK_ID WRFCOIN_CUT_BOOTSTRAP; do
    [ \"\$(grep -c \"^\${k}=\" '${REAL_PINS}')\" = 1 ] || exit 1; done"
check "cut core4 == release-pins core4 (the release gate's rule)" \
  bash -c "[ '${CUT_CORE4}' = \"\$(sed -n 's/^WRFCOIN_RC_CORE4_COMMIT=//p' '${RELEASE_PINS}')\" ]"
if [ -n "${CORE4_DIR:-}" ]; then
  check "cut core4 commit resolves in CORE4_DIR" git -C "${CORE4_DIR}" cat-file -e "${CUT_CORE4}^{commit}"
else
  echo "  SKIP  cut core4 commit resolvability (set CORE4_DIR=<core4 checkout>; not counted)"
fi

# ---------------------------------------------------------------------------
# Stubs. docker/curl/tailscale record argv; nothing reaches a daemon or a host.
# ---------------------------------------------------------------------------
BIN="${TMP}/bin"; mkdir -p "${BIN}"
cat > "${BIN}/docker" <<'EOF'
#!/usr/bin/env bash
# A faithful, daemon-free docker for exactly the commands the joiner path
# issues. Named volumes are directories; `run` resolves -v mounts to host
# paths and REALLY executes the container's `sh -ec` script against them, so
# a broken extraction command fails exactly as it would in a container.
# Anything unrecognised fails (codex round 26: never fabricate success).
printf '%s\n' "$*" >> "${E2E_LOG:?}"
S="${E2E_STATE:?}"; V="${S}/volumes"; mkdir -p "${V}"
unexpected() { echo "docker-stub: unexpected command: docker $*" >&2; exit 64; }
case "$1 ${2:-}" in
  "compose version") [ $# -eq 2 ] || unexpected "$@"; echo "Docker Compose version v2-stub"; exit 0 ;;
  "info ") exit 0 ;;
  "image inspect") exit 1 ;;                                   # no cached node image
  "volume inspect") [ -d "${V}/$3" ] && exit 0 || exit 1 ;;
  "volume create") [ ! -e "${V}/$3" ] || exit 1; mkdir -p "${V}/$3"; exit 0 ;;
  "volume rm") rm -rf "${V:?}/$3"; exit 0 ;;
esac
if [ "$1" = compose ]; then
  [ "$*" = "compose -f docker-compose.testnet.yml -f docker-compose.override.yml up -d --build postgres redis wrfcoin-node" ] \
    || unexpected "$@"
  [ "${WRFCOIN_MIN_WORK_FACTOR:-missing}" = 0 ] || {
    echo 'testnet work-factor environment must be 0' >&2; exit 65;
  }
  if [ "${WRFCOIN_CHAIN_ID:-}" = 888 ]; then
    python3 - "${S}/bootstrap.json" <<'PY'
import json, os, sys
keys = sorted(k for k in os.environ if k.startswith(('WRFCOIN_GENESIS_', 'WRFCOIN_SIGNING_PROTOCOL_VERSION')))
with open(sys.argv[1], 'w') as handle:
    json.dump({key: os.environ.get(key) for key in keys}, handle)
PY
  fi
  echo started > "${S}/compose-up"; exit 0
fi
[ "$1" = run ] || unexpected "$@"
shift
mounts=(); platform=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rm) shift ;;
    --platform) platform="$2"; shift 2 ;;
    -v) mounts+=("$2"); shift 2 ;;
    -*) unexpected run "$@" ;;
    *) break ;;
  esac
done
image="$1"; shift
[ "${image}" = alpine:3.20 ] || unexpected run "${image}" "$@"
if [ "$*" = "uname -m" ] && [ ${#mounts[@]} -eq 0 ]; then
  [ "${platform}" = linux/amd64 ] && echo x86_64 || echo aarch64; exit 0
fi
[ "$1" = sh ] && [ "$2" = -ec ] && [ $# -eq 3 ] || unexpected run "${image}" "$@"
script="$3"
# Resolve mounts: "name:/dst[:ro]" -> ${V}/name (must exist); "/host:/dst[:ro]" -> /host (must exist).
map=()
for m in "${mounts[@]}"; do
  src="${m%%:*}"; rest="${m#*:}"; dst="${rest%%:*}"
  case "${src}" in
    /*) [ -d "${src}" ] || { echo "docker-stub: bind source ${src} missing" >&2; exit 125; }; host="${src}" ;;
    *)  [ -d "${V}/${src}" ] || { echo "docker-stub: volume ${src} missing" >&2; exit 125; }; host="${V}/${src}" ;;
  esac
  map+=("${dst}=${host}")
done
mapped="$(python3 - "${script}" "${map[@]}" <<'PYM'
import re, sys
script, pairs = sys.argv[1], [p.split('=', 1) for p in sys.argv[2:]]
for dst, host in sorted(pairs, key=lambda p: -len(p[0])):
    script = re.sub(re.escape(dst) + r'(?=/|\s|$)', host.replace('\\', r'\\'), script)
print(script)
PYM
)"
sh -ec "${mapped}"
EOF
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_CURL_LOG:?}"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; --proto) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
case "${url}" in
  file://*) cp "${url#file://}" "${out:?}" ;;           # join-snapshot-restore --base-url file://
  http://localhost:8556/readyz) exit 0 ;;
  http://localhost:8556/network/info)
    printf '{"network_id":"%s","chain_id":"%s","genesis_hash":"0x%s","chain_height":16500,"peer_count":1,"sync_status":"syncing"}' \
      "${E2E_NODE_NETWORK:?}" "${E2E_NODE_CHAIN:?}" "${E2E_NODE_GENESIS:?}" ;;
  *) exit 7 ;;
esac
EOF
cat > "${BIN}/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$1" in status) echo "100.64.0.1 wrfcoin-testnet tagged-devices linux -" ;; ip) : ;; esac
EOF
chmod +x "${BIN}/docker" "${BIN}/curl" "${BIN}/tailscale"

# A real loopback listener for check-p2p-external-addr.sh's self-dial.
python3 - > "${TMP}/port" <<'PY' &
import socket, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(64); print(s.getsockname()[1], flush=True)
s.settimeout(1.0); end = time.time() + 900
while time.time() < end:
    try: c, _ = s.accept(); c.close()
    except socket.timeout: pass
PY
LISTENER_PID=$!
for _ in $(seq 1 50); do [ -s "${TMP}/port" ] && break; sleep 0.1; done
PORT="$(cat "${TMP}/port")"
[ -n "${PORT}" ] || { echo "FATAL: loopback listener did not start" >&2; exit 1; }
ADVERTISE="/ip4/127.0.0.1/tcp/${PORT}"

# ---------------------------------------------------------------------------
# Workspace factory: <ws>/infra (git) + <ws>/core4 (git, pin + a newer HEAD).
# ---------------------------------------------------------------------------
gitq() { git -c user.name=e2e -c user.email=e2e@invalid -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

make_ws() {
  # make_ws <name>  -> prints the ws path; sets nothing global
  local ws="${TMP}/$1"
  mkdir -p "${ws}/infra" "${ws}/core4"
  cp -a "${REPO}/testnet" "${ws}/infra/testnet"
  rm -f "${ws}/infra/testnet/.env" "${ws}/infra/testnet/.core4-commit"
  gitq -C "${ws}/infra" init -q
  gitq -C "${ws}/core4" init -q
  printf 'cut\n' > "${ws}/core4/README"; gitq -C "${ws}/core4" add README; gitq -C "${ws}/core4" commit -qm cut
  gitq -C "${ws}/core4" rev-parse HEAD > "${ws}/pin"
  printf 'newer\n' >> "${ws}/core4/README"; gitq -C "${ws}/core4" commit -qam newer   # operator's stale/newer checkout
  # The workspace pins: the committed file with ONLY the core4 line re-pointed.
  python3 - "${ws}/infra/testnet/cut-pins.env" "$(cat "${ws}/pin")" <<'PY'
import re, sys
p, pin = sys.argv[1], sys.argv[2]; s = open(p).read()
s, n = re.subn(r'(?m)^WRFCOIN_CUT_CORE4_COMMIT=.*$', 'WRFCOIN_CUT_CORE4_COMMIT=' + pin, s)
assert n == 1, n
open(p, 'w').write(s)
PY
  # The operator's own config: the example, as documented (#762 shape) — but
  # joined BEFORE a re-cut, so its seed is stale. The script, not the
  # template, must be what puts the pinned seed in place (the template
  # happens to carry the current one, which would hide a missing write).
  cp "${ws}/infra/testnet/.env.testnet.example" "${ws}/infra/testnet/.env"
  # Exercise an old operator file, rather than relying on the template's 0.
  sed -i '/^WRFCOIN_MIN_WORK_FACTOR=/d' "${ws}/infra/testnet/.env"
  printf '\nWRFCOIN_MIN_WORK_FACTOR=93\n' >> "${ws}/infra/testnet/.env"
  sed -i 's|^BOOTSTRAP_PEERS=.*|BOOTSTRAP_PEERS=/ip4/192.0.2.44/tcp/9000/p2p/12D3KooWStaleSeedFromBeforeTheReCutxxxxxxxxxxxxxx|' "${ws}/infra/testnet/.env"
  # Snapshot fixture bound to the CUT pins (hash-bound manifest).
  mkdir -p "${ws}/snap/src"
  printf 'redb-fixture' > "${ws}/snap/src/wrfcoin.redb"
  tar czf "${ws}/snap/snapshot.tar.gz" -C "${ws}/snap/src" wrfcoin.redb
  make_manifest "${ws}/snap/manifest.json" "${ws}/snap/snapshot.tar.gz" "${CUT_GENESIS}" "${CUT_CHAIN}" "${CUT_NETWORK}"
  : > "${ws}/docker.log"; : > "${ws}/curl.log"; mkdir -p "${ws}/state"
  printf '%s' "${ws}"
}
make_manifest() {
  # make_manifest <out> <archive> <genesis> <chain> <network>
  cat > "$1" <<MAN
{
  "file": "snapshot.tar.gz",
  "sha256": "$(sha256sum "$2" | cut -d' ' -f1)",
  "size_bytes": $(stat -c %s "$2"),
  "height": 16416,
  "state_root_hex": "$(printf 'a%.0s' $(seq 1 64))",
  "genesis_hash": "0x$3",
  "chain_id": "$4",
  "network_id": "$5",
  "core4_commit": "$(cat "$(dirname "$(dirname "$1")")/pin")",
  "created_utc": "2026-09-26T00:00:00Z",
  "source": "e2e-fixture"
}
MAN
}

# run_join <ws> [join.sh args...]; env E2E_NODE_* choose what the stub node reports.
run_join() {
  local ws="$1"; shift
  ( cd "${ws}" && env -u WRFCOIN_P2P_EXTERNAL_ADDR -u WRFCOIN_SEED_P2P_EXTERNAL_ADDR -u CUT_PINS_FILE -u CORE4_PIN \
      PATH="${BIN}:${PATH}" E2E_LOG="${ws}/docker.log" E2E_CURL_LOG="${ws}/curl.log" E2E_STATE="${ws}/state" \
      E2E_NODE_GENESIS="${E2E_NODE_GENESIS:-${CUT_GENESIS}}" E2E_NODE_CHAIN="${E2E_NODE_CHAIN:-${CUT_CHAIN}}" \
      E2E_NODE_NETWORK="${E2E_NODE_NETWORK:-${CUT_NETWORK}}" \
      WRFCOIN_MIN_WORK_FACTOR=71 \
      ${CORE4_PIN:+CORE4_PIN="${CORE4_PIN}"} \
      BOOTSTRAP_PEERS="${TEST_BOOTSTRAP}" WRFCOIN_P2P_EXTERNAL_ADDR="${ADVERTISE}" \
      bash "${ws}/infra/testnet/join.sh" "$@" ) > "${ws}/out.log" 2>&1
}
env_val() { sed -n "s/^$2=//p" "$1/infra/testnet/.env" | tail -1; }
not_started() { [ ! -e "$1/state/compose-up" ] && ! grep -q 'volume create' "$1/docker.log"; }

# ---------------------------------------------------------------------------
# The happy path, asserted as a whole (reused by the mutation controls).
# ---------------------------------------------------------------------------
happy_path_holds() {
  local ws="$1" pin; pin="$(cat "${ws}/pin")"
  grep -q 'Chain identity verified' "${ws}/out.log" || { echo "    (no identity verification)" >&2; return 1; }
  [ "$(gitq -C "${ws}/core4" rev-parse HEAD)" = "${pin}" ] || { echo "    (core4 not at the pin)" >&2; return 1; }
  [ "$(cat "${ws}/infra/testnet/.core4-commit")" = "${pin}" ] || { echo "    (.core4-commit != pin)" >&2; return 1; }
  [ "$(env_val "${ws}" WRFCOIN_GENESIS_HASH)" = "${CUT_GENESIS}" ] || { echo "    (.env genesis)" >&2; return 1; }
  [ "$(env_val "${ws}" WRFCOIN_CHAIN_ID)" = "${CUT_CHAIN}" ] || { echo "    (.env chain)" >&2; return 1; }
  [ "$(env_val "${ws}" WRFCOIN_MIN_WORK_FACTOR)" = 0 ] || { echo "    (.env work factor)" >&2; return 1; }
  [ "$(env_val "${ws}" WRFCOIN_NETWORK_ID)" = "${CUT_NETWORK}" ] || { echo "    (.env network)" >&2; return 1; }
  [ "$(env_val "${ws}" BOOTSTRAP_PEERS)" = "${TEST_BOOTSTRAP}" ] || { echo "    (.env bootstrap != pinned seed)" >&2; return 1; }
  if ! { [ "$(env_val "${ws}" WRFCOIN_SYNC_ONLY)" = 1 ] && [ -z "$(env_val "${ws}" WRFCOIN_HSM_PIN)" ]; }; then echo "    (not sync-only)" >&2; return 1; fi
  # restore (volume create + unpack) strictly before the node is started
  local vc up
  vc="$(grep -n '^volume create testnet_node-data$' "${ws}/docker.log" | head -1 | cut -d: -f1)"
  up="$(grep -n '^compose -f docker-compose.testnet.yml -f docker-compose.override.yml up -d --build postgres redis wrfcoin-node$' "${ws}/docker.log" | head -1 | cut -d: -f1)"
  if ! { [ -n "${vc}" ] && [ -n "${up}" ] && [ "${vc}" -lt "${up}" ] && [ "$(cat "${ws}/state/volumes/testnet_node-data/wrfcoin.redb" 2>/dev/null)" = redb-fixture ]; }; then
    echo "    (restore not before start)" >&2; return 1
  fi
  grep -q 'http://localhost:8556/network/info' "${ws}/curl.log"
}

echo "== the docker stub fails closed =="
stub_rejects() { ! PATH="${BIN}:${PATH}" E2E_LOG="${TMP}/stub.log" E2E_STATE="${TMP}/stub-state" docker "$@" >/dev/null 2>&1; }
check "unknown docker command fails (pull)" stub_rejects pull alpine:3.20
check "unknown run shape fails (sh -c, other image, unknown flag)" bash -c "
  $(declare -f stub_rejects); BIN='${BIN}' TMP='${TMP}'
  stub_rejects run --rm alpine:3.20 sh -c 'true' && stub_rejects run --rm busybox sh -ec 'true' && stub_rejects run --privileged alpine:3.20 uname -m"
check "run with a missing volume or bind source fails" bash -c "
  $(declare -f stub_rejects); BIN='${BIN}' TMP='${TMP}'
  stub_rejects run --rm -v nosuchvol:/data alpine:3.20 sh -ec 'true' && stub_rejects run --rm -v /definitely-missing:/src:ro alpine:3.20 sh -ec 'true'"
check "compose other than the documented join 'up' fails" stub_rejects compose -f docker-compose.testnet.yml up -d

echo "== e2e: join.sh -> join-testnet-sync-node.sh -> join-snapshot-restore.sh =="
WS="$(make_ws happy)"
happy_dir() { run_join "${WS}" --snapshot "${WS}/snap" --yes && happy_path_holds "${WS}"; }
check "happy path (snapshot dir): pinned core4, cut identity, pinned seed, restore before start" happy_dir

WS_URL="$(make_ws happy-url)"
happy_url() { run_join "${WS_URL}" --snapshot "file://${WS_URL}/snap" --yes && happy_path_holds "${WS_URL}"; }
check "happy path (snapshot URL, file://): same guarantees" happy_url

prepare_888() {
  local ws="$1"
  # Replace, not duplicate, any reviewed declarations the committed pins carry.
  sed -i -e 's/^WRFCOIN_CUT_CHAIN_ID=.*/WRFCOIN_CUT_CHAIN_ID=888/' \
    -e '/^WRFCOIN_GENESIS_[A-Z_]*=/d' -e '/^WRFCOIN_SIGNING_PROTOCOL_VERSION=/d' \
    "${ws}/infra/testnet/cut-pins.env"
  cat >> "${ws}/infra/testnet/cut-pins.env" <<'PINS'
WRFCOIN_GENESIS_ORACLE_SET='{"oracle_set":[{"oracle_id":"synthetic"}],"oracle_quorum":1}'
WRFCOIN_GENESIS_SCHEDULE_GOVERNANCE_KEYS='5555555555555555555555555555555555555555555555555555555555555555'
WRFCOIN_GENESIS_FAUCET_ALLOCATION_BASE_UNITS='10000'
WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS='20'
WRFCOIN_GENESIS_FLAT_REWARD_SECONDS='600'
WRFCOIN_GENESIS_NODE_SHARE_EPOCH_BLOCKS='512'
WRFCOIN_GENESIS_NODE_SHARE_CHALLENGE_BLOCKS='512'
WRFCOIN_SIGNING_PROTOCOL_VERSION='1'
WRFCOIN_GENESIS_ACTIVATION_SCHEDULE='0:v1,2:schedule_extension,2:node_share_settlement'
WRFCOIN_GENESIS_PRODUCER_SET='{"version":1,"members":[{"producer_id":"synthetic","payout_address":"0x1111111111111111111111111111111111111111","public_key":"2222222222222222222222222222222222222222222222222222222222222222"}]}'
PINS
}
fresh_888_bootstrap() {
  local ws; ws="$(make_ws fresh-888-bootstrap)"
  prepare_888 "${ws}"
  E2E_NODE_CHAIN=888 WRFCOIN_GENESIS_HASH=stale WRFCOIN_GENESIS_ACTIVATION_SCHEDULE=stale \
    WRFCOIN_GENESIS_PRODUCER_SET=stale run_join "${ws}" --yes || return 1
  [ "$(env_val "${ws}" WRFCOIN_MIN_WORK_FACTOR)" = 0 ] || return 1
  grep -q 'syncing from genesis' "${ws}/out.log" || return 1
  grep -q 'Chain identity verified' "${ws}/out.log" && [ -e "${ws}/state/compose-up" ] || return 1
  python3 - "${ws}" "${CUT_GENESIS}" <<'PY'
import json, pathlib, runpy, sys
ws = pathlib.Path(sys.argv[1])
captured = json.loads((ws / 'state/bootstrap.json').read_text())
assert captured['WRFCOIN_GENESIS_HASH'] == sys.argv[2]
assert captured['WRFCOIN_GENESIS_ACTIVATION_SCHEDULE'] == '0:v1,2:schedule_extension,2:node_share_settlement'
assert json.loads(captured['WRFCOIN_GENESIS_PRODUCER_SET'])['members'][0]['producer_id'] == 'synthetic'
assert json.loads(captured['WRFCOIN_GENESIS_ORACLE_SET'])['oracle_set'][0]['oracle_id'] == 'synthetic'
assert captured['WRFCOIN_GENESIS_SCHEDULE_GOVERNANCE_KEYS'] == '5' * 64
assert captured['WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS'] == '20'
assert captured['WRFCOIN_SIGNING_PROTOCOL_VERSION'] == '1'
# The joiner exports every genesis input the cutter was started with (Compose
# hands them to the node via bootstrap.888.env; test_node_bootstrap.py renders it).
import re
cutter = set(re.findall(r'^  (WRFCOIN_[A-Z0-9_]+): \$\{\1:\?',
                        (ws / 'infra/testnet/docker-compose.genesis.yml').read_text(), re.M)) - {'WRFCOIN_CHAIN_ID'}
assert cutter <= set(captured), sorted(cutter - set(captured))
value = runpy.run_path(str(ws / 'infra/testnet/scripts/chain-identity.py'))['value']
for key, expected in captured.items():
    assert value(ws / 'infra/testnet/.env', key) == expected
PY
}
check "fresh 888 join: every reviewed genesis declaration reaches .env and the node despite stale shell" fresh_888_bootstrap

missing_888_bootstrap() {
  local key="$1" ws; ws="$(make_ws "missing-${key}")"
  prepare_888 "${ws}"
  sed -i "/^${key}=/d" "${ws}/infra/testnet/cut-pins.env"
  if E2E_NODE_CHAIN=888 WRFCOIN_GENESIS_HASH=stale WRFCOIN_GENESIS_ACTIVATION_SCHEDULE=stale \
      WRFCOIN_GENESIS_PRODUCER_SET=stale run_join "${ws}" --yes; then return 1; fi
  grep -q "${key}" "${ws}/out.log" && not_started "${ws}"
}
for key in WRFCOIN_CUT_GENESIS_HASH WRFCOIN_CUT_GENESIS_FAUCET_ADDRESS WRFCOIN_GENESIS_ACTIVATION_SCHEDULE \
    WRFCOIN_GENESIS_PRODUCER_SET WRFCOIN_GENESIS_ORACLE_SET WRFCOIN_GENESIS_SCHEDULE_GOVERNANCE_KEYS \
    WRFCOIN_GENESIS_FAUCET_ALLOCATION_BASE_UNITS WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS \
    WRFCOIN_GENESIS_FLAT_REWARD_SECONDS WRFCOIN_GENESIS_NODE_SHARE_EPOCH_BLOCKS \
    WRFCOIN_GENESIS_NODE_SHARE_CHALLENGE_BLOCKS WRFCOIN_SIGNING_PROTOCOL_VERSION; do
  check "fresh 888 missing ${key}: refused before volume creation/startup" missing_888_bootstrap "${key}"
done

# Producer handoff (infra#1057): JOIN_E2E_SNAPSHOT_DIR names a directory
# holding a bundle made by the REAL publish-join-snapshot.sh + promote step
# (scripts/tests/test-join-snapshot.sh sets it). The same joiner chain must
# restore that bundle, byte for byte, from a dir and over a URL. Its redb is
# the literal "redb-fixture", so happy_path_holds' content check applies.
if [ -n "${JOIN_E2E_SNAPSHOT_DIR:-}" ]; then
  use_published() {
    local ws="$1"
    cp "${JOIN_E2E_SNAPSHOT_DIR}/manifest.json" "${JOIN_E2E_SNAPSHOT_DIR}/snapshot.tar.gz" "${ws}/snap/"
    # The workspace re-points the core4 pin at its own fixture commit, so the
    # published manifest's core4_commit (the COMMITTED pin, asserted by
    # test-join-snapshot.sh) is swapped for it here; nothing else, and the
    # archive bytes are untouched.
    sed -i "s/\"core4_commit\": \"[0-9a-f]*\"/\"core4_commit\": \"$(cat "${ws}/pin")\"/" "${ws}/snap/manifest.json"
    rm -f "${ws}/snap/src/wrfcoin.redb"; tar xzf "${ws}/snap/snapshot.tar.gz" -C "${ws}/snap/src"
    ! grep -q '"source": "e2e-fixture"' "${ws}/snap/manifest.json"
  }
  WS_PUB="$(make_ws published)"; WS_PUB_URL="$(make_ws published-url)"
  pub_dir() { use_published "${WS_PUB}" && run_join "${WS_PUB}" --snapshot "${WS_PUB}/snap" --yes && happy_path_holds "${WS_PUB}"; }
  pub_url() { use_published "${WS_PUB_URL}" && run_join "${WS_PUB_URL}" --snapshot "file://${WS_PUB_URL}/snap" --yes && happy_path_holds "${WS_PUB_URL}"; }
  check "happy path (PUBLISHED bundle from ${JOIN_E2E_SNAPSHOT_DIR}, dir): restored before start" pub_dir
  check "happy path (PUBLISHED bundle over file:// URL): same guarantees" pub_url
  if [ "${JOIN_E2E_ONLY_PUBLISHED:-0}" = 1 ]; then
    echo ""; echo "${assertions} assertions, ${fails} failures (JOIN_E2E_ONLY_PUBLISHED: remaining cases not run)"
    [ "${fails}" -eq 0 ]; exit
  fi
fi

check "operator's advertise address was dialed for real (loopback) and preserved" \
  grep -q "PASS: ${ADVERTISE} accepted a TCP connection" "${WS}/out.log"

echo "== e2e refusals: mismatched pins =="
refused() {
  # refused <ws> <expected text> [join args...]: nonzero, text present, nothing started
  local ws="$1" want="$2"; shift 2
  if run_join "${ws}" "$@"; then echo "    (unexpected success)" >&2; return 1; fi
  grep -qF -- "${want}" "${ws}/out.log" || { echo "    (missing: ${want})" >&2; tail -3 "${ws}/out.log" >&2; return 1; }
}
node_wrong() {
  local ws; ws="$(make_ws "node-$1")"
  refused "${ws}" "$2" --snapshot "${ws}/snap" --yes
}
wrong_genesis() { E2E_NODE_GENESIS="$(printf 'b%.0s' $(seq 1 64))" node_wrong genesis "genesis_hash mismatch"; }
wrong_chain()   { E2E_NODE_CHAIN=778 node_wrong chain "chain_id mismatch"; }
wrong_network() { E2E_NODE_NETWORK=mainnet node_wrong network "network_id mismatch"; }
check "node on another genesis -> refused (exit 1, named)" wrong_genesis
check "node on another chain id -> refused" wrong_chain
check "node on another network id -> refused" wrong_network

snap_refused() {
  # snap_refused <name> <mutator fn> <expected text>: refused BEFORE any volume or node start,
  # and by THAT guard: no other restore refusal may be what stopped it (codex round 26).
  local ws; ws="$(make_ws "snap-$1")"; "$2" "${ws}"
  refused "${ws}" "$3" --snapshot "${ws}/snap" --yes && not_started "${ws}" || return 1
  if [ "$3" = "sha256 mismatch" ] && grep -qE 'not a readable tar.gz|exactly one root member|must be a regular file|manifest (genesis|chain|network)' "${ws}/out.log"; then
    echo "    (refused by another guard, not the hash)" >&2; return 1
  fi
}
tamper_archive()   { printf 'x' >> "$1/snap/snapshot.tar.gz"; }
swap_archive()     { printf 'another-state' > "$1/snap/src/wrfcoin.redb"; tar czf "$1/snap/snapshot.tar.gz" -C "$1/snap/src" wrfcoin.redb; }
wrong_chain_snap() { make_manifest "$1/snap/manifest.json" "$1/snap/snapshot.tar.gz" "$(printf 'c%.0s' $(seq 1 64))" "${CUT_CHAIN}" "${CUT_NETWORK}"; }
check "tampered archive (sha256 != manifest) -> refused before any volume/node" \
  snap_refused tamper tamper_archive "sha256 mismatch"
check "well-formed archive of another state beside the manifest -> refused before any volume/node" \
  snap_refused swap swap_archive "sha256 mismatch"
check "snapshot manifest for another genesis -> refused before any volume/node" \
  snap_refused chain wrong_chain_snap "genesis_hash mismatch"

# Legacy chain 777 (the #2806 wedge at block 11,016) is no longer what the
# committed pins name, so these cases get a PRIVATE 777 pins fixture: the
# workspace copy re-pointed to chain 777, without the 888-only bootstrap
# declarations, with a manifest and node stub that also say 777.
make_ws_777() {
  local ws; ws="$(make_ws "$1")"
  sed -i -e 's/^WRFCOIN_CUT_CHAIN_ID=.*/WRFCOIN_CUT_CHAIN_ID=777/' \
    -e '/^WRFCOIN_GENESIS_ACTIVATION_SCHEDULE=/d' -e '/^WRFCOIN_GENESIS_PRODUCER_SET=/d' \
    "${ws}/infra/testnet/cut-pins.env"
  make_manifest "${ws}/snap/manifest.json" "${ws}/snap/snapshot.tar.gz" "${CUT_GENESIS}" 777 "${CUT_NETWORK}"
  printf '%s' "${ws}"
}
no_snapshot_refused() {
  local ws; ws="$(make_ws_777 nosnap)"
  E2E_NODE_CHAIN=777 refused "${ws}" "core4#2806" --yes && not_started "${ws}"
}
check "brand-new node without a snapshot -> refused, names core4#2806" no_snapshot_refused

echo "== e2e refusals: the core4 pin (join.sh) =="
pin_unknown() {
  local ws; ws="$(make_ws pin-unknown)"
  sed -i "s/^WRFCOIN_CUT_CORE4_COMMIT=.*/WRFCOIN_CUT_CORE4_COMMIT=$(printf 'd%.0s' $(seq 1 40))/" "${ws}/infra/testnet/cut-pins.env"
  refused "${ws}" "not found after fetching" --snapshot "${ws}/snap" --yes && not_started "${ws}" \
    && [ ! -e "${ws}/infra/testnet/.core4-commit" ]
}
check "pin absent from core4 (and unfetchable) -> refused, nothing built" pin_unknown
dirty_core4() {
  local ws; ws="$(make_ws dirty)"; printf 'local edit\n' >> "${ws}/core4/README"
  refused "${ws}" "uncommitted changes" --snapshot "${ws}/snap" --yes && not_started "${ws}" \
    && grep -q 'local edit' "${ws}/core4/README"
}
check "dirty core4 at another commit -> refused, operator's work untouched" dirty_core4
pins_without_core4() {
  local ws; ws="$(make_ws nopin)"; sed -i '/^WRFCOIN_CUT_CORE4_COMMIT=/d' "${ws}/infra/testnet/cut-pins.env"
  refused "${ws}" "does not define WRFCOIN_CUT_CORE4_COMMIT" --snapshot "${ws}/snap" --yes && not_started "${ws}"
}
check "cut-pins.env without the core4 line -> refused by name" pins_without_core4
override_announced() {
  local ws first; ws="$(make_ws override)"; first="$(gitq -C "${ws}/core4" rev-parse HEAD)"
  CORE4_PIN="${first}" run_join "${ws}" --snapshot "${ws}/snap" --yes || return 1
  grep -q "CORE4_PIN is overridden" "${ws}/out.log" && [ "$(cat "${ws}/infra/testnet/.core4-commit")" = "${first}" ]
}
check "CORE4_PIN override is announced and recorded as the real build commit" override_announced

echo "== RED controls: the same e2e must fail on a broken joiner (#769 standard) =="
# mutate <ws> <relative file> <python regex> <replacement>: must apply exactly once.
mutate() {
  python3 - "$1/infra/testnet/$2" "$3" "$4" <<'PY'
import re, sys
p, pat, rep = sys.argv[1:4]; s = open(p).read()
s2, n = re.subn(pat, rep, s, count=1, flags=re.M)
if n != 1: sys.exit(f"MUTATION DID NOT APPLY to {p}: {pat!r}")
open(p, 'w').write(s2)
PY
}
red_control() {
  # red_control <name> <file> <pattern> <replacement> <expected reason>:
  # the happy path must NOT hold, and it must fail for the EXPECTED reason
  # (a mutant that dies of something incidental proves nothing).
  local ws name="$1" file="$2" pat="$3" rep="$4" why="$5" reason
  ws="$("${RED_WS:-make_ws}" "red-${name}")"
  mutate "${ws}" "${file}" "${pat}" "${rep}" || return 1
  run_join "${ws}" --snapshot "${ws}/snap" --yes
  if reason="$(happy_path_holds "${ws}" 2>&1)"; then echo "    (mutant ${name} survived)" >&2; return 1; fi
  reason="${reason} $(tail -5 "${ws}/out.log")"
  grep -qF -- "${why}" <<<"${reason}" || { echo "    (mutant ${name} failed for another reason: ${reason})" >&2; return 1; }
}
check "RED join.sh: pin check skipped (node built from whatever is checked out)" \
  red_control skip-pin join.sh '^check_core4_pin "\$\{ROOT\}/core4" "\$\{CORE4_PIN\}" \\\n  \|\| die .*$' ':' '(core4 not at the pin)'
check "RED join.sh: default pin hardcoded instead of read from cut-pins.env" \
  red_control literal-pin join.sh '^CORE4_PIN_DEFAULT=.*$' 'CORE4_PIN_DEFAULT="HEAD"' '(core4 not at the pin)'
check "RED sync-node: bootstrap not taken from the pinned seed" \
  red_control wrong-seed join-testnet-sync-node.sh '^BOOTSTRAP_PEERS=.*$' 'BOOTSTRAP_PEERS="/ip4/192.0.2.1/tcp/9000"' '(.env bootstrap != pinned seed)'
check "RED sync-node: pinned seed never written (stale operator seed kept)" \
  red_control no-seed-write join-testnet-sync-node.sh '^set_env BOOTSTRAP_PEERS .*$' ':' '(.env bootstrap != pinned seed)'
check "RED sync-node: genesis pin not written to .env" \
  red_control no-genesis join-testnet-sync-node.sh '^set_env WRFCOIN_GENESIS_HASH .*$' ':' '(.env genesis)'
check "RED sync-node: stale persisted work factor survives without explicit write" \
  red_control no-work-write join-testnet-sync-node.sh '^set_env WRFCOIN_MIN_WORK_FACTOR .*$' ':' '(.env work factor)'
check "RED sync-node: stale exported work factor overrides Compose without explicit export" \
  red_control no-work-export join-testnet-sync-node.sh '^export WRFCOIN_MIN_WORK_FACTOR=0$' ':' 'testnet work-factor environment must be 0'
red_no_restore_777() {
  RED_WS=make_ws_777 E2E_NODE_CHAIN=777 red_control no-restore join-testnet-sync-node.sh '^  if \[ -n "\$\{SNAPSHOT_SOURCE\}" \]; then\n    echo "==> Brand-new node' '  if false; then\n    echo "==> Brand-new node' 'core4#2806'
}
check "RED sync-node: snapshot restore skipped (full sync into the #2806 wedge)" red_no_restore_777
red_identity() {
  # Protecting check: wrong_genesis (refused, named). On this mutant it must FAIL.
  local ws; ws="$(make_ws red-identity)"
  mutate "${ws}" join-testnet-sync-node.sh '^  if \[ "\$\{identity_ok\}" != "1" \]; then' '  if false; then' || return 1
  ! E2E_NODE_GENESIS="$(printf 'b%.0s' $(seq 1 64))" refused "${ws}" "genesis_hash mismatch" --snapshot "${ws}/snap" --yes 2>/dev/null \
    || ! grep -q '^ERROR: genesis_hash mismatch' "${ws}/out.log" \
    || grep -q 'Chain identity verified' "${ws}/out.log"
}
check "RED sync-node: identity gate removed -> the wrong-genesis refusal no longer holds" red_identity
# hash_bypass_observed <ws>: the swapped (well-formed, other-state) archive was
# NOT refused by hash, was restored byte for byte into the node volume, and the
# node was started. Only a real hash bypass produces all three; an unrelated
# exit (e.g. `return 73`) produces none (codex round 26).
hash_bypass_observed() {
  local ws="$1"
  run_join "${ws}" --snapshot "${ws}/snap" --yes || { echo "    (mutant exited nonzero: $(tail -1 "${ws}/out.log"))" >&2; return 1; }
  ! grep -q 'sha256 mismatch' "${ws}/out.log" || return 1
  [ "$(cat "${ws}/state/volumes/testnet_node-data/wrfcoin.redb" 2>/dev/null)" = another-state ] || { echo "    (swapped bytes not restored)" >&2; return 1; }
  [ -e "${ws}/state/compose-up" ]
}
red_hash() {
  # Intact guard refuses the swapped archive by hash (checked above). With the
  # hash check removed, the swapped archive must be RESTORED and the node started.
  local ws; ws="$(make_ws red-hash)"
  mutate "${ws}" join-snapshot-restore.sh '^  jsr_verify_archive "\$\{manifest_path\}" "\$\{archive_path\}" \|\| return 1$' '  :' || return 1
  swap_archive "${ws}"
  hash_bypass_observed "${ws}"
}
check "RED restore: sha256 check removed -> the other-state archive is restored and started (hash bypass observed)" red_hash
control_rejects_unrelated_exit() {
  # Meta-control: replacing the hash call with an unrelated failure must NOT
  # count as a hash bypass (the old control accepted it).
  local ws; ws="$(make_ws red-hash-73)"
  mutate "${ws}" join-snapshot-restore.sh '^  jsr_verify_archive "\$\{manifest_path\}" "\$\{archive_path\}" \|\| return 1$' '  return 73' || return 1
  swap_archive "${ws}"
  ! hash_bypass_observed "${ws}" 2>/dev/null
}
check "meta: hash call -> 'return 73' is NOT mistaken for a hash bypass" control_rejects_unrelated_exit
red_broken_extract() {
  # codex round 26: the restorer extracts from a path that is not the mounted archive.
  local ws; ws="$(make_ws red-extract)"
  mutate "${ws}" join-snapshot-restore.sh 'tar xzf /src/\$\{archive_file\} -C /data' 'tar xzf /definitely-missing/snapshot.tar.gz -C /data' || return 1
  run_join "${ws}" --snapshot "${ws}/snap" --yes
  if happy_path_holds "${ws}" 2>/dev/null; then echo "    (broken extract survived)" >&2; return 1; fi
  grep -q 'unpack failed' "${ws}/out.log" && [ ! -e "${ws}/state/compose-up" ] \
    && [ ! -e "${ws}/state/volumes/testnet_node-data" ]
}
check "RED restore: extraction reads a path that is not the mounted archive -> unpack fails, volume removed, node never started" red_broken_extract
red_wrong_volume() {
  # The restore unpacks into a different volume than the node uses.
  local ws; ws="$(make_ws red-volume)"
  # shellcheck disable=SC1003  # the regex deliberately matches the literal line-continuation backslash
  mutate "${ws}" join-snapshot-restore.sh '-v "\$\{volume\}:/data" \\' '-v "scratch-vol:/data" \\' || return 1
  run_join "${ws}" --snapshot "${ws}/snap" --yes
  ! happy_path_holds "${ws}" 2>/dev/null
}
check "RED restore: unpack into a volume other than the node's -> refused by the stub (unknown volume) / not restored" red_wrong_volume

echo ""
echo "${assertions} assertions, ${fails} failures"
[ "${fails}" -eq 0 ]
