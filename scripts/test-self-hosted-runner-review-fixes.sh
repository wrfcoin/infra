#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="${ROOT}/scripts/setup-self-hosted-runner.sh"

extract_function() {
  local name="$1"
  awk -v signature="${name}()" '
    index($0, signature " {") == 1 { capture = 1 }
    capture { print }
    capture && $0 == "}" { exit }
  ' "$SETUP_SCRIPT"
}

# Exercise the exact helper functions shipped in the setup script.
# shellcheck disable=SC2294 # eval input is extracted from this tracked file.
eval "$(extract_function runner_service_unit_name)"
# shellcheck disable=SC2294 # eval input is extracted from this tracked file.
eval "$(extract_function resolve_runner_service_unit)"
# shellcheck disable=SC2294 # eval input is extracted from this tracked file.
eval "$(extract_function configure_runner)"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# Review finding 2: with core4 and infra units present, the old alphabetical
# selection chooses core4. The shipped resolver must select infra by repo/name,
# and must refuse rather than fall back when the infra unit is absent.
unit_dir="${scratch}/systemd"
mkdir -p "$unit_dir"
core4_unit="actions.runner.wrfcoin-core4.n5pro-ct102.service"
infra_unit="actions.runner.wrfcoin-infra.n5pro-ct102.service"
touch "${unit_dir}/${core4_unit}" "${unit_dir}/${infra_unit}"

legacy_unit="$(basename "$(find "$unit_dir" -maxdepth 1 -name 'actions.runner.*.service' | sort | head -1)")"
[[ "$legacy_unit" == "$core4_unit" ]] || {
  echo "FAIL: fixture did not reproduce the alphabetical wrong-unit selection" >&2
  exit 1
}

resolved_unit="$(resolve_runner_service_unit "$unit_dir" "wrfcoin/infra" "n5pro-ct102")"
[[ "$resolved_unit" == "$infra_unit" ]] || {
  echo "FAIL: resolver selected ${resolved_unit}, expected ${infra_unit}" >&2
  exit 1
}

rm -f "${unit_dir}/${infra_unit}"
if resolve_runner_service_unit "$unit_dir" "wrfcoin/infra" "n5pro-ct102" >/dev/null; then
  echo "FAIL: resolver accepted the unrelated core4 service" >&2
  exit 1
fi

# Review finding 1: execute the shipped configuration wrapper with a fake sudo
# and config.sh. The credential must be absent from the longer-lived sudo/bash
# argv while remaining visible in config.sh's unavoidable --token argv.
grep -Fq 'OWN argv contains the plaintext token' "$SETUP_SCRIPT"
mkdir -p "${scratch}/bin" "${scratch}/runner" "${scratch}/capture"

cat >"${scratch}/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
set -euo pipefail
tr '\0' ' ' <"/proc/$$/cmdline" >"${CAPTURE_DIR}/sudo.cmdline"
[[ "$1" == "-u" ]]
shift 2
[[ "$1" == "--preserve-env=REG_TOKEN" ]]
shift
exec "$@"
SUDO

cat >"${scratch}/runner/config.sh" <<'CONFIG'
#!/usr/bin/env bash
set -euo pipefail
tr '\0' ' ' <"/proc/$$/cmdline" >"${CAPTURE_DIR}/config.cmdline"
tr '\0' ' ' <"/proc/${PPID}/cmdline" >"${CAPTURE_DIR}/parent.cmdline"
CONFIG

chmod +x "${scratch}/bin/sudo" "${scratch}/runner/config.sh"

sentinel='review-registration-secret-645'
export RUNNER_USER='review-runner'
export RUNNER_DIR="${scratch}/runner"
export REPO='wrfcoin/infra'
export RUNNER_NAME='n5pro-ct102'
export ALL_LABELS='self-hosted,linux,x64'
export EPHEMERAL_FLAG=''
REG_TOKEN="$sentinel"
CAPTURE_DIR="${scratch}/capture"
export CAPTURE_DIR
PATH="${scratch}/bin:${PATH}"
configure_runner

grep -Fq -- "--token ${sentinel}" "${CAPTURE_DIR}/config.cmdline"
if grep -Fq "$sentinel" "${CAPTURE_DIR}/sudo.cmdline" \
  || grep -Fq "$sentinel" "${CAPTURE_DIR}/parent.cmdline"; then
  echo "FAIL: registration token leaked into the sudo/bash wrapper argv" >&2
  exit 1
fi
[[ -z "${REG_TOKEN+x}" ]] || {
  echo "FAIL: REG_TOKEN remained exported after config.sh returned" >&2
  exit 1
}

echo "PASS: runner token boundary and exact service-unit selection verified"
