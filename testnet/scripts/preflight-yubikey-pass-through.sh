#!/usr/bin/env bash
# =============================================================================
# WRFCoin Testnet — YubiKey passthrough preflight
#
# Read-only checks for host/CT/docker prerequisites before running YubiKey-backed
# node signing in testnet. This script does not change host, CT, USB, or HSM state.
#
# Usage:
#   bash testnet/scripts/preflight-yubikey-pass-through.sh
#   bash testnet/scripts/preflight-yubikey-pass-through.sh --target desktop
#   bash testnet/scripts/preflight-yubikey-pass-through.sh --target n5
#   bash testnet/scripts/preflight-yubikey-pass-through.sh --yubikey-only
#
# Exit codes:
#   0 = no hard failures
#   1 = one or more hard failures
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${TESTNET_DIR}/.env"
CT_ID="${N5_CT_ID:-101}"
NODE_SERVICE="wrfcoin-node"
TARGET="${YUBIKEY_TARGET:-n5}"

HSM_MODULE_PATH_SOFTHSM="/usr/lib/softhsm/libsofthsm2.so"
HSM_MODULE_PATH_YUBIKEY="/usr/lib/x86_64-linux-gnu/libykcs11.so"
YUBIKEY_USB_PATH="/dev/bus/usb"
PCSC_SOCKET="/run/pcscd/pcscd.comm"

YUBIKEY_ONLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --yubikey-only)
      YUBIKEY_ONLY=1
      shift
      ;;
    --target)
      shift
      TARGET="${1:-}"
      if [ -z "$TARGET" ]; then
        echo "ERROR: --target requires desktop or n5" >&2
        exit 2
      fi
      shift
      ;;
    -h|--help)
      awk '/^# ===/{ if (++n == 2) { print; exit } } n >= 1 { print }' "$0"
      exit 0
      ;;
    *)
      echo "Unsupported argument: ${1}" >&2
      exit 2
      ;;
  esac
done

case "$TARGET" in
  desktop)
    COMPOSE_FILE="${TESTNET_DIR}/docker-compose.yubikey.desktop.yml"
    ;;
  n5)
    COMPOSE_FILE="${TESTNET_DIR}/docker-compose.yubikey.n5.yml"
    ;;
  *)
    echo "ERROR: --target must be desktop or n5" >&2
    exit 2
    ;;
esac

if [ -t 1 ]; then
  C_PASS='\033[32m'
  C_WARN='\033[33m'
  C_FAIL='\033[31m'
  C_RESET='\033[0m'
else
  C_PASS=''
  C_WARN=''
  C_FAIL=''
  C_RESET=''
fi

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '%bPASS%b %s\n' "${C_PASS}" "${C_RESET}" "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '%bWARN%b %s\n' "${C_WARN}" "${C_RESET}" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '%bFAIL%b %s\n' "${C_FAIL}" "${C_RESET}" "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

env_value() {
  local key="$1"
  local file="$2"
  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^"|"$/, "", value)
      print value
      exit
    }
  ' "$file"
}

node_service_block() {
  awk '
    /^  wrfcoin-node:/ { in_service = 1; next }
    /^  [^ ]/ && in_service { in_service = 0 }
    in_service { print }
  ' "$1"
}

extract_compose_value() {
  local key="$1"
  local path="$2"

  node_service_block "$path" \
    | awk -v key="${key}:" '
      $0 ~ key { print $2; exit }
    ' \
    | tr -d '"'
}

resolve_compose_default() {
  local expr="$1"
  local key="$2"
  expr="$(trim "$expr")"

  expr="${expr#\$\{}"
  expr="${expr%\}}"

  if [ "${expr#"$key:-"}" != "$expr" ]; then
    expr="${expr#"$key:-"}"
  elif [ "$expr" = "$key" ]; then
    expr=""
  fi

  printf '%s' "$expr"
}

read_hsm_env() {
  local key="$1"

  local env_path override_path
  env_path="$(env_value "$key" "$ENV_FILE" || true)"

  if [ -n "${env_path}" ]; then
    printf '%s' "$env_path"
    return 0
  fi

  override_path="$(extract_compose_value "$key" "$COMPOSE_FILE" || true)"
  if [ -n "$override_path" ]; then
    resolve_compose_default "$override_path" "$key"
    return 0
  fi

  return 1
}

validate_usb_present() {
  if [ -e "$YUBIKEY_USB_PATH" ]; then
    pass "USB device root exists: $YUBIKEY_USB_PATH"
  else
    fail "USB device root missing: $YUBIKEY_USB_PATH"
    return
  fi

  if ! have lsusb; then
    fail "lsusb command is required for device inventory checks"
    return
  fi

  local yubikey_lines
  yubikey_lines="$(lsusb | grep -i -E '1050:|yubico|yubikey' || true)"
  if [ -n "$yubikey_lines" ]; then
    pass "Detected YubiKey USB presence from lsusb:"
    printf '%s\n' "$yubikey_lines" | sed 's/^/  /'
  else
    fail "No YubiKey device found on lsusb (VID 1050 not matched)."
  fi
}

validate_compose_mapping() {
  if [ ! -f "$COMPOSE_FILE" ]; then
    fail "Missing compose override file: $COMPOSE_FILE"
    return
  fi

  local block
  local active_block
  block="$(node_service_block "$COMPOSE_FILE")"
  active_block="$(printf '%s\n' "$block" | sed -E 's/[[:space:]]*#.*$//' | sed '/^[[:space:]]*$/d')"

  if [ "$TARGET" = "desktop" ]; then
    if printf '%s\n' "$active_block" | grep -q '^[[:space:]]*devices:' &&
       printf '%s\n' "$active_block" | grep -q '^[[:space:]]*- .*\/dev\/bus\/usb'; then
      pass "Desktop overlay maps /dev/bus/usb into wrfcoin-node container"
    else
      fail "Desktop overlay must map /dev/bus/usb into wrfcoin-node"
    fi
  else
    if printf '%s\n' "$active_block" | grep -q '^[[:space:]]*volumes:' &&
       printf '%s\n' "$active_block" | grep -q '^[[:space:]]*- .*\/run\/pcscd:\/run\/pcscd:ro'; then
      pass "N5 overlay bind-mounts /run/pcscd into wrfcoin-node container"
    else
      fail "N5 overlay must bind-mount /run/pcscd:/run/pcscd:ro"
    fi
  fi

  if printf '%s\n' "$block" | grep -q 'WRFCOIN_HSM_TOKEN_LABEL'; then
    pass "Compose node section contains WRFCOIN_HSM_TOKEN_LABEL"
  else
    fail "Compose node section missing WRFCOIN_HSM_TOKEN_LABEL"
  fi

  if printf '%s\n' "$block" | grep -q 'WRFCOIN_HSM_KEY_LABEL'; then
    pass "Compose node section contains WRFCOIN_HSM_KEY_LABEL"
  else
    fail "Compose node section missing WRFCOIN_HSM_KEY_LABEL"
  fi
}

validate_ct_usb_passthrough() {
  if ! have pct; then
    warn "pct command unavailable; cannot verify Proxmox CT USB passthrough on host"
    return
  fi

  local config
  config="$(pct config "$CT_ID" 2>/dev/null || true)"
  if [ -z "$config" ]; then
    warn "Unable to read CT ${CT_ID} config via pct config; permission/host context required"
    return
  fi

  if printf '%s\n' "$config" | grep -q '/run/pcscd'; then
    pass "Proxmox CT ${CT_ID} config contains /run/pcscd socket bind mount"
  else
    fail "Proxmox CT ${CT_ID} config has no visible /run/pcscd socket bind mount"
  fi
}

validate_pcsc_socket() {
  if [ -S "$PCSC_SOCKET" ]; then
    pass "pcscd socket is available: ${PCSC_SOCKET}"
  else
    fail "pcscd socket missing: ${PCSC_SOCKET}"
  fi
}

validate_pkcs11_mode() {
  local hsm_module
  hsm_module="$(read_hsm_env WRFCOIN_HSM_MODULE_PATH || true)"
  if [ -z "$hsm_module" ]; then
    hsm_module="$HSM_MODULE_PATH_SOFTHSM"
  fi

  local token_label
  local key_label
  local pin_env

  token_label="$(read_hsm_env WRFCOIN_HSM_TOKEN_LABEL || true)"
  key_label="$(read_hsm_env WRFCOIN_HSM_KEY_LABEL || true)"
  pin_env="$(read_hsm_env WRFCOIN_HSM_PIN_ENV || true)"

  if [ -n "$pin_env" ]; then
    pass "WRFCOIN_HSM_PIN_ENV is configured (${pin_env})"
  else
    pass "WRFCOIN_HSM_PIN_ENV is unset; default token env WRFCOIN_HSM_PIN would be used"
  fi

  if [ -n "$token_label" ]; then
    pass "WRFCOIN_HSM_TOKEN_LABEL present"
  else
    fail "WRFCOIN_HSM_TOKEN_LABEL is empty"
  fi

  if [ -n "$key_label" ]; then
    pass "WRFCOIN_HSM_KEY_LABEL present"
  else
    fail "WRFCOIN_HSM_KEY_LABEL is empty"
  fi

  if [[ "$hsm_module" == *"softhsm"* ]]; then
    pass "Mode detected: SoftHSM default path (${hsm_module})"
    if [ "$YUBIKEY_ONLY" -eq 1 ]; then
      fail "--yubikey-only requested but module path is SoftHSM default"
    else
      warn "YubiKey passthrough checks are skipped in SoftHSM mode"
    fi
    return
  fi

  if [[ "$hsm_module" != *"libykcs11"* && "$hsm_module" != *"ykcs11"* ]]; then
    fail "Custom PKCS#11 module path does not look like libykcs11: ${hsm_module}"
    return
  fi

  pass "Mode detected: PKCS#11 module path is libykcs11 (${hsm_module})"

  if ! have pkcs11-tool; then
    warn "pkcs11-tool missing; cannot introspect mechanism support"
    return
  fi

  local mechanisms
  mechanisms="$(timeout 12s pkcs11-tool --module "$hsm_module" --list-mechanisms 2>/dev/null || true)"
  if [ -n "$mechanisms" ]; then
    if printf '%s\n' "$mechanisms" | grep -qi 'eddsa\|ed25519\|edwards'; then
      pass "PKCS#11 mechanism list includes Ed25519/EdDSA support"
    else
      warn "PKCS#11 mechanism output did not show explicit Ed25519/EdDSA support; verify key provisioning"
    fi
  else
    warn "Could not read PKCS#11 mechanism list from ${hsm_module}; token may be locked or absent"
  fi

  local token_lines
  token_lines="$(timeout 12s pkcs11-tool --module "$hsm_module" --list-tokens 2>/dev/null || true)"
  if [ -n "$token_lines" ]; then
    pass "PKCS#11 tokens are enumerated from module path ${hsm_module}"
  else
    warn "Unable to enumerate PKCS#11 tokens without auth/context; proceed and verify in-container logs after start"
  fi
}

main() {
  printf 'WRFCoin YubiKey passthrough preflight\n'
  printf 'Target: %s\n' "$TARGET"
  printf 'Compose: %s\n' "$COMPOSE_FILE"
  printf 'Env: %s\n' "$ENV_FILE"
  printf 'CT: %s\n' "$CT_ID"

  validate_compose_mapping
  validate_pkcs11_mode

  local hsm_module
  hsm_module="$(read_hsm_env WRFCOIN_HSM_MODULE_PATH || true)"
  if [[ "$hsm_module" == *"ykcs11"* ]] || [ "$YUBIKEY_ONLY" -eq 1 ]; then
    if [ "$TARGET" = "desktop" ]; then
      validate_usb_present
    else
      validate_pcsc_socket
      validate_ct_usb_passthrough
    fi
  fi

  printf '\nSummary: PASS=%s WARN=%s FAIL=%s\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  if [ "$FAIL_COUNT" -eq 0 ]; then
    printf '%bGO%b safe to execute YubiKey-backed runbook steps\n' "${C_PASS}" "${C_RESET}"
    exit 0
  fi

  printf '%bNO-GO%b fix failing items before YubiKey-backed startup\n' "${C_FAIL}" "${C_RESET}"
  exit 1
}

main "$@"
