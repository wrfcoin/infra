#!/usr/bin/env bash
# Hermetic contract tests for boot-heal Compose custody.
#
# `docker compose config` is used only to render a disposable minimal fixture;
# it does not contact the daemon or mutate a Compose project.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/testnet/boot-heal.sh"
SOURCE_HEALTH="${REPO_ROOT}/testnet/check-health.sh"
SOURCE_COMPOSE_INPUTS="${REPO_ROOT}/testnet/lib/compose-inputs.sh"
SOURCE_CUSTODY_CONFIG="${REPO_ROOT}/testnet/provisioning/ct101-hsm-init-custody.conf"
TMP_DIR="$(mktemp -d)"
FIXTURE_DIR="${TMP_DIR}/testnet"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  printf '  ok    %s\n' "$*"
}

command -v docker >/dev/null 2>&1 || fail "docker CLI is required for non-mutating compose rendering"
docker compose version >/dev/null 2>&1 || fail "docker compose is required for non-mutating compose rendering"

mkdir -p "${FIXTURE_DIR}/lib" "${TMP_DIR}/bin"
cp "${SOURCE_SCRIPT}" "${FIXTURE_DIR}/boot-heal.sh"
cp "${SOURCE_HEALTH}" "${FIXTURE_DIR}/check-health.sh"
cp "${SOURCE_COMPOSE_INPUTS}" "${FIXTURE_DIR}/lib/compose-inputs.sh"
cp "${SOURCE_CUSTODY_CONFIG}" "${FIXTURE_DIR}/hsm-init-custody.conf"
export WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${FIXTURE_DIR}/hsm-init-custody.conf"

printf '%s\n' \
  'services:' \
  '  softhsm-init: {image: fixture/native:base}' \
  '  softhsm-seed-init: {image: fixture/native:base}' \
  '  wrfcoin-node: {image: fixture/native:base}' \
  '  wrfcoin-seed: {image: fixture/native:base}' \
  '  wrfcoin-faucet: {image: fixture/faucet, profiles: [seed]}' \
  '  oracle-attester: {image: fixture/attester:base}' \
  > "${FIXTURE_DIR}/docker-compose.testnet.yml"

printf '%s\n' \
  'services:' \
  '  softhsm-init: {image: wrfcoin/native-chain:testnet-local}' \
  '  softhsm-seed-init: {image: wrfcoin/native-chain:testnet-local}' \
  '  wrfcoin-node: {image: wrfcoin/native-chain:testnet-local}' \
  '  wrfcoin-seed: {image: wrfcoin/native-chain:testnet-local}' \
  '  alert-receiver: {image: fixture/alerts}' \
  '  wrfcoin-explorer: {image: fixture/explorer}' \
  '  oracle-attester: {image: wrfcoin/oracle-attester:testnet-local}' \
  > "${FIXTURE_DIR}/docker-compose.override.yml"

for overlay in docker-compose.local-paths.yml docker-compose.cut.yml \
               docker-compose.cut-miner.yml docker-compose.cut-genesis-seed.yml \
               docker-compose.yubikey.n5.yml; do
  printf '%s\n' 'services: {}' > "${FIXTURE_DIR}/${overlay}"
done
printf '%s\n' \
  'services:' \
  '  container-health-watch: {image: fixture/health-watch, profiles: [container-health-watch]}' \
  > "${FIXTURE_DIR}/docker-compose.container-health-watch.yml"

# The fixture must preserve this Compose interpolation expression literally.
# shellcheck disable=SC2016
printf '%s\n' \
  'services:' \
  '  oracle-attester:' \
  '    image: ${WRFCOIN_TESTNET_ATTESTER_IMAGE:-wrfcoin/oracle-attester-runtime:testnet-local}' \
  '    profiles: [attester]' \
  '    container_name: wrfcoin-testnet-oracle-attester' \
  '    environment:' \
  '      FIXTURE_CUSTODY: companion' \
  '    volumes:' \
  '      - oracle-attester-data:/app/data' \
  '    devices:' \
  '      - /dev/null:/dev/null' \
  'volumes:' \
  '  oracle-attester-data: {}' \
  > "${FIXTURE_DIR}/docker-compose.oracle-attester.yml"

printf '%s\n' \
  'services:' \
  '  oracle-attester:' \
  '    environment:' \
  '      FIXTURE_TRANSPORT: yubikey' \
  '    volumes:' \
  '      - /run/pcscd:/run/pcscd:ro' \
  > "${FIXTURE_DIR}/docker-compose.oracle-attester-yubikey.n5.yml"

EXTRA_COMPOSE="${TMP_DIR}/quorum-image-override.yml"
printf '%s\n' \
  'services:' \
  '  softhsm-init: {image: wrfcoin/native-chain:testnet-quorum-exact}' \
  '  softhsm-seed-init: {image: wrfcoin/native-chain:testnet-quorum-exact}' \
  '  wrfcoin-node: {image: wrfcoin/native-chain:testnet-quorum-exact}' \
  '  wrfcoin-seed: {image: wrfcoin/native-chain:testnet-quorum-exact}' \
  '  oracle-attester: {image: wrfcoin/oracle-attester:testnet-quorum-exact}' \
  > "${EXTRA_COMPOSE}"

mapfile -t configured_files < <(
  WRFCOIN_HSM_MODE=yubikey \
  WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}" \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files
)

expected_files=(
  "${FIXTURE_DIR}/docker-compose.testnet.yml"
  "${FIXTURE_DIR}/docker-compose.override.yml"
  "${FIXTURE_DIR}/docker-compose.local-paths.yml"
  "${FIXTURE_DIR}/docker-compose.cut.yml"
  "${FIXTURE_DIR}/docker-compose.cut-miner.yml"
  "${FIXTURE_DIR}/docker-compose.cut-genesis-seed.yml"
  "${FIXTURE_DIR}/docker-compose.container-health-watch.yml"
  "${FIXTURE_DIR}/docker-compose.yubikey.n5.yml"
  "${FIXTURE_DIR}/docker-compose.oracle-attester.yml"
  "${FIXTURE_DIR}/docker-compose.oracle-attester-yubikey.n5.yml"
  "${EXTRA_COMPOSE}"
)

[[ ${#configured_files[@]} -eq ${#expected_files[@]} ]] || \
  fail "configured-present list length differs from the exact custody set"
for i in "${!expected_files[@]}"; do
  [[ "${configured_files[$i]}" == "${expected_files[$i]}" ]] || \
    fail "compose ordering mismatch at index ${i}"
done
ok "configured-present override is observable at final image precedence"

mapfile -t unset_files < <(
  env -u WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE WRFCOIN_HSM_MODE=yubikey \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files
)
[[ ${#unset_files[@]} -eq 8 ]] || \
  fail "unset override changed the built-in Compose set"
[[ "${unset_files[-1]}" == "${FIXTURE_DIR}/docker-compose.yubikey.n5.yml" ]] || \
  fail "unset override did not leave the built-in order intact"
ok "unset override preserves the built-in Compose set"

mv "${FIXTURE_DIR}/docker-compose.container-health-watch.yml" \
  "${TMP_DIR}/container-health-watch-away.yml"
mapfile -t without_watch_files < <(
  env -u WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files
)
if printf '%s\n' "${without_watch_files[@]}" | grep -Fq docker-compose.container-health-watch.yml; then
  fail "absent health-watch overlay remained in effective file set"
fi
ok "absent health-watch overlay is optional"
mv "${TMP_DIR}/container-health-watch-away.yml" \
  "${FIXTURE_DIR}/docker-compose.container-health-watch.yml"

mapfile -t default_reconcile < <(
  env -u COMPOSE_PROFILES -u WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-reconcile-services
)
for service in alert-receiver wrfcoin-explorer; do
  printf '%s\n' "${default_reconcile[@]}" | grep -Fxq "$service" || \
    fail "default reconcile omitted $service"
done
if printf '%s\n' "${default_reconcile[@]}" | grep -Fxq wrfcoin-faucet; then
  fail "default reconcile included profile-gated faucet"
fi
if printf '%s\n' "${default_reconcile[@]}" | grep -Fxq container-health-watch; then
  fail "default reconcile included profile-gated health watcher"
fi
ok "default reconcile includes alert/explorer but not watcher or faucet"

mapfile -t watch_reconcile < <(
  COMPOSE_PROFILES=container-health-watch env -u WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-reconcile-services
)
printf '%s\n' "${watch_reconcile[@]}" | grep -Fxq container-health-watch || \
  fail "watcher profile reconcile omitted watcher"
ok "watcher profile reconcile includes watcher"

mapfile -t seed_reconcile < <(
  COMPOSE_PROFILES=seed env -u WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-reconcile-services
)
printf '%s\n' "${seed_reconcile[@]}" | grep -Fxq wrfcoin-faucet || \
  fail "seed reconcile omitted faucet"
ok "seed reconcile includes faucet"

DOCKER_MARKER="${TMP_DIR}/docker-called"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  "printf called > '${DOCKER_MARKER}'" \
  'exit 97' \
  > "${TMP_DIR}/bin/docker"
chmod +x "${TMP_DIR}/bin/docker"

missing_path="${TMP_DIR}/missing-override.yml"
set +e
PATH="${TMP_DIR}/bin:${PATH}" WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${missing_path}" \
  bash "${FIXTURE_DIR}/boot-heal.sh" >"${TMP_DIR}/missing.out" 2>"${TMP_DIR}/missing.err"
missing_rc=$?
set -e
[[ ${missing_rc} -ne 0 ]] || fail "configured-missing override passed"
[[ ! -e "${DOCKER_MARKER}" ]] || fail "configured-missing override reached Docker"
grep -q 'not a readable regular file' "${TMP_DIR}/missing.err" || \
  fail "configured-missing failure was not explicit"
ok "configured-missing override fails before any Docker call"

GENESIS_FIXTURE=1111111111111111111111111111111111111111111111111111111111111111
printf 'WRFCOIN_CUT_GENESIS_HASH=%s\n' "$GENESIS_FIXTURE" > "${FIXTURE_DIR}/cut-pins.env"
mv "${FIXTURE_DIR}/docker-compose.cut.yml" "${TMP_DIR}/cut-overlay-away.yml"

set +e
bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files \
  >"${TMP_DIR}/missing-cut.out" 2>"${TMP_DIR}/missing-cut.err"
missing_cut_rc=$?
set -e
[[ ${missing_cut_rc} -ne 0 ]] || fail "missing genesis overlay passed boot-heal"
grep -Fq 'genesis pin overlay missing — run testnet/scripts/render-cut-overlay.sh' \
  "${TMP_DIR}/missing-cut.err" || fail "missing genesis overlay error was not actionable"
ok "missing genesis overlay fails boot-heal closed"

set +e
bash "${FIXTURE_DIR}/check-health.sh" \
  >"${TMP_DIR}/missing-cut-health.out" 2>"${TMP_DIR}/missing-cut-health.err"
missing_cut_health_rc=$?
set -e
[[ ${missing_cut_health_rc} -ne 0 ]] || fail "missing genesis overlay passed check-health"
grep -Fq 'genesis pin overlay missing — run testnet/scripts/render-cut-overlay.sh' \
  "${TMP_DIR}/missing-cut-health.err" || fail "check-health missing-overlay error was not actionable"
ok "missing genesis overlay fails check-health closed"

set +e
WRFCOIN_ALLOW_UNPINNED_GENESIS=1 \
  bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files \
  >"${TMP_DIR}/unpin.out" 2>"${TMP_DIR}/unpin.err"
unpin_rc=$?
set -e
[[ ${unpin_rc} -eq 0 ]] || fail "explicit unpinned developer escape hatch failed"
grep -Fq 'NON_RELEASE: genesis pin overlay missing' "${TMP_DIR}/unpin.err" || \
  fail "unpinned escape hatch was not labelled NON_RELEASE"
ok "explicit unpinned escape hatch is labelled NON_RELEASE"

mv "${TMP_DIR}/cut-overlay-away.yml" "${FIXTURE_DIR}/docker-compose.cut.yml"

non_file="${TMP_DIR}/override-directory"
mkdir "${non_file}"
set +e
WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${non_file}" \
  bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files \
  >"${TMP_DIR}/non-file.out" 2>"${TMP_DIR}/non-file.err"
non_file_rc=$?
set -e
[[ ${non_file_rc} -ne 0 ]] || fail "configured non-file override passed"
grep -q 'not a readable regular file' "${TMP_DIR}/non-file.err" || \
  fail "configured non-file failure was not explicit"
ok "configured unreadable/non-file override fails closed"

render_compose() {
  local output="$1"
  local attester_image="$2"
  shift 2
  local args=() file
  for file in "$@"; do
    args+=(-f "${file}")
  done
  if [[ "${attester_image}" == "__UNSET__" ]]; then
    env -u WRFCOIN_TESTNET_ATTESTER_IMAGE \
      bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile attester "${args[@]}" config --format json > "${output}"
  else
    WRFCOIN_TESTNET_ATTESTER_IMAGE="${attester_image}" \
      bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile attester "${args[@]}" config --format json > "${output}"
  fi
}

assert_exact_pins() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    services = json.load(handle)["services"]

expected = {
    "softhsm-init": "wrfcoin/native-chain:testnet-quorum-exact",
    "softhsm-seed-init": "wrfcoin/native-chain:testnet-quorum-exact",
    "wrfcoin-node": "wrfcoin/native-chain:testnet-quorum-exact",
    "wrfcoin-seed": "wrfcoin/native-chain:testnet-quorum-exact",
    "oracle-attester": "wrfcoin/oracle-attester:testnet-quorum-exact",
}
actual = {name: services.get(name, {}).get("image") for name in expected}
if actual != expected:
    print(f"image pins differ: {actual}", file=sys.stderr)
    raise SystemExit(1)
PY
}

assert_attester_custody() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    attester = json.load(handle)["services"]["oracle-attester"]

assert attester["profiles"] == ["attester"], attester.get("profiles")
assert attester["container_name"] == "wrfcoin-testnet-oracle-attester"
assert set(attester["environment"]) == {"FIXTURE_CUSTODY", "FIXTURE_TRANSPORT"}
assert {item["target"] for item in attester["volumes"]} == {"/app/data", "/run/pcscd"}
assert {item["target"] for item in attester["devices"]} == {"/dev/null"}
PY
}

CT101_ATTESTER_IMAGE="wrfcoin/oracle-attester:testnet-quorum-dc2ed165c"

render_compose "${TMP_DIR}/configured-unset.json" "__UNSET__" "${configured_files[@]}"
assert_exact_pins "${TMP_DIR}/configured-unset.json" || \
  fail "final override did not pin every image with attester env unset"
assert_attester_custody "${TMP_DIR}/configured-unset.json" || \
  fail "final override discarded attester custody with attester env unset"
ok "final override pins node, seed, and attester with production default behavior"

render_compose "${TMP_DIR}/configured-ct101.json" "${CT101_ATTESTER_IMAGE}" "${configured_files[@]}"
assert_exact_pins "${TMP_DIR}/configured-ct101.json" || \
  fail "final override did not pin every image with CT101-like attester env"
assert_attester_custody "${TMP_DIR}/configured-ct101.json" || \
  fail "final override discarded attester custody with CT101-like attester env"
ok "final override pins node, seed, and attester with CT101-like configured image"

configured_args=()
for file in "${configured_files[@]}"; do
  configured_args+=(-f "${file}")
done
WRFCOIN_TESTNET_ATTESTER_IMAGE="${CT101_ATTESTER_IMAGE}" \
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${configured_args[@]}" config --services \
  > "${TMP_DIR}/services-default-profile.txt"
if grep -qx 'oracle-attester' "${TMP_DIR}/services-default-profile.txt"; then
  fail "attester unexpectedly rendered without its profile"
fi
WRFCOIN_TESTNET_ATTESTER_IMAGE="${CT101_ATTESTER_IMAGE}" \
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${configured_args[@]}" --profile attester config --services \
  > "${TMP_DIR}/services-attester-profile.txt"
[[ "$(grep -cx 'oracle-attester' "${TMP_DIR}/services-attester-profile.txt")" -eq 1 ]] || \
  fail "attester profile did not render exactly one oracle-attester service"
WRFCOIN_TESTNET_ATTESTER_IMAGE="${CT101_ATTESTER_IMAGE}" \
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${configured_args[@]}" --profile attester config --hash='oracle-attester' \
  > "${TMP_DIR}/attester-hash.txt"
[[ "$(awk '$1 == "oracle-attester" && $2 ~ /^[0-9a-f]{64}$/ { n++ } END { print n + 0 }' \
  "${TMP_DIR}/attester-hash.txt")" -eq 1 ]] || \
  fail "attester profile did not produce exactly one config hash"
ok "attester operator probe is profile-aware and non-vacuous"

# Reconstruct the reviewed bad order: the explicit override precedes both
# attester custody overlays. Native pins survive, but the later production
# expression silently replaces the attester pin. Both environment branches must
# make the exact-pin assertion turn RED for that specific reason.
bad_order_files=(
  # An array initialiser element (data, not a command): the first seven configured compose files.
    # dynamic-payload-reviewed: boot-heal-custody-array-initialiser
  "${configured_files[@]:0:7}"
  "${EXTRA_COMPOSE}"
  "${FIXTURE_DIR}/docker-compose.oracle-attester.yml"
  "${FIXTURE_DIR}/docker-compose.oracle-attester-yubikey.n5.yml"
)

render_compose "${TMP_DIR}/bad-order-unset.json" "__UNSET__" "${bad_order_files[@]}"
if assert_exact_pins "${TMP_DIR}/bad-order-unset.json" \
  >"${TMP_DIR}/bad-order-unset.out" 2>"${TMP_DIR}/bad-order-unset.err"; then
  fail "reviewed bad order stayed GREEN with attester env unset"
fi
grep -q 'oracle-attester-runtime:testnet-local' "${TMP_DIR}/bad-order-unset.err" || \
  fail "bad-order unset RED was not caused by the production attester default"
ok "reviewed bad order is REAL-RED with attester env unset"

render_compose "${TMP_DIR}/bad-order-ct101.json" "${CT101_ATTESTER_IMAGE}" "${bad_order_files[@]}"
if assert_exact_pins "${TMP_DIR}/bad-order-ct101.json" \
  >"${TMP_DIR}/bad-order-ct101.out" 2>"${TMP_DIR}/bad-order-ct101.err"; then
  fail "reviewed bad order stayed GREEN with CT101-like attester env"
fi
grep -q "${CT101_ATTESTER_IMAGE}" "${TMP_DIR}/bad-order-ct101.err" || \
  fail "bad-order CT101 RED was not caused by the configured attester image"
ok "reviewed bad order is REAL-RED with CT101-like attester env"

mutated_files=()
for file in "${configured_files[@]}"; do
  [[ "${file}" == "${EXTRA_COMPOSE}" ]] || mutated_files+=("${file}")
done
render_compose "${TMP_DIR}/mutated.json" "${CT101_ATTESTER_IMAGE}" "${mutated_files[@]}"
if assert_exact_pins "${TMP_DIR}/mutated.json" >"${TMP_DIR}/mutation.out" 2>"${TMP_DIR}/mutation.err"; then
  fail "drop-extra mutation stayed GREEN"
fi
grep -q 'image pins differ' "${TMP_DIR}/mutation.err" || \
  fail "drop-extra mutation failed for an unrelated reason"
ok "drop-extra mutation goes RED on exact image pins"

printf 'PASS: boot-heal Compose custody (13 assertions including 3 REAL-RED controls)\n'
