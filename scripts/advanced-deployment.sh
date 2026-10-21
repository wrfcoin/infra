#!/bin/bash
# Advanced Deployment Script for Wrfcoin Platform
# Implements blue-green, canary, and rolling deployment strategies

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLUSTER_NAME="${CLUSTER_NAME:-wrfcoin-production}"
REGION="${AWS_REGION:-us-east-1}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-canary}"
ENVIRONMENT="${ENVIRONMENT:-production}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Pre-deployment checks
pre_deployment_checks() {
    log "Running pre-deployment checks..."
    
    # Check required tools
    local required_tools=("kubectl" "helm" "aws" "docker" "jq")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            error "$tool is required but not installed"
        fi
    done
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured"
    fi
    
    # Check kubectl context
    if ! kubectl cluster-info &> /dev/null; then
        error "kubectl not connected to cluster"
    fi
    
    # Verify cluster connection
    local current_context=$(kubectl config current-context)
    if [[ "$current_context" != *"$CLUSTER_NAME"* ]]; then
        warning "Current kubectl context: $current_context"
        read -p "Continue with this context? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Deployment cancelled by user"
        fi
    fi
    
    success "Pre-deployment checks passed"
}

# Build and push images
build_and_push_images() {
    log "Building and pushing container images..."
    
    local image_tag="${IMAGE_TAG:-$(git rev-parse --short HEAD)}"
    local registry="${REGISTRY:-ghcr.io/wrfcoin}"
    
    # Services to build
    local services=("api" "frontend" "cross-chain" "iot" "storage" "governance" "wallet")
    
    for service in "${services[@]}"; do
        log "Building $service image..."
        
        local dockerfile="infrastructure/docker/Dockerfile.$service"
        local image_name="$registry/wrfcoin-$service:$image_tag"
        
        if [[ -f "$dockerfile" ]]; then
            docker build -f "$dockerfile" -t "$image_name" .
            docker push "$image_name"
            success "Built and pushed $service:$image_tag"
        else
            warning "Dockerfile not found for $service, skipping..."
        fi
    done
    
    # Update image references
    export IMAGE_TAG="$image_tag"
    export REGISTRY="$registry"
}

# Security scanning
security_scan() {
    log "Running security scans..."
    
    # Trivy scan for vulnerabilities
    local image_tag="${IMAGE_TAG:-latest}"
    local registry="${REGISTRY:-ghcr.io/wrfcoin}"
    
    for service in api frontend; do
        local image_name="$registry/wrfcoin-$service:$image_tag"
        log "Scanning $image_name for vulnerabilities..."
        
        if docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
           aquasec/trivy:latest image --severity HIGH,CRITICAL \
           --exit-code 1 "$image_name"; then
            success "Security scan passed for $service"
        else
            error "Security vulnerabilities found in $service image"
        fi
    done
}

# Performance testing
performance_test() {
    log "Running performance tests..."
    
    local api_endpoint="${API_ENDPOINT:-http://localhost:3001}"
    
    # Basic load test
    if command -v artillery &> /dev/null; then
        log "Running Artillery load test..."
        artillery quick --count 100 --num 10 "$api_endpoint/api/health"
    else
        warning "Artillery not installed, skipping load test"
    fi
    
    # Custom performance test
    if [[ -f "performance-tests/load-test.yml" ]]; then
        artillery run performance-tests/load-test.yml
    fi
}

# Canary deployment
deploy_canary() {
    log "Starting canary deployment..."
    
    # Apply canary rollout configuration
    kubectl apply -f infrastructure/kubernetes/advanced/canary-deployment.yaml
    
    # Update rollout with new image
    local image_tag="${IMAGE_TAG:-latest}"
    local registry="${REGISTRY:-ghcr.io/wrfcoin}"
    
    kubectl argo rollouts set image wrfcoin-api-rollout \
        wrfcoin-api="$registry/wrfcoin-api:$image_tag" \
        -n wrfcoin-production
    
    # Monitor rollout progress
    log "Monitoring canary rollout progress..."
    kubectl argo rollouts get rollout wrfcoin-api-rollout \
        -n wrfcoin-production --watch --timeout 1800s
    
    # Check rollout status
    local status=$(kubectl argo rollouts status wrfcoin-api-rollout \
        -n wrfcoin-production --timeout 1800s)
    
    if [[ $? -eq 0 ]]; then
        success "Canary deployment completed successfully"
    else
        error "Canary deployment failed"
    fi
}

# Blue-green deployment
deploy_blue_green() {
    log "Starting blue-green deployment..."
    
    local image_tag="${IMAGE_TAG:-latest}"
    local registry="${REGISTRY:-ghcr.io/wrfcoin}"
    
    # Create green environment
    helm upgrade --install wrfcoin-green ./helm/wrfcoin \
        --namespace wrfcoin-production \
        --set image.tag="$image_tag" \
        --set image.repository="$registry" \
        --set environment=production \
        --set deployment.type=green \
        --set service.name=wrfcoin-green \
        --wait --timeout=600s
    
    # Health check for green environment
    log "Running health checks on green environment..."
    kubectl wait --for=condition=ready pod \
        -l app=wrfcoin-api,deployment=green \
        -n wrfcoin-production --timeout=300s
    
    # Run smoke tests
    if run_smoke_tests "wrfcoin-green"; then
        # Switch traffic to green
        log "Switching traffic to green environment..."
        kubectl patch service wrfcoin-api-service \
            -n wrfcoin-production \
            -p '{"spec":{"selector":{"deployment":"green"}}}'
        
        # Wait and verify
        sleep 30
        if run_smoke_tests "wrfcoin-api-service"; then
            # Remove blue environment
            log "Cleaning up blue environment..."
            kubectl delete deployment wrfcoin-blue -n wrfcoin-production || true
            success "Blue-green deployment completed successfully"
        else
            # Rollback to blue
            rollback_blue_green
        fi
    else
        error "Green environment health checks failed"
    fi
}

# Rolling deployment
deploy_rolling() {
    log "Starting rolling deployment..."
    
    local image_tag="${IMAGE_TAG:-latest}"
    local registry="${REGISTRY:-ghcr.io/wrfcoin}"
    
    # Update deployment with rolling strategy
    helm upgrade wrfcoin ./helm/wrfcoin \
        --namespace wrfcoin-production \
        --set image.tag="$image_tag" \
        --set image.repository="$registry" \
        --set environment=production \
        --set deployment.strategy.type=RollingUpdate \
        --set deployment.strategy.rollingUpdate.maxUnavailable=1 \
        --set deployment.strategy.rollingUpdate.maxSurge=1 \
        --wait --timeout=600s
    
    # Monitor rollout
    kubectl rollout status deployment/wrfcoin-api \
        -n wrfcoin-production --timeout=600s
    
    success "Rolling deployment completed successfully"
}

# Smoke tests
run_smoke_tests() {
    local service_name="${1:-wrfcoin-api-service}"
    local namespace="${2:-wrfcoin-production}"
    
    log "Running smoke tests against $service_name..."
    
    # Port forward for testing
    kubectl port-forward service/"$service_name" 8080:80 \
        -n "$namespace" &
    local port_forward_pid=$!
    
    # Wait for port forward
    sleep 5
    
    # Run tests
    local test_passed=true
    
    # Health check
    if ! curl -f -s http://localhost:8080/health > /dev/null; then
        warning "Health check failed"
        test_passed=false
    fi
    
    # API endpoints
    if ! curl -f -s http://localhost:8080/api/stats > /dev/null; then
        warning "API stats endpoint failed"
        test_passed=false
    fi
    
    # Cleanup
    kill $port_forward_pid 2>/dev/null || true
    
    if $test_passed; then
        success "Smoke tests passed"
        return 0
    else
        error "Smoke tests failed"
        return 1
    fi
}

# Rollback functions
rollback_canary() {
    log "Rolling back canary deployment..."
    kubectl argo rollouts abort wrfcoin-api-rollout -n wrfcoin-production
    kubectl argo rollouts undo wrfcoin-api-rollout -n wrfcoin-production
    success "Canary rollback completed"
}

rollback_blue_green() {
    log "Rolling back to blue environment..."
    kubectl patch service wrfcoin-api-service \
        -n wrfcoin-production \
        -p '{"spec":{"selector":{"deployment":"blue"}}}'
    success "Blue-green rollback completed"
}

# Post-deployment verification
post_deployment_verification() {
    log "Running post-deployment verification..."
    
    # Health checks
    kubectl wait --for=condition=ready pod \
        -l app=wrfcoin-api -n wrfcoin-production --timeout=300s
    
    # Service mesh verification (if Istio is installed)
    if kubectl get crd gateways.networking.istio.io &> /dev/null; then
        log "Verifying Istio service mesh configuration..."
        kubectl get virtualservice,destinationrule,gateway \
            -n wrfcoin-production
    fi
    
    # Run integration tests
    if [[ -f "tests/integration-tests.sh" ]]; then
        log "Running integration tests..."
        bash tests/integration-tests.sh
    fi
    
    # Performance baseline check
    performance_test
    
    success "Post-deployment verification completed"
}

# Monitoring and alerting setup
setup_monitoring() {
    log "Setting up monitoring and alerting..."

    kubectl get namespace monitoring >/dev/null 2>&1 || kubectl create namespace monitoring
    if ! kubectl get secret wrfcoin-alertmanager-smtp -n monitoring >/dev/null 2>&1; then
        error "Missing monitoring/wrfcoin-alertmanager-smtp Secret (required key: password)."
        error "Create it from the operator secret store before installing Alertmanager."
        return 1
    fi
    
    # Apply monitoring configurations
    kubectl apply -f infrastructure/monitoring/enhanced-monitoring.yaml
    
    # Install/upgrade Prometheus stack
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --values infrastructure/monitoring/prometheus-values.yaml \
        --wait --timeout=600s
    
    # Install Jaeger for tracing
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
    helm upgrade --install jaeger jaegertracing/jaeger \
        --namespace tracing \
        --create-namespace \
        --wait --timeout=300s
    
    success "Monitoring stack deployed"
}

# Chaos engineering setup
setup_chaos_engineering() {
    log "Setting up chaos engineering..."
    
    # Install Chaos Mesh
    helm repo add chaos-mesh https://charts.chaos-mesh.org
    helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace chaos-mesh \
        --create-namespace \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
        --wait --timeout=300s
    
    # Apply chaos experiments
    kubectl apply -f infrastructure/kubernetes/advanced/chaos-engineering.yaml
    
    success "Chaos engineering setup completed"
}

# Service mesh setup
setup_service_mesh() {
    log "Setting up Istio service mesh..."
    
    # Install Istio
    if ! command -v istioctl &> /dev/null; then
        log "Installing Istio CLI..."
        curl -L https://istio.io/downloadIstio | sh -
        export PATH="$PWD/istio-*/bin:$PATH"
    fi
    
    # Install Istio
    istioctl install --set values.defaultRevision=default -y
    
    # Label namespace for injection
    kubectl label namespace wrfcoin-production istio-injection=enabled --overwrite
    
    # Apply service mesh configurations
    kubectl apply -f infrastructure/kubernetes/advanced/istio-service-mesh.yaml
    
    success "Service mesh setup completed"
}

# Network policies
apply_network_policies() {
    log "Applying network security policies..."
    kubectl apply -f infrastructure/kubernetes/advanced/network-policies.yaml
    success "Network policies applied"
}

# Main deployment function
main() {
    log "Starting Wrfcoin advanced deployment..."
    log "Deployment type: $DEPLOYMENT_TYPE"
    log "Environment: $ENVIRONMENT"
    log "Cluster: $CLUSTER_NAME"
    
    # Pre-deployment
    pre_deployment_checks
    
    # Optional: Build and push (skip if images already built)
    if [[ "${BUILD_IMAGES:-true}" == "true" ]]; then
        build_and_push_images
        security_scan
    fi
    
    # Setup infrastructure components
    if [[ "${SETUP_MONITORING:-true}" == "true" ]]; then
        setup_monitoring
    fi
    
    if [[ "${SETUP_SERVICE_MESH:-false}" == "true" ]]; then
        setup_service_mesh
    fi
    
    if [[ "${SETUP_CHAOS:-false}" == "true" ]]; then
        setup_chaos_engineering
    fi
    
    if [[ "${APPLY_NETWORK_POLICIES:-true}" == "true" ]]; then
        apply_network_policies
    fi
    
    # Deploy based on strategy
    case "$DEPLOYMENT_TYPE" in
        "canary")
            deploy_canary
            ;;
        "blue-green")
            deploy_blue_green
            ;;
        "rolling")
            deploy_rolling
            ;;
        *)
            error "Unknown deployment type: $DEPLOYMENT_TYPE"
            ;;
    esac
    
    # Post-deployment
    post_deployment_verification
    
    success "Wrfcoin deployment completed successfully!"
    log "Deployment summary:"
    log "  - Type: $DEPLOYMENT_TYPE"
    log "  - Environment: $ENVIRONMENT"
    log "  - Image tag: ${IMAGE_TAG:-latest}"
    log "  - Cluster: $CLUSTER_NAME"
}

# Handle script arguments
case "${1:-deploy}" in
    "deploy")
        main
        ;;
    "rollback")
        case "$DEPLOYMENT_TYPE" in
            "canary")
                rollback_canary
                ;;
            "blue-green")
                rollback_blue_green
                ;;
            *)
                error "Rollback not supported for $DEPLOYMENT_TYPE"
                ;;
        esac
        ;;
    "test")
        run_smoke_tests
        ;;
    "monitoring")
        setup_monitoring
        ;;
    "chaos")
        setup_chaos_engineering
        ;;
    "mesh")
        setup_service_mesh
        ;;
    *)
        echo "Usage: $0 {deploy|rollback|test|monitoring|chaos|mesh}"
        exit 1
        ;;
esac
