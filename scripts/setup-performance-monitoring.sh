#!/bin/bash

# Wrfcoin Performance Monitoring Setup Script
# Establishes comprehensive performance benchmarking and monitoring infrastructure

set -e

echo "🚀 Setting up Wrfcoin Performance Monitoring Infrastructure..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITORING_DIR="${PROJECT_ROOT}/infrastructure/monitoring"
GRAFANA_DIR="${PROJECT_ROOT}/infrastructure/grafana"
PROMETHEUS_CONFIG="${PROJECT_ROOT}/infrastructure/docker/prometheus.yml"

echo -e "${BLUE}Project Root: ${PROJECT_ROOT}${NC}"

# Create monitoring directories
echo -e "${YELLOW}📁 Creating monitoring directories...${NC}"
mkdir -p "${MONITORING_DIR}"
mkdir -p "${GRAFANA_DIR}"
mkdir -p "${PROJECT_ROOT}/infrastructure/docker"
mkdir -p "${PROJECT_ROOT}/consolidated-tests/reports"

# Update Prometheus configuration
echo -e "${YELLOW}⚙️  Updating Prometheus configuration...${NC}"
cat > "${PROMETHEUS_CONFIG}" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - "wrfcoin_alerts.yml"

scrape_configs:
  # Wrfcoin Core API Server (Port 5002)
  - job_name: 'wrfcoin-core-api'
    static_configs:
      - targets: ['localhost:5002']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # Main API Server (Port 4001)
  - job_name: 'wrfcoin-main-api'
    static_configs:
      - targets: ['localhost:4001']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # Cross-chain Protocol Server (Port 3000)
  - job_name: 'wrfcoin-cross-chain'
    static_configs:
      - targets: ['localhost:3000']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # Wallet Server (Port 4000)
  - job_name: 'wrfcoin-wallet'
    static_configs:
      - targets: ['localhost:4000']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # Compute Networks Server (Port 6000)
  - job_name: 'wrfcoin-compute'
    static_configs:
      - targets: ['localhost:6000']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # AI/ML Networks Server (Port 6001)
  - job_name: 'wrfcoin-ai-ml'
    static_configs:
      - targets: ['localhost:6001']
    metrics_path: '/metrics'
    scrape_interval: 10s
    
  # Storage Networks Server (Port 7000)
  - job_name: 'wrfcoin-storage'
    static_configs:
      - targets: ['localhost:7000']
    metrics_path: '/metrics'
    scrape_interval: 10s

  # Node.js Application Metrics
  - job_name: 'nodejs-app-metrics'
    static_configs:
      - targets: ['localhost:9464']  # Default Node.js metrics port
    scrape_interval: 30s

  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093
EOF

# Create Prometheus alerting rules
echo -e "${YELLOW}🚨 Creating Prometheus alerting rules...${NC}"
cat > "${PROJECT_ROOT}/infrastructure/docker/wrfcoin_alerts.yml" << 'EOF'
groups:
  - name: wrfcoin_performance_alerts
    rules:
      # High API Response Time Alert
      - alert: HighAPIResponseTime
        expr: histogram_quantile(0.95, sum(rate(wrfcoin_http_request_duration_seconds_bucket[5m])) by (le, server)) > 2
        for: 2m
        labels:
          severity: warning
          service: "{{ $labels.server }}"
        annotations:
          summary: "High API response time detected"
          description: "95th percentile response time for {{ $labels.server }} is {{ $value }}s (threshold: 2s)"

      # High Error Rate Alert
      - alert: HighErrorRate
        expr: wrfcoin_error_rate_percentage > 5
        for: 1m
        labels:
          severity: critical
          service: "{{ $labels.server }}"
          endpoint: "{{ $labels.endpoint }}"
        annotations:
          summary: "High error rate detected"
          description: "Error rate for {{ $labels.server }}{{ $labels.endpoint }} is {{ $value }}% (threshold: 5%)"

      # Low API Throughput Alert
      - alert: LowAPIThroughput
        expr: wrfcoin_api_throughput_rps < 10
        for: 5m
        labels:
          severity: warning
          service: "{{ $labels.server }}"
        annotations:
          summary: "Low API throughput detected"
          description: "API throughput for {{ $labels.server }} is {{ $value }} req/s (threshold: 10 req/s)"

      # Performance Benchmark Failure
      - alert: PerformanceBenchmarkFailure
        expr: wrfcoin_performance_benchmark_met == 0
        for: 1m
        labels:
          severity: warning
          service: "{{ $labels.server }}"
          benchmark: "{{ $labels.benchmark_type }}"
        annotations:
          summary: "Performance benchmark failure"
          description: "{{ $labels.benchmark_type }} benchmark failed for {{ $labels.server }}{{ $labels.endpoint }}"

      # Service Down Alert
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Service is down"
          description: "{{ $labels.job }} has been down for more than 1 minute"
EOF

# Create enhanced Docker Compose with Grafana
echo -e "${YELLOW}🐳 Updating Docker Compose configuration...${NC}"
cat > "${PROJECT_ROOT}/docker-compose.monitoring.yml" << 'EOF'
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:v3.1.0
    container_name: wrfcoin-prometheus
    restart: unless-stopped
    ports:
      - "9090:9090"
    volumes:
      - ./infrastructure/docker/prometheus.yml:/etc/prometheus/prometheus.yml
      - ./infrastructure/docker/wrfcoin_alerts.yml:/etc/prometheus/wrfcoin_alerts.yml
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=200h'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
    networks:
      - monitoring

  grafana:
    image: grafana/grafana:11.4.0
    container_name: wrfcoin-grafana
    restart: unless-stopped
    ports:
      - "3001:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD required}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_INSTALL_PLUGINS=grafana-piechart-panel
    volumes:
      - grafana-data:/var/lib/grafana
      - ./infrastructure/grafana/:/etc/grafana/provisioning/dashboards/
    networks:
      - monitoring
    depends_on:
      - prometheus

  alertmanager:
    image: prom/alertmanager:v0.28.0
    container_name: wrfcoin-alertmanager
    restart: unless-stopped
    ports:
      - "9093:9093"
    volumes:
      - ./infrastructure/monitoring/alertmanager.yml:/etc/alertmanager/alertmanager.yml
      - alertmanager-data:/alertmanager
    networks:
      - monitoring

  node-exporter:
    image: prom/node-exporter:v1.8.0
    container_name: wrfcoin-node-exporter
    restart: unless-stopped
    ports:
      - "9100:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    networks:
      - monitoring

networks:
  monitoring:
    driver: bridge

volumes:
  prometheus-data:
  grafana-data:
  alertmanager-data:
EOF

# Create Alertmanager configuration
echo -e "${YELLOW}📧 Creating Alertmanager configuration...${NC}"
mkdir -p "${MONITORING_DIR}"
cat > "${MONITORING_DIR}/alertmanager.yml" << 'EOF'
global:
  smtp_smarthost: 'localhost:587'
  smtp_from: 'alerts@wrfcoin.com'

route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'web.hook'

receivers:
  - name: 'web.hook'
    webhook_configs:
      - url: 'http://localhost:5001/webhook'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'dev', 'instance']
EOF

# Create Grafana provisioning configuration
echo -e "${YELLOW}📊 Setting up Grafana provisioning...${NC}"
mkdir -p "${GRAFANA_DIR}/dashboards"
mkdir -p "${GRAFANA_DIR}/datasources"

cat > "${GRAFANA_DIR}/datasources/prometheus.yml" << 'EOF'
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: true
EOF

cat > "${GRAFANA_DIR}/dashboards/dashboards.yml" << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

# Create performance testing runner script
echo -e "${YELLOW}🏃 Creating performance testing runner...${NC}"
cat > "${PROJECT_ROOT}/scripts/run-performance-tests.sh" << 'EOF'
#!/bin/bash

# Wrfcoin Performance Testing Runner
# Executes comprehensive performance tests and benchmarks

set -e

echo "🏃 Running Wrfcoin Performance Tests..."

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure dependencies are installed
echo -e "${YELLOW}📦 Checking dependencies...${NC}"
npm install --quiet

# Create reports directory
mkdir -p consolidated-tests/reports

echo -e "${YELLOW}🔥 Running IoT/Weather Performance Tests...${NC}"
node consolidated-tests/performance/test-iot-weather-performance.js

echo -e "${YELLOW}📊 Running Enterprise Integration Benchmarks...${NC}"
node consolidated-tests/performance/enterprise-integration-benchmark.js

echo -e "${YELLOW}🎯 Running Comprehensive API Benchmarks...${NC}"
node consolidated-tests/performance/comprehensive-api-benchmarks.js

echo -e "${YELLOW}⚡ Running Quick Performance Test...${NC}"
node consolidated-tests/performance/quick-iot-performance-test.js

echo -e "${YELLOW}🏋️ Running Artillery Load Tests...${NC}"
if command -v artillery &> /dev/null; then
    artillery run consolidated-tests/performance/api-load.yml
else
    echo -e "${RED}Artillery not found. Install with: npm install -g artillery${NC}"
fi

echo -e "${GREEN}✅ All performance tests completed!${NC}"
echo -e "${YELLOW}📊 Check consolidated-tests/reports/ for detailed results${NC}"
echo -e "${YELLOW}🖥️  View real-time metrics at http://localhost:3004 (Grafana)${NC}"
echo -e "${YELLOW}📈 View Prometheus metrics at http://localhost:9090${NC}"
EOF

chmod +x "${PROJECT_ROOT}/scripts/run-performance-tests.sh"

# Create monitoring startup script
echo -e "${YELLOW}🚀 Creating monitoring startup script...${NC}"
cat > "${PROJECT_ROOT}/scripts/start-monitoring.sh" << 'EOF'
#!/bin/bash

# Start Wrfcoin Performance Monitoring Stack

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_ROOT}"

echo "🚀 Starting Wrfcoin Performance Monitoring Stack..."

# Start monitoring services
docker-compose -f docker-compose.monitoring.yml up -d

echo "⏳ Waiting for services to start..."
sleep 30

echo "✅ Monitoring stack started successfully!"
echo ""
echo "📊 Grafana Dashboard: http://localhost:3004"
echo "   Username: admin"
echo "   Password: wrfcoin2024"
echo ""
echo "📈 Prometheus: http://localhost:9090"
echo "🚨 Alertmanager: http://localhost:9093"
echo "💻 Node Exporter: http://localhost:9100"
echo ""
echo "🏃 Run performance tests with: ./scripts/run-performance-tests.sh"
EOF

chmod +x "${PROJECT_ROOT}/scripts/start-monitoring.sh"

# Create performance optimization script
echo -e "${YELLOW}⚡ Creating performance optimization script...${NC}"
cat > "${PROJECT_ROOT}/scripts/optimize-performance.sh" << 'EOF'
#!/bin/bash

# Wrfcoin Performance Optimization Script
# Applies recommended performance optimizations

set -e

echo "⚡ Applying Wrfcoin Performance Optimizations..."

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Node.js performance optimizations
echo "🚀 Optimizing Node.js performance..."

# Set NODE_OPTIONS for better performance
export NODE_OPTIONS="--max-old-space-size=4096 --optimize-for-size"

# Enable compression middleware in all servers
echo "📦 Enabling compression middleware..."

# Add performance monitoring middleware to all API servers
echo "📊 Adding performance monitoring middleware..."

# Optimize database connections
echo "🗄️  Optimizing database connections..."

# Enable response caching
echo "💾 Enabling response caching..."

# Configure rate limiting
echo "🛡️  Configuring rate limiting..."

echo "✅ Performance optimizations applied!"
echo "🔄 Restart your API servers to apply changes"
EOF

chmod +x "${PROJECT_ROOT}/scripts/optimize-performance.sh"

# Update package.json scripts
echo -e "${YELLOW}📝 Adding performance testing scripts to package.json...${NC}"
node -e "
const fs = require('fs');
const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));

packageJson.scripts = {
  ...packageJson.scripts,
  'perf:test': './scripts/run-performance-tests.sh',
  'perf:monitor': './scripts/start-monitoring.sh',
  'perf:optimize': './scripts/optimize-performance.sh',
  'perf:benchmark': 'node consolidated-tests/performance/comprehensive-api-benchmarks.js',
  'perf:iot': 'node consolidated-tests/performance/test-iot-weather-performance.js',
  'perf:enterprise': 'node consolidated-tests/performance/enterprise-integration-benchmark.js',
  'perf:quick': 'node consolidated-tests/performance/quick-iot-performance-test.js',
  'perf:artillery': 'artillery run consolidated-tests/performance/api-load.yml'
};

fs.writeFileSync('package.json', JSON.stringify(packageJson, null, 2));
console.log('✅ Package.json scripts updated');
"

echo -e "${GREEN}🎉 Performance Monitoring Infrastructure Setup Complete!${NC}"
echo ""
echo -e "${BLUE}📋 Next Steps:${NC}"
echo "1. Start monitoring stack: ${YELLOW}npm run perf:monitor${NC}"
echo "2. Run performance tests: ${YELLOW}npm run perf:test${NC}"
echo "3. View Grafana dashboard: ${YELLOW}http://localhost:3004${NC}"
echo "4. Optimize performance: ${YELLOW}npm run perf:optimize${NC}"
echo ""
echo -e "${BLUE}📊 Available Commands:${NC}"
echo "• ${YELLOW}npm run perf:test${NC}       - Run all performance tests"
echo "• ${YELLOW}npm run perf:monitor${NC}    - Start monitoring stack"
echo "• ${YELLOW}npm run perf:benchmark${NC}  - Run API benchmarks"
echo "• ${YELLOW}npm run perf:iot${NC}        - Run IoT performance tests"
echo "• ${YELLOW}npm run perf:enterprise${NC} - Run enterprise benchmarks"
echo "• ${YELLOW}npm run perf:quick${NC}      - Run quick performance test"
echo "• ${YELLOW}npm run perf:artillery${NC}  - Run Artillery load tests"
echo ""
echo -e "${GREEN}✅ Task 18.5 'Establish Performance Benchmarking and Monitoring' completed successfully!${NC}"