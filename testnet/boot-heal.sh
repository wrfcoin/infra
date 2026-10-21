#!/usr/bin/env bash
# boot-heal.sh - compose boot reconciliation for the WRFCoin N5 Pro testnet stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_HEALTH="${SCRIPT_DIR}/check-health.sh"
P2P_GUARD="${SCRIPT_DIR}/check-p2p-external-addr.sh"
P2P_RECEIPT_VERIFIER="${SCRIPT_DIR}/verify-p2p-reachability-receipt.sh"
DOCKER_READY_TIMEOUT_SECS="${DOCKER_READY_TIMEOUT_SECS:-60}"
BOOT_HEAL_WAIT_SECS="${BOOT_HEAL_WAIT_SECS:-180}"
BOOT_HEAL_SECOND_WAIT_SECS="${BOOT_HEAL_SECOND_WAIT_SECS:-180}"
BOOT_HEAL_INTERVAL_SECS="${BOOT_HEAL_INTERVAL_SECS:-10}"

# HSM-init custody shape shared by supported deployments. Host observations are
# loaded below from an explicit deployment-owned artifact; generic source must
# not silently bless one host's mountpoints, executable digests, or keys.
HSM_INIT_IMAGE_ID_ALLOWLIST=""
HSM_INIT_CONTAINER_NAMES=(
  wrfcoin-testnet-softhsm-init
  wrfcoin-testnet-seed-softhsm-init
)
HSM_INIT_COMPOSE_SERVICES=(softhsm-init softhsm-seed-init)
# Every HSM-init container this deployment has ever run. Custody may shrink to
# the node's owner (seed retired, infra#1057), but starting ANY of these from a
# reconcile stays forbidden, so this list is never truncated (codex round 53).
readonly HSM_INIT_ALL_CONTAINER_NAMES=("${HSM_INIT_CONTAINER_NAMES[@]}")
HSM_INIT_VOLUME_NAMES=(testnet_node-data testnet_seed-data)
HSM_INIT_VOLUME_TARGETS=(/app/data /app/data)
HSM_INIT_VOLUME_MOUNTPOINTS=()
HSM_INIT_CMD_SHA256=()
HSM_INIT_ENTRYPOINT_SHA256=()
HSM_INIT_HEALTHCHECK_SHA256=()
HSM_INIT_PUBLIC_KEY_SHA256=()
declare -a HSM_INIT_ALLOWED_IMAGE_IDS=()
declare -A HSM_INIT_BEFORE_IDS=()
declare -A HSM_INIT_BEFORE_IMAGE_IDS=()
declare -A HSM_INIT_BEFORE_MOUNTS=()
declare -A HSM_INIT_BEFORE_STARTED_AT=()
declare -A HSM_INIT_BEFORE_RESTARTS=()
declare -A HSM_INIT_BEFORE_CONFIG_HASHES=()
declare -A HSM_INIT_BEFORE_PUBLIC_KEY_FINGERPRINTS=()
declare -A HSM_VOLUME_BEFORE_CREATED_AT=()
declare -A HSM_VOLUME_BEFORE_MOUNTPOINTS=()
declare -A HSM_EXISTING_CONTAINER_IDS=()

load_hsm_init_custody_config() {
  local path="${WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG:-}"
  local line key value required
  local -A values=() allowed_keys=(
    [HSM_INIT_IMAGE_IDS]=1
    [HSM_INIT_NODE_VOLUME_MOUNTPOINT]=1
    [HSM_INIT_SEED_VOLUME_MOUNTPOINT]=1
    [HSM_INIT_NODE_CMD_SHA256]=1
    [HSM_INIT_SEED_CMD_SHA256]=1
    [HSM_INIT_NODE_ENTRYPOINT_SHA256]=1
    [HSM_INIT_SEED_ENTRYPOINT_SHA256]=1
    [HSM_INIT_NODE_HEALTHCHECK_SHA256]=1
    [HSM_INIT_SEED_HEALTHCHECK_SHA256]=1
    [HSM_INIT_NODE_PUBLIC_KEY_SHA256]=1
    [HSM_INIT_SEED_PUBLIC_KEY_SHA256]=1
  )
  local -a required_keys=(
    HSM_INIT_IMAGE_IDS
    HSM_INIT_NODE_VOLUME_MOUNTPOINT
    HSM_INIT_NODE_CMD_SHA256
    HSM_INIT_NODE_ENTRYPOINT_SHA256
    HSM_INIT_NODE_HEALTHCHECK_SHA256
    HSM_INIT_NODE_PUBLIC_KEY_SHA256
  )
  local -a seed_keys=(
    HSM_INIT_SEED_VOLUME_MOUNTPOINT
    HSM_INIT_SEED_CMD_SHA256
    HSM_INIT_SEED_ENTRYPOINT_SHA256
    HSM_INIT_SEED_HEALTHCHECK_SHA256
    HSM_INIT_SEED_PUBLIC_KEY_SHA256
  )
  # Seed retired (infra#1057 Q4): the seed's HSM-init owner is in custody only
  # while the "seed" profile is active. With it inactive, the SEED_* keys are
  # still accepted (so the reviewed CT101 custody file needs no edit and a
  # rollback is only re-adding the profile) but are not required and not used.
  local seed_in_custody=0
  if wrfcoin_seed_profile_active; then
    seed_in_custody=1
    required_keys+=("${seed_keys[@]}")
  fi

  if [[ -z "${path}" ]]; then
    echo "ERROR: WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG is required" >&2
    return 1
  fi
  if [[ "${path}" != /* ]]; then
    echo "ERROR: WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG must be an absolute path" >&2
    return 1
  fi
  if [[ ! -f "${path}" || ! -r "${path}" ]]; then
    echo "ERROR: HSM init custody config is not a readable regular file" >&2
    return 1
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ || "${line}" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "${line}" =~ ^([A-Z0-9_]+)=([^[:space:]#]+)$ ]]; then
      echo "ERROR: malformed HSM init custody config entry" >&2
      return 1
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ -z "${allowed_keys[${key}]+present}" ]]; then
      echo "ERROR: unknown HSM init custody config key" >&2
      return 1
    fi
    if [[ -n "${values[${key}]+present}" ]]; then
      echo "ERROR: duplicate HSM init custody config key" >&2
      return 1
    fi
    values["${key}"]="${value}"
  done < "${path}"

  for required in "${required_keys[@]}"; do
    if [[ -z "${values[${required}]+present}" ]]; then
      echo "ERROR: missing required HSM init custody config value" >&2
      return 1
    fi
  done

  if [[ ! "${values[HSM_INIT_IMAGE_IDS]}" =~ ^sha256:[0-9a-f]{64}(,sha256:[0-9a-f]{64})*$ ]]; then
    echo "ERROR: malformed immutable HSM init image ID configuration" >&2
    return 1
  fi
  for key in "${required_keys[@]}"; do
    [[ "${key}" == *_VOLUME_MOUNTPOINT ]] || continue
    if [[ ! "${values[${key}]}" =~ ^/[a-zA-Z0-9._/-]+$ ]]; then
      echo "ERROR: malformed HSM init volume mountpoint configuration" >&2
      return 1
    fi
  done
  for key in "${required_keys[@]}"; do
    [[ "${key}" == *_SHA256 ]] || continue
    if [[ ! "${values[${key}]}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: malformed HSM init custody digest configuration" >&2
      return 1
    fi
  done

  HSM_INIT_IMAGE_ID_ALLOWLIST="${values[HSM_INIT_IMAGE_IDS]}"
  HSM_INIT_VOLUME_MOUNTPOINTS=(
    "${values[HSM_INIT_NODE_VOLUME_MOUNTPOINT]}"
    "${values[HSM_INIT_SEED_VOLUME_MOUNTPOINT]:-}"
  )
  HSM_INIT_CMD_SHA256=(
    "${values[HSM_INIT_NODE_CMD_SHA256]}"
    "${values[HSM_INIT_SEED_CMD_SHA256]:-}"
  )
  HSM_INIT_ENTRYPOINT_SHA256=(
    "${values[HSM_INIT_NODE_ENTRYPOINT_SHA256]}"
    "${values[HSM_INIT_SEED_ENTRYPOINT_SHA256]:-}"
  )
  HSM_INIT_HEALTHCHECK_SHA256=(
    "${values[HSM_INIT_NODE_HEALTHCHECK_SHA256]}"
    "${values[HSM_INIT_SEED_HEALTHCHECK_SHA256]:-}"
  )
  HSM_INIT_PUBLIC_KEY_SHA256=(
    "${values[HSM_INIT_NODE_PUBLIC_KEY_SHA256]}"
    "${values[HSM_INIT_SEED_PUBLIC_KEY_SHA256]:-}"
  )
  if (( seed_in_custody == 0 )); then
    # Node owner only. Every per-owner array is truncated to index 0 together,
    # so no loop over "${!HSM_INIT_CONTAINER_NAMES[@]}" can reach a seed entry.
    HSM_INIT_CONTAINER_NAMES=("${HSM_INIT_CONTAINER_NAMES[0]}")
    HSM_INIT_COMPOSE_SERVICES=("${HSM_INIT_COMPOSE_SERVICES[0]}")
    HSM_INIT_VOLUME_NAMES=("${HSM_INIT_VOLUME_NAMES[0]}")
    HSM_INIT_VOLUME_TARGETS=("${HSM_INIT_VOLUME_TARGETS[0]}")
    HSM_INIT_VOLUME_MOUNTPOINTS=("${HSM_INIT_VOLUME_MOUNTPOINTS[0]}")
    HSM_INIT_CMD_SHA256=("${HSM_INIT_CMD_SHA256[0]}")
    HSM_INIT_ENTRYPOINT_SHA256=("${HSM_INIT_ENTRYPOINT_SHA256[0]}")
    HSM_INIT_HEALTHCHECK_SHA256=("${HSM_INIT_HEALTHCHECK_SHA256[0]}")
    HSM_INIT_PUBLIC_KEY_SHA256=("${HSM_INIT_PUBLIC_KEY_SHA256[0]}")
    echo "boot-heal: seed profile inactive (seed retired, infra#1057); HSM-init custody covers softhsm-init only" >&2
  fi
}

# The file/profile derivation is shared verbatim with check-health.sh so boot
# cannot recover one effective deployment while health evaluates another.
# shellcheck source=testnet/lib/compose-inputs.sh
source "${SCRIPT_DIR}/lib/compose-inputs.sh"
wrfcoin_init_compose_inputs "${SCRIPT_DIR}"

# Custody is loaded AFTER the profile set is known: the seed's HSM-init owner
# is in custody only while the "seed" profile is active (infra#1057 Q4).
load_hsm_init_custody_config

# The cut overlays are NOT optional extras. `docker-compose.cut.yml` carries the
# node's genesis pin and `docker-compose.cut-miner.yml` carries the producer's
# authorized payout address; without either, the stack starts and then refuses
# to work, in two different ways that look nothing like a missing overlay:
#
#   cut.yml missing        -> node falls back to the binary's compiled-in
#                             TESTNET_GENESIS_HASH, which after a cut is the
#                             RETIRED genesis, and it refuses to start (#2035)
#   cut-miner.yml missing  -> producer asks for a coinbase it is not authorized
#                             to pay, every mine returns 500, chain stalls
#                             silently at the last block (#2290 §R2)
#
# `docker-compose.cut-genesis-seed.yml` is the SAME fault for the seed, and was
# the one overlay this list still missed. cut.yml pins only `wrfcoin-node`;
# nothing pinned `wrfcoin-seed`, so the seed resolved its genesis from the
# binary's compiled-in TESTNET_GENESIS_HASH — the retired a3301def chain — and
# crash-looped against a node running 805efc97. Measured on CT 101 2026-08-06:
# the seed had been restarting since the previous boot with
#
#   Genesis hash mismatch: local chain genesis is 0x805efc97... but this node
#   expects a3301def... Refusing to start
#
# Note which side was wrong: the seed's 821 persisted blocks were CORRECT and
# its expectation was stale. Wiping its volume would have destroyed good data.
#
# A cut may pin locally-built images through an override outside the deploy
# checkout. That override is part of deployment custody, not a best-effort
# convenience: silently omitting it lets the earlier local-image overlay win
# and can recreate the chain on a different binary at boot.
#
# Require an absolute path so the systemd WorkingDirectory cannot change what
# the setting means. Validate it while constructing COMPOSE_FILES, before any
# Docker/Compose command can run. The current quorum override also names the
# oracle-attester service. Its full service/custody overlays must be present
# before the override is appended, so Compose retains their profile, container,
# mount, device, and environment shape while the cut image pin wins last.
print_compose_files() {
  wrfcoin_print_compose_files
}

RECONCILE_SERVICES=(
  postgres
  redis
  db-migrate
  wrfcoin-node
  wrfcoin-backend
  wrfcoin-frontend
  wrfcoin-governance
  wrfcoin-iot
  wrfcoin-weather-earnings
  prometheus
  grafana
  alertmanager
  node-exporter
  alert-receiver
  container-health-watch
  wrfcoin-explorer
  wrfcoin-faucet
)

resolve_reconcile_services() {
  local rendered service candidate profile watcher_enabled=0
  local -A available=()
  EFFECTIVE_RECONCILE_SERVICES=()
  for profile in "${EFFECTIVE_COMPOSE_PROFILES[@]}"; do
    if [[ "${profile}" == "container-health-watch" || "${profile}" == "*" ]]; then
      watcher_enabled=1
    fi
  done

  if ! rendered="$(compose config --services)"; then
    echo "ERROR: cannot discover effective services for boot reconciliation" >&2
    return 1
  fi
  while IFS= read -r service; do
    [[ -n "$service" ]] || continue
    [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
      echo "ERROR: unsafe service name in boot reconciliation: $service" >&2
      return 1
    }
    available["$service"]=1
  done <<< "$rendered"
  for candidate in "${RECONCILE_SERVICES[@]}"; do
    # Some Compose versions list inactive profiles in config --services.
    # Explicit up targets bypass profile gating, so boot must gate the watcher too.
    if [[ "${candidate}" == "container-health-watch" && "${watcher_enabled}" != 1 ]]; then
      continue
    fi
    [[ -n "${available[$candidate]+present}" ]] || continue
    EFFECTIVE_RECONCILE_SERVICES+=("$candidate")
  done
}

print_reconcile_services() {
  resolve_reconcile_services
  printf '%s\n' "${EFFECTIVE_RECONCILE_SERVICES[@]}"
}

# Boot starts what is already built; it never builds.
#
# `docker compose up` asks buildkit's bake to prepare EVERY image defined in the
# file set, not just the services being started. On CT 101 that includes
# `oracle-reference`, whose build context does not exist and which has never run
# there — so a service that was not being started, and could not start, aborted
# the entire stack before a single container came up. Measured 2026-08-06:
#
#   unable to prepare context: path ".../oracle-reference" not found
#
# `--no-build` is also the correct posture independently: this host builds images
# deliberately and locally (never from a registry), so boot is the wrong moment
# to discover a build is needed. A missing image now fails loudly for that one
# service instead of silently taking down the other twenty-six.
compose() {
  wrfcoin_compose "$@"
}

load_hsm_init_image_allowlist() {
  local candidate
  local normalized="${HSM_INIT_IMAGE_ID_ALLOWLIST//,/ }"

  read -r -a HSM_INIT_ALLOWED_IMAGE_IDS <<< "${normalized}"
  if (( ${#HSM_INIT_ALLOWED_IMAGE_IDS[@]} == 0 )); then
    echo "ERROR: HSM init image ID allowlist is empty" >&2
    return 1
  fi
  for candidate in "${HSM_INIT_ALLOWED_IMAGE_IDS[@]}"; do
    if [[ ! "${candidate}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "ERROR: HSM init image allowlist accepts immutable sha256 IDs only" >&2
      return 1
    fi
  done
}

hsm_init_image_is_allowed() {
  local actual="$1" allowed
  for allowed in "${HSM_INIT_ALLOWED_IMAGE_IDS[@]}"; do
    [[ "${actual}" == "${allowed}" ]] && return 0
  done
  return 1
}

verify_docker_dataset_custody() {
  local dataset_source data_root_entry

  if ! dataset_source="$(findmnt -no SOURCE /mnt/tank-docker 2>/dev/null)"; then
    echo "ERROR: Docker dataset mount is unavailable" >&2
    return 1
  fi
  if [[ "${dataset_source}" != "tank/docker" ]]; then
    echo "ERROR: Docker dataset custody mismatch; expected tank/docker" >&2
    return 1
  fi
  if ! data_root_entry="$(find /mnt/tank-docker/docker-data -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" \
      || [[ -z "${data_root_entry}" ]]; then
    echo "ERROR: Docker data root is empty or unavailable" >&2
    return 1
  fi
}

inspect_hsm_init_container() {
  local name="$1"
  local format raw

  format='{{.Id}}{{"\t"}}{{.Image}}{{"\t"}}{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}{{"\t"}}{{.RestartCount}}{{"\t"}}{{.State.StartedAt}}{{"\t"}}{{.HostConfig.RestartPolicy.Name}}{{"\t"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.service"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.oneoff"}}{{"\t"}}{{index .Config.Labels "com.docker.compose.config-hash"}}{{"\t"}}{{len .Mounts}}{{"\t"}}{{range .Mounts}}{{printf "%s|%s|%s|%t;" .Type .Name .Destination .RW}}{{end}}{{"\t"}}{{json .Config.Entrypoint}}{{"\t"}}{{json .Config.Cmd}}{{"\t"}}{{json .Config.Healthcheck.Test}}'
  if ! raw="$(docker inspect --type container --format "${format}" "${name}" 2>/dev/null)"; then
    echo "ERROR: required HSM init container is missing: ${name}" >&2
    return 1
  fi

  IFS=$'\t' read -r INSPECT_ID INSPECT_IMAGE_ID INSPECT_STATE INSPECT_HEALTH \
    INSPECT_RESTARTS INSPECT_STARTED_AT INSPECT_RESTART_POLICY INSPECT_PROJECT \
    INSPECT_SERVICE INSPECT_ONEOFF INSPECT_CONFIG_HASH INSPECT_MOUNT_COUNT \
    INSPECT_MOUNTS INSPECT_ENTRYPOINT_JSON INSPECT_CMD_JSON \
    INSPECT_HEALTHCHECK_JSON <<< "${raw}"
  if [[ -z "${INSPECT_ID:-}" || -z "${INSPECT_IMAGE_ID:-}" \
     || -z "${INSPECT_MOUNTS:-}" || -z "${INSPECT_CMD_JSON:-}" ]]; then
    echo "ERROR: incomplete HSM init container metadata: ${name}" >&2
    return 1
  fi
}

sha256_text() {
  printf '%s' "$1" | sha256sum | awk '{print $1}'
}

read_hsm_public_key_fingerprint() {
  local index="$1"
  local name="${HSM_INIT_CONTAINER_NAMES[$index]}"
  local probe

  # PIN material is resolved and consumed only by the already-running init
  # container. pkcs11-tool performs a read-object operation for public key ID
  # 01; stdout is hashed inside the container, and neither key bytes nor PINs
  # cross the container boundary. pipefail prevents an empty/partial read from
  # being mistaken for a successful digest.
  # shellcheck disable=SC2016
  probe='pin_env="${WRFCOIN_HSM_PIN_ENV:-WRFCOIN_HSM_PIN}"
pin="$(printenv "${pin_env}" 2>/dev/null || true)"
module="${WRFCOIN_HSM_MODULE_PATH:-/usr/lib/softhsm/libsofthsm2.so}"
token_label="${WRFCOIN_HSM_TOKEN_LABEL:-wrfcoin-validator}"
test -n "${pin}"
export SOFTHSM2_CONF=/app/data/hsm/softhsm2.conf
pkcs11-tool --module "${module}" --login --pin "${pin}" \
  --token-label "${token_label}" --read-object --type pubkey --id 01 \
  2>/dev/null | sha256sum | awk "{print \$1}"'
  if ! HSM_PUBLIC_KEY_FINGERPRINT="$(docker exec "${name}" /bin/bash -o pipefail -eu -c "${probe}")"; then
    echo "ERROR: cannot read HSM init public-key fingerprint: ${name}" >&2
    return 1
  fi
  if [[ "${HSM_PUBLIC_KEY_FINGERPRINT}" != "${HSM_INIT_PUBLIC_KEY_SHA256[$index]}" ]]; then
    echo "ERROR: HSM init public-key fingerprint mismatch: ${name}" >&2
    return 1
  fi
}

validate_hsm_init_container() {
  local index="$1"
  local name="${HSM_INIT_CONTAINER_NAMES[$index]}"
  local expected_service="${HSM_INIT_COMPOSE_SERVICES[$index]}"
  local expected_mount="volume|${HSM_INIT_VOLUME_NAMES[$index]}|${HSM_INIT_VOLUME_TARGETS[$index]}|true;"
  local cmd_sha256 entrypoint_sha256 healthcheck_sha256

  inspect_hsm_init_container "${name}" || return 1
  if [[ ! "${INSPECT_ID}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: invalid HSM init container ID: ${name}" >&2
    return 1
  fi
  if [[ "${INSPECT_STATE}" != "running" || "${INSPECT_HEALTH}" != "healthy" ]]; then
    echo "ERROR: HSM init container is not running and healthy: ${name}" >&2
    return 1
  fi
  if [[ "${INSPECT_PROJECT}" != "testnet" || "${INSPECT_SERVICE}" != "${expected_service}" ]]; then
    echo "ERROR: HSM init Compose label custody mismatch: ${name}" >&2
    return 1
  fi
  if [[ "${INSPECT_ONEOFF}" != "False" || "${INSPECT_RESTART_POLICY}" != "unless-stopped" \
     || ! "${INSPECT_RESTARTS}" =~ ^[0-9]+$ \
     || ! "${INSPECT_CONFIG_HASH}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "ERROR: HSM init lifecycle custody mismatch: ${name}" >&2
    return 1
  fi
  if [[ "${INSPECT_MOUNT_COUNT}" != "1" || "${INSPECT_MOUNTS}" != "${expected_mount}" ]]; then
    echo "ERROR: HSM init volume custody mismatch: ${name}" >&2
    return 1
  fi
  if [[ ! "${INSPECT_IMAGE_ID}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || ! hsm_init_image_is_allowed "${INSPECT_IMAGE_ID}"; then
    echo "ERROR: HSM init image ID is not on the immutable allowlist: ${name}" >&2
    return 1
  fi
  cmd_sha256="$(sha256_text "${INSPECT_CMD_JSON}")"
  entrypoint_sha256="$(sha256_text "${INSPECT_ENTRYPOINT_JSON}")"
  healthcheck_sha256="$(sha256_text "${INSPECT_HEALTHCHECK_JSON}")"
  if [[ "${cmd_sha256}" != "${HSM_INIT_CMD_SHA256[$index]}" \
     || "${entrypoint_sha256}" != "${HSM_INIT_ENTRYPOINT_SHA256[$index]}" \
     || "${healthcheck_sha256}" != "${HSM_INIT_HEALTHCHECK_SHA256[$index]}" ]]; then
    echo "ERROR: HSM init executable contract mismatch: ${name}" >&2
    return 1
  fi
  read_hsm_public_key_fingerprint "${index}"
}

inspect_hsm_volume() {
  local index="$1"
  local name="${HSM_INIT_VOLUME_NAMES[$index]}"
  local expected_mountpoint="${HSM_INIT_VOLUME_MOUNTPOINTS[$index]}"
  local raw

  if ! raw="$(docker volume inspect --format '{{.Name}}{{"\t"}}{{.Mountpoint}}{{"\t"}}{{.CreatedAt}}' "${name}" 2>/dev/null)"; then
    echo "ERROR: required HSM backing volume is missing: ${name}" >&2
    return 1
  fi
  IFS=$'\t' read -r VOLUME_NAME VOLUME_MOUNTPOINT VOLUME_CREATED_AT <<< "${raw}"
  if [[ "${VOLUME_NAME}" != "${name}" || "${VOLUME_MOUNTPOINT}" != "${expected_mountpoint}" \
     || -z "${VOLUME_CREATED_AT}" ]]; then
    echo "ERROR: HSM backing volume identity mismatch: ${name}" >&2
    return 1
  fi
}

capture_existing_compose_container_ids() {
  local rendered_names name id

  HSM_EXISTING_CONTAINER_IDS=()
  if ! rendered_names="$(compose ps -a --format '{{.Name}}')"; then
    echo "ERROR: cannot enumerate existing Compose containers" >&2
    return 1
  fi
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    if [[ ! "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      echo "ERROR: unsafe container name in Compose preflight" >&2
      return 1
    fi
    if ! id="$(docker inspect --type container --format '{{.Id}}' "${name}" 2>/dev/null)" \
       || [[ ! "${id}" =~ ^[0-9a-f]{64}$ ]]; then
      echo "ERROR: cannot bind existing Compose container ID: ${name}" >&2
      return 1
    fi
    HSM_EXISTING_CONTAINER_IDS["${name}"]="${id}"
  done <<< "${rendered_names}"
  if (( ${#HSM_EXISTING_CONTAINER_IDS[@]} == 0 )); then
    echo "ERROR: no existing Compose containers found" >&2
    return 1
  fi
}

verify_existing_compose_container_ids_unchanged() {
  local name id

  for name in "${!HSM_EXISTING_CONTAINER_IDS[@]}"; do
    if ! id="$(docker inspect --type container --format '{{.Id}}' "${name}" 2>/dev/null)" \
       || [[ "${id}" != "${HSM_EXISTING_CONTAINER_IDS[${name}]}" ]]; then
      echo "ERROR: Compose container identity changed during reconciliation: ${name}" >&2
      return 1
    fi
  done
}

capture_verified_hsm_init_custody() {
  local index name

  verify_docker_dataset_custody
  load_hsm_init_image_allowlist
  for index in "${!HSM_INIT_CONTAINER_NAMES[@]}"; do
    name="${HSM_INIT_CONTAINER_NAMES[$index]}"
    validate_hsm_init_container "${index}"
    HSM_INIT_BEFORE_IDS["${name}"]="${INSPECT_ID}"
    HSM_INIT_BEFORE_IMAGE_IDS["${name}"]="${INSPECT_IMAGE_ID}"
    HSM_INIT_BEFORE_MOUNTS["${name}"]="${INSPECT_MOUNTS}"
    HSM_INIT_BEFORE_STARTED_AT["${name}"]="${INSPECT_STARTED_AT}"
    HSM_INIT_BEFORE_RESTARTS["${name}"]="${INSPECT_RESTARTS}"
    HSM_INIT_BEFORE_CONFIG_HASHES["${name}"]="${INSPECT_CONFIG_HASH}"
    HSM_INIT_BEFORE_PUBLIC_KEY_FINGERPRINTS["${name}"]="${HSM_PUBLIC_KEY_FINGERPRINT}"
    inspect_hsm_volume "${index}"
    HSM_VOLUME_BEFORE_CREATED_AT["${VOLUME_NAME}"]="${VOLUME_CREATED_AT}"
    HSM_VOLUME_BEFORE_MOUNTPOINTS["${VOLUME_NAME}"]="${VOLUME_MOUNTPOINT}"
  done
}

verify_hsm_init_custody_unchanged() {
  local index name

  verify_docker_dataset_custody
  load_hsm_init_image_allowlist
  for index in "${!HSM_INIT_CONTAINER_NAMES[@]}"; do
    name="${HSM_INIT_CONTAINER_NAMES[$index]}"
    validate_hsm_init_container "${index}"
    if [[ "${INSPECT_ID}" != "${HSM_INIT_BEFORE_IDS[${name}]}" \
       || "${INSPECT_IMAGE_ID}" != "${HSM_INIT_BEFORE_IMAGE_IDS[${name}]}" \
       || "${INSPECT_MOUNTS}" != "${HSM_INIT_BEFORE_MOUNTS[${name}]}" \
       || "${INSPECT_STARTED_AT}" != "${HSM_INIT_BEFORE_STARTED_AT[${name}]}" \
       || "${INSPECT_RESTARTS}" != "${HSM_INIT_BEFORE_RESTARTS[${name}]}" \
       || "${INSPECT_CONFIG_HASH}" != "${HSM_INIT_BEFORE_CONFIG_HASHES[${name}]}" \
       || "${HSM_PUBLIC_KEY_FINGERPRINT}" != "${HSM_INIT_BEFORE_PUBLIC_KEY_FINGERPRINTS[${name}]}" ]]; then
      echo "ERROR: HSM init custody changed during reconciliation: ${name}" >&2
      return 1
    fi
    inspect_hsm_volume "${index}"
    if [[ "${VOLUME_CREATED_AT}" != "${HSM_VOLUME_BEFORE_CREATED_AT[${VOLUME_NAME}]}" \
       || "${VOLUME_MOUNTPOINT}" != "${HSM_VOLUME_BEFORE_MOUNTPOINTS[${VOLUME_NAME}]}" ]]; then
      echo "ERROR: HSM backing volume changed during reconciliation: ${VOLUME_NAME}" >&2
      return 1
    fi
  done
}

validate_hsm_safe_dry_run() {
  local output line name normalized_name action init_name
  local action_count=0
  local -a dry_run_lines=()

  output="$(mktemp)"
  if ! compose up -d --no-build --no-recreate --dry-run >"${output}" 2>&1; then
    echo "ERROR: Compose diagnostic dry-run failed" >&2
    rm -f "${output}"
    return 1
  fi
  mapfile -t dry_run_lines < "${output}"
  rm -f "${output}"

  for line in "${dry_run_lines[@]}"; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ ! "${line}" =~ Container[[:space:]]+([^[:space:]]+)[[:space:]]+(Creating|Created|Recreate|Recreated|Starting|Started|Running|Waiting|Healthy|Exited)([[:space:]]|$) ]]; then
      echo "ERROR: unknown or ambiguous action in Compose diagnostic dry-run" >&2
      return 1
    fi
    name="${BASH_REMATCH[1]}"
    action="${BASH_REMATCH[2]}"
    normalized_name="${name}"
    [[ "${normalized_name}" =~ ^[0-9a-f]{12}_(.+)$ ]] && normalized_name="${BASH_REMATCH[1]}"
    action_count=$((action_count + 1))

    if [[ ! "${normalized_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      echo "ERROR: unsafe container name in Compose diagnostic dry-run" >&2
      return 1
    fi
    if [[ -z "${HSM_EXISTING_CONTAINER_IDS[${normalized_name}]+present}" ]]; then
      echo "ERROR: dry-run references a container without a preflight-bound ID: ${normalized_name}" >&2
      return 1
    fi
    if [[ "${action}" == "Creating" || "${action}" == "Created" \
       || "${action}" == "Recreate" || "${action}" == "Recreated" ]]; then
      echo "ERROR: create or recreate in Compose diagnostic dry-run: ${normalized_name} ${action}" >&2
      return 1
    fi
    if [[ "${action}" == "Starting" || "${action}" == "Started" ]]; then
      for init_name in "${HSM_INIT_ALL_CONTAINER_NAMES[@]}"; do
        if [[ "${normalized_name}" == "${init_name}" ]]; then
          echo "ERROR: unsafe init start in Compose diagnostic dry-run: ${normalized_name}" >&2
          return 1
        fi
      done
    fi
  done
  if (( action_count == 0 )); then
    echo "ERROR: Compose diagnostic dry-run produced no recognized actions" >&2
    return 1
  fi
}

reconcile_preserving_hsm_init() {
  capture_verified_hsm_init_custody
  capture_existing_compose_container_ids
  validate_hsm_safe_dry_run
  compose up -d --no-build --no-recreate
  verify_existing_compose_container_ids_unchanged
  verify_hsm_init_custody_unchanged
}

force_recovery_preserving_hsm_init() {
  capture_verified_hsm_init_custody
  resolve_reconcile_services
  compose up -d --no-build --force-recreate --no-deps "${EFFECTIVE_RECONCILE_SERVICES[@]}"
  verify_hsm_init_custody_unchanged
}

stop_preserving_hsm_init() {
  local rendered_services service
  local -a stop_services=()

  if ! rendered_services="$(compose config --services)"; then
    echo "ERROR: cannot discover services for HSM-preserving stop" >&2
    return 1
  fi
  while IFS= read -r service; do
    [[ -z "${service}" ]] && continue
    if [[ ! "${service}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      echo "ERROR: unsafe service name in HSM-preserving stop" >&2
      return 1
    fi
    [[ "${service}" == "softhsm-init" || "${service}" == "softhsm-seed-init" ]] && continue
    stop_services+=("${service}")
  done <<< "${rendered_services}"
  if (( ${#stop_services[@]} == 0 )); then
    echo "ERROR: no non-init services discovered for HSM-preserving stop" >&2
    return 1
  fi
  compose stop "${stop_services[@]}"
}

wait_for_docker() {
  local deadline=$((SECONDS + DOCKER_READY_TIMEOUT_SECS))
  until docker info >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "ERROR: docker did not become ready within ${DOCKER_READY_TIMEOUT_SECS}s" >&2
      return 1
    fi
    sleep 2
  done
}

guard_external_address() {
  "${P2P_GUARD}" --env-file "${SCRIPT_DIR}/.env" --require
}

# Read one key from the deployment .env without sourcing it. Sourcing an env
# file executes it; these values feed a verifier whose whole job is to be
# unfoolable, so they are extracted textually like the P2P guard already does.
read_env_value() {
  local key="$1" file="${SCRIPT_DIR}/.env"
  [[ -r "${file}" ]] || return 0
  sed -n "s/^[[:space:]]*${key}=//p" "${file}" | tail -1 | tr -d '"' | tr -d "'"
}

# Consult the external reachability receipt. Returns 0 only when a receipt is
# configured, present, authentic, fresh, and bound to THIS node's advertisement.
# Every other outcome returns nonzero, including "no receipt configured" — the
# absence of external evidence is not evidence of reachability.
accept_external_reachability_receipt() {
  local receipt key_file expect_addr expect_peer expect_genesis max_age
  local -a args=()

  receipt="${WRFCOIN_P2P_RECEIPT_FILE:-$(read_env_value WRFCOIN_P2P_RECEIPT_FILE)}"
  if [[ -z "${receipt}" ]]; then
    echo "boot-heal: no WRFCOIN_P2P_RECEIPT_FILE configured — no external evidence to consider." >&2
    return 1
  fi
  if [[ ! -x "${P2P_RECEIPT_VERIFIER}" ]]; then
    echo "ERROR: receipt verifier missing or not executable: ${P2P_RECEIPT_VERIFIER}" >&2
    return 1
  fi

  key_file="${WRFCOIN_P2P_RECEIPT_KEY_FILE:-$(read_env_value WRFCOIN_P2P_RECEIPT_KEY_FILE)}"
  expect_addr="$(read_env_value WRFCOIN_P2P_EXTERNAL_ADDR)"
  expect_peer="${WRFCOIN_P2P_PEER_ID:-$(read_env_value WRFCOIN_P2P_PEER_ID)}"
  expect_genesis="${WRFCOIN_GENESIS_HASH:-$(read_env_value WRFCOIN_GENESIS_HASH)}"
  max_age="${WRFCOIN_P2P_RECEIPT_MAX_AGE_SECS:-$(read_env_value WRFCOIN_P2P_RECEIPT_MAX_AGE_SECS)}"

  # The advertised address is the thing under proof; a receipt that is not bound
  # to it proves nothing, so an unknown expectation is a hard stop rather than
  # an unchecked field.
  if [[ -z "${expect_addr}" ]]; then
    echo "ERROR: cannot bind receipt — WRFCOIN_P2P_EXTERNAL_ADDR is not readable from .env" >&2
    return 1
  fi

  # Identity bindings are MANDATORY in the boot path (#841 review): an
  # authentic receipt for some other node or chain must never settle THIS
  # node's guard. The peer id falls back to the node's own peer_id.txt when
  # the env does not pin it; the genesis expectation has no derivable
  # fallback and must be configured.
  if [[ -z "${expect_peer}" ]]; then
    local peer_file
    peer_file="${WRFCOIN_P2P_PEER_ID_FILE:-$(read_env_value WRFCOIN_P2P_PEER_ID_FILE)}"
    if [[ -n "${peer_file}" && -r "${peer_file}" ]]; then
      expect_peer="$(tr -d '[:space:]' < "${peer_file}")"
    fi
  fi
  if [[ -z "${expect_peer}" ]]; then
    echo "ERROR: cannot bind receipt — peer id unresolvable (set WRFCOIN_P2P_PEER_ID, or point WRFCOIN_P2P_PEER_ID_FILE at the node's peer_id.txt). An unbound receipt is not evidence about THIS node." >&2
    return 1
  fi
  if [[ -z "${expect_genesis}" ]]; then
    echo "ERROR: cannot bind receipt — WRFCOIN_GENESIS_HASH is not set. A receipt that is not bound to this chain is not evidence about it." >&2
    return 1
  fi

  args=(--receipt "${receipt}" --expect-multiaddr "${expect_addr}")
  args+=(--expect-peer-id "${expect_peer}")
  args+=(--expect-genesis "${expect_genesis}")
  [[ -n "${key_file}" ]] && args+=(--key-file "${key_file}")
  [[ -n "${max_age}" ]] && args+=(--max-age-secs "${max_age}")

  "${P2P_RECEIPT_VERIFIER}" "${args[@]}"
}

wait_for_health() {
  local label="$1" timeout_secs="$2"
  local deadline=$((SECONDS + timeout_secs))

  while true; do
    if "${CHECK_HEALTH}" >/dev/null 2>&1; then
      echo "boot-heal: ${label} healthy"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "boot-heal: ${label} still unhealthy after ${timeout_secs}s" >&2
      return 1
    fi
    sleep "${BOOT_HEAL_INTERVAL_SECS}"
  done
}

# The advertised-address proof dials our own P2P port and requires an answer.
# That is a VERIFICATION, not a precondition: the thing that answers on that
# port is the node this script is about to start.
#
# Running it before `compose up` is unsatisfiable on a cold boot and cost the
# testnet a full outage on 2026-08-06 — the guard passed on the way down (node
# still running) and could never pass on the way up. It belongs after the stack
# is up, where a failure means "the advertised address is wrong", which is the
# thing it was written to catch (#690, #731).
#
# The self-dial's WARN verdict (exit 3) is the ONLY outcome external evidence
# can answer, and that narrowness is the safety property (#840).
#
# The guard already distinguishes the two failures. Exit 3 means "a PUBLIC
# address did not answer a dial from here", which is precisely what NAT hairpin
# produces on a node that is in fact reachable — CT 101 leaves and re-enters
# through a router with no hairpin reflection, so the packet never arrives.
# Exit 1 means something a receipt cannot excuse: an unparsable multiaddr, an
# unset advertisement under --require, the known-vacant #673 address, an
# injected host, or a PRIVATE/tailnet address that failed to self-dial. A
# private address MUST answer its own dial; there is no hairpin story there, so
# a receipt claiming otherwise is either wrong or forged.
#
# Written as an allowlist of one code rather than "not 1", so a future guard
# verdict is RED by default instead of silently inheriting the override.
guard_external_address_after_up() {
  local rc=0
  guard_external_address || rc=$?

  if (( rc == 0 )); then
    return 0
  fi

  if (( rc != 3 )); then
    echo "boot-heal: advertised-address proof FAILED after the stack came up." >&2
    echo "boot-heal: the stack is running; WRFCOIN_P2P_EXTERNAL_ADDR is wrong and" >&2
    echo "boot-heal: remote peers will fail silently against it. Fix and recreate." >&2
    echo "boot-heal: this verdict (exit ${rc}) is not the NAT-hairpin case; an external" >&2
    echo "boot-heal: reachability receipt cannot and does not override it." >&2
    return 1
  fi

  echo "boot-heal: self-dial of the PUBLIC advertised address did not answer (guard WARN)." >&2
  echo "boot-heal: that is unfalsifiable from inside this NAT — checking for external evidence." >&2
  if accept_external_reachability_receipt; then
    echo "boot-heal: external reachability receipt ACCEPTED; treating the self-dial WARN as"
    echo "boot-heal: a NAT-hairpin false negative. The advertised address is proven reachable"
    echo "boot-heal: from outside, so the stack stays as reconciled — no recreate."
    return 0
  fi

  echo "boot-heal: advertised-address proof FAILED after the stack came up." >&2
  echo "boot-heal: the self-dial warned and no fresh, authentic, on-target external" >&2
  echo "boot-heal: reachability receipt was available. Missing, stale, mismatched, or" >&2
  echo "boot-heal: failed external evidence stays RED — run the external probe and retry." >&2
  return 1
}

main() {
  case "${1:-}" in
    --print-compose-files)
      # Read-only/operator-test seam: emit only the effective ordered file
      # paths. No environment values, rendered configuration, or secrets.
      print_compose_files
      return 0
      ;;
    --print-compose-profiles)
      # Read-only/operator-test seam: emit only effective profile names.
      wrfcoin_print_compose_profiles
      return 0
      ;;
    --print-reconcile-services)
      # Read-only test/operator seam. Only services in the effective Compose
      # inventory are emitted, so force recovery cannot abort on absent ones.
      print_reconcile_services
      return 0
      ;;
    --stop)
      # Preserve the two long-running identity-init containers across a
      # graceful reboot. `compose down` removes them, making the next start an
      # identity-generative create path. HSM preflight deliberately does not
      # run here, so degraded init state cannot block stopping consumers.
      stop_preserving_hsm_init
      return 0
      ;;
    --compose-up-only)
      wait_for_docker
      reconcile_preserving_hsm_init
      guard_external_address_after_up
      return 0
      ;;
  esac

  wait_for_docker
  reconcile_preserving_hsm_init

  if wait_for_health "initial boot window" "${BOOT_HEAL_WAIT_SECS}"; then
    guard_external_address_after_up
    return 0
  fi

  echo "boot-heal: running a forced recovery pass for required services..." >&2
  force_recovery_preserving_hsm_init

  if wait_for_health "recovery window" "${BOOT_HEAL_SECOND_WAIT_SECS}"; then
    guard_external_address_after_up
    return 0
  fi

  echo "boot-heal: recovery failed; final health summary follows" >&2
  "${CHECK_HEALTH}" || true
  return 1
}

main "$@"
