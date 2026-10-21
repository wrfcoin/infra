#!/bin/bash

# Setup script for WRFCoin Test Automation & Analytics System
# This script sets up the comprehensive testing and analytics infrastructure

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONITORING_DIR="$PROJECT_ROOT/infra/monitoring"
ANALYTICS_DIR="$PROJECT_ROOT/scripts/analytics"
TEST_DIR="$PROJECT_ROOT/test"
REPORTS_DIR="$PROJECT_ROOT/reports"

echo -e "${BLUE}=== WRFCoin Test Automation & Analytics Setup ===${NC}"
echo "Project Root: $PROJECT_ROOT"
echo

# Function to print status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    local missing_deps=()
    
    if ! command_exists docker; then
        missing_deps+=("docker")
    fi
    
    if ! command_exists docker-compose; then
        missing_deps+=("docker-compose")
    fi
    
    if ! command_exists node; then
        missing_deps+=("node")
    fi
    
    if ! command_exists npm; then
        missing_deps+=("npm")
    fi
    
    if ! command_exists k6; then
        print_warning "k6 not found. Will install during setup."
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies and run this script again."
        exit 1
    fi
    
    print_status "All prerequisites satisfied."
}

# Create necessary directories
create_directories() {
    print_status "Creating directory structure..."
    
    local directories=(
        "$REPORTS_DIR/regression"
        "$REPORTS_DIR/performance"
        "$REPORTS_DIR/analytics"
        "$REPORTS_DIR/quality"
        "$REPORTS_DIR/business-intelligence"
        "$TEST_DIR/regression/reports"
        "$TEST_DIR/regression/artifacts"
        "$ANALYTICS_DIR/data"
        "$ANALYTICS_DIR/reports"
        "$PROJECT_ROOT/logs"
        "$PROJECT_ROOT/config/test-analytics"
    )
    
    for dir in "${directories[@]}"; do
        mkdir -p "$dir"
        echo "Created: $dir"
    done
}

# Install Node.js dependencies
install_dependencies() {
    print_status "Installing Node.js dependencies..."
    
    # Install root dependencies
    cd "$PROJECT_ROOT"
    if [ -f package.json ]; then
        npm ci --production=false
    fi
    
    # Install regression test dependencies
    if [ -d "$TEST_DIR/regression" ] && [ -f "$TEST_DIR/regression/package.json" ]; then
        cd "$TEST_DIR/regression"
        npm ci
        cd "$PROJECT_ROOT"
    fi
    
    # Install analytics dependencies
    if [ -f "$ANALYTICS_DIR/package.json" ]; then
        cd "$ANALYTICS_DIR"
        npm ci
        cd "$PROJECT_ROOT"
    fi
}

# Install k6 for load testing
install_k6() {
    if ! command_exists k6; then
        print_status "Installing k6..."
        
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux
            curl -s https://dl.k6.io/key.gpg | sudo apt-key add -
            echo "deb https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
            sudo apt-get update
            sudo apt-get install k6
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS
            if command_exists brew; then
                brew install k6
            else
                print_warning "Homebrew not found. Please install k6 manually: https://k6.io/docs/getting-started/installation/"
            fi
        else
            print_warning "Unsupported OS. Please install k6 manually: https://k6.io/docs/getting-started/installation/"
        fi
    else
        print_status "k6 already installed."
    fi
}

# Install Playwright browsers
install_playwright() {
    print_status "Installing Playwright browsers..."
    
    if [ -f "$PROJECT_ROOT/node_modules/.bin/playwright" ]; then
        "$PROJECT_ROOT/node_modules/.bin/playwright" install --with-deps
    else
        npx playwright install --with-deps
    fi
}

# Setup database for analytics
setup_database() {
    print_status "Setting up analytics database..."
    
    # Check if PostgreSQL is running
    if docker ps | grep -q postgres; then
        print_status "PostgreSQL container already running."
    else
        print_status "Starting PostgreSQL container for analytics..."
        docker run -d \
            --name wrfcoin-analytics-db \
            -e POSTGRES_DB=wrfcoin_analytics \
            -e POSTGRES_USER=postgres \
            -e POSTGRES_PASSWORD=${POSTGRES_PASSWORD:?POSTGRES_PASSWORD required} \
            -p 5433:5432 \
            postgres:15
        
        # Wait for PostgreSQL to be ready
        sleep 10
    fi
    
    # Initialize database schema
    if [ -f "$ANALYTICS_DIR/test-analytics-processor.js" ]; then
        print_status "Initializing analytics database schema..."
        cd "$ANALYTICS_DIR"
        node test-analytics-processor.js setup
        cd "$PROJECT_ROOT"
    fi
}

# Setup Redis for caching
setup_redis() {
    print_status "Setting up Redis for analytics caching..."
    
    if docker ps | grep -q redis; then
        print_status "Redis container already running."
    else
        print_status "Starting Redis container..."
        docker run -d \
            --name wrfcoin-analytics-redis \
            -p 6380:6379 \
            redis:7-alpine
    fi
}

# Configure monitoring dashboards
setup_monitoring() {
    print_status "Setting up monitoring dashboards..."
    
    # Copy dashboard configurations
    if [ -d "$MONITORING_DIR/dashboards" ]; then
        # Make sure Grafana provisioning directories exist
        mkdir -p "$MONITORING_DIR/grafana/dashboards"
        
        # Copy dashboard files
        cp "$MONITORING_DIR/dashboards/wrfcoin-test-analytics.json" \
           "$MONITORING_DIR/grafana/dashboards/"
        cp "$MONITORING_DIR/dashboards/wrfcoin-business-intelligence.json" \
           "$MONITORING_DIR/grafana/dashboards/"
        
        print_status "Dashboard configurations copied."
    fi
    
    # Update Grafana provisioning configuration
    cat > "$MONITORING_DIR/grafana/dashboard-provisioning.yaml" << EOF
apiVersion: 1

providers:
  - name: 'WRFCoin Dashboards'
    orgId: 1
    folder: 'WRFCoin'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
}

# Create configuration files
create_configs() {
    print_status "Creating configuration files..."
    
    # Test analytics configuration
    cat > "$PROJECT_ROOT/config/test-analytics/config.json" << EOF
{
  "database": {
    "host": "localhost",
    "port": 5433,
    "database": "wrfcoin_analytics",
    "username": "postgres",
    "password": "postgres"
  },
  "redis": {
    "url": "redis://localhost:6380"
  },
  "retention": {
    "rawData": 90,
    "aggregated": 365,
    "trends": 730
  },
  "thresholds": {
    "responseTime": {
      "warning": 300,
      "critical": 500
    },
    "errorRate": {
      "warning": 0.01,
      "critical": 0.05
    },
    "availability": {
      "warning": 0.99,
      "critical": 0.95
    },
    "regression": {
      "minor": 0.1,
      "major": 0.25,
      "critical": 0.5
    }
  }
}
EOF

    # Regression testing configuration
    cat > "$TEST_DIR/regression/config.json" << EOF
{
  "environments": {
    "local": {
      "baseUrl": "http://localhost:5000",
      "apiUrl": "http://localhost:4001",
      "wsUrl": "ws://localhost:4001/ws"
    },
    "staging": {
      "baseUrl": "https://staging.wrfcoin.com",
      "apiUrl": "https://api-staging.wrfcoin.com",
      "wsUrl": "wss://api-staging.wrfcoin.com/ws"
    },
    "production": {
      "baseUrl": "https://app.wrfcoin.com",
      "apiUrl": "https://api.wrfcoin.com",
      "wsUrl": "wss://api.wrfcoin.com/ws"
    }
  },
  "browsers": ["chromium", "firefox", "webkit"],
  "parallelWorkers": 4,
  "retries": 2,
  "timeout": 30000,
  "thresholds": {
    "responseTime": 500,
    "errorRate": 0.01,
    "regressionTolerance": 0.1
  }
}
EOF

    # Performance testing configuration
    cat > "$TEST_DIR/performance/config.json" << EOF
{
  "scenarios": {
    "baseline": {
      "executor": "ramping-vus",
      "startVUs": 5,
      "stages": [
        {"duration": "2m", "target": 50},
        {"duration": "5m", "target": 50},
        {"duration": "2m", "target": 0}
      ]
    },
    "stress": {
      "executor": "ramping-vus", 
      "startVUs": 10,
      "stages": [
        {"duration": "2m", "target": 100},
        {"duration": "5m", "target": 200},
        {"duration": "2m", "target": 0}
      ]
    }
  },
  "thresholds": {
    "http_req_duration": ["p(95)<500"],
    "http_req_failed": ["rate<0.01"]
  }
}
EOF
}

# Create helper scripts
create_helper_scripts() {
    print_status "Creating helper scripts..."
    
    # Regression test runner
    cat > "$PROJECT_ROOT/scripts/run-regression-tests.sh" << 'EOF'
#!/bin/bash

# Quick regression test runner
set -e

ENVIRONMENT=${1:-local}
BROWSER=${2:-chromium}
TEST_TYPE=${3:-all}

echo "Running regression tests..."
echo "Environment: $ENVIRONMENT"
echo "Browser: $BROWSER"
echo "Test Type: $TEST_TYPE"

cd "$(dirname "$0")/../test/regression"

case $TEST_TYPE in
  "wallet")
    npm run test:regression:wallet -- --browser=$BROWSER
    ;;
  "weather")
    npm run test:regression:weather -- --browser=$BROWSER
    ;;
  "bridge") 
    npm run test:regression:bridge -- --browser=$BROWSER
    ;;
  "all")
    npm run test:regression:wallet -- --browser=$BROWSER
    npm run test:regression:weather -- --browser=$BROWSER
    npm run test:regression:bridge -- --browser=$BROWSER
    npm run test:regression:defi -- --browser=$BROWSER
    npm run test:regression:nft -- --browser=$BROWSER
    npm run test:regression:governance -- --browser=$BROWSER
    ;;
  *)
    echo "Unknown test type: $TEST_TYPE"
    echo "Available types: wallet, weather, bridge, all"
    exit 1
    ;;
esac

echo "Regression tests completed."
EOF

    # Performance test runner
    cat > "$PROJECT_ROOT/scripts/run-performance-tests.sh" << 'EOF'
#!/bin/bash

# Performance test runner
set -e

SCENARIO=${1:-baseline}
ENVIRONMENT=${2:-local}

echo "Running performance tests..."
echo "Scenario: $SCENARIO" 
echo "Environment: $ENVIRONMENT"

cd "$(dirname "$0")/../test/performance"

# Set environment variables
export BASE_URL="http://localhost:4001"
export WS_URL="ws://localhost:4001/ws"

case $ENVIRONMENT in
  "staging")
    export BASE_URL="https://api-staging.wrfcoin.com"
    export WS_URL="wss://api-staging.wrfcoin.com/ws"
    ;;
  "production")
    export BASE_URL="https://api.wrfcoin.com" 
    export WS_URL="wss://api.wrfcoin.com/ws"
    ;;
esac

# Run k6 tests
k6 run k6-regression-suite.js \
  --env SCENARIO=$SCENARIO \
  --out json=../reports/performance/k6-results-$(date +%Y%m%d-%H%M%S).json

echo "Performance tests completed."
EOF

    # Analytics processor runner
    cat > "$PROJECT_ROOT/scripts/process-test-analytics.sh" << 'EOF'
#!/bin/bash

# Test analytics processor runner
set -e

COMMAND=${1:-summary}
RESULTS_DIR=${2:-./reports}

echo "Processing test analytics..."
echo "Command: $COMMAND"

cd "$(dirname "$0")/analytics"

case $COMMAND in
  "process")
    node test-analytics-processor.js process "$RESULTS_DIR"
    ;;
  "summary")
    node test-analytics-processor.js summary
    ;;
  "trends")
    node test-analytics-processor.js trends 7
    ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Available commands: process, summary, trends"
    exit 1
    ;;
esac

echo "Analytics processing completed."
EOF

    # Make scripts executable
    chmod +x "$PROJECT_ROOT/scripts/run-regression-tests.sh"
    chmod +x "$PROJECT_ROOT/scripts/run-performance-tests.sh"
    chmod +x "$PROJECT_ROOT/scripts/process-test-analytics.sh"
}

# Setup cron jobs for automated execution
setup_cron_jobs() {
    print_status "Setting up cron jobs for automated testing..."
    
    # Create cron job script
    cat > "$PROJECT_ROOT/scripts/cron-test-automation.sh" << EOF
#!/bin/bash

# Automated test execution cron job
cd "$PROJECT_ROOT"

# Run daily regression tests
if [ "\$(date +%H)" = "02" ]; then
    echo "\$(date): Running daily regression tests" >> logs/cron.log
    bash scripts/run-regression-tests.sh local all >> logs/cron.log 2>&1
    bash scripts/process-test-analytics.sh process ./reports >> logs/cron.log 2>&1
fi

# Run hourly performance checks  
if [ "\$(date +%M)" = "00" ]; then
    echo "\$(date): Running hourly performance check" >> logs/cron.log
    bash scripts/run-performance-tests.sh baseline local >> logs/cron.log 2>&1
fi

# Process analytics every 15 minutes
echo "\$(date): Processing test analytics" >> logs/cron.log
bash scripts/process-test-analytics.sh summary >> logs/cron.log 2>&1
EOF

    chmod +x "$PROJECT_ROOT/scripts/cron-test-automation.sh"
    
    print_warning "To enable automated testing, add this line to your crontab:"
    echo "*/15 * * * * $PROJECT_ROOT/scripts/cron-test-automation.sh"
    echo ""
    echo "Run 'crontab -e' and add the line above to enable automation."
}

# Create documentation
create_documentation() {
    print_status "Creating documentation..."
    
    cat > "$PROJECT_ROOT/docs/test-automation-analytics.md" << 'EOF'
# WRFCoin Test Automation & Analytics System

## Overview

This document describes the comprehensive test automation and analytics system implemented for the WRFCoin platform.

## Architecture

### Components

1. **Automated Regression Testing System**
   - CI/CD integration with GitHub Actions
   - Critical user flow regression tests (Playwright)
   - Service-level regression testing
   - Performance regression detection (K6)

2. **Test Analytics & Reporting**
   - Real-time test execution dashboards (Grafana)
   - Historical analytics and trends (PostgreSQL + Redis)
   - Business intelligence dashboards
   - Quality metrics and SLA monitoring

3. **Performance Testing Infrastructure**
   - K6 load testing suite
   - Artillery integration
   - Cross-browser performance monitoring
   - Resource utilization tracking

## Usage

### Running Regression Tests

```bash
# Run all regression tests
npm run test:regression

# Run specific test suite
npm run test:regression:wallet
npm run test:regression:weather
npm run test:regression:bridge

# Run with specific browser
npm run test:regression:wallet -- --browser=firefox

# Use helper script
bash scripts/run-regression-tests.sh local chromium wallet
```

### Running Performance Tests

```bash
# Run baseline performance tests
bash scripts/run-performance-tests.sh baseline local

# Run stress tests
bash scripts/run-performance-tests.sh stress staging

# Run K6 directly
k6 run test/performance/k6-regression-suite.js
```

### Processing Analytics

```bash
# Process test results from directory
bash scripts/process-test-analytics.sh process ./reports

# Generate daily summary
bash scripts/process-test-analytics.sh summary

# Generate trend analysis
bash scripts/process-test-analytics.sh trends
```

## Monitoring & Dashboards

### Grafana Dashboards

1. **Test Analytics Dashboard**: Real-time test execution monitoring
   - Test execution rates and status
   - Performance regression analysis  
   - Test coverage and quality metrics
   - Service health during testing

2. **Business Intelligence Dashboard**: Strategic quality insights
   - Platform health KPIs
   - SLA compliance tracking
   - Cost optimization opportunities
   - User experience metrics

### Accessing Dashboards

```bash
# Start monitoring stack
docker-compose -f docker-compose.monitoring.yml up -d

# Access Grafana
open http://localhost:3004
# Default login: admin/wrfcoin2024

# Access Prometheus
open http://localhost:9090
```

## Configuration

### Test Configuration

Edit `config/test-analytics/config.json` to customize:
- Database connection settings
- Performance thresholds
- Regression detection sensitivity
- Data retention policies

### Environment Configuration

Edit `test/regression/config.json` to configure:
- Test environments (local, staging, production)
- Browser configurations
- Timeout and retry settings
- Performance thresholds

## CI/CD Integration

The system automatically integrates with your CI/CD pipeline:

1. **GitHub Actions Workflow**: `.github/workflows/regression-testing.yml`
   - Triggered on PR and push events
   - Runs parallel regression test suites
   - Generates comprehensive reports
   - Posts results as PR comments

2. **Quality Gates**
   - Automated regression detection
   - Performance threshold enforcement
   - Test coverage requirements
   - SLA compliance checking

## Troubleshooting

### Common Issues

1. **Database Connection Errors**
   ```bash
   # Check if analytics database is running
   docker ps | grep wrfcoin-analytics-db
   
   # Restart database if needed
   docker restart wrfcoin-analytics-db
   ```

2. **Test Execution Failures**
   ```bash
   # Check Playwright browser installation
   npx playwright install --with-deps
   
   # Verify k6 installation
   k6 version
   ```

3. **Dashboard Loading Issues**
   ```bash
   # Restart monitoring stack
   docker-compose -f docker-compose.monitoring.yml restart
   
   # Check Grafana logs
   docker logs wrfcoin-grafana
   ```

### Logs

- Test execution logs: `logs/test-analytics.log`
- Cron job logs: `logs/cron.log`
- Error logs: `logs/test-analytics-error.log`

## Best Practices

1. **Regression Testing**
   - Run critical flow tests on every PR
   - Schedule comprehensive tests daily
   - Monitor flaky test rates
   - Update baselines regularly

2. **Performance Testing**  
   - Establish performance baselines
   - Monitor trends over time
   - Set appropriate thresholds
   - Test under realistic load

3. **Analytics**
   - Review quality metrics weekly
   - Act on regression alerts promptly
   - Use business intelligence for planning
   - Maintain data retention policies

## Maintenance

### Regular Tasks

1. **Weekly**
   - Review quality trends
   - Update performance baselines
   - Check for flaky tests
   - Analyze cost optimization opportunities

2. **Monthly**
   - Update test configurations
   - Review SLA compliance
   - Clean up old test data
   - Update dashboards as needed

### Data Cleanup

```bash
# Clean old test data (older than 90 days)
node scripts/analytics/cleanup-old-data.js

# Optimize database
node scripts/analytics/optimize-database.js
```
EOF
}

# Main execution
main() {
    echo -e "${BLUE}Starting WRFCoin Test Automation & Analytics Setup...${NC}"
    echo
    
    check_prerequisites
    create_directories
    install_dependencies
    install_k6
    install_playwright
    setup_database
    setup_redis
    setup_monitoring
    create_configs
    create_helper_scripts
    setup_cron_jobs
    create_documentation
    
    echo
    print_status "Setup completed successfully!"
    echo
    echo -e "${GREEN}Next Steps:${NC}"
    echo "1. Configure your environment variables in .env file"
    echo "2. Start the monitoring stack: docker-compose -f docker-compose.monitoring.yml up -d"
    echo "3. Access Grafana at http://localhost:3004 (admin/wrfcoin2024)"
    echo "4. Run your first regression test: bash scripts/run-regression-tests.sh local all"
    echo "5. Set up cron jobs for automation (see logs for crontab command)"
    echo
    echo -e "${BLUE}Documentation available at: docs/test-automation-analytics.md${NC}"
}

# Run main function
main "$@"