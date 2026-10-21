#!/usr/bin/env bash
# Shared immutable validator-image gate for setup, promotion, and readiness.
set -euo pipefail

PROFILE="public-release"
IMAGE="${WRFCOIN_TESTNET_RUNTIME_IMAGE:-}"
CHECK_RUNNING=false
CONTAINERS=()

fail() { echo "RUNTIME_IMAGE_FAIL: $*" >&2; exit 1; }

# The seed pair is in the default --check-running set only while the "seed"
# Compose profile is active (COMPOSE_PROFILES from the environment, else the
# deploy .env beside this tree). Seed retired by owner ruling 2026-09-27
# (infra#1057 Q4); re-adding the profile restores the check.
seed_profile_active() {
  local value="${COMPOSE_PROFILES-}" env_file
  env_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
  if [[ -z "${COMPOSE_PROFILES+x}" && -f "${env_file}" ]]; then
    value="$(sed -n 's/^[[:space:]]*COMPOSE_PROFILES[[:space:]]*=//p' "${env_file}" | tail -1 | tr -d "\"' ")"
  fi
  [[ ",${value// /,}," == *",seed,"* ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --image) IMAGE="${2:-}"; shift 2 ;;
    --check-running) CHECK_RUNNING=true; shift ;;
    --container) CONTAINERS+=("${2:-}"); shift 2 ;;
    --help|-h)
      echo "usage: $0 [--profile public-release|developer] [--image IMAGE] [--check-running] [--container NAME]"
      exit 0
      ;;
    *) fail "unknown argument '$1'" ;;
  esac
done

case "$PROFILE" in
  public-release)
    if [[ ! "$IMAGE" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      fail "profile=public-release configured=${IMAGE:-<missing>} expected=sha256:<64-lowercase-hex-local-image-id>"
    fi
    echo "RUNTIME_IMAGE_PASS: classification=IMMUTABLE profile=public-release configured=${IMAGE}"
    ;;
  developer|demo)
    [[ -n "$IMAGE" ]] || fail "profile=${PROFILE} configured=<missing>"
    echo "RUNTIME_IMAGE_PASS: classification=NON_RELEASE profile=${PROFILE} configured=${IMAGE}"
    ;;
  *) fail "unknown profile=${PROFILE}; expected public-release or developer" ;;
esac

if [[ "$CHECK_RUNNING" == true ]]; then
  [[ "$PROFILE" == "public-release" ]] || fail "running-image evidence is release-only; profile=${PROFILE} classification=NON_RELEASE"
  command -v docker >/dev/null 2>&1 || fail "configured=${IMAGE} running=<unavailable> reason=docker-not-found"
  if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    CONTAINERS=(
      wrfcoin-testnet-softhsm-init
      wrfcoin-testnet-node
    )
    if seed_profile_active; then
      CONTAINERS+=(wrfcoin-testnet-seed-softhsm-init wrfcoin-testnet-seed)
    else
      echo "RUNTIME_IMAGE_NOTE: seed profile not active (seed retired, infra#1057); seed containers not checked"
    fi
  fi
  for container in "${CONTAINERS[@]}"; do
    running="$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || true)"
    [[ -n "$running" ]] || fail "container=${container} configured=${IMAGE} running=<unavailable>"
    if [[ "$running" != "$IMAGE" ]]; then
      fail "container=${container} configured=${IMAGE} running=${running} mismatch=true"
    fi
    echo "RUNTIME_IMAGE_MATCH: container=${container} configured=${IMAGE} running=${running}"
  done
fi
