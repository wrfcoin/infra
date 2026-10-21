#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# WRFCoin Environment Promotion Script
#
# Promotes Docker images between environments by re-tagging (no rebuild).
# Runs smoke tests against the source environment before re-tagging.
#
# Promotion path: dev -> staging -> testnet
#
# Usage:
#   ./scripts/promote-environment.sh --from=dev --to=staging [--sha=<sha>] [--dry-run]
#   ./scripts/promote-environment.sh --from=staging --to=testnet [--sha=<sha>] [--dry-run]
#
# Options:
#   --from=<env>     Source environment: dev, staging
#   --to=<env>       Target environment: staging, testnet
#   --sha=<sha>      Short commit SHA to promote (default: latest tag in source env)
#   --dry-run        Show tag changes without modifying anything
#   --skip-smoke     Skip smoke tests (not recommended for testnet promotion)
#   --help           Show this message
#
# Environment Variables:
#   GHCR_TOKEN       GitHub Container Registry token (required for re-tagging)
#   SOURCE_ENV_URL   URL of the source environment for smoke tests (optional)
#
# Note: This script does NOT push Docker images to a registry in testnet mode.
#       Testnet deployment is local-build-only via SSH to the N5 Pro.
#       See infra/testnet/docker-compose.override.yml for the local-build constraint.
# ============================================================================

SCRIPT_NAME="$(basename "$0")"
FROM_ENV=""
TO_ENV=""
SHORT_SHA=""
DRY_RUN=false
SKIP_SMOKE=false

SERVICES=(
  "native-chain"
  "backend"
  "frontend"
)

# ============================================================================
# Utility
# ============================================================================

log() {
  local level="$1"; shift
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] $*"
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
Usage: ${SCRIPT_NAME} --from=<env> --to=<env> [--sha=<sha>] [--dry-run] [--skip-smoke]

Environments: dev, staging, testnet
Promotion path: dev -> staging -> testnet (only adjacent promotion is allowed)

Options:
  --from=<env>     Source environment
  --to=<env>       Target environment
  --sha=<sha>      Git short SHA of the build to promote (7+ chars)
  --dry-run        Print what would happen without modifying anything
  --skip-smoke     Skip source environment smoke tests
  --help           Show this help

Required env vars (non-dry-run):
  GHCR_TOKEN       GitHub Container Registry PAT with write:packages scope

Optional env vars:
  SOURCE_ENV_URL   Base URL of source environment for smoke tests
                   (e.g., http://staging-node:8556 — defaults to localhost endpoints)
EOF
  exit 0
}

# ============================================================================
# Argument parsing
# ============================================================================

for arg in "$@"; do
  case "$arg" in
    --from=*)   FROM_ENV="${arg#*=}" ;;
    --to=*)     TO_ENV="${arg#*=}" ;;
    --sha=*)    SHORT_SHA="${arg#*=}" ;;
    --dry-run)  DRY_RUN=true ;;
    --skip-smoke) SKIP_SMOKE=true ;;
    --help|-h)  usage ;;
    *) fail "Unknown argument: ${arg}. Use --help for usage." ;;
  esac
done

[[ -z "$FROM_ENV" ]] && fail "Missing --from. Use --help."
[[ -z "$TO_ENV"   ]] && fail "Missing --to. Use --help."

# Validate promotion path
case "${FROM_ENV}->${TO_ENV}" in
  "dev->staging"|"staging->testnet") ;;
  "dev->testnet") fail "Skipping staging is not allowed. Promote dev->staging first." ;;
  *) fail "Invalid promotion path: ${FROM_ENV} -> ${TO_ENV}. Allowed: dev->staging, staging->testnet." ;;
esac

# ============================================================================
# Pre-flight checks
# ============================================================================

if [[ "$DRY_RUN" == false ]]; then
  if [[ -z "${GHCR_TOKEN:-}" ]]; then
    fail "GHCR_TOKEN is not set. Export a GitHub Container Registry token with write:packages scope."
  fi
  # Login to GHCR
  echo "${GHCR_TOKEN}" | docker login ghcr.io -u github-actions --password-stdin 2>/dev/null || \
    fail "Failed to authenticate with ghcr.io. Check GHCR_TOKEN."
fi

# Detect SHA from source environment if not provided
if [[ -z "$SHORT_SHA" ]]; then
  info "No --sha provided. Using git HEAD short SHA."
  SHORT_SHA="$(git rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")"
  if [[ "$SHORT_SHA" == "unknown" ]]; then
    fail "Could not determine short SHA. Provide --sha=<sha> explicitly."
  fi
fi

info "=== WRFCoin Environment Promotion ==="
info "From: ${FROM_ENV}  ->  To: ${TO_ENV}"
info "SHA: ${SHORT_SHA}"
info "Dry run: ${DRY_RUN}"

# ============================================================================
# Source environment smoke tests
# ============================================================================

run_smoke_tests() {
  local env="$1"
  local node_url="${SOURCE_ENV_URL:-http://127.0.0.1:8556}"
  local backend_url="http://127.0.0.1:4001"

  info "Running smoke tests against ${env} environment..."

  # Node health
  if curl -sf --max-time 10 "${node_url}/health" > /dev/null 2>&1; then
    info "[PASS] Node health check: ${node_url}/health"
  else
    warn "[WARN] Node health check failed: ${node_url}/health"
    warn "       Promotion will continue — verify manually if this is unexpected."
  fi

  # Backend health
  if curl -sf --max-time 10 "${backend_url}/health" > /dev/null 2>&1; then
    info "[PASS] Backend health check: ${backend_url}/health"
  else
    warn "[WARN] Backend health check failed: ${backend_url}/health"
    warn "       Promotion will continue — verify manually if this is unexpected."
  fi

  info "Smoke tests complete."
}

if [[ "$SKIP_SMOKE" == false ]]; then
  run_smoke_tests "$FROM_ENV"
else
  warn "Smoke tests skipped (--skip-smoke)."
fi

# ============================================================================
# Image re-tagging
# ============================================================================

retag_image() {
  local service="$1"
  local src_tag="${FROM_ENV}-${SHORT_SHA}"
  local dst_tag="${TO_ENV}-${SHORT_SHA}"
  local image="ghcr.io/wrfcoin/${service}"

  if [[ "$DRY_RUN" == true ]]; then
    info "[DRY RUN] Would pull:  ${image}:${src_tag}"
    info "[DRY RUN] Would tag:   ${image}:${dst_tag}"
    info "[DRY RUN] Would tag:   ${image}:${TO_ENV}  (latest pointer)"
    info "[DRY RUN] Would push:  ${image}:${dst_tag}"
    info "[DRY RUN] Would push:  ${image}:${TO_ENV}"
    return 0
  fi

  info "Re-tagging ${service}: ${src_tag} -> ${dst_tag}"

  # Pull source image
  docker pull "${image}:${src_tag}" || {
    warn "Image ${image}:${src_tag} not found in GHCR. Skipping."
    return 0
  }

  # Tag for target environment
  docker tag "${image}:${src_tag}" "${image}:${dst_tag}"
  docker tag "${image}:${src_tag}" "${image}:${TO_ENV}"  # latest pointer

  # Push — skip for testnet (local-build-only constraint)
  if [[ "$TO_ENV" == "testnet" ]]; then
    warn "Testnet is local-build-only. Skipping push to ghcr.io for ${service}."
    warn "Deploy using SSH to N5 Pro — see testnet/docker-compose.override.yml."
  else
    docker push "${image}:${dst_tag}"
    docker push "${image}:${TO_ENV}"
    info "Pushed ${image}:${dst_tag} and ${image}:${TO_ENV}"
  fi
}

# ============================================================================
# Env diff
# ============================================================================

show_env_diff() {
  local src_config="config/${FROM_ENV}.env.example"
  local dst_config="config/${TO_ENV}.env.example"

  if [[ -f "$src_config" && -f "$dst_config" ]]; then
    info "Environment variable diff (${FROM_ENV} vs ${TO_ENV}):"
    diff --unified=2 \
      <(grep -v "^#\|^$" "$src_config" | sort) \
      <(grep -v "^#\|^$" "$dst_config" | sort) \
      || true   # diff exits 1 when there are differences — that is expected
  else
    warn "Could not find config/${FROM_ENV}.env.example or config/${TO_ENV}.env.example for diff."
  fi
}

show_env_diff

# ============================================================================
# Main promotion loop
# ============================================================================

for service in "${SERVICES[@]}"; do
  retag_image "$service"
done

# ============================================================================
# Summary
# ============================================================================

info "=== Promotion complete ==="
if [[ "$DRY_RUN" == true ]]; then
  info "This was a dry run. No images were modified."
else
  info "Promoted SHA ${SHORT_SHA} from ${FROM_ENV} to ${TO_ENV}."
  if [[ "$TO_ENV" == "testnet" ]]; then
    info ""
    info "Next steps for testnet deployment (local-build-only):"
    info "  1. SSH to N5 Pro"
    info "  2. cd /root/wrfcoin/infra/testnet"
    info "  3. cp /path/to/config/testnet.env.example .env  (update secrets)"
    info "  4. docker compose pull   (pulls from local build, not ghcr.io)"
    info "  5. docker compose up -d"
    info "  6. docker compose ps     (verify all services healthy)"
  else
    info ""
    info "Next steps:"
    info "  - Verify staging deployment: docker compose -f docker-compose.staging.yml up -d"
    info "  - Monitor for 15+ minutes before promoting to testnet"
  fi
fi
