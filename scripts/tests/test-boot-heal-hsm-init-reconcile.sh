#!/usr/bin/env bash
# Hermetic behavior tests for CT101 HSM-safe boot reconciliation (infra#830).
# Docker, findmnt, find, health, and P2P are test doubles; no daemon, container,
# volume, HSM, mount, or network state is touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/testnet/boot-heal.sh"
SOURCE_COMPOSE_INPUTS="${REPO_ROOT}/testnet/lib/compose-inputs.sh"
SOURCE_CUSTODY_CONFIG="${REPO_ROOT}/testnet/provisioning/ct101-hsm-init-custody.conf"
SOURCE_SYSTEMD_UNIT="${REPO_ROOT}/testnet/systemd/wrfcoin-testnet.service"
REVIEWED_LIVE_HSM_INIT_IMAGE_ID="sha256:3e66b3f8b4d254bef00904059001401568174de2797771dbfbcf851316051e82"
TMP_DIR="$(mktemp -d)"
# Everything above the "seed retired" section runs with the seed profile ACTIVE:
# that is the rollback configuration, and it keeps the full two-owner custody
# coverage. The seed-retired (profile inactive) cases set their own value.
export COMPOSE_PROFILES=seed
FIXTURE_DIR="${TMP_DIR}/testnet"
BIN_DIR="${TMP_DIR}/bin"
CUSTODY_CONFIG="${FIXTURE_DIR}/hsm-init-custody.conf"
ASSERTIONS=0
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  ASSERTIONS=$((ASSERTIONS + 1))
  printf '  ok    %s\n' "$*"
}

source_image_pin_is_exact() {
  local config="$1" expected="$2"
  local count value

  count="$(awk -F= '$1 == "HSM_INIT_IMAGE_IDS" { count++ } END { print count + 0 }' "${config}")"
  value="$(awk -F= '$1 == "HSM_INIT_IMAGE_IDS" { print substr($0, index($0, "=") + 1) }' "${config}")"
  [[ "${count}" -eq 1 && "${value}" == "${expected}" ]]
}

mkdir -p "${FIXTURE_DIR}/lib" "${BIN_DIR}"
cp "${SOURCE_SCRIPT}" "${FIXTURE_DIR}/boot-heal.sh"
cp "${SOURCE_COMPOSE_INPUTS}" "${FIXTURE_DIR}/lib/compose-inputs.sh"
cp "${SOURCE_CUSTODY_CONFIG}" "${CUSTODY_CONFIG}"
printf '%s\n' 'services: {}' > "${FIXTURE_DIR}/docker-compose.testnet.yml"

ALTERNATE_CUSTODY_CONFIG="${FIXTURE_DIR}/alternate-hsm-init-custody.conf"
MISSING_VALUE_CONFIG="${FIXTURE_DIR}/missing-value-hsm-init-custody.conf"
MALFORMED_DIGEST_CONFIG="${FIXTURE_DIR}/malformed-digest-hsm-init-custody.conf"
MUTABLE_IMAGE_CONFIG="${FIXTURE_DIR}/mutable-image-hsm-init-custody.conf"
SECOND_IMAGE_CONFIG="${FIXTURE_DIR}/second-image-hsm-init-custody.conf"
sed \
  -e 's#^HSM_INIT_IMAGE_IDS=.*#HSM_INIT_IMAGE_IDS=sha256:7777777777777777777777777777777777777777777777777777777777777777#' \
  -e 's#/mnt/tank-docker/docker-data/volumes/testnet_node-data/_data#/srv/wrfcoin/volumes/testnet_node-data/_data#' \
  -e 's#/mnt/tank-docker/docker-data/volumes/testnet_seed-data/_data#/srv/wrfcoin/volumes/testnet_seed-data/_data#' \
  -e 's#^HSM_INIT_NODE_CMD_SHA256=.*#HSM_INIT_NODE_CMD_SHA256=1111111111111111111111111111111111111111111111111111111111111111#' \
  -e 's#^HSM_INIT_SEED_CMD_SHA256=.*#HSM_INIT_SEED_CMD_SHA256=2222222222222222222222222222222222222222222222222222222222222222#' \
  -e 's#^HSM_INIT_NODE_ENTRYPOINT_SHA256=.*#HSM_INIT_NODE_ENTRYPOINT_SHA256=3333333333333333333333333333333333333333333333333333333333333333#' \
  -e 's#^HSM_INIT_SEED_ENTRYPOINT_SHA256=.*#HSM_INIT_SEED_ENTRYPOINT_SHA256=3333333333333333333333333333333333333333333333333333333333333333#' \
  -e 's#^HSM_INIT_NODE_HEALTHCHECK_SHA256=.*#HSM_INIT_NODE_HEALTHCHECK_SHA256=5555555555555555555555555555555555555555555555555555555555555555#' \
  -e 's#^HSM_INIT_SEED_HEALTHCHECK_SHA256=.*#HSM_INIT_SEED_HEALTHCHECK_SHA256=5555555555555555555555555555555555555555555555555555555555555555#' \
  -e 's#^HSM_INIT_NODE_PUBLIC_KEY_SHA256=.*#HSM_INIT_NODE_PUBLIC_KEY_SHA256=8888888888888888888888888888888888888888888888888888888888888888#' \
  -e 's#^HSM_INIT_SEED_PUBLIC_KEY_SHA256=.*#HSM_INIT_SEED_PUBLIC_KEY_SHA256=9999999999999999999999999999999999999999999999999999999999999999#' \
  "${CUSTODY_CONFIG}" > "${ALTERNATE_CUSTODY_CONFIG}"
grep -v '^HSM_INIT_SEED_PUBLIC_KEY_SHA256=' "${CUSTODY_CONFIG}" > "${MISSING_VALUE_CONFIG}"
sed 's/^HSM_INIT_NODE_CMD_SHA256=.*/HSM_INIT_NODE_CMD_SHA256=not-a-digest/' \
  "${CUSTODY_CONFIG}" > "${MALFORMED_DIGEST_CONFIG}"
sed 's/^HSM_INIT_IMAGE_IDS=.*/HSM_INIT_IMAGE_IDS=wrfcoin\/native-chain:testnet-local/' \
  "${CUSTODY_CONFIG}" > "${MUTABLE_IMAGE_CONFIG}"
sed "s#^HSM_INIT_IMAGE_IDS=.*#HSM_INIT_IMAGE_IDS=${REVIEWED_LIVE_HSM_INIT_IMAGE_ID},sha256:7777777777777777777777777777777777777777777777777777777777777777#" \
  "${CUSTODY_CONFIG}" > "${SECOND_IMAGE_CONFIG}"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FIXTURE_DIR}/check-health.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${FIXTURE_DIR}/check-p2p-external-addr.sh"
chmod +x "${FIXTURE_DIR}/check-health.sh" "${FIXTURE_DIR}/check-p2p-external-addr.sh"

cat > "${BIN_DIR}/findmnt" <<'SH'
#!/usr/bin/env bash
if [[ "${HSM_TEST_DATASET:-imported}" == "imported" ]]; then
  printf 'tank/docker\n'
else
  printf 'tank/not-docker\n'
fi
SH

cat > "${BIN_DIR}/find" <<'SH'
#!/usr/bin/env bash
if [[ "${HSM_TEST_DATA_ROOT:-nonempty}" == "nonempty" ]]; then
  printf '/mnt/tank-docker/docker-data/volumes\n'
fi
SH

cat > "${BIN_DIR}/sha256sum" <<'SH'
#!/usr/bin/env bash
value="$(cat)"
if [[ "${HSM_TEST_DEPLOYMENT:-ct101}" == "alternate" ]]; then
  case "${value}" in
    '["node-init"]') digest=1111111111111111111111111111111111111111111111111111111111111111 ;;
    '["seed-init"]') digest=2222222222222222222222222222222222222222222222222222222222222222 ;;
    '["entrypoint"]') digest=3333333333333333333333333333333333333333333333333333333333333333 ;;
    '["healthcheck"]') digest=5555555555555555555555555555555555555555555555555555555555555555 ;;
    *) digest=0000000000000000000000000000000000000000000000000000000000000000 ;;
  esac
else
  case "${value}" in
    '["node-init"]') digest=f9fcb52f417e84aa18dda424c7ea65e702d904e514187043dd473a86232a2f41 ;;
    '["seed-init"]') digest=60d7e1c70aca868e32259f67779e35b227d675c1cf3c39ec66e7a07d2b6bc494 ;;
    '["entrypoint"]') digest=538cf86ad1dd81e9749207d29a655500a42d3b90657e79a69da190d0b6da58d2 ;;
    '["healthcheck"]') digest=be0ed52d29f3e42d136ca7242612a4035ec40f293897940b6b32478181e7d6cc ;;
    *) digest=0000000000000000000000000000000000000000000000000000000000000000 ;;
  esac
fi
printf '%s  -\n' "${digest}"
SH

cat > "${BIN_DIR}/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${HSM_TEST_DOCKER_LOG}"

if [[ "${1:-}" == "info" ]]; then
  exit 0
fi

if [[ "${1:-}" == "exec" ]]; then
  name="${2:-}"
  case "${name}" in
    wrfcoin-testnet-softhsm-init) suffix=node; fingerprint=6d3ebaeb18b810cd4e05e832fde110f5181024a2c30180272992f2f4731d8852 ;;
    wrfcoin-testnet-seed-softhsm-init) suffix=seed; fingerprint=3d4c35e7918529da53ba39545ae9892723b8efad61e2f75541ee4c65ef9d99a5 ;;
    *) exit 1 ;;
  esac
  if [[ "${HSM_TEST_DEPLOYMENT:-ct101}" == "alternate" ]]; then
    if [[ "${suffix}" == "node" ]]; then
      fingerprint=8888888888888888888888888888888888888888888888888888888888888888
    else
      fingerprint=9999999999999999999999999999999999999999999999999999999999999999
    fi
  fi
  count_file="${HSM_TEST_STATE_DIR}/fingerprint-${suffix}.count"
  count=0
  [[ -f "${count_file}" ]] && read -r count < "${count_file}"
  count=$((count + 1))
  printf '%s\n' "${count}" > "${count_file}"
  scenario="${HSM_TEST_SCENARIO:-good}"
  [[ "${scenario}" == "fingerprint-read-fail-${suffix}" ]] && exit 1
  [[ "${scenario}" == "wrong-fingerprint-${suffix}" ]] && fingerprint=9999999999999999999999999999999999999999999999999999999999999999
  if (( count >= 2 )) && [[ "${scenario}" == "post-fingerprint-drift-${suffix}" ]]; then
    fingerprint=9999999999999999999999999999999999999999999999999999999999999999
  fi
  printf '%s\n' "${fingerprint}"
  exit 0
fi

if [[ "${1:-}" == "volume" && "${2:-}" == "inspect" ]]; then
  name="${!#}"
  case "${name}" in
    testnet_node-data) suffix=node; created=2026-06-13T16:57:20Z ;;
    testnet_seed-data) suffix=seed; created=2026-07-03T00:28:02Z ;;
    *) exit 1 ;;
  esac
  count_file="${HSM_TEST_STATE_DIR}/volume-${suffix}.count"
  count=0
  [[ -f "${count_file}" ]] && read -r count < "${count_file}"
  count=$((count + 1))
  printf '%s\n' "${count}" > "${count_file}"
  scenario="${HSM_TEST_SCENARIO:-good}"
  [[ "${scenario}" == "missing-volume-${suffix}" ]] && exit 1
  mountpoint="/mnt/tank-docker/docker-data/volumes/${name}/_data"
  if [[ "${HSM_TEST_DEPLOYMENT:-ct101}" == "alternate" ]]; then
    mountpoint="/srv/wrfcoin/volumes/${name}/_data"
  fi
  if (( count >= 2 )); then
    [[ "${scenario}" == "post-volume-created-drift-${suffix}" ]] && created=2099-01-01T00:00:00Z
    [[ "${scenario}" == "post-volume-mount-drift-${suffix}" ]] && mountpoint=/wrong
  fi
  [[ "${scenario}" == "wrong-volume-object-${suffix}" ]] && mountpoint=/wrong
  printf '%s\t%s\t%s\n' "${name}" "${mountpoint}" "${created}"
  exit 0
fi

if [[ "${1:-}" == "inspect" ]]; then
  name="${!#}"
  case "${name}" in
    wrfcoin-testnet-softhsm-init)
      suffix=node
      id="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      service=softhsm-init
      volume=testnet_node-data
      command='["node-init"]'
      ;;
    wrfcoin-testnet-seed-softhsm-init)
      suffix=seed
      id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      service=softhsm-seed-init
      volume=testnet_seed-data
      command='["seed-init"]'
      ;;
    wrfcoin-testnet-node)
      suffix=consumer-node
      id="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      image="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      config_hash="1111111111111111111111111111111111111111111111111111111111111111"
      ;;
    wrfcoin-testnet-seed)
      suffix=consumer-seed
      id="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      image="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      config_hash="2222222222222222222222222222222222222222222222222222222222222222"
      ;;
    *) exit 1 ;;
  esac

  if [[ " $* " == *" --format {{.Id}} "* ]]; then
    count_file="${HSM_TEST_STATE_DIR}/idprobe-${suffix}.count"
    count=0
    [[ -f "${count_file}" ]] && read -r count < "${count_file}"
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"
    scenario="${HSM_TEST_SCENARIO:-good}"
    if (( count >= 2 )) && [[ "${scenario}" == "post-project-id-drift-${suffix}" ]]; then
      id="9999999999999999999999999999999999999999999999999999999999999999"
    fi
    printf '%s\n' "${id}"
    exit 0
  fi

  count_file="${HSM_TEST_STATE_DIR}/${suffix}.count"
  count=0
  [[ -f "${count_file}" ]] && read -r count < "${count_file}"
  count=$((count + 1))
  printf '%s\n' "${count}" > "${count_file}"

  scenario="${HSM_TEST_SCENARIO:-good}"
  [[ "${scenario}" == "missing-${suffix}" ]] && exit 1

  if [[ "${suffix}" == consumer-* ]]; then
    state=running
    health=healthy
    restarts=0
    started=2026-08-12T00:00:00Z
    if (( count >= 2 )); then
      [[ "${scenario}" == "post-id-drift-${suffix}" ]] && id="9999999999999999999999999999999999999999999999999999999999999999"
      [[ "${scenario}" == "post-start-drift-${suffix}" ]] && started=2099-01-01T00:00:00Z
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${id}" "${image}" "${state}" "${health}" "${restarts}" "${started}" "${config_hash}"
    exit 0
  fi

  image="sha256:3e66b3f8b4d254bef00904059001401568174de2797771dbfbcf851316051e82"
  if [[ "${HSM_TEST_DEPLOYMENT:-ct101}" == "alternate" ]]; then
    image="sha256:7777777777777777777777777777777777777777777777777777777777777777"
  fi
  state=running
  health=healthy
  restarts=0
  started=2026-08-12T00:00:00Z
  restart_policy=unless-stopped
  project=testnet
  oneoff=False
  config_hash="3333333333333333333333333333333333333333333333333333333333333333"
  mount_count=1
  target=/app/data
  mount_type=volume
  rw=true

  [[ "${scenario}" == "stopped-${suffix}" ]] && state=exited
  [[ "${scenario}" == "unhealthy-${suffix}" ]] && health=unhealthy
  [[ "${scenario}" == "wrong-project-${suffix}" ]] && project=other
  [[ "${scenario}" == "wrong-service-${suffix}" ]] && service=other-init
  [[ "${scenario}" == "oneoff-${suffix}" ]] && oneoff=True
  [[ "${scenario}" == "wrong-restart-policy-${suffix}" ]] && restart_policy=no
  [[ "${scenario}" == "wrong-volume-${suffix}" ]] && volume=testnet_wrong-data
  [[ "${scenario}" == "wrong-target-${suffix}" ]] && target=/wrong
  [[ "${scenario}" == "wrong-type-${suffix}" ]] && mount_type=bind
  [[ "${scenario}" == "extra-mount-${suffix}" ]] && mount_count=2
  [[ "${scenario}" == "readonly-${suffix}" ]] && rw=false
  [[ "${scenario}" == "wrong-image-${suffix}" ]] && image="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  [[ "${scenario}" == "mutable-image-${suffix}" ]] && image="wrfcoin/native-chain:testnet-local"
  [[ "${scenario}" == "wrong-cmd-${suffix}" ]] && command='["wrong"]'
  entrypoint='["entrypoint"]'
  healthcheck='["healthcheck"]'
  [[ "${scenario}" == "wrong-entrypoint-${suffix}" ]] && entrypoint='["wrong"]'

  if (( count >= 2 )); then
    [[ "${scenario}" == "post-id-drift-${suffix}" ]] && id="dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    [[ "${scenario}" == "post-image-drift-${suffix}" ]] && image="sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    [[ "${scenario}" == "post-mount-drift-${suffix}" ]] && volume=testnet_wrong-data
    [[ "${scenario}" == "post-health-drift-${suffix}" ]] && health=unhealthy
    [[ "${scenario}" == "post-start-drift-${suffix}" ]] && started=2099-01-01T00:00:00Z
    [[ "${scenario}" == "post-restart-drift-${suffix}" ]] && restarts=1
  fi

  mounts="${mount_type}|${volume}|${target}|${rw};"
  [[ "${scenario}" == "extra-mount-${suffix}" ]] && mounts+="volume|extra|/extra|true;"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${id}" "${image}" "${state}" "${health}" "${restarts}" "${started}" \
    "${restart_policy}" "${project}" "${service}" "${oneoff}" "${config_hash}" \
    "${mount_count}" "${mounts}" "${entrypoint}" "${command}" "${healthcheck}"
  exit 0
fi

if [[ "${1:-}" == "compose" ]]; then
  args=" $* "
  if [[ "${args}" == *" config --services "* ]]; then
    printf '%s\n' postgres redis softhsm-init wrfcoin-node softhsm-seed-init wrfcoin-seed
    exit 0
  fi
  if [[ "${args}" == *" ps -a --format "* ]]; then
    printf '%s\n' \
      wrfcoin-testnet-softhsm-init wrfcoin-testnet-seed-softhsm-init \
      wrfcoin-testnet-node wrfcoin-testnet-seed
    exit 0
  fi
  if [[ "${args}" == *" --dry-run "* ]]; then
    case "${HSM_TEST_DRY_RUN:-converged}" in
      converged)
        printf '%s\n' \
          'Container wrfcoin-testnet-softhsm-init Running' \
          'Container wrfcoin-testnet-seed-softhsm-init Running' \
          'Container wrfcoin-testnet-node Running' \
          'Container wrfcoin-testnet-seed Running' \
          'Container wrfcoin-testnet-node Exited'
        ;;
      known-init-recreates)
        printf '%s\n' \
          'Container wrfcoin-testnet-softhsm-init Recreate' \
          'Container wrfcoin-testnet-seed-softhsm-init Recreate' \
          'Container wrfcoin-testnet-softhsm-init Recreated' \
          'Container wrfcoin-testnet-seed-softhsm-init Recreated' \
          'Container wrfcoin-testnet-node Running'
        ;;
      unrelated-recreate) printf '%s\n' 'Container wrfcoin-testnet-node Recreate' ;;
      remove) printf '%s\n' 'Container wrfcoin-testnet-node Removing' ;;
      build) printf '%s\n' 'Image wrfcoin/native-chain Building' ;;
      pull) printf '%s\n' 'Image wrfcoin/native-chain Pulling' ;;
      ambiguous) printf '%s\n' 'plan will recreate something unknown' ;;
      creating-init) printf '%s\n' 'Container wrfcoin-testnet-softhsm-init Creating' ;;
      creating-other) printf '%s\n' 'Container wrfcoin-testnet-node Created' ;;
      starting-init) printf '%s\n' 'Container wrfcoin-testnet-seed-softhsm-init Started' ;;
      starting-existing) printf '%s\n' 'Container wrfcoin-testnet-node Started' ;;
      starting-existing-starting) printf '%s\n' 'Container wrfcoin-testnet-node Starting' ;;
      starting-node-init) printf '%s\n' 'Container wrfcoin-testnet-softhsm-init Starting' ;;
      unknown-container) printf '%s\n' 'Container not-preflight-bound Running' ;;
      unknown) printf '%s\n' 'Container wrfcoin-testnet-node Stopping' ;;
      empty) : ;;
      none) printf '%s\n' 'Container wrfcoin-testnet-node Running' ;;
      *) exit 91 ;;
    esac
  fi
  exit 0
fi

exit 97
SH
chmod +x "${BIN_DIR}/docker" "${BIN_DIR}/findmnt" "${BIN_DIR}/find" "${BIN_DIR}/sha256sum"

reset_case_state() {
  rm -rf "${TMP_DIR}/state"
  mkdir -p "${TMP_DIR}/state"
  : > "${TMP_DIR}/docker.log"
}

invoke_case() {
  local script="$1" scenario="$2" dataset="$3" data_root="$4" dry_run="$5"
  local custody_config="${6:-${CUSTODY_CONFIG}}"
  local deployment="${7:-ct101}"

  reset_case_state
  PATH="${BIN_DIR}:${PATH}" \
  HSM_TEST_DOCKER_LOG="${TMP_DIR}/docker.log" \
  HSM_TEST_STATE_DIR="${TMP_DIR}/state" \
  HSM_TEST_SCENARIO="${scenario}" \
  HSM_TEST_DATASET="${dataset}" \
  HSM_TEST_DATA_ROOT="${data_root}" \
  HSM_TEST_DRY_RUN="${dry_run}" \
  HSM_TEST_DEPLOYMENT="${deployment}" \
  WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${custody_config}" \
    bash "${script}"
}

invoke_stop_case() {
  local script="$1"

  reset_case_state
  PATH="${BIN_DIR}:${PATH}" \
  HSM_TEST_DOCKER_LOG="${TMP_DIR}/docker.log" \
  HSM_TEST_STATE_DIR="${TMP_DIR}/state" \
  HSM_TEST_SCENARIO=missing-node \
  WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${CUSTODY_CONFIG}" \
    bash "${script}" --stop
}

assert_executed_safe_up() {
  local actual_up_lines
  actual_up_lines="$(grep ' up -d ' "${TMP_DIR}/docker.log" | grep -v -- '--dry-run' || true)"
  [[ "$(printf '%s\n' "${actual_up_lines}" | sed '/^$/d' | wc -l)" -eq 1 ]] || return 1
  grep -qE ' up -d --no-build --no-recreate([[:space:]]|$)' <<< "${actual_up_lines}"
}

assert_executed_safe_diagnostic() {
  local dry_run_lines
  dry_run_lines="$(grep ' up -d ' "${TMP_DIR}/docker.log" | grep -- '--dry-run' || true)"
  [[ "$(printf '%s\n' "${dry_run_lines}" | sed '/^$/d' | wc -l)" -eq 1 ]] || return 1
  grep -qE ' up -d --no-build --no-recreate --dry-run([[:space:]]|$)' <<< "${dry_run_lines}"
}

expect_pass() {
  local name="$1"
  shift
  if ! invoke_case "${FIXTURE_DIR}/boot-heal.sh" "$@" \
      >"${TMP_DIR}/case.out" 2>"${TMP_DIR}/case.err"; then
    sed -n '1,20p' "${TMP_DIR}/case.err" >&2
    fail "${name} unexpectedly failed"
  fi
  assert_executed_safe_diagnostic || fail "${name} did not execute the exact safe diagnostic argv"
  assert_executed_safe_up || fail "${name} did not execute exactly one --no-recreate up"
  ok "${name}"
}

expect_fail() {
  local name="$1" expected="$2"
  shift 2
  if invoke_case "${FIXTURE_DIR}/boot-heal.sh" "$@" \
      >"${TMP_DIR}/case.out" 2>"${TMP_DIR}/case.err"; then
    fail "${name} unexpectedly passed"
  fi
  grep -qF "${expected}" "${TMP_DIR}/case.err" || {
    sed -n '1,20p' "${TMP_DIR}/case.err" >&2
    fail "${name} failed for an unrelated reason"
  }
  ok "${name}"
}

expect_config_fail_before_docker() {
  local name="$1" expected="$2" mode="$3" configured="${4:-}"

  reset_case_state
  set +e
  if [[ "${mode}" == "unset" ]]; then
    env -u WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG \
      PATH="${BIN_DIR}:${PATH}" \
      HSM_TEST_DOCKER_LOG="${TMP_DIR}/docker.log" \
        bash "${FIXTURE_DIR}/boot-heal.sh" \
        >"${TMP_DIR}/config.out" 2>"${TMP_DIR}/config.err"
  else
    PATH="${BIN_DIR}:${PATH}" \
    HSM_TEST_DOCKER_LOG="${TMP_DIR}/docker.log" \
    WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${configured}" \
      bash "${FIXTURE_DIR}/boot-heal.sh" \
      >"${TMP_DIR}/config.out" 2>"${TMP_DIR}/config.err"
  fi
  local rc=$?
  set -e
  [[ ${rc} -ne 0 ]] || fail "${name} unexpectedly passed"
  [[ ! -s "${TMP_DIR}/docker.log" ]] || fail "${name} reached Docker before rejection"
  grep -qF "${expected}" "${TMP_DIR}/config.err" || {
    sed -n '1,20p' "${TMP_DIR}/config.err" >&2
    fail "${name} failed for an unrelated reason"
  }
  ok "${name}"
}

grep -qF \
  'Environment=WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG=@WRFCOIN_DEPLOY_ROOT@/infra/testnet/provisioning/ct101-hsm-init-custody.conf' \
  "${SOURCE_SYSTEMD_UNIT}" || fail "systemd unit does not select the CT101 deployment artifact"
ok "systemd deployment channel selects the CT101 custody artifact"

source_image_pin_is_exact \
  "${SOURCE_CUSTODY_CONFIG}" "${REVIEWED_LIVE_HSM_INIT_IMAGE_ID}" || \
  fail "CT101 source baseline is not pinned to exactly the reviewed live HSM init image ID"
ok "CT101 source baseline pins exactly the reviewed live HSM init image ID"
if source_image_pin_is_exact \
    "${SECOND_IMAGE_CONFIG}" "${REVIEWED_LIVE_HSM_INIT_IMAGE_ID}"; then
  fail "CT101 source baseline accepted an unreviewed second HSM init image ID"
fi
ok "CT101 source baseline rejects an unreviewed second HSM init image ID"

expect_config_fail_before_docker \
  "missing custody configuration fails before Docker" \
  "WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG is required" unset
expect_config_fail_before_docker \
  "relative custody configuration path fails before Docker" \
  "must be an absolute path" configured relative.conf
expect_config_fail_before_docker \
  "missing required custody value fails before Docker" \
  "missing required HSM init custody config value" configured "${MISSING_VALUE_CONFIG}"
expect_config_fail_before_docker \
  "malformed custody digest fails before Docker" \
  "malformed HSM init custody digest configuration" configured "${MALFORMED_DIGEST_CONFIG}"
expect_config_fail_before_docker \
  "mutable image configuration fails before Docker" \
  "malformed immutable HSM init image ID configuration" configured "${MUTABLE_IMAGE_CONFIG}"

expect_pass "CT101 deployment artifact supplies the verified custody baseline" \
  good imported nonempty converged
expect_pass "configured alternate deployment values are used as custody evidence" \
  good imported nonempty converged "${ALTERNATE_CUSTODY_CONFIG}" alternate
expect_fail "missing container fails closed" "required HSM init container is missing" \
  missing-node imported nonempty converged
expect_fail "stopped container fails closed" "not running and healthy" \
  stopped-node imported nonempty converged
expect_fail "unhealthy container fails closed" "not running and healthy" \
  unhealthy-seed imported nonempty converged
expect_fail "wrong project label fails closed" "Compose label custody mismatch" \
  wrong-project-node imported nonempty converged
expect_fail "wrong service label fails closed" "Compose label custody mismatch" \
  wrong-service-seed imported nonempty converged
expect_fail "wrong named volume fails closed" "volume custody mismatch" \
  wrong-volume-node imported nonempty converged
expect_fail "wrong mount target fails closed" "volume custody mismatch" \
  wrong-target-seed imported nonempty converged
expect_fail "bind mount substitution fails closed" "volume custody mismatch" \
  wrong-type-node imported nonempty converged
expect_fail "extra mount fails cardinality gate" "volume custody mismatch" \
  extra-mount-seed imported nonempty converged
expect_fail "read-only mount fails closed" "volume custody mismatch" \
  readonly-node imported nonempty converged
expect_fail "non-allowlisted image ID fails closed" "not on the immutable allowlist" \
  wrong-image-node imported nonempty converged
expect_fail "mutable image evidence fails closed" "not on the immutable allowlist" \
  mutable-image-seed imported nonempty converged
expect_fail "wrong init command fails closed" "executable contract mismatch" \
  wrong-cmd-node imported nonempty converged
expect_fail "wrong init entrypoint fails closed" "executable contract mismatch" \
  wrong-entrypoint-seed imported nonempty converged
expect_fail "oneoff container fails closed" "lifecycle custody mismatch" \
  oneoff-node imported nonempty converged
expect_fail "wrong restart policy fails closed" "lifecycle custody mismatch" \
  wrong-restart-policy-seed imported nonempty converged
expect_fail "wrong public-key fingerprint fails closed" "public-key fingerprint mismatch" \
  wrong-fingerprint-node imported nonempty converged
expect_fail "failed public-key read fails closed" "cannot read HSM init public-key fingerprint" \
  fingerprint-read-fail-seed imported nonempty converged
expect_fail "unimported dataset fails closed" "dataset custody mismatch" \
  good unimported nonempty converged
expect_fail "empty Docker data root fails closed" "data root is empty or unavailable" \
  good imported empty converged
expect_fail "wrong volume object path fails closed" "backing volume identity mismatch" \
  wrong-volume-object-node imported nonempty converged
expect_fail "missing volume object fails closed" "backing volume is missing" \
  missing-volume-seed imported nonempty converged
expect_fail "any recreate action fails closed" "create or recreate" \
  good imported nonempty unrelated-recreate
expect_fail "known init recreate action also fails closed" "create or recreate" \
  good imported nonempty known-init-recreates
expect_fail "remove action fails closed" "unknown or ambiguous" \
  good imported nonempty remove
expect_fail "build action fails closed" "unknown or ambiguous" \
  good imported nonempty build
expect_fail "pull action fails closed" "unknown or ambiguous" \
  good imported nonempty pull
expect_fail "ambiguous recreate output fails closed" "unknown or ambiguous" \
  good imported nonempty ambiguous
expect_fail "init Creating action fails closed" "create or recreate" \
  good imported nonempty creating-init
expect_fail "unrelated Created action fails closed" "create or recreate" \
  good imported nonempty creating-other
expect_fail "init Started action fails closed" "unsafe init start" \
  good imported nonempty starting-init
expect_pass "preflight-bound existing consumer may start" good imported nonempty starting-existing
expect_fail "unknown dry-run verb fails closed" "unknown or ambiguous" \
  good imported nonempty unknown
expect_fail "unbound container action fails closed" "without a preflight-bound ID" \
  good imported nonempty unknown-container
expect_fail "empty dry-run output fails closed" "no recognized actions" \
  good imported nonempty empty
expect_fail "post-reconcile container ID drift fails closed" "custody changed" \
  post-id-drift-node imported nonempty converged
expect_fail "post-reconcile image drift fails closed" "not on the immutable allowlist" \
  post-image-drift-seed imported nonempty converged
expect_fail "post-reconcile mount drift fails closed" "volume custody mismatch" \
  post-mount-drift-node imported nonempty converged
expect_fail "post-reconcile health drift fails closed" "not running and healthy" \
  post-health-drift-seed imported nonempty converged
expect_fail "post-reconcile start-time drift fails closed" "custody changed" \
  post-start-drift-node imported nonempty converged
expect_fail "post-reconcile restart drift fails closed" "custody changed" \
  post-restart-drift-seed imported nonempty converged
expect_fail "post-reconcile public-key drift fails closed" "public-key fingerprint mismatch" \
  post-fingerprint-drift-node imported nonempty converged
expect_fail "post-reconcile volume creation drift fails closed" "backing volume changed" \
  post-volume-created-drift-node imported nonempty converged
expect_fail "post-reconcile project container ID drift fails closed" "container identity changed" \
  post-project-id-drift-consumer-node imported nonempty converged

if ! invoke_stop_case "${FIXTURE_DIR}/boot-heal.sh" \
    >"${TMP_DIR}/stop.out" 2>"${TMP_DIR}/stop.err"; then
  sed -n '1,20p' "${TMP_DIR}/stop.err" >&2
  fail "HSM-preserving stop failed with missing init metadata"
fi
grep -q ' stop ' "${TMP_DIR}/docker.log" || fail "stop did not use Compose stop"
! grep -q ' down' "${TMP_DIR}/docker.log" || fail "stop still used Compose down"
! grep -q 'inspect' "${TMP_DIR}/docker.log" || fail "HSM preflight leaked into stop path"
stop_line="$(grep ' stop ' "${TMP_DIR}/docker.log")"
[[ " ${stop_line} " != *" softhsm-init "* && " ${stop_line} " != *" softhsm-seed-init "* ]] \
  || fail "stop included HSM init services"
ok "graceful stop preserves init services and bypasses HSM preflight"

MUTATED_SCRIPT="${FIXTURE_DIR}/boot-heal-without-no-recreate.sh"
python3 - "${FIXTURE_DIR}/boot-heal.sh" "${MUTATED_SCRIPT}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = '  compose up -d --no-build --no-recreate'
assert source.count(needle) == 1, source.count(needle)
pathlib.Path(sys.argv[2]).write_text(source.replace(
    needle, '  compose up -d --no-build', 1))
PY
if invoke_case "${MUTATED_SCRIPT}" good imported nonempty converged \
    >"${TMP_DIR}/mutation.out" 2>"${TMP_DIR}/mutation.err" \
    && assert_executed_safe_up; then
  fail "delete --no-recreate mutation stayed GREEN"
fi
ok "delete --no-recreate mutation is REAL-RED on the executed command"

mutate_and_require_red() {
  local name="$1" mutation="$2" scenario="$3" dry_run="$4"
  local mutated="${FIXTURE_DIR}/mutation-${mutation}.sh"
  python3 - "${FIXTURE_DIR}/boot-heal.sh" "${mutated}" "${mutation}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
mutation = sys.argv[3]
if mutation == "creating":
    needle = '    if [[ "${action}" == "Creating" || "${action}" == "Created" \\\n+       || "${action}" == "Recreate" || "${action}" == "Recreated" ]]; then'
    replacement = '    if [[ "${action}" == "Recreate" || "${action}" == "Recreated" ]]; then'
elif mutation == "mount-type":
    needle = '  if [[ "${INSPECT_MOUNT_COUNT}" != "1" || "${INSPECT_MOUNTS}" != "${expected_mount}" ]]; then'
    replacement = '  if [[ "${INSPECT_MOUNT_COUNT}" != "1" || "${INSPECT_MOUNTS}" != *"|${HSM_INIT_VOLUME_TARGETS[$index]}|true;" ]]; then'
elif mutation == "command-pin":
    needle = '  if [[ "${cmd_sha256}" != "${HSM_INIT_CMD_SHA256[$index]}" \\\n+     || "${entrypoint_sha256}" != "${HSM_INIT_ENTRYPOINT_SHA256[$index]}" \\\n+     || "${healthcheck_sha256}" != "${HSM_INIT_HEALTHCHECK_SHA256[$index]}" ]]; then'
    replacement = '  if [[ "${healthcheck_sha256}" != "${HSM_INIT_HEALTHCHECK_SHA256[$index]}" ]]; then'
else:
    raise AssertionError(mutation)
# The multi-line literals use a visible leading-plus sentinel; strip it before
# matching the production shell source.
needle = needle.replace("\n+", "\n")
assert source.count(needle) == 1, (mutation, source.count(needle))
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement, 1))
PY
  if ! invoke_case "${mutated}" "${scenario}" imported nonempty "${dry_run}" \
      >"${TMP_DIR}/${mutation}.out" 2>"${TMP_DIR}/${mutation}.err"; then
    sed -n '1,20p' "${TMP_DIR}/${mutation}.err" >&2
    fail "${name} did not expose the negative fixture"
  fi
  ok "${name} is REAL-RED"
}

mutate_and_require_red "delete Creating/Created global guard" creating good creating-other
mutate_and_require_red "replace volume type/name gate with destination-only gate" mount-type wrong-type-node converged
mutate_and_require_red "drop command and entrypoint pins" command-pin wrong-cmd-node converged

HARDCODED_CONFIG_SCRIPT="${FIXTURE_DIR}/boot-heal-hardcoded-mountpoints.sh"
python3 - "${FIXTURE_DIR}/boot-heal.sh" "${HARDCODED_CONFIG_SCRIPT}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = '  local expected_mountpoint="${HSM_INIT_VOLUME_MOUNTPOINTS[$index]}"'
replacement = '''  local -a hardcoded_mountpoints=(
    /mnt/tank-docker/docker-data/volumes/testnet_node-data/_data
    /mnt/tank-docker/docker-data/volumes/testnet_seed-data/_data
  )
  local expected_mountpoint="${hardcoded_mountpoints[$index]}"'''
assert source.count(needle) == 1, source.count(needle)
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement, 1))
PY
if invoke_case "${HARDCODED_CONFIG_SCRIPT}" good imported nonempty converged \
    "${ALTERNATE_CUSTODY_CONFIG}" alternate \
    >"${TMP_DIR}/hardcoded-config.out" 2>"${TMP_DIR}/hardcoded-config.err"; then
  fail "replace configured mountpoints with CT101 literals stayed GREEN"
fi
grep -qF 'backing volume identity mismatch' "${TMP_DIR}/hardcoded-config.err" || \
  fail "hardcoded mountpoint mutation failed for an unrelated reason"
ok "replace configured mountpoints with CT101 literals is REAL-RED"

NO_CONFIG_LOAD_SCRIPT="${FIXTURE_DIR}/boot-heal-without-config-load.sh"
python3 - "${FIXTURE_DIR}/boot-heal.sh" "${NO_CONFIG_LOAD_SCRIPT}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = '\nload_hsm_init_custody_config\n'
assert source.count(needle) == 1, source.count(needle)
pathlib.Path(sys.argv[2]).write_text(source.replace(
    needle, '\n', 1))
PY
reset_case_state
set +e
env -u WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG \
  PATH="${BIN_DIR}:${PATH}" \
  HSM_TEST_DOCKER_LOG="${TMP_DIR}/docker.log" \
  HSM_TEST_STATE_DIR="${TMP_DIR}/state" \
    bash "${NO_CONFIG_LOAD_SCRIPT}" \
    >"${TMP_DIR}/no-config-load.out" 2>"${TMP_DIR}/no-config-load.err"
no_config_load_rc=$?
set -e
[[ ${no_config_load_rc} -ne 0 ]] || fail "delete custody-config load mutation unexpectedly passed"
[[ -s "${TMP_DIR}/docker.log" ]] || \
  fail "delete custody-config load mutation did not bypass the before-Docker gate"
ok "delete custody-config load mutation is REAL-RED against the before-Docker gate"

TOP_LEVEL_SCRIPT="${FIXTURE_DIR}/boot-heal-top-level-preflight.sh"
python3 - "${FIXTURE_DIR}/boot-heal.sh" "${TOP_LEVEL_SCRIPT}" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'main "$@"'
assert source.count(needle) == 1
pathlib.Path(sys.argv[2]).write_text(source.replace(
    needle, 'capture_verified_hsm_init_custody\nmain "$@"', 1))
PY
if invoke_stop_case "${TOP_LEVEL_SCRIPT}" >"${TMP_DIR}/top.out" 2>"${TMP_DIR}/top.err"; then
  fail "move preflight to top level stayed GREEN on --stop"
fi
ok "move preflight to top level is REAL-RED on --stop"

# ---------------------------------------------------------------------------
# Seed retired (infra#1057 Q4, owner ruling 2026-09-27): "seed" not in the
# effective profiles. Only softhsm-init is in custody; SEED_* keys are accepted
# but neither required nor used; NODE custody is exactly as strict as before.
# ---------------------------------------------------------------------------
export COMPOSE_PROFILES=collector
NODE_MISSING_CONFIG="${FIXTURE_DIR}/node-missing-hsm-init-custody.conf"
grep -v '^HSM_INIT_NODE_PUBLIC_KEY_SHA256=' "${CUSTODY_CONFIG}" > "${NODE_MISSING_CONFIG}"
NO_SEED_KEYS_CONFIG="${FIXTURE_DIR}/no-seed-keys-hsm-init-custody.conf"
grep -v '^HSM_INIT_SEED_' "${CUSTODY_CONFIG}" > "${NO_SEED_KEYS_CONFIG}"

expect_pass "seed retired: the reviewed custody file (with SEED keys) still loads and reconciles" \
  good imported nonempty converged
grep -q 'seed profile inactive' "${TMP_DIR}/case.err" || fail "seed retired: no explicit custody-scope notice"
ok "seed retired: custody scope is announced, not silent"
# The custody inspection (the long {{.State.Health}} format) must not touch the
# seed's init. (Generic Compose ID binding follows whatever `compose ps` lists;
# this stub lists the seed regardless of profile, real Compose does not.)
if grep -E 'State\.Health.*wrfcoin-testnet-seed-softhsm-init$' "${TMP_DIR}/docker.log" >&2; then
  fail "seed retired: the seed's HSM-init container was still custody-inspected"
fi
ok "seed retired: the seed's HSM-init container is never custody-inspected"
expect_pass "seed retired: a custody file WITHOUT any SEED key reconciles" \
  good imported nonempty converged "${NO_SEED_KEYS_CONFIG}"
expect_pass "seed retired: a seed-only fault (unhealthy seed HSM init) is out of custody" \
  unhealthy-seed imported nonempty converged
# codex round 53: with the seed retired only index 0 is in custody; the
# dry-run validator must not reach for a seed-init index, and must still
# refuse starting ANY HSM init (the node's, or the retired seed's).
expect_pass "seed retired: an existing consumer 'Started' in the dry-run reconciles" \
  good imported nonempty starting-existing
expect_pass "seed retired: an existing consumer 'Starting' in the dry-run reconciles" \
  good imported nonempty starting-existing-starting
expect_fail "seed retired: starting the node's HSM init is still refused" "unsafe init start" \
  good imported nonempty starting-node-init
expect_fail "seed retired: starting the retired seed's HSM init is still refused" "unsafe init start" \
  good imported nonempty starting-init
expect_config_fail_before_docker \
  "seed retired: a missing NODE custody value still fails before Docker" \
  "missing required HSM init custody config value" configured "${NODE_MISSING_CONFIG}"
expect_fail "seed retired: a node-owner fault still fails closed" "not running and healthy" \
  stopped-node imported nonempty converged
export COMPOSE_PROFILES=seed
expect_pass "seed profile ACTIVE (rollback): both HSM-init owners in custody" good imported nonempty converged
grep -qE 'State\.Health.*wrfcoin-testnet-seed-softhsm-init$' "${TMP_DIR}/docker.log" || \
  fail "positive control: the seed custody-inspect pattern does not match an active-seed run (the retired check would be vacuous)"
ok "positive control: the seed's HSM-init IS custody-inspected with the profile active"
expect_config_fail_before_docker \
  "seed profile ACTIVE (rollback): a custody file without SEED keys fails before Docker" \
  "missing required HSM init custody config value" configured "${NO_SEED_KEYS_CONFIG}"

printf 'PASS: HSM-safe boot reconciliation (%d assertions, including executed-command REAL-RED)\n' \
  "${ASSERTIONS}"
