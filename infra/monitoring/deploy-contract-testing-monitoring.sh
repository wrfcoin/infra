#!/bin/bash

# Deploy Contract Testing Monitoring Infrastructure
# Sets up comprehensive contract test monitoring with Grafana dashboards, Prometheus metrics, and Pact Broker

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_COMPOSE_FILES=(
    "docker-compose.monitoring.yml"
    "docker-compose.contract-testing.yml"
)

echo -e "${BLUE}🚀 WRFCoin Contract Testing Monitoring Deployment${NC}"
echo -e "${BLUE}=================================================${NC}"
echo

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check if port is available
check_port() {
    local port=$1
    if lsof -Pi :$port -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${YELLOW}⚠️  Warning: Port $port is already in use${NC}"
        return 1
    fi
    return 0
}

# Function to wait for service to be ready
wait_for_service() {
    local name=$1
    local url=$2
    local max_attempts=${3:-30}
    local attempt=1
    
    echo -e "${YELLOW}⏳ Waiting for $name to be ready...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        if curl -s -f "$url" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ $name is ready!${NC}"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo -e "${RED}❌ $name failed to start within expected time${NC}"
    return 1
}

# Check prerequisites
echo -e "${YELLOW}🔍 Checking prerequisites...${NC}"

if ! command_exists docker; then
    echo -e "${RED}❌ Docker is not installed${NC}"
    exit 1
fi

if ! command_exists docker-compose; then
    echo -e "${RED}❌ Docker Compose is not installed${NC}"
    exit 1
fi

if ! command_exists node; then
    echo -e "${RED}❌ Node.js is not installed${NC}"
    exit 1
fi

if ! command_exists npm; then
    echo -e "${RED}❌ npm is not installed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Prerequisites check passed${NC}"
echo

# Check ports availability
echo -e "${YELLOW}🔌 Checking port availability...${NC}"

REQUIRED_PORTS=(3000 9090 9095 9292 8090 9096)
for port in "${REQUIRED_PORTS[@]}"; do
    if ! check_port $port; then
        echo -e "${YELLOW}   Port $port is in use - this may cause conflicts${NC}"
    fi
done

echo

# Create necessary directories
echo -e "${YELLOW}📁 Creating directories...${NC}"

DIRS=(
    "tests/contract/reports"
    "tests/contract/logs"
    "tests/contract/pacts"
    "infra/monitoring/data"
    "infra/monitoring/logs"
)

for dir in "${DIRS[@]}"; do
    mkdir -p "$PROJECT_ROOT/$dir"
    echo -e "   Created: $dir"
done

echo -e "${GREEN}✅ Directories created${NC}"
echo

# Install dependencies
echo -e "${YELLOW}📦 Installing monitoring dependencies...${NC}"

cd "$SCRIPT_DIR"
if [ ! -f package.json ]; then
    echo -e "${RED}❌ package.json not found in monitoring directory${NC}"
    exit 1
fi

npm install --production
echo -e "${GREEN}✅ Dependencies installed${NC}"
echo

# Build Docker images
echo -e "${YELLOW}🐳 Building Docker images...${NC}"

docker build -f Dockerfile.contract-metrics -t wrfcoin/contract-metrics:latest .
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Contract metrics image built successfully${NC}"
else
    echo -e "${RED}❌ Failed to build contract metrics image${NC}"
    exit 1
fi

echo

# Update Prometheus configuration
echo -e "${YELLOW}⚙️  Updating Prometheus configuration...${NC}"

if [ -f prometheus.yml ]; then
    # Backup existing config
    cp prometheus.yml prometheus.yml.backup
    echo -e "   Created backup: prometheus.yml.backup"
    
    # Merge contract testing configuration
    if [ -f prometheus-contract-testing.yml ]; then
        echo -e "   Merging contract testing configuration..."
        
        # Simple merge - in production, use proper YAML merge tools
        cat prometheus-contract-testing.yml >> prometheus.yml
        echo -e "${GREEN}✅ Prometheus configuration updated${NC}"
    fi
fi

# Update Grafana dashboard provisioning
echo -e "${YELLOW}📊 Setting up Grafana dashboards...${NC}"

GRAFANA_DASHBOARD_DIR="grafana/dashboards"
if [ -d "$GRAFANA_DASHBOARD_DIR" ]; then
    # Dashboard should already be created - verify it exists
    if [ -f "$GRAFANA_DASHBOARD_DIR/wrfcoin-contract-testing.json" ]; then
        echo -e "${GREEN}✅ Contract testing dashboard available${NC}"
    else
        echo -e "${YELLOW}⚠️  Contract testing dashboard not found${NC}"
    fi
fi

# Update alerting rules
echo -e "${YELLOW}🚨 Setting up alerting rules...${NC}"

if [ -f contract-test-alerts.yml ]; then
    echo -e "${GREEN}✅ Contract test alerting rules configured${NC}"
else
    echo -e "${RED}❌ Contract test alerting rules not found${NC}"
    exit 1
fi

echo

# Start services
echo -e "${YELLOW}🚀 Starting contract testing monitoring services...${NC}"

# Stop any existing services
echo -e "   Stopping existing services..."
docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml down --remove-orphans 2>/dev/null || true

# Start services
echo -e "   Starting services..."
docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml up -d

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Services started successfully${NC}"
else
    echo -e "${RED}❌ Failed to start services${NC}"
    exit 1
fi

echo

# Wait for services to be ready
echo -e "${YELLOW}🔄 Waiting for services to be ready...${NC}"

wait_for_service "Prometheus" "http://localhost:9090/api/v1/status/config" 30
wait_for_service "Grafana" "http://localhost:3000/api/health" 30
wait_for_service "Contract Metrics Collector" "http://localhost:9095/health" 30
wait_for_service "Pact Broker" "http://localhost:9292/diagnostic/status/heartbeat" 60

echo

# Verify dashboard installation
echo -e "${YELLOW}📊 Verifying dashboard installation...${NC}"

# Check if contract testing dashboard is available in Grafana
sleep 5
if curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/contract-testing-monitoring" | grep -q "contract-testing-monitoring"; then
    echo -e "${GREEN}✅ Contract testing dashboard installed successfully${NC}"
else
    echo -e "${YELLOW}⚠️  Contract testing dashboard may not be properly installed${NC}"
fi

# Test metrics collection
echo -e "${YELLOW}🧪 Testing metrics collection...${NC}"

if curl -s -f "http://localhost:9095/metrics" | grep -q "pact_"; then
    echo -e "${GREEN}✅ Contract test metrics are being collected${NC}"
else
    echo -e "${YELLOW}⚠️  Contract test metrics may not be properly configured${NC}"
fi

echo

# Display service information
echo -e "${GREEN}🎉 Contract Testing Monitoring Deployment Complete!${NC}"
echo
echo -e "${BLUE}Service URLs:${NC}"
echo -e "   📊 Grafana Dashboard: ${YELLOW}http://localhost:3000${NC} (admin/admin)"
echo -e "   📈 Prometheus: ${YELLOW}http://localhost:9090${NC}"
echo -e "   📊 Contract Testing Dashboard: ${YELLOW}http://localhost:3000/d/contract-testing-monitoring${NC}"
echo -e "   🔧 Contract Metrics API: ${YELLOW}http://localhost:9095${NC}"
echo -e "   🤝 Pact Broker: ${YELLOW}http://localhost:9292${NC}"
echo -e "   📋 Contract Test Reports: ${YELLOW}http://localhost:8090${NC}"
echo

echo -e "${BLUE}Quick Commands:${NC}"
echo -e "   View service status: ${YELLOW}docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml ps${NC}"
echo -e "   View logs: ${YELLOW}docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml logs -f${NC}"
echo -e "   Stop services: ${YELLOW}docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml down${NC}"
echo -e "   Collect metrics manually: ${YELLOW}curl -X POST http://localhost:9095/collect-metrics${NC}"
echo

echo -e "${BLUE}Test Integration:${NC}"
echo -e "   1. Run contract tests: ${YELLOW}cd tests/contract && npm test${NC}"
echo -e "   2. Check metrics: ${YELLOW}curl http://localhost:9095/metrics | grep pact_${NC}"
echo -e "   3. View dashboard: ${YELLOW}Open http://localhost:3000/d/contract-testing-monitoring${NC}"
echo

# Create integration guide
cat > "$PROJECT_ROOT/CONTRACT_TESTING_MONITORING.md" << EOF
# Contract Testing Monitoring Integration Guide

## Overview
This document describes how to integrate with the WRFCoin Contract Testing Monitoring system.

## Services
- **Contract Metrics Collector**: http://localhost:9095
- **Pact Broker**: http://localhost:9292
- **Grafana Dashboard**: http://localhost:3000/d/contract-testing-monitoring

## Integration

### In Your Tests
\`\`\`javascript
const { enhancedPactIntegration } = require('./tests/contract/setup/enhanced-pact-integration');

describe('API Contract Tests', () => {
  beforeEach(async () => {
    await enhancedPactIntegration.setupPactTest({
      consumer: 'my-consumer',
      provider: 'my-provider'
    });
  });
});
\`\`\`

### CI/CD Integration
\`\`\`bash
# In your CI pipeline
npm run test:contract
curl -X POST http://localhost:9095/collect-metrics
\`\`\`

### Monitoring
- Dashboard: Monitor real-time contract test health
- Alerts: Automatic notifications for contract test failures
- Reports: Comprehensive HTML reports in tests/contract/reports/

## Troubleshooting
- Check service health: \`curl http://localhost:9095/health\`
- View logs: \`docker-compose logs contract-test-metrics\`
- Restart services: \`docker-compose restart\`

Generated: $(date)
EOF

echo -e "${GREEN}✅ Integration guide created: CONTRACT_TESTING_MONITORING.md${NC}"
echo
echo -e "${BLUE}🎯 Next Steps:${NC}"
echo -e "   1. Review the integration guide: ${YELLOW}CONTRACT_TESTING_MONITORING.md${NC}"
echo -e "   2. Update your contract tests to use enhanced integration"
echo -e "   3. Configure CI/CD pipelines to report to metrics collector"
echo -e "   4. Set up alerting channels (Slack, email, etc.)"
echo -e "   5. Train team on using the monitoring dashboard"
echo

echo -e "${GREEN}🚀 Contract Testing Monitoring is ready!${NC}"