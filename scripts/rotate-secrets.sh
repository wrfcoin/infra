#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# WRFCoin Secret Rotation Script
#
# Rotates secrets stored in HashiCorp Vault for production environments.
# Supports JWT secrets, database credentials, and API keys.
#
# Usage:
#   ./scripts/rotate-secrets.sh --secret-type=jwt
#   ./scripts/rotate-secrets.sh --secret-type=database
#   ./scripts/rotate-secrets.sh --secret-type=api-keys
#   ./scripts/rotate-secrets.sh --secret-type=all
#   ./scripts/rotate-secrets.sh --secret-type=all --dry-run
#
# Environment Variables (required unless --dry-run):
#   VAULT_ADDR    - Vault server address (e.g., https://vault.wrfcoin.io)
#   VAULT_TOKEN   - Vault authentication token
#
# Optional:
#   VAULT_NAMESPACE   - Vault namespace (default: wrfcoin/production)
#   VAULT_MOUNT_PATH  - Secret engine mount path (default: secret)
# ============================================================================

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="logs/secret-rotation-$(date +%Y%m%d-%H%M%S).log"
SECRET_TYPE=""
DRY_RUN=false
VAULT_NAMESPACE="${VAULT_NAMESPACE:-wrfcoin/production}"
VAULT_MOUNT_PATH="${VAULT_MOUNT_PATH:-secret}"
ROLLBACK_DATA=()

# ============================================================================
# Utility functions
# ============================================================================

log() {
  local level="$1"
  shift
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] $*"
  echo "$msg"
  if [[ -d "$(dirname "$LOG_FILE")" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

info()  { log "INFO"  "$@"; }
warn()  { log "WARN"  "$@"; }
error() { log "ERROR" "$@"; }

fail() {
  error "$1"
  exit 1
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} --secret-type=<type> [--dry-run]

Options:
  --secret-type=<type>   Type of secret to rotate: jwt, database, api-keys, all
  --dry-run              Show what would be rotated without making changes
  --help                 Show this help message

Required environment variables:
  VAULT_ADDR             Vault server address
  VAULT_TOKEN            Vault authentication token

Optional environment variables:
  VAULT_NAMESPACE        Vault namespace (default: wrfcoin/production)
  VAULT_MOUNT_PATH       Secret engine mount path (default: secret)
EOF
  exit 0
}

# ============================================================================
# Argument parsing
# ============================================================================

for arg in "$@"; do
  case "$arg" in
    --secret-type=*)
      SECRET_TYPE="${arg#*=}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --help|-h)
      usage
      ;;
    *)
      fail "Unknown argument: ${arg}. Use --help for usage."
      ;;
  esac
done

if [[ -z "$SECRET_TYPE" ]]; then
  fail "Missing required --secret-type flag. Use --help for usage."
fi

case "$SECRET_TYPE" in
  jwt|database|api-keys|all) ;;
  *) fail "Invalid secret type: ${SECRET_TYPE}. Must be: jwt, database, api-keys, all" ;;
esac

# ============================================================================
# Pre-flight checks
# ============================================================================

# Ensure logs directory exists
mkdir -p "$(dirname "$LOG_FILE")"

info "=== WRFCoin Secret Rotation ==="
info "Secret type: ${SECRET_TYPE}"
info "Dry run: ${DRY_RUN}"

if ! command -v vault &>/dev/null; then
  fail "'vault' CLI is not installed or not in PATH."
fi

if [[ "$DRY_RUN" == false ]]; then
  if [[ -z "${VAULT_ADDR:-}" ]]; then
    fail "VAULT_ADDR environment variable is not set."
  fi
  if [[ -z "${VAULT_TOKEN:-}" ]]; then
    fail "VAULT_TOKEN environment variable is not set."
  fi

  export VAULT_ADDR
  export VAULT_TOKEN
  if [[ -n "$VAULT_NAMESPACE" ]]; then
    export VAULT_NAMESPACE
  fi

  # Verify Vault connectivity
  if ! vault status &>/dev/null; then
    fail "Cannot connect to Vault at ${VAULT_ADDR}. Check VAULT_ADDR and VAULT_TOKEN."
  fi
  info "Vault connection verified: ${VAULT_ADDR}"
fi

# ============================================================================
# Secret rotation functions
# ============================================================================

generate_random_key() {
  local bytes="${1:-32}"
  openssl rand -base64 "$bytes" | tr -d '\n'
}

vault_read_secret() {
  local path="$1"
  vault kv get -format=json "${VAULT_MOUNT_PATH}/${path}" 2>/dev/null
}

vault_write_secret() {
  local path="$1"
  shift
  vault kv put "${VAULT_MOUNT_PATH}/${path}" "$@"
}

save_rollback() {
  local path="$1"
  local old_value="$2"
  ROLLBACK_DATA+=("${path}|${old_value}")
}

perform_rollback() {
  error "Rotation failed. Attempting rollback..."
  for entry in "${ROLLBACK_DATA[@]}"; do
    local path="${entry%%|*}"
    local old_value="${entry#*|}"
    if vault_write_secret "$path" value="$old_value" 2>/dev/null; then
      info "Rolled back: ${path}"
    else
      error "CRITICAL: Failed to roll back ${path}. Manual intervention required."
    fi
  done
}

rotate_jwt_secret() {
  local secret_path="${VAULT_NAMESPACE}/jwt-secret"
  info "Rotating JWT_SECRET at ${secret_path}..."

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would generate new 256-bit JWT secret"
    info "[DRY RUN] Would write to Vault path: ${secret_path}"
    return 0
  fi

  # Read current value for rollback
  local current
  current="$(vault_read_secret "$secret_path" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('data',{}).get('value',''))" 2>/dev/null || echo "")"
  if [[ -n "$current" ]]; then
    save_rollback "$secret_path" "$current"
  fi

  # Generate new 256-bit key
  local new_key
  new_key="$(generate_random_key 32)"

  if vault_write_secret "$secret_path" value="$new_key"; then
    info "JWT_SECRET rotated successfully."
  else
    error "Failed to write new JWT_SECRET to Vault."
    return 1
  fi
}

rotate_database_credentials() {
  info "Rotating database credentials via Vault database secrets engine..."

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would rotate credentials via Vault database engine"
    info "[DRY RUN] Would rotate roles: wrfcoin-production, wrfcoin-read"
    return 0
  fi

  # Rotate the primary database credentials via Vault's database engine
  local roles=("wrfcoin-production" "wrfcoin-read")
  for role in "${roles[@]}"; do
    info "Rotating database role: ${role}"
    if vault write -force "database/rotate-role/${role}" 2>/dev/null; then
      info "Database role ${role} rotated successfully."
    else
      warn "Could not rotate database role ${role}. It may not be configured in Vault's database engine."
      warn "Falling back to manual credential rotation..."

      local secret_path="${VAULT_NAMESPACE}/database/${role}"
      local new_password
      new_password="$(generate_random_key 24)"

      local current
      current="$(vault_read_secret "$secret_path" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('data',{}).get('password',''))" 2>/dev/null || echo "")"
      if [[ -n "$current" ]]; then
        save_rollback "$secret_path" "$current"
      fi

      if vault_write_secret "$secret_path" password="$new_password"; then
        info "Database credentials for ${role} stored in Vault."
      else
        error "Failed to rotate database credentials for ${role}."
        return 1
      fi
    fi
  done
}

rotate_api_keys() {
  local api_key_paths=(
    "${VAULT_NAMESPACE}/api-keys/pinata"
    "${VAULT_NAMESPACE}/api-keys/infura"
    "${VAULT_NAMESPACE}/api-keys/alchemy"
    "${VAULT_NAMESPACE}/api-keys/etherscan"
  )

  info "Rotating API keys..."

  if [[ "$DRY_RUN" == true ]]; then
    for path in "${api_key_paths[@]}"; do
      info "[DRY RUN] Would regenerate API key at: ${path}"
    done
    info "[DRY RUN] Note: External API keys (Infura, Alchemy, etc.) must also be rotated on provider dashboards."
    return 0
  fi

  for path in "${api_key_paths[@]}"; do
    local key_name
    key_name="$(basename "$path")"
    info "Rotating API key: ${key_name}"

    local current
    current="$(vault_read_secret "$path" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('data',{}).get('value',''))" 2>/dev/null || echo "")"
    if [[ -n "$current" ]]; then
      save_rollback "$path" "$current"
    fi

    local new_key
    new_key="$(generate_random_key 32)"

    if vault_write_secret "$path" value="$new_key"; then
      info "API key ${key_name} rotated in Vault."
    else
      error "Failed to rotate API key: ${key_name}"
      return 1
    fi
  done

  warn "IMPORTANT: External provider API keys (Infura, Alchemy, Etherscan, Pinata) must also be regenerated on their respective dashboards and updated in Vault."
}

# ============================================================================
# Main execution
# ============================================================================

trap 'if [[ $? -ne 0 && "$DRY_RUN" == false && ${#ROLLBACK_DATA[@]} -gt 0 ]]; then perform_rollback; fi' EXIT

rotate() {
  local type="$1"
  case "$type" in
    jwt)
      rotate_jwt_secret
      ;;
    database)
      rotate_database_credentials
      ;;
    api-keys)
      rotate_api_keys
      ;;
    all)
      rotate_jwt_secret
      rotate_database_credentials
      rotate_api_keys
      ;;
  esac
}

info "Starting secret rotation..."
if rotate "$SECRET_TYPE"; then
  info "=== Secret rotation completed successfully ==="
  if [[ "$DRY_RUN" == true ]]; then
    info "This was a dry run. No secrets were modified."
  else
    info "Rotation log saved to: ${LOG_FILE}"
    warn "Affected services should be restarted to pick up new secrets."
  fi
else
  fail "Secret rotation failed. Check logs at: ${LOG_FILE}"
fi
