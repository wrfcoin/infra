#!/usr/bin/env bash
# Prove PIN-free Compose renders do not weaken the runtime HSM guard.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RENDERED_CONFIG="$(mktemp "${TMPDIR:-/tmp}/wrfcoin-hsm-render.XXXXXX.json")"
COMMAND_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-hsm-commands.XXXXXX")"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-hsm-build-root.XXXXXX")"
trap 'rm -f "$RENDERED_CONFIG"; rm -rf "$COMMAND_DIR" "$BUILD_ROOT"' EXIT

COMPOSE_FILES=(
  -f "${REPO_ROOT}/testnet/docker-compose.testnet.yml"
  -f "${REPO_ROOT}/testnet/docker-compose.override.yml"
  -f "${REPO_ROOT}/testnet/docker-compose.local-paths.example.yml"
)

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

bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${COMPOSE_FILES[@]}" config -q
if docker buildx version >/dev/null 2>&1; then
  # Buildx makes `--print` a render-only Bake output; no contexts are sent.
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" "${COMPOSE_FILES[@]}" build --print >/dev/null
else
  # Compose without Buildx cannot print Bake output. Its global dry-run still
  # exercises build resolution without producing images.
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --dry-run "${COMPOSE_FILES[@]}" build >/dev/null
fi
bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile seed "${COMPOSE_FILES[@]}" config --format json > "$RENDERED_CONFIG"

python3 - "$RENDERED_CONFIG" "$COMMAND_DIR" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
output_dir = pathlib.Path(sys.argv[2])
config = json.loads(config_path.read_text(encoding="utf-8"))

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

for service_name in softhsm-init softhsm-seed-init; do
  command_file="${COMMAND_DIR}/${service_name}"

  set +e
  output="$(
    WRFCOIN_HSM_PIN=runtime-test-user \
      WRFCOIN_HSM_SO_PIN='' \
      /bin/sh -c "$(cat "$command_file")" 2>&1
  )"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]] || ! grep -q "HSM SO-PIN not configured" <<<"$output"; then
    printf 'FAIL: %s did not refuse a missing HSM SO-PIN\n%s\n' "$service_name" "$output" >&2
    exit 1
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
    printf 'FAIL: %s did not refuse the unsafe default HSM SO-PIN\n%s\n' "$service_name" "$output" >&2
    exit 1
  fi

  printf 'PASS: %s refuses missing and unsafe-default SO-PINs\n' "$service_name"
done

# The ordinary node initializer must remain alive and healthy without either PIN only when the
# join script explicitly selects the sync-only role. The seed initializer has no such bypass.
sync_command="${COMMAND_DIR}/softhsm-init"
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
  printf 'FAIL: sync-only initializer did not stay healthy without HSM PINs (rc=%s)\n%s\n' \
    "${sync_status}" "${sync_output}" >&2
  exit 1
fi

if ! grep -q 'WRFCOIN_SYNC_ONLY:-0.*= "1"' "${REPO_ROOT}/infra/docker/hsm-entrypoint.sh" \
  || ! grep -q 'exec_wrfcoin_node "\$@"' "${REPO_ROOT}/infra/docker/hsm-entrypoint.sh"; then
  echo "FAIL: image entrypoint does not route explicit sync-only mode through the uid-dropping exec helper" >&2
  exit 1
fi

echo "PASS: explicit sync-only mode stays alive without creating an HSM token"

echo "PASS: PIN-free three-file config and build renders succeed"
