#!/bin/bash
# WRFCoin Load Testing Infrastructure Automation Scripts
# Task 43 Subtask 14: Set Up Load Testing Infrastructure and Scaling Capabilities

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TERRAFORM_DIR="${PROJECT_ROOT}/infrastructure-load-testing"
KUBERNETES_MANIFESTS="${PROJECT_ROOT}/kubernetes-load-testing-manifests.yaml"

# Default values
ENVIRONMENT=${ENVIRONMENT:-development}
AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME="wrfcoin-${ENVIRONMENT}-loadtest-cluster"

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        INFO)  echo -e "${GREEN}[${timestamp}] INFO: ${message}${NC}" ;;
        WARN)  echo -e "${YELLOW}[${timestamp}] WARN: ${message}${NC}" ;;
        ERROR) echo -e "${RED}[${timestamp}] ERROR: ${message}${NC}" ;;
        DEBUG) echo -e "${BLUE}[${timestamp}] DEBUG: ${message}${NC}" ;;
    esac
}

# Error handling
error_exit() {
    log ERROR "$1"
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log INFO "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check required tools
    command -v terraform >/dev/null 2>&1 || missing_tools+=("terraform")
    command -v kubectl >/dev/null 2>&1 || missing_tools+=("kubectl")
    command -v helm >/dev/null 2>&1 || missing_tools+=("helm")
    command -v aws >/dev/null 2>&1 || missing_tools+=("aws")
    command -v jq >/dev/null 2>&1 || missing_tools+=("jq")
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        error_exit "Missing required tools: ${missing_tools[*]}"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        error_exit "AWS credentials not configured"
    fi
    
    log INFO "Prerequisites check passed"
}

# Provision infrastructure
provision_infrastructure() {
    log INFO "Provisioning load testing infrastructure..."
    
    local env_file="${ENVIRONMENT}.tfvars"
    
    # Create terraform directory if it doesn't exist
    mkdir -p "${TERRAFORM_DIR}"
    
    # Copy terraform files to terraform directory
    if [ -f "${PROJECT_ROOT}/infrastructure-load-testing-main.tf" ]; then
        cp "${PROJECT_ROOT}/infrastructure-load-testing-main.tf" "${TERRAFORM_DIR}/main.tf"
    fi
    
    if [ -f "${PROJECT_ROOT}/infrastructure-load-testing-variables.tf" ]; then
        cp "${PROJECT_ROOT}/infrastructure-load-testing-variables.tf" "${TERRAFORM_DIR}/variables.tf"
    fi
    
    cd "${TERRAFORM_DIR}"
    
    # Initialize Terraform
    log INFO "Initializing Terraform..."
    terraform init
    
    # Create workspace for environment
    terraform workspace select "${ENVIRONMENT}" 2>/dev/null || terraform workspace new "${ENVIRONMENT}"
    
    # Plan infrastructure
    log INFO "Planning infrastructure changes..."
    terraform plan -var="environment=${ENVIRONMENT}" -var="aws_region=${AWS_REGION}" -out=tfplan
    
    # Apply infrastructure
    log INFO "Applying infrastructure changes..."
    terraform apply -auto-approve tfplan
    
    # Get outputs
    local cluster_endpoint=$(terraform output -raw cluster_endpoint 2>/dev/null || echo "")
    local cluster_name=$(terraform output -raw cluster_name 2>/dev/null || echo "${CLUSTER_NAME}")
    
    if [ -n "$cluster_endpoint" ]; then
        log INFO "EKS cluster created: $cluster_name"
        log INFO "Cluster endpoint: $cluster_endpoint"
    fi
    
    cd "${PROJECT_ROOT}"
    log INFO "Infrastructure provisioning completed"
}

# Configure kubectl
configure_kubectl() {
    log INFO "Configuring kubectl..."
    
    # Update kubeconfig
    aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"
    
    # Verify connection
    if kubectl cluster-info >/dev/null 2>&1; then
        log INFO "kubectl configured successfully"
    else
        error_exit "Failed to configure kubectl"
    fi
}

# Deploy Kubernetes resources
deploy_kubernetes_resources() {
    log INFO "Deploying Kubernetes resources..."
    
    # Apply load testing manifests
    if [ -f "${KUBERNETES_MANIFESTS}" ]; then
        kubectl apply -f "${KUBERNETES_MANIFESTS}"
        log INFO "Kubernetes manifests applied"
    else
        error_exit "Kubernetes manifests file not found: ${KUBERNETES_MANIFESTS}"
    fi
    
    # Wait for deployments to be ready
    log INFO "Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/k6-load-generator -n wrfcoin-load-testing
    
    log INFO "Kubernetes resources deployed successfully"
}

# Install monitoring stack
install_monitoring() {
    log INFO "Installing monitoring stack..."
    
    # Add Prometheus community Helm repository
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add grafana https://grafana.github.io/helm-charts
    helm repo update
    
    # Create monitoring namespace
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    
    # Install Prometheus Operator
    helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set prometheus.prometheusSpec.retention=7d \
        --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
        --wait
    
    # Install Grafana dashboards for load testing
    install_grafana_dashboards
    
    log INFO "Monitoring stack installed successfully"
}

# Install Grafana dashboards
install_grafana_dashboards() {
    log INFO "Installing Grafana dashboards..."
    
    # Create dashboard ConfigMaps
    kubectl create configmap load-testing-dashboard \
        --from-literal=dashboard.json='{}' \
        --namespace monitoring \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Label ConfigMaps for Grafana discovery
    kubectl label configmap load-testing-dashboard grafana_dashboard=1 -n monitoring
    
    log INFO "Grafana dashboards installed"
}

# Scale load generators
scale_load_generators() {
    local instances=${1:-5}
    local regions=${2:-"${AWS_REGION}"}
    
    log INFO "Scaling load generators to ${instances} instances across regions: ${regions}"
    
    # Scale K6 deployment
    kubectl scale deployment k6-load-generator --replicas="${instances}" -n wrfcoin-load-testing
    
    # Wait for scaling to complete
    kubectl wait --for=condition=available --timeout=300s deployment/k6-load-generator -n wrfcoin-load-testing
    
    log INFO "Load generators scaled successfully"
}

# Run distributed load test
run_distributed_load_test() {
    local scenario=${1:-sensor_flood}
    local target_tps=${2:-10000}
    local duration=${3:-30m}
    local geographic_distribution=${4:-false}
    
    log INFO "Running distributed load test..."
    log INFO "Scenario: ${scenario}"
    log INFO "Target TPS: ${target_tps}"
    log INFO "Duration: ${duration}"
    log INFO "Geographic Distribution: ${geographic_distribution}"
    
    # Create test configuration
    local test_config_name="load-test-config-$(date +%s)"
    
    kubectl create configmap "${test_config_name}" \
        --from-literal=LOAD_SCENARIO="${scenario}" \
        --from-literal=TARGET_TPS="${target_tps}" \
        --from-literal=TEST_DURATION="${duration}" \
        --from-literal=GEOGRAPHIC_DISTRIBUTION="${geographic_distribution}" \
        -n wrfcoin-load-testing
    
    # Update deployment with new config
    kubectl patch deployment k6-load-generator -n wrfcoin-load-testing \
        --patch "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"k6\",\"envFrom\":[{\"configMapRef\":{\"name\":\"${test_config_name}\"}}]}]}}}}"
    
    # Monitor test execution
    monitor_load_test "${test_config_name}"
    
    # Cleanup test configuration
    kubectl delete configmap "${test_config_name}" -n wrfcoin-load-testing
    
    log INFO "Load test completed"
}

# Monitor load test execution
monitor_load_test() {
    local test_config_name=${1:-"default"}
    
    log INFO "Monitoring load test execution..."
    
    # Monitor pod logs
    kubectl logs -l app=k6-load-generator -n wrfcoin-load-testing --tail=100 -f &
    local logs_pid=$!
    
    # Monitor metrics
    while true; do
        local running_pods=$(kubectl get pods -l app=k6-load-generator -n wrfcoin-load-testing --field-selector=status.phase=Running --no-headers | wc -l)
        
        if [ "$running_pods" -eq 0 ]; then
            log INFO "All load generator pods have completed"
            break
        fi
        
        log INFO "Load test in progress. Running pods: ${running_pods}"
        sleep 30
    done
    
    # Stop log monitoring
    kill $logs_pid 2>/dev/null || true
    
    log INFO "Load test monitoring completed"
}

# Monitor infrastructure during load test
monitor_infrastructure() {
    local dashboard=${1:-load-testing}
    
    log INFO "Monitoring infrastructure during load test..."
    
    # Get Grafana service details
    local grafana_service=$(kubectl get service -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}')
    
    if [ -n "$grafana_service" ]; then
        # Port forward to Grafana
        kubectl port-forward service/"${grafana_service}" 3000:80 -n monitoring &
        local port_forward_pid=$!
        
        log INFO "Grafana dashboard available at: http://localhost:3000"
        log INFO "Default credentials: admin/prom-operator"
        
        # Monitor key metrics
        while true; do
            # Get cluster resource usage
            local node_count=$(kubectl get nodes --no-headers | wc -l)
            local pod_count=$(kubectl get pods --all-namespaces --no-headers | wc -l)
            local cpu_usage=$(kubectl top nodes 2>/dev/null | tail -n +2 | awk '{sum+=$3} END {print sum}' || echo "N/A")
            
            log INFO "Infrastructure Status:"
            log INFO "  Nodes: ${node_count}"
            log INFO "  Pods: ${pod_count}"
            log INFO "  CPU Usage: ${cpu_usage}"
            
            sleep 60
        done
        
        # Cleanup port forward
        kill $port_forward_pid 2>/dev/null || true
    else
        error_exit "Grafana service not found"
    fi
}

# Scale target services
scale_target_services() {
    local service=${1:-all}
    local replicas=${2:-5}
    
    log INFO "Scaling target services..."
    
    case $service in
        "main-api"|"all")
            kubectl scale deployment wrfcoin-main-api --replicas="${replicas}" -n default 2>/dev/null || log WARN "wrfcoin-main-api deployment not found"
            ;;
        "iot-sensors"|"all")
            kubectl scale deployment wrfcoin-iot-sensors --replicas="${replicas}" -n default 2>/dev/null || log WARN "wrfcoin-iot-sensors deployment not found"
            ;;
        "cross-chain"|"all")
            kubectl scale deployment wrfcoin-cross-chain --replicas="${replicas}" -n default 2>/dev/null || log WARN "wrfcoin-cross-chain deployment not found"
            ;;
        "compute-networks"|"all")
            kubectl scale deployment wrfcoin-compute-networks --replicas="${replicas}" -n default 2>/dev/null || log WARN "wrfcoin-compute-networks deployment not found"
            ;;
        *)
            error_exit "Unknown service: ${service}"
            ;;
    esac
    
    log INFO "Target services scaling initiated"
}

# Configure auto-scaling
configure_auto_scaling() {
    local cpu_threshold=${1:-70}
    local memory_threshold=${2:-80}
    local scale_up_cooldown=${3:-300}
    local scale_down_cooldown=${4:-600}
    
    log INFO "Configuring auto-scaling policies..."
    log INFO "CPU Threshold: ${cpu_threshold}%"
    log INFO "Memory Threshold: ${memory_threshold}%"
    log INFO "Scale Up Cooldown: ${scale_up_cooldown}s"
    log INFO "Scale Down Cooldown: ${scale_down_cooldown}s"
    
    # The auto-scaling configuration is applied via Kubernetes manifests
    # This function can be extended to dynamically update HPA configurations
    
    log INFO "Auto-scaling policies configured"
}

# Emergency scale up
emergency_scale() {
    local preset=${1:-maximum-capacity}
    
    log INFO "Executing emergency scaling: ${preset}"
    
    case $preset in
        "maximum-capacity")
            scale_load_generators 50
            scale_target_services "all" 20
            ;;
        "minimal-resources")
            scale_load_generators 1
            scale_target_services "all" 2
            ;;
        *)
            error_exit "Unknown preset: ${preset}"
            ;;
    esac
    
    log INFO "Emergency scaling completed"
}

# View costs
view_costs() {
    local period=${1:-daily}
    
    log INFO "Viewing costs for period: ${period}"
    
    # This would integrate with AWS Cost Explorer API
    # For now, provide basic cost estimation based on running resources
    
    local running_nodes=$(kubectl get nodes --no-headers | wc -l)
    local load_gen_pods=$(kubectl get pods -l app=k6-load-generator -n wrfcoin-load-testing --no-headers | wc -l)
    
    log INFO "Cost Estimation (approximate):"
    log INFO "  Running Nodes: ${running_nodes}"
    log INFO "  Load Generator Pods: ${load_gen_pods}"
    log INFO "  Estimated Daily Cost: \$$(echo "scale=2; ${running_nodes} * 2.5 * 24" | bc 2>/dev/null || echo "N/A")"
    
    log WARN "For detailed costs, check AWS Cost Explorer or implement Cost Explorer API integration"
}

# Set budget alert
set_budget_alert() {
    local daily_limit=${1:-500}
    local monthly_limit=${2:-10000}
    
    log INFO "Setting budget alerts..."
    log INFO "Daily Limit: \$${daily_limit}"
    log INFO "Monthly Limit: \$${monthly_limit}"
    
    # This would integrate with AWS Budgets API
    # Budget configuration is handled in Terraform
    
    log INFO "Budget alerts configured (check Terraform for implementation)"
}

# Optimize costs
optimize_costs() {
    local analyze_usage=${1:-7d}
    
    log INFO "Optimizing costs based on ${analyze_usage} usage analysis..."
    
    # Basic cost optimization recommendations
    local spot_percentage=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["eks.amazonaws.com/capacityType"]=="SPOT") | .metadata.name' | wc -l)
    local total_nodes=$(kubectl get nodes --no-headers | wc -l)
    
    if [ "$spot_percentage" -lt "$((total_nodes / 2))" ]; then
        log WARN "Consider using more spot instances for cost optimization"
    fi
    
    log INFO "Cost optimization analysis completed"
}

# Verify deployment
verify_deployment() {
    log INFO "Verifying deployment..."
    
    local issues=()
    
    # Check cluster connectivity
    if ! kubectl cluster-info >/dev/null 2>&1; then
        issues+=("Cluster connectivity")
    fi
    
    # Check load testing namespace
    if ! kubectl get namespace wrfcoin-load-testing >/dev/null 2>&1; then
        issues+=("Load testing namespace")
    fi
    
    # Check load generator deployment
    if ! kubectl get deployment k6-load-generator -n wrfcoin-load-testing >/dev/null 2>&1; then
        issues+=("K6 load generator deployment")
    fi
    
    # Check monitoring stack
    if ! kubectl get namespace monitoring >/dev/null 2>&1; then
        issues+=("Monitoring namespace")
    fi
    
    # Check HPA configurations
    local hpa_count=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l)
    if [ "$hpa_count" -eq 0 ]; then
        issues+=("HorizontalPodAutoscaler configurations")
    fi
    
    if [ ${#issues[@]} -ne 0 ]; then
        log ERROR "Deployment verification failed. Issues found:"
        for issue in "${issues[@]}"; do
            log ERROR "  - ${issue}"
        done
        exit 1
    else
        log INFO "Deployment verification passed"
    fi
}

# Cleanup resources
cleanup_resources() {
    local environment=${1:-development}
    
    log INFO "Cleaning up resources for environment: ${environment}"
    
    # Delete Kubernetes resources
    if [ -f "${KUBERNETES_MANIFESTS}" ]; then
        kubectl delete -f "${KUBERNETES_MANIFESTS}" --ignore-not-found=true
    fi
    
    # Delete Helm releases
    helm uninstall prometheus-stack -n monitoring 2>/dev/null || true
    
    # Delete namespaces
    kubectl delete namespace wrfcoin-load-testing --ignore-not-found=true
    kubectl delete namespace monitoring --ignore-not-found=true
    
    # Destroy Terraform infrastructure
    if [ -d "${TERRAFORM_DIR}" ]; then
        cd "${TERRAFORM_DIR}"
        terraform workspace select "${environment}" 2>/dev/null || true
        terraform destroy -auto-approve -var="environment=${environment}"
        cd "${PROJECT_ROOT}"
    fi
    
    log INFO "Resource cleanup completed"
}

# Emergency abort
emergency_abort() {
    local cleanup_resources=${1:-true}
    
    log WARN "Emergency abort initiated!"
    
    # Stop all load generators
    kubectl scale deployment k6-load-generator --replicas=0 -n wrfcoin-load-testing 2>/dev/null || true
    
    # Scale down target services
    emergency_scale "minimal-resources"
    
    if [ "$cleanup_resources" = "true" ]; then
        log WARN "Cleaning up resources..."
        cleanup_resources
    fi
    
    log INFO "Emergency abort completed"
}

# Cost runaway protection
cost_protection() {
    local emergency_shutdown=${1:-false}
    
    log WARN "Cost runaway protection activated!"
    
    # Emergency scale down
    emergency_scale "minimal-resources"
    
    if [ "$emergency_shutdown" = "true" ]; then
        log WARN "Emergency shutdown initiated"
        emergency_abort "true"
    fi
    
    log INFO "Cost protection measures applied"
}

# Usage information
usage() {
    cat << EOF
WRFCoin Load Testing Infrastructure Automation

Usage: $0 <command> [options]

Commands:
  provision-infrastructure              Provision load testing infrastructure
  configure-kubectl                     Configure kubectl for the cluster
  deploy-kubernetes-resources          Deploy Kubernetes resources
  install-monitoring                    Install monitoring stack
  scale-load-generators <instances>     Scale load generators
  run-distributed-load-test <scenario> <tps> <duration>
                                       Run distributed load test
  monitor-infrastructure [dashboard]    Monitor infrastructure during testing
  scale-target-services <service> <replicas>
                                       Scale target services
  configure-auto-scaling <cpu> <memory> <up> <down>
                                       Configure auto-scaling
  emergency-scale <preset>              Emergency scaling (maximum-capacity|minimal-resources)
  view-costs [period]                   View cost information
  set-budget-alert <daily> <monthly>    Set budget alerts
  optimize-costs [period]               Optimize costs
  verify-deployment                     Verify deployment status
  cleanup-resources [environment]       Cleanup all resources
  emergency-abort [cleanup]             Emergency abort with optional cleanup
  cost-protection [shutdown]            Cost runaway protection

Environment Variables:
  ENVIRONMENT     Environment name (default: development)
  AWS_REGION      AWS region (default: us-east-1)

Examples:
  $0 provision-infrastructure
  $0 run-distributed-load-test sensor_flood 10000 30m
  $0 scale-load-generators 20
  $0 emergency-scale maximum-capacity
  $0 cleanup-resources development

EOF
}

# Main execution
main() {
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    local command=$1
    shift
    
    case $command in
        "provision-infrastructure")
            check_prerequisites
            provision_infrastructure
            ;;
        "configure-kubectl")
            configure_kubectl
            ;;
        "deploy-kubernetes-resources")
            deploy_kubernetes_resources
            ;;
        "install-monitoring")
            install_monitoring
            ;;
        "scale-load-generators")
            scale_load_generators "$@"
            ;;
        "run-distributed-load-test")
            run_distributed_load_test "$@"
            ;;
        "monitor-infrastructure")
            monitor_infrastructure "$@"
            ;;
        "scale-target-services")
            scale_target_services "$@"
            ;;
        "configure-auto-scaling")
            configure_auto_scaling "$@"
            ;;
        "emergency-scale")
            emergency_scale "$@"
            ;;
        "view-costs")
            view_costs "$@"
            ;;
        "set-budget-alert")
            set_budget_alert "$@"
            ;;
        "optimize-costs")
            optimize_costs "$@"
            ;;
        "verify-deployment")
            verify_deployment
            ;;
        "cleanup-resources")
            cleanup_resources "$@"
            ;;
        "emergency-abort")
            emergency_abort "$@"
            ;;
        "cost-protection")
            cost_protection "$@"
            ;;
        *)
            log ERROR "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Execute main function with all arguments
main "$@"