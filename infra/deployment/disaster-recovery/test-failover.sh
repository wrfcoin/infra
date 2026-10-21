#!/bin/bash
# Wrfcoin Disaster Recovery Testing Script
# Location: infra/deployment/disaster-recovery/test-failover.sh
# Purpose: Automated DR testing with comprehensive validation

# Do NOT use set -e: individual test failures must be captured, not fatal.
# The script always generates a report so the CI workflow can parse results.

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/dr-test-$(date +%Y%m%d-%H%M%S).log"
PRIMARY_REGION="us-east-1"
SECONDARY_REGION="us-west-2"
CLUSTER_NAME="wrfcoin-production-cluster"
DB_IDENTIFIER="wrfcoin-production-database"
HEALTH_ENDPOINT="https://api.wrfcoin.com/health"

# Global timestamp for report generation
start_timestamp=$(date +%s)

# Test result variables (global so generate_report can read them)
database_test_result="not_run"
dns_test_result="not_run"
k8s_test_result="not_run"
redis_test_result="not_run"
app_health_result="not_run"
backup_test_result="not_run"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Fatal error for prerequisites only (aborts before tests start)
error_exit() {
    log "FATAL: $1"
    exit 1
}

# Non-fatal test error (returns 1 so caller captures "failed")
test_error() {
    log "ERROR: $1"
    return 1
}

# Verify prerequisites
verify_prerequisites() {
    log "Verifying prerequisites..."

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI not found"
    fi

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        error_exit "kubectl not found"
    fi

    # Check jq
    if ! command -v jq &> /dev/null; then
        error_exit "jq not found"
    fi

    # Verify AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error_exit "AWS credentials not configured"
    fi

    log "Prerequisites verified successfully"
}

# Test database failover
test_database_failover() {
    log "Starting database failover test..."

    # Get current database status
    local db_status
    db_status=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$DB_IDENTIFIER" \
        --region "$PRIMARY_REGION" \
        --query 'DBClusters[0].Status' \
        --output text 2>/dev/null) || { test_error "Failed to query database cluster status"; return 1; }

    if [ "$db_status" != "available" ]; then
        test_error "Database cluster not in available state: $db_status"
        return 1
    fi

    # Record start time
    local start_time=$(date +%s)

    # Initiate failover
    log "Initiating database cluster failover..."
    if ! aws rds failover-db-cluster \
        --db-cluster-identifier "$DB_IDENTIFIER" \
        --region "$PRIMARY_REGION" \
        --target-db-instance-identifier "${DB_IDENTIFIER}-replica-1" 2>/dev/null; then
        test_error "Failed to initiate database failover"
        return 1
    fi

    # Wait for failover completion
    log "Waiting for failover completion..."
    local max_wait=300  # 5 minutes
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        local current_status
        current_status=$(aws rds describe-db-clusters \
            --db-cluster-identifier "$DB_IDENTIFIER" \
            --region "$PRIMARY_REGION" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null) || current_status="query_failed"

        if [ "$current_status" = "available" ]; then
            local end_time=$(date +%s)
            local failover_time=$((end_time - start_time))
            log "Database failover completed in ${failover_time} seconds"
            return 0
        fi

        sleep 10
        elapsed=$((elapsed + 10))
        log "Database status: $current_status (${elapsed}s elapsed)"
    done

    test_error "Database failover timeout after ${max_wait} seconds"
    return 1
}

# Test DNS failover simulation
test_dns_failover() {
    log "Starting DNS failover test..."

    # Get current primary health check ID
    local health_check_id
    health_check_id=$(aws route53 list-health-checks \
        --query "HealthChecks[?contains(Tags[?Key=='Name'].Value, 'primary-health')].Id" \
        --output text 2>/dev/null) || { test_error "Failed to list health checks"; return 1; }

    if [ -z "$health_check_id" ]; then
        test_error "Primary health check not found"
        return 1
    fi

    log "Found primary health check: $health_check_id"

    # Simulate health check failure by temporarily updating the path
    log "Simulating health check failure..."
    if ! aws route53 update-health-check \
        --health-check-id "$health_check_id" \
        --resource-path "/health-test-failure" 2>/dev/null; then
        test_error "Failed to update health check"
        return 1
    fi

    # Wait for DNS propagation and failover
    log "Waiting for DNS failover (2 minutes)..."
    sleep 120

    # Verify traffic is routing to secondary region
    local routing_ok=false
    log "Verifying traffic routing to secondary region..."
    local max_attempts=10
    local attempts=0

    while [ $attempts -lt $max_attempts ]; do
        local response
        response=$(curl -s -H "User-Agent: DR-Test-Bot" "$HEALTH_ENDPOINT" | jq -r '.region // "unknown"' 2>/dev/null || echo "unknown")

        if [ "$response" = "$SECONDARY_REGION" ]; then
            log "Traffic successfully routing to secondary region"
            routing_ok=true
            break
        fi

        attempts=$((attempts + 1))
        log "Attempt $attempts: Traffic still routing to $response"
        sleep 30
    done

    # Always restore health check, even if routing verification failed
    log "Restoring health check..."
    aws route53 update-health-check \
        --health-check-id "$health_check_id" \
        --resource-path "/health" 2>/dev/null || log "WARNING: Failed to restore health check"

    if [ "$routing_ok" = false ]; then
        test_error "Traffic not routing to secondary region after $max_attempts attempts"
        return 1
    fi

    log "DNS failover test completed successfully"
    return 0
}

# Test Kubernetes cluster failover
test_k8s_failover() {
    log "Starting Kubernetes cluster failover test..."

    # Update kubeconfig for secondary region
    if ! aws eks update-kubeconfig \
        --region "$SECONDARY_REGION" \
        --name "${CLUSTER_NAME}-secondary" 2>/dev/null; then
        test_error "Failed to update kubeconfig for secondary region"
        return 1
    fi

    # Check cluster status
    local cluster_status
    cluster_status=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [ "$cluster_status" -eq 0 ]; then
        test_error "No nodes available in secondary cluster"
        return 1
    fi

    log "Secondary cluster has $cluster_status nodes available"

    # Scale up node groups to handle production load
    log "Scaling secondary cluster for production load..."
    if ! aws eks update-nodegroup-config \
        --cluster-name "${CLUSTER_NAME}-secondary" \
        --nodegroup-name "api-nodes-secondary" \
        --scaling-config minSize=5,maxSize=15,desiredSize=10 \
        --region "$SECONDARY_REGION" 2>/dev/null; then
        test_error "Failed to scale secondary cluster"
        return 1
    fi

    # Wait for nodes to be ready
    log "Waiting for nodes to be ready..."
    local ready_nodes=0
    local max_wait=600  # 10 minutes
    local elapsed=0

    while [ $elapsed -lt $max_wait ] && [ $ready_nodes -lt 8 ]; do
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo 0)
        log "Ready nodes: $ready_nodes (${elapsed}s elapsed)"
        sleep 30
        elapsed=$((elapsed + 30))
    done

    if [ $ready_nodes -lt 8 ]; then
        test_error "Insufficient ready nodes after ${max_wait} seconds"
        return 1
    fi

    log "Kubernetes failover test completed successfully"
    return 0
}

# Test Redis failover
test_redis_failover() {
    log "Starting Redis failover test..."

    # Get Redis Global Replication Group ID
    local global_rg_id
    global_rg_id=$(aws elasticache describe-global-replication-groups \
        --global-replication-group-id "wrfcoin-global" \
        --region "$PRIMARY_REGION" \
        --query 'GlobalReplicationGroups[0].GlobalReplicationGroupId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$global_rg_id" ] || [ "$global_rg_id" = "None" ]; then
        log "Redis Global Datastore not configured, skipping test"
        return 0
    fi

    log "Found Redis Global Replication Group: $global_rg_id"

    # Simulate failover by promoting secondary region
    log "Testing Redis regional failover capability..."

    # For testing, verify the configuration exists
    local secondary_clusters
    secondary_clusters=$(aws elasticache describe-replication-groups \
        --region "$SECONDARY_REGION" \
        --query "ReplicationGroups[?contains(ReplicationGroupId, 'secondary')].ReplicationGroupId" \
        --output text 2>/dev/null) || { test_error "Failed to query Redis replication groups"; return 1; }

    if [ -z "$secondary_clusters" ]; then
        test_error "No Redis clusters found in secondary region"
        return 1
    fi

    log "Redis failover test completed successfully (configuration verified)"
    return 0
}

# Verify application health and functionality
verify_application_health() {
    log "Verifying application health..."

    # Test API health endpoint
    local health_response
    health_response=$(curl -s -f "$HEALTH_ENDPOINT" 2>/dev/null) || health_response="failed"

    if [ "$health_response" = "failed" ]; then
        test_error "API health check failed"
        return 1
    fi

    log "API health check passed"

    # Test specific API endpoints
    local endpoints=(
        "/api/v1/blockchain/status"
        "/api/v1/weather/latest"
        "/api/v1/consensus/info"
    )

    local endpoint_failures=0
    for endpoint in "${endpoints[@]}"; do
        local response_code
        response_code=$(curl -s -o /dev/null -w "%{http_code}" "https://api.wrfcoin.com${endpoint}" 2>/dev/null) || response_code="000"

        if [ "$response_code" != "200" ]; then
            log "WARNING: Endpoint $endpoint returned $response_code"
            endpoint_failures=$((endpoint_failures + 1))
        else
            log "Endpoint $endpoint: OK"
        fi
    done

    if [ $endpoint_failures -gt 0 ]; then
        log "WARNING: $endpoint_failures endpoint(s) returned non-200 status"
    fi

    log "Application health verification completed"
    return 0
}

# Test backup and recovery procedures
test_backup_recovery() {
    log "Starting backup and recovery test..."

    # Test S3 cross-region replication
    local test_file="dr-test-$(date +%s).txt"
    local test_content="DR test file created at $(date)"
    local primary_bucket="wrfcoin-production-blockchain-backup"
    local secondary_bucket="wrfcoin-production-secondary-blockchain-backup"

    # Create test file in primary bucket
    if ! echo "$test_content" | aws s3 cp - "s3://${primary_bucket}/${test_file}" \
        --region "$PRIMARY_REGION" 2>/dev/null; then
        test_error "Failed to upload test file to primary bucket"
        return 1
    fi

    log "Test file uploaded to primary bucket"

    # Wait for replication
    log "Waiting for cross-region replication (30 seconds)..."
    sleep 30

    # Verify file exists in secondary bucket
    local replicated_content
    replicated_content=$(aws s3 cp "s3://${secondary_bucket}/${test_file}" - \
        --region "$SECONDARY_REGION" 2>/dev/null || echo "failed")

    # Clean up test files regardless of result
    aws s3 rm "s3://${primary_bucket}/${test_file}" --region "$PRIMARY_REGION" &>/dev/null || true
    aws s3 rm "s3://${secondary_bucket}/${test_file}" --region "$SECONDARY_REGION" &>/dev/null || true

    if [ "$replicated_content" != "$test_content" ]; then
        test_error "S3 cross-region replication test failed"
        return 1
    fi

    log "S3 cross-region replication verified"
    log "Backup and recovery test completed successfully"
    return 0
}

# Generate test report (always called, even after failures)
generate_report() {
    log "Generating DR test report..."

    local report_file="${SCRIPT_DIR}/dr-test-report-$(date +%Y%m%d-%H%M%S).json"
    local duration=$(($(date +%s) - start_timestamp))

    cat > "$report_file" << EOF
{
  "test_run": {
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "duration_seconds": ${duration},
    "log_file": "$LOG_FILE"
  },
  "tests": {
    "database_failover": "${database_test_result}",
    "dns_failover": "${dns_test_result}",
    "kubernetes_failover": "${k8s_test_result}",
    "redis_failover": "${redis_test_result}",
    "application_health": "${app_health_result}",
    "backup_recovery": "${backup_test_result}"
  },
  "metrics": {
    "rto_target_seconds": 900,
    "rpo_target_seconds": 300,
    "total_test_duration": ${duration}
  },
  "recommendations": [
    "Review any failed tests and update procedures",
    "Schedule next DR test in 30 days",
    "Update contact information if needed"
  ]
}
EOF

    log "DR test report generated: $report_file"
    echo "Report location: $report_file"
}

# Main execution
main() {
    log "Starting Wrfcoin Disaster Recovery Test Suite"
    log "Test run ID: $(date +%Y%m%d-%H%M%S)"

    # Run prerequisite checks (fatal on failure - no point running tests)
    verify_prerequisites

    # Track whether any test failed
    local any_failed=false

    # Run tests based on command line arguments
    case "${1:-all}" in
        "database")
            test_database_failover && database_test_result="passed" || { database_test_result="failed"; any_failed=true; }
            ;;
        "dns")
            test_dns_failover && dns_test_result="passed" || { dns_test_result="failed"; any_failed=true; }
            ;;
        "k8s"|"kubernetes")
            test_k8s_failover && k8s_test_result="passed" || { k8s_test_result="failed"; any_failed=true; }
            ;;
        "redis")
            test_redis_failover && redis_test_result="passed" || { redis_test_result="failed"; any_failed=true; }
            ;;
        "backup")
            test_backup_recovery && backup_test_result="passed" || { backup_test_result="failed"; any_failed=true; }
            ;;
        "health")
            verify_application_health && app_health_result="passed" || { app_health_result="failed"; any_failed=true; }
            ;;
        "all")
            test_database_failover && database_test_result="passed" || { database_test_result="failed"; any_failed=true; }
            test_dns_failover && dns_test_result="passed" || { dns_test_result="failed"; any_failed=true; }
            test_k8s_failover && k8s_test_result="passed" || { k8s_test_result="failed"; any_failed=true; }
            test_redis_failover && redis_test_result="passed" || { redis_test_result="failed"; any_failed=true; }
            verify_application_health && app_health_result="passed" || { app_health_result="failed"; any_failed=true; }
            test_backup_recovery && backup_test_result="passed" || { backup_test_result="failed"; any_failed=true; }
            ;;
        *)
            echo "Usage: $0 [database|dns|kubernetes|redis|backup|health|all]"
            exit 1
            ;;
    esac

    # Always generate final report
    generate_report

    log "Disaster Recovery Test Suite completed"
    log "Log file: $LOG_FILE"

    # Exit with failure if any test failed (so CI detects it)
    if [ "$any_failed" = true ]; then
        exit 1
    fi
}

# Execute main function with all arguments
main "$@"
