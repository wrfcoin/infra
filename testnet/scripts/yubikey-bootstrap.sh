#!/usr/bin/env bash
# Bootstrap one node for YubiKey-backed testnet signing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_TEMPLATE="${TESTNET_DIR}/.env.testnet.example"
ENV_FILE="${TESTNET_DIR}/.env"
SECRETS_DIR="${TESTNET_DIR}/secrets"
PUBKEY_TMP="/tmp/pub.pem"
SIGN_PAYLOAD_TMP="/tmp/wrfcoin-yubikey-payload.bin"
SIGNATURE_TMP="/tmp/wrfcoin-yubikey-signature.bin"
DEFAULT_NODE_NAME="$(hostname -s 2>/dev/null || echo node)"
DEFAULT_MGMT_KEY="010203040506070801020304050607080102030405060708"
YKCS11_MODULE="/usr/lib/x86_64-linux-gnu/libykcs11.so"
KEY_LABEL="Private key for Digital Signature"
PUBKEY_LABEL="Public key for Digital Signature"

DRY_RUN=0
NODE_NAME="${DEFAULT_NODE_NAME}"

usage() {
  cat <<'EOF'
Usage: bash testnet/scripts/yubikey-bootstrap.sh [--node <name>] [--dry-run]
EOF
}

have() {
  command -v "$1" >/dev/null 2>&1
}

check_ykman_version() {
  local version
  version="$(ykman --version | awk '{print $NF}')"
  if ! printf '%s\n' "5.5.0" "$version" | sort -V -C; then
    echo "ERROR: ykman ${version} < 5.5.0; Ed25519 PIV support requires yubikey-manager 5.5+." >&2
    echo "Install via: sudo add-apt-repository -y ppa:yubico/stable && sudo apt install -y yubikey-manager yubico-piv-tool" >&2
    exit 1
  fi
}

detect_token_label() {
  if ! have pkcs11-tool || [ ! -r "$YKCS11_MODULE" ]; then
    printf 'YubiKey PIV #REPLACE'
    return
  fi

  local label
  label="$(timeout 12s pkcs11-tool --module "$YKCS11_MODULE" -T 2>/dev/null \
    | awk -F: '/token label/ {
        value = substr($0, index($0, ":") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value != "") { print value; exit }
      }')"
  printf '%s' "${label:-YubiKey PIV #REPLACE}"
}

validate_pkcs11_signing() {
  local token_label="$1"

  printf 'wrfcoin-r102-yubikey-validation!' > "$SIGN_PAYLOAD_TMP"

  timeout 20s pkcs11-tool \
    --module "$YKCS11_MODULE" \
    --login --pin "$HSM_PIN" \
    --token-label "$token_label" \
    --sign --mechanism EDDSA \
    --type privkey --label "$KEY_LABEL" \
    --input-file "$SIGN_PAYLOAD_TMP" \
    --output-file "$SIGNATURE_TMP" >/dev/null

  timeout 20s pkcs11-tool \
    --module "$YKCS11_MODULE" \
    --token-label "$token_label" \
    --verify --mechanism EDDSA \
    --type pubkey --label "$PUBKEY_LABEL" \
    --input-file "$SIGN_PAYLOAD_TMP" \
    --signature-file "$SIGNATURE_TMP" >/dev/null
}

set_env_var() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$file"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --node)
      shift
      NODE_NAME="${1:-}"
      if [ -z "$NODE_NAME" ]; then
        echo "ERROR: --node requires a value" >&2
        exit 2
      fi
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unsupported argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PUBKEY_DEST="${SECRETS_DIR}/validator-${NODE_NAME}.pub"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: would generate YubiKey slot 9c keypair, export ${PUBKEY_DEST}, and update ${ENV_FILE} for node ${NODE_NAME}."
  exit 0
fi

for cmd in ykman openssl chmod sed grep sort awk timeout pkcs11-tool; do
  if ! have "$cmd"; then
    echo "ERROR: required command not found: ${cmd}" >&2
    exit 1
  fi
done

if [ ! -r "$YKCS11_MODULE" ]; then
  echo "ERROR: libykcs11 module not found: ${YKCS11_MODULE}" >&2
  exit 1
fi

check_ykman_version

mkdir -p "$SECRETS_DIR"

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_TEMPLATE" "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

trap 'rm -f "$PUBKEY_TMP" "$SIGN_PAYLOAD_TMP" "$SIGNATURE_TMP"' EXIT

MGMT_KEY="${WRFCOIN_PIV_MGMT_KEY:-$DEFAULT_MGMT_KEY}"

read -rsp "YubiKey PIN for ${NODE_NAME}: " HSM_PIN
printf '\n'

ykman piv keys generate \
  --algorithm ED25519 \
  --pin-policy ONCE \
  --touch-policy NEVER \
  --management-key "$MGMT_KEY" \
  9c "$PUBKEY_TMP"

ykman piv certificates generate \
  --management-key "$MGMT_KEY" \
  --pin "$HSM_PIN" \
  --subject "CN=wrfcoin-validator-${NODE_NAME}" \
  9c "$PUBKEY_TMP"

openssl pkey -pubin -in "$PUBKEY_TMP" -out "$PUBKEY_DEST" >/dev/null 2>&1
TOKEN_LABEL="$(detect_token_label)"

if ! validate_pkcs11_signing "$TOKEN_LABEL"; then
  echo "ERROR: YubiKey PKCS#11 sign/verify validation failed via ${YKCS11_MODULE}." >&2
  echo "Check pcscd/socket access, slot 9c certificate installation, token label, and infra/docs/hsm/yubikey-ct101-passthrough.md." >&2
  exit 1
fi

set_env_var "$ENV_FILE" "WRFCOIN_HSM_MODE" "yubikey"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_MODULE" "$YKCS11_MODULE"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_MODULE_PATH" "$YKCS11_MODULE"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_TOKEN_LABEL" "$TOKEN_LABEL"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_KEY_LABEL" "$KEY_LABEL"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_PUBKEY_LABEL" "$PUBKEY_LABEL"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_PIN_ENV" "WRFCOIN_HSM_PIN"
set_env_var "$ENV_FILE" "WRFCOIN_HSM_PIN" "$HSM_PIN"
chmod 600 "$ENV_FILE"

echo "Wrote ${PUBKEY_DEST}, installed a slot 9c certificate, validated PKCS#11 signing, and updated ${ENV_FILE} for node ${NODE_NAME}."
