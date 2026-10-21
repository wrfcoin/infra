#!/usr/bin/env bash
# Production-entrypoint tests for optional oracle-reference health semantics.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_HEALTH="${REPO_ROOT}/testnet/check-health.sh"
SOURCE_BOOT_HEAL="${REPO_ROOT}/testnet/boot-heal.sh"
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

mkdir -p "${FIXTURE_DIR}/lib" "${FIXTURE_DIR}/scripts" "${TMP_DIR}/bin"
cp "${SOURCE_HEALTH}" "${FIXTURE_DIR}/check-health.sh"
cp "${REPO_ROOT}/testnet/scripts/validate-health-payload.py" "${FIXTURE_DIR}/scripts/validate-health-payload.py"
cp "${SOURCE_BOOT_HEAL}" "${FIXTURE_DIR}/boot-heal.sh"
cp "${SOURCE_CUSTODY_CONFIG}" "${FIXTURE_DIR}/hsm-init-custody.conf"
if [[ -f "${REPO_ROOT}/testnet/lib/compose-inputs.sh" ]]; then
  cp "${REPO_ROOT}/testnet/lib/compose-inputs.sh" "${FIXTURE_DIR}/lib/compose-inputs.sh"
fi

for compose_file in docker-compose.testnet.yml docker-compose.override.yml \
                    docker-compose.local-paths.yml docker-compose.cut.yml \
                    docker-compose.cut-miner.yml docker-compose.cut-genesis-seed.yml \
                    docker-compose.yubikey.n5.yml docker-compose.oracle-attester.yml \
                    docker-compose.oracle-attester-yubikey.n5.yml; do
  printf '%s\n' 'services: {}' > "${FIXTURE_DIR}/${compose_file}"
done

EXTRA_COMPOSE="${TMP_DIR}/required-oracle.yml"
printf '%s\n' 'services:' '  oracle-reference: {image: fixture/oracle-reference}' > "${EXTRA_COMPOSE}"

cat > "${TMP_DIR}/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${COMPOSE_LOG}"
printf '\n' >> "${COMPOSE_LOG}"

if [[ "${1:-}" == "inspect" ]]; then
  [[ "${ORACLE_INSPECT_FAIL:-false}" == true ]] && exit 4
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${ORACLE_CONTAINER_ID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
    "${ORACLE_SERVICE_LABEL:-oracle-reference}" \
    "${ORACLE_ONEOFF:-False}" \
    "${ORACLE_STATE:-running}" \
    "${ORACLE_HEALTH:-healthy}" \
    "${ORACLE_ACTUAL_HASH:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  exit 0
fi
[[ "${1:-}" == "compose" ]] || exit 2
shift

profile_required=false
extra_required=false
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--profile" && "${args[$((i + 1))]:-}" == "oracle-reference" ]]; then
    profile_required=true
  fi
  if [[ "${args[$i]}" == "-f" && "${args[$((i + 1))]:-}" == *required-oracle.yml ]]; then
    extra_required=true
  fi
done

case " $* " in
  *' version '*)
    printf 'Docker Compose fixture\n'
    ;;
  *' config --services '*)
    [[ "${COMPOSE_CONFIG_FAIL:-false}" == true ]] && exit 5
    printf 'wrfcoin-node\n'
    if [[ "${profile_required}" == true || "${extra_required}" == true ]]; then
      printf 'oracle-reference\n'
    fi
    [[ "${COMPOSE_DUPLICATE_ORACLE:-false}" == true ]] && printf 'oracle-reference\n'
    [[ "${COMPOSE_MALFORMED_SERVICE:-false}" == true ]] && printf 'bad service name\n'
    true
    ;;
  *' config --format json '*)
    [[ "${COMPOSE_CONFIG_FAIL:-false}" == true ]] && exit 5
    # infra#972 fixture: the rendered backend carries REFERENCE_SHADOW, and the
    # sidecar is present exactly when its profile or deployment overlay is.
    oracle_json=''
    if [[ "${profile_required}" == true || "${extra_required}" == true ]]; then
      oracle_json=', "oracle-reference": {"image": "fixture/oracle-reference"}'
    fi
    printf '{"services": {"wrfcoin-backend": {"environment": {"REFERENCE_SHADOW": "%s"}}%s}}\n' \
      "${FIXTURE_REFERENCE_SHADOW:-0}" "${oracle_json}"
    ;;
  *' config --hash=oracle-reference '*)
    [[ "${COMPOSE_HASH_FAIL:-false}" == true ]] && exit 6
    printf 'oracle-reference %s\n' \
      "${ORACLE_EXPECTED_HASH:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
    ;;
  *' ps --format json '*)
    printf '[]\n'
    ;;
  *' ps -q oracle-reference '*)
    if [[ "${ORACLE_RUNNING:-false}" == true ]]; then
      printf '%s\n' "${ORACLE_CONTAINER_IDS:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    fi
    ;;
  *)
    exit 3
    ;;
esac
SH
chmod +x "${TMP_DIR}/bin/docker"

cat > "${TMP_DIR}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while (( $# > 0 )); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    --connect-timeout|--max-time) shift 2 ;;
    -sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "${url}" in
  */blockchain) body='{"height":10423}' ;;
  */network/info) body='{"peer_count":2}' ;;
  */readyz) body='ready' ;;
  *:4001/health) body='{"success":true,"data":{"status":"healthy","dependencies":{"cache":{"status":"up"},"core4":{"status":"up"},"database":{"status":"up"}}}}' ;;
  *:8000/health) body='{"status":"healthy","dependencies":{"database":{"critical":false,"status":"up","mode":"connected"}},"draining":false}' ;;
  *) body='ok' ;;
esac
printf '%s' "${body}" > "${output}"
if [[ -n "${CURL_FAIL_URL:-}" && "${url}" == *"${CURL_FAIL_URL}"* ]]; then
  printf '500'
  exit 0
fi
printf '200'
SH
chmod +x "${TMP_DIR}/bin/curl"

cat > "${TMP_DIR}/bin/ss" <<'SH'
#!/usr/bin/env bash
printf 'LISTEN 0 4096 0.0.0.0:9000 0.0.0.0:*\n'
SH
chmod +x "${TMP_DIR}/bin/ss"

run_health() {
  local script="$1" output="$2" log="$3"
  shift 3
  : > "${log}"
  env -u COMPOSE_PROFILES \
    PATH="${TMP_DIR}/bin:${PATH}" \
    COMPOSE_LOG="${log}" \
    WRFCOIN_HSM_MODE=yubikey \
    WRFCOIN_READER_TOKEN=fixture-reader-token \
    "$@" \
    bash "${script}" > "${output}" 2>&1
}

OPTIONAL_OUT="${TMP_DIR}/optional.out"
OPTIONAL_LOG="${TMP_DIR}/optional.log"
if ! run_health "${FIXTURE_DIR}/check-health.sh" "${OPTIONAL_OUT}" "${OPTIONAL_LOG}"; then
  cat "${OPTIONAL_OUT}" >&2
  fail "optional absent oracle-reference failed production health"
fi
grep -q 'Oracle reference: not configured; optional check skipped' "${OPTIONAL_OUT}" || \
  fail "optional absent PASS was not explicit"
! grep -q 'ps -q oracle-reference' "${OPTIONAL_LOG}" || \
  fail "optional absent path inferred configuration from container state"
! grep -q 'inspect' "${OPTIONAL_LOG}" || \
  fail "optional absent path inspected runtime container state"
ok "optional absent oracle-reference is an explicit production-path PASS"

STRAY_OUT="${TMP_DIR}/stray.out"
STRAY_LOG="${TMP_DIR}/stray.log"
if ! run_health "${FIXTURE_DIR}/check-health.sh" "${STRAY_OUT}" "${STRAY_LOG}" \
    ORACLE_RUNNING=true; then
  fail "inactive profile was affected by a stray oracle container"
fi
! grep -q 'ps -q oracle-reference' "${STRAY_LOG}" || \
  fail "inactive profile consulted a stray oracle container"
ok "inactive profile ignores stray oracle runtime state"

REQUIRED_OUT="${TMP_DIR}/required.out"
REQUIRED_LOG="${TMP_DIR}/required.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${REQUIRED_OUT}" "${REQUIRED_LOG}" \
    COMPOSE_PROFILES=oracle-reference; then
  fail "profile-required absent oracle-reference passed"
fi
grep -q 'FAIL  Oracle reference: container is not running' "${REQUIRED_OUT}" || \
  fail "profile-required absence did not fail for the oracle container"
grep -q -- '--profile oracle-reference' "${REQUIRED_LOG}" || \
  fail "effective oracle-reference profile did not reach Compose"
ok "profile-required absent oracle-reference is RED"

printf '%s\n' 'COMPOSE_PROFILES=oracle-reference' > "${FIXTURE_DIR}/.env"
ENV_PROFILE_OUT="${TMP_DIR}/env-profile.out"
ENV_PROFILE_LOG="${TMP_DIR}/env-profile.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${ENV_PROFILE_OUT}" "${ENV_PROFILE_LOG}"; then
  fail "deployment .env-required absent oracle-reference passed"
fi
grep -q -- '--profile oracle-reference' "${ENV_PROFILE_LOG}" || \
  fail "deployment .env profile did not reach Compose"
rm "${FIXTURE_DIR}/.env"
ok "deployment .env-required absent oracle-reference is RED"

MULTI_PROFILE_OUT="${TMP_DIR}/multi-profile.out"
MULTI_PROFILE_LOG="${TMP_DIR}/multi-profile.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${MULTI_PROFILE_OUT}" "${MULTI_PROFILE_LOG}" \
    COMPOSE_PROFILES='seed,oracle-reference,full'; then
  fail "oracle-reference inside multiple profiles was not required"
fi
grep -q -- '--profile oracle-reference' "${MULTI_PROFILE_LOG}" || \
  fail "oracle-reference profile token was not preserved"
ok "multiple effective profiles retain oracle-reference requirement"

HEALTHY_OUT="${TMP_DIR}/healthy.out"
HEALTHY_LOG="${TMP_DIR}/healthy.log"
if ! run_health "${FIXTURE_DIR}/check-health.sh" "${HEALTHY_OUT}" "${HEALTHY_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true; then
  cat "${HEALTHY_OUT}" >&2
  fail "matching configured healthy oracle-reference failed"
fi
grep -q 'Oracle reference: container is running, healthy, and matches effective Compose configuration' \
  "${HEALTHY_OUT}" || fail "required healthy PASS did not bind effective configuration"
ok "required healthy matching oracle-reference is GREEN"

STALE_OUT="${TMP_DIR}/stale.out"
STALE_LOG="${TMP_DIR}/stale.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${STALE_OUT}" "${STALE_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true \
    ORACLE_ACTUAL_HASH=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc; then
  fail "healthy stale-config oracle-reference passed"
fi
grep -q 'container config hash does not match' "${STALE_OUT}" || \
  fail "stale-config RED was caused by an unrelated failure"
ok "healthy stale-config oracle-reference is RED"

UNHEALTHY_OUT="${TMP_DIR}/unhealthy.out"
UNHEALTHY_LOG="${TMP_DIR}/unhealthy.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${UNHEALTHY_OUT}" "${UNHEALTHY_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true ORACLE_HEALTH=unhealthy; then
  fail "profile-required unhealthy oracle-reference passed"
fi
grep -q 'FAIL  Oracle reference: container health is unhealthy' "${UNHEALTHY_OUT}" || \
  fail "profile-required unhealthy container did not fail its health check"
ok "profile-required unhealthy oracle-reference is RED"

INSPECT_FAIL_OUT="${TMP_DIR}/inspect-fail.out"
INSPECT_FAIL_LOG="${TMP_DIR}/inspect-fail.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${INSPECT_FAIL_OUT}" "${INSPECT_FAIL_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true ORACLE_INSPECT_FAIL=true; then
  fail "oracle inspection failure passed"
fi
grep -q 'container inspection failed' "${INSPECT_FAIL_OUT}" || \
  fail "inspect-failure RED was caused by an unrelated failure"
ok "required oracle inspection failure is RED"

AMBIGUOUS_OUT="${TMP_DIR}/ambiguous.out"
AMBIGUOUS_LOG="${TMP_DIR}/ambiguous.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${AMBIGUOUS_OUT}" "${AMBIGUOUS_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true \
    ORACLE_CONTAINER_IDS=$'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\ndddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'; then
  fail "multiple oracle container IDs passed"
fi
grep -q 'container lookup is malformed or ambiguous' "${AMBIGUOUS_OUT}" || \
  fail "multiple-container RED was caused by an unrelated failure"
ok "ambiguous required oracle containers are RED"

UNKNOWN_OUT="${TMP_DIR}/unknown.out"
UNKNOWN_LOG="${TMP_DIR}/unknown.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${UNKNOWN_OUT}" "${UNKNOWN_LOG}" \
    COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true COMPOSE_CONFIG_FAIL=true; then
  fail "failed requirement resolution became optional"
fi
grep -q 'effective Compose configuration could not be rendered' "${UNKNOWN_OUT}" || \
  fail "UNKNOWN requirement RED was caused by an unrelated failure"
! grep -q 'ps -q oracle-reference' "${UNKNOWN_LOG}" || \
  fail "UNKNOWN requirement resolution consulted runtime state"
ok "UNKNOWN requirement resolution fails before runtime inspection"

for malformed_case in COMPOSE_DUPLICATE_ORACLE COMPOSE_MALFORMED_SERVICE; do
  malformed_out="${TMP_DIR}/${malformed_case}.out"
  malformed_log="${TMP_DIR}/${malformed_case}.log"
  if run_health "${FIXTURE_DIR}/check-health.sh" "${malformed_out}" "${malformed_log}" \
      COMPOSE_PROFILES=oracle-reference "${malformed_case}=true"; then
    fail "${malformed_case} inventory passed"
  fi
  ! grep -q 'ps -q oracle-reference' "${malformed_log}" || \
    fail "${malformed_case} inventory reached runtime inspection"
done
ok "malformed and duplicate service inventories are RED before runtime inspection"

MANDATORY_OUT="${TMP_DIR}/mandatory.out"
MANDATORY_LOG="${TMP_DIR}/mandatory.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${MANDATORY_OUT}" "${MANDATORY_LOG}" \
    CURL_FAIL_URL=localhost:4001/health; then
  fail "optional oracle path weakened a mandatory backend failure"
fi
grep -q 'FAIL  Backend dependency health: HTTP 500' "${MANDATORY_OUT}" || \
  fail "mandatory-probe RED was caused by an unrelated failure"
ok "mandatory service failures remain RED when oracle-reference is optional"

EXTRA_OUT="${TMP_DIR}/extra.out"
EXTRA_LOG="${TMP_DIR}/extra.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${EXTRA_OUT}" "${EXTRA_LOG}" \
    WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}"; then
  fail "deployment-extra-required absent oracle-reference passed"
fi
grep -q 'FAIL  Oracle reference: container is not running' "${EXTRA_OUT}" || \
  fail "deployment-owned required absence did not fail for the oracle container"
grep -q -- "-f ${EXTRA_COMPOSE}" "${EXTRA_LOG}" || \
  fail "deployment-owned extra Compose file did not reach health rendering"
ok "deployment-owned effective configuration makes absent oracle-reference RED"

mapfile -t health_extra_files < <(
  WRFCOIN_HSM_MODE=yubikey WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}" \
    bash "${FIXTURE_DIR}/check-health.sh" --print-compose-files
)
mapfile -t boot_extra_files < <(
  WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${FIXTURE_DIR}/hsm-init-custody.conf" \
  WRFCOIN_HSM_MODE=yubikey WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE="${EXTRA_COMPOSE}" \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files
)
[[ "${health_extra_files[*]}" == "${boot_extra_files[*]}" ]] || \
  fail "health and boot-heal deployment-owned Compose file order diverged"
[[ "${health_extra_files[-1]}" == "${EXTRA_COMPOSE}" ]] || \
  fail "deployment-owned Compose file lost final precedence"
ok "health and boot-heal share exact deployment-owned Compose custody order"

mapfile -t health_profiles < <(
  COMPOSE_PROFILES='seed,oracle-reference' \
    bash "${FIXTURE_DIR}/check-health.sh" --print-compose-profiles
)
mapfile -t boot_profiles < <(
  WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${FIXTURE_DIR}/hsm-init-custody.conf" \
  COMPOSE_PROFILES='seed,oracle-reference' \
    bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-profiles
)
[[ "${health_profiles[*]}" == 'seed oracle-reference' ]] || \
  fail "health effective profile derivation changed order"
[[ "${health_profiles[*]}" == "${boot_profiles[*]}" ]] || \
  fail "health and boot-heal effective profiles diverged"
ok "health and boot-heal share exact effective profile order"

OPTIONAL_FILES="${TMP_DIR}/optional-files.txt"
WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG="${FIXTURE_DIR}/hsm-init-custody.conf" \
WRFCOIN_HSM_MODE=yubikey \
  bash "${FIXTURE_DIR}/boot-heal.sh" --print-compose-files > "${OPTIONAL_FILES}"
mapfile -t expected_files < <(printf '%s\n' \
  "${FIXTURE_DIR}/docker-compose.testnet.yml" \
  "${FIXTURE_DIR}/docker-compose.override.yml" \
  "${FIXTURE_DIR}/docker-compose.local-paths.yml" \
  "${FIXTURE_DIR}/docker-compose.cut.yml" \
  "${FIXTURE_DIR}/docker-compose.cut-miner.yml" \
  "${FIXTURE_DIR}/docker-compose.cut-genesis-seed.yml" \
  "${FIXTURE_DIR}/docker-compose.yubikey.n5.yml")
mapfile -t actual_files < "${OPTIONAL_FILES}"
[[ "${actual_files[*]}" == "${expected_files[*]}" ]] || \
  fail "boot-heal did not retain the exact expected built-in file order"
for file in "${expected_files[@]}"; do
  grep -q -- "-f ${file}" "${OPTIONAL_LOG}" || \
    fail "health did not use boot-heal Compose input: ${file}"
done
ok "health and boot-heal use the same ordered built-in Compose files"

UNCONDITIONAL_MUTANT="${FIXTURE_DIR}/check-health-unconditional.sh"
cp "${FIXTURE_DIR}/check-health.sh" "${UNCONDITIONAL_MUTANT}"
sed -i '/ORACLE_REFERENCE_CHECK_BEGIN/,/ORACLE_REFERENCE_CHECK_END/c\  probe_compose_health "oracle-reference" "Oracle reference" "oracle-reference service not healthy"' \
  "${UNCONDITIONAL_MUTANT}"
if run_health "${UNCONDITIONAL_MUTANT}" "${TMP_DIR}/unconditional.out" \
    "${TMP_DIR}/unconditional.log"; then
  fail "unconditional-failure mutation stayed GREEN"
fi
ok "unconditional optional-service failure mutation is REAL-RED"

SILENT_SKIP_MUTANT="${FIXTURE_DIR}/check-health-silent-skip.sh"
cp "${FIXTURE_DIR}/check-health.sh" "${SILENT_SKIP_MUTANT}"
sed -i '/ORACLE_REFERENCE_CHECK_BEGIN/,/ORACLE_REFERENCE_CHECK_END/c\  :' \
  "${SILENT_SKIP_MUTANT}"
if ! run_health "${SILENT_SKIP_MUTANT}" "${TMP_DIR}/silent-skip.out" \
    "${TMP_DIR}/silent-skip.log" COMPOSE_PROFILES=oracle-reference; then
  fail "silent-skip mutation did not expose a required-service false GREEN"
fi
ok "silent required-service skip mutation is REAL-RED"

# --- infra#972: REFERENCE_SHADOW must never run without its sidecar ---------
grep -q 'PASS  Reference shadow: off (default; REFERENCE_SHADOW is not 1)' "${OPTIONAL_OUT}" || \
  fail "default render did not report shadow scoring as off"
ok "default render reports reference shadow off"

SHADOW_ALONE_OUT="${TMP_DIR}/shadow-alone.out"
SHADOW_ALONE_LOG="${TMP_DIR}/shadow-alone.log"
if run_health "${FIXTURE_DIR}/check-health.sh" "${SHADOW_ALONE_OUT}" "${SHADOW_ALONE_LOG}" \
    FIXTURE_REFERENCE_SHADOW=1; then
  fail "REFERENCE_SHADOW=1 without the oracle-reference profile passed"
fi
grep -q "FAIL  Reference shadow: REFERENCE_SHADOW=1 on wrfcoin-backend but oracle-reference is not in the effective Compose set" \
  "${SHADOW_ALONE_OUT}" || fail "shadow-without-sidecar RED was caused by an unrelated failure"
ok "REFERENCE_SHADOW=1 without the sidecar is RED with a named reason"

SHADOW_OK_OUT="${TMP_DIR}/shadow-ok.out"
SHADOW_OK_LOG="${TMP_DIR}/shadow-ok.log"
if ! run_health "${FIXTURE_DIR}/check-health.sh" "${SHADOW_OK_OUT}" "${SHADOW_OK_LOG}" \
    FIXTURE_REFERENCE_SHADOW=1 COMPOSE_PROFILES=oracle-reference ORACLE_RUNNING=true; then
  cat "${SHADOW_OK_OUT}" >&2
  fail "REFERENCE_SHADOW=1 with a healthy sidecar failed"
fi
grep -q 'WARN  Reference shadow: ON, advisory only with zero reward effect; the scorer is NOT at consensus parity yet (oracle-reference#9, backend#1169)' \
  "${SHADOW_OK_OUT}" || fail "shadow ON did not WARN that the scorer is out of parity"
ok "REFERENCE_SHADOW=1 with a healthy sidecar is GREEN and WARNs about parity"

SHADOW_MUTANT="${FIXTURE_DIR}/check-health-no-shadow-check.sh"
cp "${FIXTURE_DIR}/check-health.sh" "${SHADOW_MUTANT}"
sed -i '/REFERENCE_SHADOW_CHECK_BEGIN/,/REFERENCE_SHADOW_CHECK_END/c\  :' "${SHADOW_MUTANT}"
if ! run_health "${SHADOW_MUTANT}" "${TMP_DIR}/shadow-mutant.out" "${TMP_DIR}/shadow-mutant.log" \
    FIXTURE_REFERENCE_SHADOW=1; then
  fail "removing the shadow check did not expose a false GREEN (control is vacuous)"
fi
ok "removed shadow check turns shadow-without-sidecar GREEN: the check is REAL-RED"

printf 'PASS: oracle-reference health semantics (23 assertions including 3 REAL-RED controls)\n'
