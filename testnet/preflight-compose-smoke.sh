#!/usr/bin/env bash
#
# preflight-compose-smoke.sh — REAL boot smoke for the testnet compose stack
# (backend#910 finding 3).
#
# Everything previously called a "compose smoke test" in this repo validated
# rendered YAML without starting a container (scripts/test-compose-smoke.sh
# says so itself). This script is the missing half: it actually runs
# `docker compose up -d`, waits for container health, probes a real endpoint,
# and tears everything down — so "the stack boots" is an executed claim, not
# a rendered one.
#
# It is a PRE-DEPLOY step for the operator/deploy host, not a CI job: the
# CT102 runners have no Compose (and hosted runners are billing-dead), and a
# boot smoke belongs where the images that are about to be deployed exist.
# Run it on the workstation before shipping a stack change, and on CT101
# before `docker compose up` of a new cut.
#
# Isolation: runs under its own project name with docker-compose.smoke.yml,
# which resets container_name (the base file pins fixed names), publishes NO
# host ports, and disables restarts. It is safe next to a live stack; its
# `down -v` removes only the smoke project's containers/volumes.
#
# Usage:
#   bash testnet/preflight-compose-smoke.sh                  # postgres redis wrfcoin-backend
#   bash testnet/preflight-compose-smoke.sh postgres redis   # subset (e.g. no backend image yet)
#
# Environment:
#   SMOKE_PROJECT       project name (default: collision-resistant generated name)
#   WRFCOIN_DEPLOY_PROJECT live project name that must never be reused
#                         (default wrfcoin-testnet)
#   SMOKE_TIMEOUT_SECS  per-service health wait (default 120)
#   SMOKE_PROBE_INTERVAL_SECS delay between backend probes (default 3)
#   SMOKE_ENV_FILE      operator env file (default testnet/.env)
#
# Exit 0 only when every requested service reaches a healthy/running state
# AND the backend (when requested) answers /health with a JSON body.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" || exit 1

SMOKE_PROJECT="${SMOKE_PROJECT:-wrfcoin-preflight-smoke-${UID}-$(date +%s)-$$}"
DEPLOY_PROJECT="${WRFCOIN_DEPLOY_PROJECT:-${COMPOSE_PROJECT_NAME:-wrfcoin-testnet}}"
SMOKE_TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-120}"
SMOKE_PROBE_INTERVAL_SECS="${SMOKE_PROBE_INTERVAL_SECS:-3}"
SMOKE_ENV_FILE="${SMOKE_ENV_FILE:-.env}"
SERVICES=("$@")
if [ ${#SERVICES[@]} -eq 0 ]; then
  SERVICES=(postgres redis wrfcoin-backend)
fi

case "${SMOKE_PROJECT}" in
  ''|*[!a-z0-9_-]*)
    echo "ERROR: SMOKE_PROJECT must contain only lowercase letters, digits, '_' or '-'." >&2
    exit 1
    ;;
esac
if [ "${SMOKE_PROJECT}" = "${DEPLOY_PROJECT}" ] || [ "${SMOKE_PROJECT}" = "wrfcoin-testnet" ]; then
  echo "ERROR: refusing smoke project '${SMOKE_PROJECT}': it is the deployment project." >&2
  exit 1
fi

for service in "${SERVICES[@]}"; do
  case "${service}" in
    postgres|redis|wrfcoin-backend) ;;
    *)
      echo "ERROR: unsupported smoke service '${service}'; allowed: postgres redis wrfcoin-backend." >&2
      exit 1
      ;;
  esac
done

if [ ! -f "${SMOKE_ENV_FILE}" ]; then
  echo "ERROR: ${SMOKE_ENV_FILE} not found. The smoke boots the real composition," >&2
  echo "       which requires the operator env (run setup-env.sh first)." >&2
  exit 1
fi
for required_command in docker jq; do
  if ! command -v "${required_command}" >/dev/null 2>&1; then
    echo "ERROR: required command '${required_command}' is unavailable." >&2
    exit 1
  fi
done

compose() {
  docker compose \
    --env-file "${SMOKE_ENV_FILE}" \
    -p "${SMOKE_PROJECT}" \
    -f docker-compose.testnet.yml \
    -f docker-compose.override.yml \
    -f docker-compose.smoke.yml \
    "$@"
}

# Refuse before installing the cleanup trap if this project name already owns
# anything. Otherwise `down -v` could destroy a live or previous project's
# volumes even when `compose up` never ran in this invocation.
existing_resources="$({
  docker ps -aq --filter "label=com.docker.compose.project=${SMOKE_PROJECT}"
  docker volume ls -q --filter "label=com.docker.compose.project=${SMOKE_PROJECT}"
  docker network ls -q --filter "label=com.docker.compose.project=${SMOKE_PROJECT}"
} | sed '/^[[:space:]]*$/d')"
if [ -n "${existing_resources}" ]; then
  echo "ERROR: refusing pre-existing Compose project '${SMOKE_PROJECT}'; no cleanup was armed." >&2
  exit 1
fi

cleanup() {
  echo "==> Tearing down smoke project '${SMOKE_PROJECT}' (containers + volumes)"
  compose down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Booting for real: ${SERVICES[*]} (project ${SMOKE_PROJECT}, no published ports)"
if ! compose up -d --no-build --no-deps "${SERVICES[@]}"; then
  echo "ERROR: compose up failed — the stack does not boot as composed." >&2
  echo "       (A missing image here means the deploy would fail the same way.)" >&2
  exit 1
fi

# `--no-deps` is the primary closure fence. Verify Docker agrees after startup:
# no container carrying this project label may belong to an unrequested service.
actual_services="$(docker ps -a \
  --filter "label=com.docker.compose.project=${SMOKE_PROJECT}" \
  --format '{{.Label "com.docker.compose.service"}}' \
  | sed '/^[[:space:]]*$/d' | sort -u)"
while IFS= read -r actual; do
  [ -n "${actual}" ] || continue
  allowed=false
  for requested in "${SERVICES[@]}"; do
    if [ "${actual}" = "${requested}" ]; then
      allowed=true
      break
    fi
  done
  if [ "${allowed}" != true ]; then
    echo "ERROR: unexpected service '${actual}' appeared in smoke project '${SMOKE_PROJECT}'." >&2
    exit 1
  fi
done <<< "${actual_services}"

# --- Wait for health -------------------------------------------------------
# A service with a healthcheck must reach 'healthy'; one without must at
# least stay 'running' (restarts are disabled by the overlay, so a crash
# stays visible).
deadline=$(( $(date +%s) + SMOKE_TIMEOUT_SECS ))
for service in "${SERVICES[@]}"; do
  while :; do
    cid="$(compose ps -q "${service}" | head -1)"
    if [ -z "${cid}" ]; then
      echo "ERROR: ${service}: no container exists — it exited and was removed, or never started." >&2
      exit 1
    fi
    state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo missing)"
    if [ "${state}" != "running" ]; then
      echo "ERROR: ${service}: state '${state}' (health '${health}') — the stack does not boot." >&2
      docker logs --tail 40 "${cid}" >&2 || true
      exit 1
    fi
    if [ "${health}" = "healthy" ] || [ "${health}" = "none" ]; then
      echo "    ${service}: running (health: ${health})"
      break
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "ERROR: ${service}: still '${health}' after ${SMOKE_TIMEOUT_SECS}s." >&2
      docker logs --tail 40 "${cid}" >&2 || true
      exit 1
    fi
    sleep 3
  done
done

# --- Probe a real endpoint --------------------------------------------------
# The backend, when requested, must ANSWER — from inside the container, since
# the overlay publishes no host ports. 200 is a fully healthy backend; 503
# with a JSON body is also a PASS for the boot smoke: it is the backend's
# own fail-closed report that a dependency (core4 node, absent here by
# design) is down — which proves the server booted, bound, and serves its
# health contract (backend#1051).
for service in "${SERVICES[@]}"; do
  if [ "${service}" = "wrfcoin-backend" ]; then
    cid="$(compose ps -q wrfcoin-backend | head -1)"
    probe_deadline=$(( $(date +%s) + SMOKE_TIMEOUT_SECS ))
    response=""
    while :; do
      if response="$(docker exec "${cid}" sh -c '
        body_file=$(mktemp)
        trap '\''rm -f "$body_file"'\'' EXIT
        # backend#1234: the data.status/dependencies contract below is served
        # only to an operator/reader bearer, taken from the container environment.
        # The header goes to curl on stdin (printf is a shell builtin), so the
        # token never appears in any process argv.
        code=$(printf "Authorization: Bearer %s\n" "${WRFCOIN_READER_TOKEN:-${WRFCOIN_OPERATOR_TOKEN:-}}" |
          curl -sS -m 10 -H @- -o "$body_file" -w "%{http_code}" http://localhost:4001/health)
        curl_rc=$?
        if [ "${curl_rc}" -ne 0 ]; then
          exit "${curl_rc}"
        fi
        printf "%s\n" "$code"
        cat "$body_file"
      ' 2>/dev/null)"; then
        # curl normally returns nonzero for connection failures, but retain an
        # explicit 000 fence so a wrapper cannot turn not-ready into a terminal
        # HTTP response. Other completed HTTP responses are validated below.
        probe_code="${response%%$'\n'*}"
        if [ -n "${probe_code}" ] && [ "${probe_code}" != "000" ]; then
          break
        fi
      fi
      if [ "$(date +%s)" -ge "${probe_deadline}" ]; then
        echo "ERROR: /health did not answer within ${SMOKE_TIMEOUT_SECS}s." >&2
        exit 1
      fi
      sleep "${SMOKE_PROBE_INTERVAL_SECS}"
    done
    code="${response%%$'\n'*}"
    body="${response#*$'\n'}"
    case "${code}" in
      200)
        if ! printf '%s' "${body}" | jq -e \
          '.success == true and .data.status == "healthy"' >/dev/null 2>&1; then
          echo "ERROR: /health answered 200 without the healthy contract: ${body:0:200}" >&2
          exit 1
        fi
        echo "    wrfcoin-backend: /health answered 200 with the healthy contract."
        ;;
      503)
        if ! printf '%s' "${body}" | jq -e \
          '.success == false and .data.status == "unhealthy" and .data.dependencies.core4.status == "down"' \
          >/dev/null 2>&1; then
          echo "ERROR: /health answered 503 without the expected Core4-down contract: ${body:0:200}" >&2
          exit 1
        fi
        echo "    wrfcoin-backend: /health answered 503 with the expected Core4-down contract."
        ;;
      *)
        echo "ERROR: /health answered '${code:-nothing}' — the backend did not serve." >&2
        exit 1
        ;;
    esac
  fi
done

echo "==> BOOT SMOKE PASS: ${SERVICES[*]} started, reached health, and served."
