#!/bin/bash

# Container Security Verification Script
# Validates Phase 3 security hardening implementation

echo "🔐 WRFCoin Container Security Verification"
echo "=========================================="

# Determine project root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0

# Function to check and report
check_security() {
    local test_name="$1"
    local command="$2"
    local expected="$3"
    
    echo -n "Checking $test_name... "
    
    if eval "$command" &>/dev/null; then
        if [[ -n "$expected" ]]; then
            result=$(eval "$command" 2>/dev/null)
            if [[ "$result" == *"$expected"* ]]; then
                echo -e "${GREEN}PASS${NC}"
                ((PASS++))
            else
                echo -e "${RED}FAIL${NC} (Expected: $expected, Got: $result)"
                ((FAIL++))
            fi
        else
            echo -e "${GREEN}PASS${NC}"
            ((PASS++))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        ((FAIL++))
    fi
}

echo "1. Checking for privileged containers..."
privileged_containers=$(docker ps --format "table {{.Names}}\t{{.Privileged}}" | grep -v "PRIVILEGED" | grep "true" | wc -l)
if [[ $privileged_containers -eq 0 ]]; then
    echo -e "${GREEN}✓ No privileged containers found${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ Found $privileged_containers privileged containers${NC}"
    ((FAIL++))
fi

echo "2. Checking port bindings..."
# Check if services are bound to localhost only
services=("wrfcoin-prometheus:9090" "wrfcoin-grafana:3000" "wrfcoin-cadvisor:8080")
for service in "${services[@]}"; do
    container_name="${service%:*}"
    port="${service#*:}"
    
    if docker ps --format "{{.Names}}" | grep -q "$container_name"; then
        binding=$(docker port "$container_name" "$port" 2>/dev/null | head -1)
        if [[ "$binding" == "127.0.0.1:"* ]]; then
            echo -e "${GREEN}✓ $container_name properly bound to localhost${NC}"
            ((PASS++))
        else
            echo -e "${RED}✗ $container_name not bound to localhost: $binding${NC}"
            ((FAIL++))
        fi
    else
        echo -e "${YELLOW}! $container_name not running${NC}"
    fi
done

echo "3. Checking user contexts..."
# Check if containers run as non-root users
containers=("wrfcoin-prometheus" "wrfcoin-grafana" "wrfcoin-node-exporter")
for container in "${containers[@]}"; do
    if docker ps --format "{{.Names}}" | grep -q "$container"; then
        user_info=$(docker exec "$container" whoami 2>/dev/null)
        if [[ "$user_info" != "root" ]]; then
            echo -e "${GREEN}✓ $container running as non-root user: $user_info${NC}"
            ((PASS++))
        else
            echo -e "${RED}✗ $container running as root${NC}"
            ((FAIL++))
        fi
    else
        echo -e "${YELLOW}! $container not running${NC}"
    fi
done

echo "4. Checking security configurations..."
# Check for no-new-privileges
if docker inspect wrfcoin-prometheus 2>/dev/null | grep -q '"NoNewPrivileges": true'; then
    echo -e "${GREEN}✓ Prometheus has no-new-privileges enabled${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ Prometheus missing no-new-privileges${NC}"
    ((FAIL++))
fi

# Check for capability dropping
if docker inspect wrfcoin-prometheus 2>/dev/null | grep -q '"CapDrop": \["ALL"\]'; then
    echo -e "${GREEN}✓ Prometheus has capabilities properly dropped${NC}"
    ((PASS++))
else
    echo -e "${RED}✗ Prometheus capabilities not properly configured${NC}"
    ((FAIL++))
fi

echo "5. Checking dangerous volume mounts..."
# Check for dangerous mounts (should not exist)
dangerous_mounts=(":/rootfs" ":/host/dev" ":/host/etc")
containers_to_check=("wrfcoin-cadvisor" "wrfcoin-falco" "wrfcoin-node-exporter")

for container in "${containers_to_check[@]}"; do
    if docker ps --format "{{.Names}}" | grep -q "$container"; then
        mounts=$(docker inspect "$container" 2>/dev/null | jq -r '.[] | .Mounts[] | .Source + ":" + .Destination' 2>/dev/null)
        dangerous_found=false
        
        for dangerous in "${dangerous_mounts[@]}"; do
            if echo "$mounts" | grep -q "$dangerous"; then
                echo -e "${RED}✗ $container has dangerous mount: $dangerous${NC}"
                dangerous_found=true
                ((FAIL++))
            fi
        done
        
        if [[ "$dangerous_found" == "false" ]]; then
            echo -e "${GREEN}✓ $container has no dangerous mounts${NC}"
            ((PASS++))
        fi
    else
        echo -e "${YELLOW}! $container not running${NC}"
    fi
done

echo "6. Checking configuration files..."
# Check if Prometheus admin API is disabled in comprehensive monitoring
if [[ -f "$PROJECT_ROOT/infra/monitoring/docker-compose.comprehensive-monitoring.yml" ]]; then
    if grep -q "web.enable-admin-api" "$PROJECT_ROOT/infra/monitoring/docker-compose.comprehensive-monitoring.yml"; then
        echo -e "${RED}✗ Prometheus admin API still enabled${NC}"
        ((FAIL++))
    else
        echo -e "${GREEN}✓ Prometheus admin API properly disabled${NC}"
        ((PASS++))
    fi
fi

# Check if services are bound to localhost in compose files
compose_files=(
    "$PROJECT_ROOT/infra/monitoring/docker-compose.monitoring.yml"
    "$PROJECT_ROOT/infra/monitoring/docker-compose.comprehensive-monitoring.yml"
    # Historical microservices variant is quarantined in infra/docker/attic/.
)

for file in "${compose_files[@]}"; do
    if [[ -f "$file" ]]; then
        # Check for localhost binding patterns
        if grep -q "127.0.0.1:" "$file"; then
            echo -e "${GREEN}✓ $(basename "$file") has localhost binding configured${NC}"
            ((PASS++))
        else
            echo -e "${YELLOW}! $(basename "$file") may not have localhost binding${NC}"
        fi
        
        # Check for security contexts
        if grep -q "no-new-privileges:true" "$file"; then
            echo -e "${GREEN}✓ $(basename "$file") has security contexts configured${NC}"
            ((PASS++))
        else
            echo -e "${YELLOW}! $(basename "$file") may not have security contexts${NC}"
        fi
    fi
done

echo ""
echo "Security Verification Summary"
echo "============================="
echo -e "Tests Passed: ${GREEN}$PASS${NC}"
echo -e "Tests Failed: ${RED}$FAIL${NC}"

if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}🎉 All security checks passed! Container hardening is successful.${NC}"
    exit 0
else
    echo -e "${RED}⚠️  Some security checks failed. Please review and fix the issues.${NC}"
    exit 1
fi
