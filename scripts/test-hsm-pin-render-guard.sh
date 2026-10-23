#!/usr/bin/env bash
# Prove PIN-free Compose renders do not weaken the runtime HSM guard.
#
# Runs against the shipped testnet/docker-compose.local-paths.example.yml and, WHEN PRESENT,
# against the operator's real testnet/docker-compose.local-paths.yml (excluded from the public
# snapshot), so a real overlay cannot reintroduce PIN environment values or PIN-bearing
# commands unnoticed (infra#32 review). Absent real overlay: an explicit SKIP line.
#
#   bash scripts/test-hsm-pin-render-guard.sh              # the checks above
#   bash scripts/test-hsm-pin-render-guard.sh --self-test  # RED controls: mutant real overlays must fail
#
# HSM_GUARD_REAL_OVERLAY overrides the real overlay's path (used by --self-test).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXAMPLE_OVERLAY="${REPO_ROOT}/testnet/docker-compose.local-paths.example.yml"
REAL_OVERLAY="${HSM_GUARD_REAL_OVERLAY:-${REPO_ROOT}/testnet/docker-compose.local-paths.yml}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-hsm-guard.XXXXXX")"
BUILD_ROOT="${WORK_DIR}/build-root"
mkdir -p "$BUILD_ROOT"
trap 'rm -rf "$WORK_DIR"' EXIT

export POSTGRES_PASSWORD=render-test-postgres
export REDIS_PASSWORD=render-test-redis
export WRFCOIN_OPERATOR_TOKEN=render-test-operator
export WRFCOIN_CONTRIBUTOR_TOKEN=render-test-contributor
export JWT_SECRET=render-test-jwt
export OAUTH_STATE_SECRET=render-test-oauth
export RPC_API_KEY=render-test-rpc
export ADMIN_TOKEN=render-test-admin
export GRAFANA_ADMIN_PASSWORD=render-test-grafana
export N8N_WEBHOOK_SECRET=render-test-n8n
# CI-only RFC 5737 documentation fixtures for every positive render below.
# Production Compose retains both required-value interpolations.
export WRFCOIN_P2P_EXTERNAL_ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-/ip4/198.51.100.7/tcp/9000}"
export WRFCOIN_SEED_P2P_EXTERNAL_ADDR="${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:-/ip4/203.0.113.9/tcp/9000}"
ln -s "$REPO_ROOT" "${BUILD_ROOT}/infra"
export WRFCOIN_ROOT="$BUILD_ROOT"
unset WRFCOIN_HSM_PIN WRFCOIN_HSM_SO_PIN

# guard_overlay <third compose file> <label>: render the three-file stack PIN-free, then
#   1. no service carries a PIN value of its own (every *PIN* variable renders empty, and so
#      does any variable a *_PIN_ENV names) and no command or entrypoint passes a literal
#      --pin/--so-pin (only $-references to the runtime environment);
#   2. both SoftHSM initializers still refuse a missing and the unsafe-default SO-PIN;
#   3. the node initializer stays alive without PINs only in explicit sync-only mode.
guard_overlay() {
  local overlay="$1" label="$2"
  local run_dir rendered command_dir
  run_dir="$(mktemp -d "${WORK_DIR}/run.XXXXXX")"
  rendered="${run_dir}/rendered.json"
  command_dir="${run_dir}/commands"
  mkdir -p "$command_dir"
  local compose_files=(
    -f "${REPO_ROOT}/testnet/docker-compose.testnet.yml"
    -f "${REPO_ROOT}/testnet/docker-compose.override.yml"
    -f "$overlay"
  )

  echo "== ${label}: ${overlay#"${REPO_ROOT}/"} =="
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${compose_files[@]}" config -q
  if docker buildx version >/dev/null 2>&1; then
    # Buildx makes `--print` a render-only Bake output; no contexts are sent.
    bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${compose_files[@]}" build --print >/dev/null
  else
    # Compose without Buildx cannot print Bake output. Its global dry-run still
    # exercises build resolution without producing images.
    bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --dry-run "${compose_files[@]}" build >/dev/null
  fi
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile seed "${compose_files[@]}" config --format json > "$rendered"

  python3 - "$rendered" "$command_dir" "$label" <<'PY'
import json
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
label = sys.argv[3]
config = json.loads(config_path.read_text(encoding="utf-8"))

# 1. No PIN value of its own anywhere in the rendered stack. The render runs with both PINs
# unset, so a PIN variable that is not empty was set by a compose file (or its env_file).
VARIABLE_NAME = re.compile(r"[A-Z_][A-Z0-9_]*")
LITERAL_PIN_FLAG = re.compile(r"--(?:so-)?pin(?:=|\s+)(?![\"']?\$)\S+")
problems = []
for service_name, service in sorted(config.get("services", {}).items()):
    environment = service.get("environment") or {}
    if isinstance(environment, list):
        environment = dict(item.split("=", 1) if "=" in item else (item, None) for item in environment)
    for name, value in environment.items():
        if name.upper().endswith("_PIN_ENV"):
            if value is not None and not VARIABLE_NAME.fullmatch(str(value)):
                problems.append(f"{service_name}: {name} must name a variable")
            elif value and environment.get(value) not in (None, ""):
                problems.append(f"{service_name}: {name} points at {value}, which carries a value")
        elif "PIN" in name.upper() and value not in (None, ""):
            problems.append(f"{service_name}: environment {name} carries a value")
    for field in ("command", "entrypoint"):
        text = service.get(field)
        if isinstance(text, list):
            text = " ".join(str(part) for part in text)
        if text and LITERAL_PIN_FLAG.search(str(text).replace("$$", "$")):
            problems.append(f"{service_name}: {field} passes a literal --pin/--so-pin")
if problems:
    # Names only; the offending values are never printed.
    raise SystemExit("FAIL: " + label + " reintroduces PIN material:\n  " + "\n  ".join(problems))

for service_name in ("softhsm-init", "softhsm-seed-init"):
    command = config["services"][service_name]["command"]
    if isinstance(command, list):
        if len(command) != 1:
            raise AssertionError(f"{service_name}: unexpected command array: {command!r}")
        command = command[0]
    if not isinstance(command, str):
        raise AssertionError(f"{service_name}: unexpected command type: {type(command)!r}")
    # Compose keeps escaped dollars in `config` output, then passes a single
    # dollar to the container command at runtime.
    command = command.replace("$$", "$")
    (output_dir / service_name).write_text(command, encoding="utf-8")
PY
  echo "PASS: ${label}: no PIN value in any service environment, command or entrypoint"

  local service_name command_file output status
  for service_name in softhsm-init softhsm-seed-init; do
    command_file="${command_dir}/${service_name}"

    set +e
    output="$(
      WRFCOIN_HSM_PIN=runtime-test-user \
        WRFCOIN_HSM_SO_PIN='' \
        /bin/sh -c "$(cat "$command_file")" 2>&1
    )"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]] || ! grep -q "HSM SO-PIN not configured" <<<"$output"; then
      printf 'FAIL: %s: %s did not refuse a missing HSM SO-PIN\n%s\n' "$label" "$service_name" "$output" >&2
      return 1
    fi

    set +e
    output="$(
      WRFCOIN_HSM_PIN=runtime-test-user \
        WRFCOIN_HSM_SO_PIN=0000 \
        /bin/sh -c "$(cat "$command_file")" 2>&1
    )"
    status=$?
    set -e
    if [[ "$status" -eq 0 ]] || ! grep -q "refusing unsafe default HSM SO-PIN 0000" <<<"$output"; then
      printf 'FAIL: %s: %s did not refuse the unsafe default HSM SO-PIN\n%s\n' "$label" "$service_name" "$output" >&2
      return 1
    fi

    printf 'PASS: %s: %s refuses missing and unsafe-default SO-PINs\n' "$label" "$service_name"
  done

  # The ordinary node initializer must remain alive and healthy without either PIN only when the
  # join script explicitly selects the sync-only role. The seed initializer has no such bypass.
  local sync_command="${command_dir}/softhsm-init" sync_output sync_status
  set +e
  sync_output="$(
    timeout 1 env \
      WRFCOIN_SYNC_ONLY=1 \
      WRFCOIN_HSM_PIN='' \
      WRFCOIN_HSM_SO_PIN='' \
      /bin/sh -c "$(cat "${sync_command}")" 2>&1
  )"
  sync_status=$?
  set -e
  if [ "${sync_status}" -ne 124 ] \
    || ! grep -q "Sync-only mode: no signing token will be created" <<<"${sync_output}"; then
    printf 'FAIL: %s: sync-only initializer did not stay healthy without HSM PINs (rc=%s)\n%s\n' \
      "$label" "${sync_status}" "${sync_output}" >&2
    return 1
  fi
  echo "PASS: ${label}: explicit sync-only mode stays alive without creating an HSM token"
  echo "PASS: ${label}: PIN-free three-file config and build renders succeed"
}

check_entrypoint() {
  if ! grep -q 'WRFCOIN_SYNC_ONLY:-0.*= "1"' "${REPO_ROOT}/infra/docker/hsm-entrypoint.sh" \
    || ! grep -q 'exec_wrfcoin_node "\$@"' "${REPO_ROOT}/infra/docker/hsm-entrypoint.sh"; then
    echo "FAIL: image entrypoint does not route explicit sync-only mode through the uid-dropping exec helper" >&2
    exit 1
  fi
  echo "PASS: the image entrypoint routes explicit sync-only mode through the uid-dropping exec helper"
}

# RED controls for the real-overlay check: each mutant is a copy of the shipped example plus one
# PIN reintroduction, used as the "real" overlay; the guard must refuse every one of them, and
# must accept the unmodified copy (so a refusal is about the mutation, not the harness).
self_test() {
  local mutants_dir="${WORK_DIR}/mutants" name rc
  mkdir -p "$mutants_dir"
  # write_mutant <name> <service> <keys>: a copy of the shipped example with <keys> (4-space
  # indented service keys) added to <service>: under the example's own entry when it has one,
  # else as a new entry directly under services:. The key must not already exist on that entry.
  write_mutant() {
    python3 - "$EXAMPLE_OVERLAY" "${mutants_dir}/$1.yml" "$2" "$3" <<'PY'
import sys
example, out, service, keys = sys.argv[1:5]
lines = open(example, encoding="utf-8").read().splitlines(keepends=True)
block = keys.rstrip("\n") + "\n"
entry = f"  {service}:\n"
if entry in lines:
    at = lines.index(entry) + 1
else:
    at = lines.index("services:\n") + 1
    block = entry + block
lines[at:at] = [block]
open(out, "w", encoding="utf-8").write("".join(lines))
PY
    grep -qF "$(printf '%s' "$3" | head -1)" "${mutants_dir}/$1.yml" || { echo "SELF-TEST FAIL: mutant $1 not written" >&2; exit 1; }
  }
  cp "$EXAMPLE_OVERLAY" "${mutants_dir}/benign-copy.yml"
  write_mutant pin-env wrfcoin-node '    environment:
      WRFCOIN_HSM_PIN: "123456"'
  write_mutant so-pin-env softhsm-init '    environment:
      WRFCOIN_HSM_SO_PIN: "87654321"'
  write_mutant pin-env-indirection wrfcoin-node '    environment:
      WRFCOIN_HSM_PIN_ENV: NODE_SIGNING_SECRET
      NODE_SIGNING_SECRET: "123456"'
  # Compose resolves relative paths against the project directory (testnet/), so the env file is absolute.
  # (An env_file WRFCOIN_HSM_PIN is overridden by the base `environment: WRFCOIN_HSM_PIN: ${...:-}` and
  # renders empty, so it never reaches the container; a PIN variable the base does not set does.)
  printf 'SOFTHSM_USER_PIN=123456\n' > "${mutants_dir}/hsm-pins.env"
  write_mutant pin-env-file wrfcoin-node "    env_file:
      - ${mutants_dir}/hsm-pins.env"
  write_mutant literal-pin-command softhsm-init '    command: ["sh", "-c", "softhsm2-util --init-token --slot 0 --label wrfcoin --pin 123456 --so-pin 87654321"]'

  echo "== self-test: the unmodified example as the real overlay must pass =="
  if ! HSM_GUARD_REAL_OVERLAY="${mutants_dir}/benign-copy.yml" bash "${BASH_SOURCE[0]}" >"${WORK_DIR}/benign.log" 2>&1; then
    cat "${WORK_DIR}/benign.log" >&2
    echo "SELF-TEST FAIL: the benign real-overlay copy was refused" >&2
    exit 1
  fi
  echo "  ok   benign copy accepted"
  local survived=0
  for name in pin-env so-pin-env pin-env-indirection pin-env-file literal-pin-command; do
    set +e
    HSM_GUARD_REAL_OVERLAY="${mutants_dir}/${name}.yml" bash "${BASH_SOURCE[0]}" >"${WORK_DIR}/${name}.log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && grep -q "operator real overlay" "${WORK_DIR}/${name}.log" \
      && grep -q "^FAIL: " "${WORK_DIR}/${name}.log"; then
      echo "  ok   mutant refused: ${name} ($(grep -m1 -A1 '^FAIL: ' "${WORK_DIR}/${name}.log" | tail -1 | sed 's/^ *//'))"
    else
      echo "  BAD  mutant survived: ${name} (rc=${rc})"
      survived=$((survived + 1))
    fi
    if grep -q -e 123456 -e 87654321 "${WORK_DIR}/${name}.log"; then
      echo "  BAD  ${name}: the guard printed a PIN value"
      survived=$((survived + 1))
    fi
  done
  if [ "$survived" -ne 0 ]; then
    echo "SELF-TEST FAIL: ${survived} problem(s)" >&2
    exit 1
  fi
  echo "SELF-TEST PASS: every PIN-reintroducing real overlay is refused, the benign copy is accepted"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

guard_overlay "$EXAMPLE_OVERLAY" "shipped example overlay"
if [ -f "$REAL_OVERLAY" ]; then
  guard_overlay "$REAL_OVERLAY" "operator real overlay"
else
  echo "SKIP: operator real overlay ${REAL_OVERLAY#"${REPO_ROOT}/"} absent (not part of the public snapshot); only the shipped example was checked"
fi
check_entrypoint
