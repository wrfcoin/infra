#!/usr/bin/env bash
# Blue-green deployment script with automatic rollback for WRFCoin platform.
# Supports --dry-run, --environment, and automatic health-check-based rollback.

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Defaults (overridable via environment)
ENVIRONMENT="${ENVIRONMENT:-staging}"
DRY_RUN=false
ROLLBACK_ERROR_THRESHOLD="${ROLLBACK_ERROR_THRESHOLD:-5}"
DEPLOY_WEBHOOK_URL="${DEPLOY_WEBHOOK_URL:-}"
HEALTH_CHECK_RETRIES="${HEALTH_CHECK_RETRIES:-10}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-30}"
FALLBACK_KEEP_SECONDS="${FALLBACK_KEEP_SECONDS:-300}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
REGISTRY="${REGISTRY:-ghcr.io/wrfcoin}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Alternate ports for the green deployment
GREEN_API_PORT="${GREEN_API_PORT:-4002}"
GREEN_FRONTEND_PORT="${GREEN_FRONTEND_PORT:-3001}"

# Services managed by this script
SERVICES=("wrfcoin-api" "wrfcoin-frontend")

# Logging
LOG_FILE="${PROJECT_ROOT}/deploy-$(date +%Y%m%d-%H%M%S).log"

###############################################################################
# Helpers
###############################################################################

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log() {
    local msg="[$(timestamp)] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    local msg="[$(timestamp)] ERROR: $1"
    echo "$msg" >&2 | tee -a "$LOG_FILE"
}

notify() {
    local message="$1"
    local status="${2:-info}"

    log "NOTIFY [$status]: $message"

    if [[ -n "$DEPLOY_WEBHOOK_URL" ]]; then
        curl -sf -X POST "$DEPLOY_WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"[$status] $message\",\"environment\":\"$ENVIRONMENT\"}" \
            >/dev/null 2>&1 || log "Warning: webhook notification failed"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Blue-green deployment with automatic rollback for WRFCoin.

Options:
  --dry-run              Show deployment plan without executing
  --environment ENV      Target environment: staging or production (default: staging)
  --image-tag TAG        Docker image tag to deploy (default: latest)
  --help                 Show this help message

Environment variables:
  ROLLBACK_ERROR_THRESHOLD  Error rate % to trigger rollback (default: 5)
  DEPLOY_WEBHOOK_URL        Webhook URL for notifications
  HEALTH_CHECK_RETRIES      Number of health check attempts (default: 10)
  HEALTH_CHECK_INTERVAL     Seconds between health checks (default: 30)
  FALLBACK_KEEP_SECONDS     Seconds to keep old containers as fallback (default: 300)
  REGISTRY                  Container registry (default: ghcr.io/wrfcoin)
  COMPOSE_FILE              Docker compose file (default: docker-compose.yml)

Examples:
  $(basename "$0") --dry-run --environment staging
  $(basename "$0") --environment production --image-tag v1.2.3
EOF
    exit 0
}

###############################################################################
# Argument parsing
###############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate environment
if [[ "$ENVIRONMENT" != "staging" && "$ENVIRONMENT" != "production" ]]; then
    log_error "Invalid environment: $ENVIRONMENT. Must be 'staging' or 'production'."
    exit 1
fi

###############################################################################
# Pre-flight checks
###############################################################################

preflight_checks() {
    log "Running pre-flight checks..."

    local required_tools=("docker" "git" "curl")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done

    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        exit 1
    fi

    # Verify compose file exists
    if [[ ! -f "$PROJECT_ROOT/$COMPOSE_FILE" ]]; then
        log_error "Compose file not found: $PROJECT_ROOT/$COMPOSE_FILE"
        exit 1
    fi

    log "Pre-flight checks passed"
}

###############################################################################
# Tag current release
###############################################################################

tag_current_release() {
    local tag="release-$(date +%Y%m%d-%H%M%S)"
    log "Tagging current release as $tag"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would create git tag: $tag"
        return 0
    fi

    cd "$PROJECT_ROOT"
    git tag "$tag" 2>/dev/null || log "Warning: could not create git tag (may already exist or not in a git repo)"
    log "Tagged current release: $tag"
}

###############################################################################
# Pull new images
###############################################################################

pull_images() {
    log "Pulling new Docker images (tag: $IMAGE_TAG)..."

    for service in "${SERVICES[@]}"; do
        local image="$REGISTRY/$service:$IMAGE_TAG"
        if [[ "$DRY_RUN" == "true" ]]; then
            log "[DRY RUN] Would pull: $image"
        else
            log "Pulling $image..."
            docker pull "$image" || {
                log_error "Failed to pull $image"
                return 1
            }
        fi
    done

    log "All images pulled successfully"
}

###############################################################################
# Start green containers
###############################################################################

start_green_containers() {
    log "Starting green (new version) containers on alternate ports..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would start green containers:"
        log "  wrfcoin-api-green on port $GREEN_API_PORT"
        log "  wrfcoin-frontend-green on port $GREEN_FRONTEND_PORT"
        return 0
    fi

    # Start API green container
    docker run -d \
        --name wrfcoin-api-green \
        --network wrfcoin-network 2>/dev/null || true
    docker run -d \
        --rm \
        --name wrfcoin-api-green \
        -p "$GREEN_API_PORT:4001" \
        -e NODE_ENV="$ENVIRONMENT" \
        -e DEPLOYMENT_COLOR=green \
        "$REGISTRY/wrfcoin-api:$IMAGE_TAG" 2>/dev/null || {
        # If the container name already exists, remove it first
        docker rm -f wrfcoin-api-green 2>/dev/null || true
        docker run -d \
            --name wrfcoin-api-green \
            -p "$GREEN_API_PORT:4001" \
            -e NODE_ENV="$ENVIRONMENT" \
            -e DEPLOYMENT_COLOR=green \
            "$REGISTRY/wrfcoin-api:$IMAGE_TAG"
    }

    # Start frontend green container
    docker rm -f wrfcoin-frontend-green 2>/dev/null || true
    docker run -d \
        --name wrfcoin-frontend-green \
        -p "$GREEN_FRONTEND_PORT:3000" \
        -e NODE_ENV="$ENVIRONMENT" \
        -e DEPLOYMENT_COLOR=green \
        "$REGISTRY/wrfcoin-frontend:$IMAGE_TAG"

    log "Green containers started"
}

###############################################################################
# Health checks
###############################################################################

check_health() {
    local host="${1:-localhost}"
    local port="$2"
    local endpoint="${3:-/health}"

    local url="http://${host}:${port}${endpoint}"
    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null) || http_code="000"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 400 ]]; then
        return 0
    fi
    return 1
}

run_health_checks() {
    local target="${1:-green}"
    local api_port="$GREEN_API_PORT"
    local frontend_port="$GREEN_FRONTEND_PORT"

    if [[ "$target" == "blue" ]]; then
        api_port="4001"
        frontend_port="3000"
    fi

    log "Running health checks on $target containers (api:$api_port, frontend:$frontend_port)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would check /health and /ready on ports $api_port, $frontend_port"
        return 0
    fi

    local attempt=0
    while [[ $attempt -lt $HEALTH_CHECK_RETRIES ]]; do
        attempt=$((attempt + 1))
        log "Health check attempt $attempt/$HEALTH_CHECK_RETRIES..."

        local api_health=false
        local frontend_health=false

        if check_health "localhost" "$api_port" "/health"; then
            api_health=true
        fi

        if check_health "localhost" "$frontend_port" "/health" || check_health "localhost" "$frontend_port" "/"; then
            frontend_health=true
        fi

        if [[ "$api_health" == "true" && "$frontend_health" == "true" ]]; then
            log "All health checks passed on attempt $attempt"
            return 0
        fi

        if [[ "$api_health" == "false" ]]; then
            log "API health check failed on port $api_port"
        fi
        if [[ "$frontend_health" == "false" ]]; then
            log "Frontend health check failed on port $frontend_port"
        fi

        if [[ $attempt -lt $HEALTH_CHECK_RETRIES ]]; then
            log "Retrying in $HEALTH_CHECK_INTERVAL seconds..."
            sleep "$HEALTH_CHECK_INTERVAL"
        fi
    done

    log_error "Health checks failed after $HEALTH_CHECK_RETRIES attempts"
    return 1
}

###############################################################################
# Traffic switching
###############################################################################

switch_traffic() {
    log "Switching traffic to green containers..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would update load balancer / nginx config to route to green"
        return 0
    fi

    # Stop the current blue containers
    for service in "${SERVICES[@]}"; do
        local blue_name="${service}"
        if docker ps -q --filter "name=$blue_name" | grep -q .; then
            log "Stopping blue container: $blue_name"
            docker stop "$blue_name" 2>/dev/null || true
        fi
    done

    # Rename green containers to become the new primary
    docker stop wrfcoin-api-green 2>/dev/null || true
    docker stop wrfcoin-frontend-green 2>/dev/null || true

    # Remove old containers
    for service in "${SERVICES[@]}"; do
        docker rm -f "$service" 2>/dev/null || true
    done

    # Restart with standard ports using the new images
    docker run -d \
        --name wrfcoin-api \
        -p "4001:4001" \
        -e NODE_ENV="$ENVIRONMENT" \
        -e DEPLOYMENT_COLOR=blue \
        "$REGISTRY/wrfcoin-api:$IMAGE_TAG"

    docker run -d \
        --name wrfcoin-frontend \
        -p "3000:3000" \
        -e NODE_ENV="$ENVIRONMENT" \
        -e DEPLOYMENT_COLOR=blue \
        "$REGISTRY/wrfcoin-frontend:$IMAGE_TAG"

    # Clean up green containers
    docker rm -f wrfcoin-api-green 2>/dev/null || true
    docker rm -f wrfcoin-frontend-green 2>/dev/null || true

    log "Traffic switched to new version"
}

###############################################################################
# Post-deploy monitoring
###############################################################################

monitor_error_rate() {
    log "Monitoring error rate for ${FALLBACK_KEEP_SECONDS}s (threshold: ${ROLLBACK_ERROR_THRESHOLD}%)..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would monitor error rate for ${FALLBACK_KEEP_SECONDS}s"
        return 0
    fi

    local elapsed=0
    local interval=30

    while [[ $elapsed -lt $FALLBACK_KEEP_SECONDS ]]; do
        sleep "$interval"
        elapsed=$((elapsed + interval))

        # Simple health-based error rate check
        local total=0
        local errors=0

        for i in $(seq 1 5); do
            total=$((total + 1))
            if ! check_health "localhost" "4001" "/health"; then
                errors=$((errors + 1))
            fi
        done

        local error_rate=0
        if [[ $total -gt 0 ]]; then
            error_rate=$((errors * 100 / total))
        fi

        log "Health check: error_rate=${error_rate}% (${errors}/${total} failed) at +${elapsed}s"

        if [[ $error_rate -gt $ROLLBACK_ERROR_THRESHOLD ]]; then
            log_error "Error rate ${error_rate}% exceeds threshold ${ROLLBACK_ERROR_THRESHOLD}%"
            return 1
        fi
    done

    log "Post-deploy monitoring passed: error rate within threshold"
    return 0
}

###############################################################################
# Rollback
###############################################################################

rollback() {
    log "ROLLING BACK deployment..."
    notify "Rolling back $ENVIRONMENT deployment" "warning"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would roll back to previous version"
        return 0
    fi

    # Stop new containers
    docker stop wrfcoin-api wrfcoin-frontend 2>/dev/null || true
    docker rm -f wrfcoin-api wrfcoin-frontend 2>/dev/null || true

    # Restart from compose (previous known-good state)
    cd "$PROJECT_ROOT"
    docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || \
        docker-compose -f "$COMPOSE_FILE" up -d 2>/dev/null || \
        log_error "Could not restart previous version via compose"

    # Also clean up any green containers that may be lingering
    docker rm -f wrfcoin-api-green wrfcoin-frontend-green 2>/dev/null || true

    log "Rollback completed"
    notify "Rollback completed for $ENVIRONMENT" "warning"
}

###############################################################################
# Dry run summary
###############################################################################

show_dry_run_plan() {
    log "============================================"
    log "  DEPLOYMENT PLAN (DRY RUN)"
    log "============================================"
    log "  Environment:      $ENVIRONMENT"
    log "  Image tag:        $IMAGE_TAG"
    log "  Registry:         $REGISTRY"
    log "  Error threshold:  ${ROLLBACK_ERROR_THRESHOLD}%"
    log "  Fallback window:  ${FALLBACK_KEEP_SECONDS}s"
    log "  Health retries:   $HEALTH_CHECK_RETRIES"
    log "  Webhook:          ${DEPLOY_WEBHOOK_URL:-<not set>}"
    log ""
    log "  Steps:"
    log "    1. Pre-flight checks"
    log "    2. Tag current release (git tag)"
    log "    3. Pull images: ${SERVICES[*]}"
    log "    4. Start green containers on alternate ports"
    log "    5. Run health checks against green containers"
    log "    6. Switch traffic to green (new version)"
    log "    7. Monitor error rate for ${FALLBACK_KEEP_SECONDS}s"
    log "    8. Auto-rollback if error rate > ${ROLLBACK_ERROR_THRESHOLD}%"
    log "============================================"
}

###############################################################################
# Main
###############################################################################

main() {
    log "============================================"
    log "  WRFCoin Blue-Green Deployment"
    log "  Environment: $ENVIRONMENT"
    log "  Image tag:   $IMAGE_TAG"
    log "  Dry run:     $DRY_RUN"
    log "============================================"

    if [[ "$DRY_RUN" == "true" ]]; then
        show_dry_run_plan
        preflight_checks
        tag_current_release
        pull_images
        start_green_containers
        run_health_checks "green"
        switch_traffic
        monitor_error_rate
        log "Dry run complete. No changes were made."
        exit 0
    fi

    notify "Starting $ENVIRONMENT deployment (tag: $IMAGE_TAG)" "info"

    preflight_checks
    tag_current_release
    pull_images

    start_green_containers

    if ! run_health_checks "green"; then
        log_error "Green containers failed health checks. Aborting deployment."
        docker rm -f wrfcoin-api-green wrfcoin-frontend-green 2>/dev/null || true
        notify "Deployment aborted: green health checks failed" "failure"
        exit 1
    fi

    switch_traffic

    if ! run_health_checks "blue"; then
        log_error "New production containers failed health checks after switch. Rolling back."
        rollback
        notify "Deployment failed: post-switch health checks failed, rolled back" "failure"
        exit 1
    fi

    if ! monitor_error_rate; then
        log_error "Error rate exceeded threshold during monitoring window. Rolling back."
        rollback
        notify "Deployment failed: error rate exceeded threshold, rolled back" "failure"
        exit 1
    fi

    log "============================================"
    log "  Deployment successful!"
    log "  Environment: $ENVIRONMENT"
    log "  Image tag:   $IMAGE_TAG"
    log "============================================"
    notify "Deployment successful for $ENVIRONMENT (tag: $IMAGE_TAG)" "success"
}

main
