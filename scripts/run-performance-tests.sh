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
echo -e "${YELLOW}🖥️  View real-time metrics at http://localhost:3001 (Grafana)${NC}"
echo -e "${YELLOW}📈 View Prometheus metrics at http://localhost:9090${NC}"
