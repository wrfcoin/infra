#!/usr/bin/env bash
# Shared effective Compose custody for boot reconciliation and health checks.

wrfcoin_compose_env_value() {
  local testnet_dir="$1" key="$2"
  [[ -f "${testnet_dir}/.env" ]] || return 0
  awk -F= -v key="${key}" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      print value
      exit
    }
  ' "${testnet_dir}/.env"
}

wrfcoin_detect_hsm_mode() {
  local testnet_dir="$1" value
  if [[ -n "${WRFCOIN_HSM_MODE:-}" ]]; then
    value="${WRFCOIN_HSM_MODE}"
  else
    value="$(wrfcoin_compose_env_value "${testnet_dir}" WRFCOIN_HSM_MODE)"
  fi
  printf '%s\n' "${value,,}"
}

wrfcoin_append_required_compose() {
  local path="$1"
  if [[ ! -f "${path}" || ! -r "${path}" ]]; then
    echo "ERROR: boot-heal custody companion is not a readable regular file: ${path}" >&2
    return 1
  fi
  COMPOSE_FILES+=("${path}")
}

wrfcoin_init_compose_inputs() {
  local testnet_dir="$1" extra profile profiles_value cut_genesis=""
  local -a parsed_profiles=()

  if [[ -r "${testnet_dir}/cut-pins.env" ]]; then
    cut_genesis="$(awk -F= '/^WRFCOIN_CUT_GENESIS_HASH=/ {print substr($0, index($0, "=") + 1); exit}' "${testnet_dir}/cut-pins.env")"
  fi
  if [[ -n "${cut_genesis}" && ! -f "${testnet_dir}/docker-compose.cut.yml" ]]; then
    if [[ "${WRFCOIN_ALLOW_UNPINNED_GENESIS:-}" == "1" ]]; then
      echo "NON_RELEASE: genesis pin overlay missing; WRFCOIN_ALLOW_UNPINNED_GENESIS=1 bypass is active" >&2
    else
      echo "ERROR: genesis pin overlay missing — run testnet/scripts/render-cut-overlay.sh" >&2
      return 1
    fi
  fi

  COMPOSE_FILES=("${testnet_dir}/docker-compose.testnet.yml")
  for extra in docker-compose.override.yml docker-compose.local-paths.yml \
               docker-compose.cut.yml docker-compose.cut-miner.yml \
               docker-compose.cut-genesis-seed.yml \
               docker-compose.container-health-watch.yml; do
    if [[ -f "${testnet_dir}/${extra}" ]]; then
      COMPOSE_FILES+=("${testnet_dir}/${extra}")
    fi
  done

  HSM_MODE="$(wrfcoin_detect_hsm_mode "${testnet_dir}")"
  if [[ "${HSM_MODE}" == "yubikey" && -f "${testnet_dir}/docker-compose.yubikey.n5.yml" ]]; then
    COMPOSE_FILES+=("${testnet_dir}/docker-compose.yubikey.n5.yml")
  fi

  if [[ -n "${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE:-}" ]]; then
    if [[ "${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE}" != /* ]]; then
      echo "ERROR: WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE must be an absolute path" >&2
      return 1
    fi
    if [[ ! -f "${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE}" || ! -r "${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE}" ]]; then
      echo "ERROR: WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE is not a readable regular file: ${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE}" >&2
      return 1
    fi

    wrfcoin_append_required_compose "${testnet_dir}/docker-compose.oracle-attester.yml"
    if [[ "${HSM_MODE}" == "yubikey" ]]; then
      wrfcoin_append_required_compose "${testnet_dir}/docker-compose.oracle-attester-yubikey.n5.yml"
    fi
    # Deployment custody has final precedence over every authored overlay.
    COMPOSE_FILES+=("${WRFCOIN_BOOT_HEAL_EXTRA_COMPOSE}")
  fi

  COMPOSE_PROFILE_ARGS=()
  EFFECTIVE_COMPOSE_PROFILES=()
  if [[ -n "${COMPOSE_PROFILES+x}" ]]; then
    profiles_value="${COMPOSE_PROFILES}"
  else
    profiles_value="$(wrfcoin_compose_env_value "${testnet_dir}" COMPOSE_PROFILES)"
  fi
  profiles_value="${profiles_value//,/ }"
  read -r -a parsed_profiles <<< "${profiles_value}"
  for profile in "${parsed_profiles[@]}"; do
    [[ -n "${profile}" ]] || continue
    EFFECTIVE_COMPOSE_PROFILES+=("${profile}")
    COMPOSE_PROFILE_ARGS+=(--profile "${profile}")
  done
}

wrfcoin_print_compose_files() {
  printf '%s\n' "${COMPOSE_FILES[@]}"
}

wrfcoin_print_compose_profiles() {
  if (( ${#EFFECTIVE_COMPOSE_PROFILES[@]} > 0 )); then
    printf '%s\n' "${EFFECTIVE_COMPOSE_PROFILES[@]}"
  fi
}

# wrfcoin_seed_profile_active: true only when the effective profile set holds
# "seed". The seed (wrfcoin-seed + softhsm-seed-init) is RETIRED on CT101 by
# owner ruling 2026-09-27 (infra#1057 Q4): every seed-specific check keys off
# this one switch, so retiring is dropping "seed" from COMPOSE_PROFILES and
# rolling back is adding it again.
wrfcoin_seed_profile_active() {
  local profile
  for profile in "${EFFECTIVE_COMPOSE_PROFILES[@]}"; do
    [[ "${profile}" == "seed" ]] && return 0
  done
  return 1
}

wrfcoin_compose() {
  local args=() file
  for file in "${COMPOSE_FILES[@]}"; do
    args+=(-f "${file}")
  done
  args+=("${COMPOSE_PROFILE_ARGS[@]}")
  docker compose "${args[@]}" "$@"
}
