#!/bin/bash

# Task 64.6 - Mining Control Operations Test Commands
# 
# This script provides convenient commands for running all Task 64 tests

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if dependencies are installed
check_dependencies() {
    print_status "Checking dependencies..."
    
    if ! command -v node &> /dev/null; then
        print_error "Node.js is not installed"
        exit 1
    fi
    
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed"
        exit 1
    fi
    
    if [ ! -f "package.json" ]; then
        print_error "package.json not found. Run from project root."
        exit 1
    fi
    
    print_success "Dependencies check passed"
}

# Function to setup test environment
setup_test_env() {
    print_status "Setting up test environment..."
    
    # Install dependencies if needed
    if [ ! -d "node_modules" ]; then
        print_status "Installing dependencies..."
        npm install
    fi
    
    # Create test directories
    mkdir -p tests/reports
    mkdir -p tests/coverage/task64
    
    # Set environment variables
    export NODE_ENV=test
    export TEST_MODE=true
    export API_BASE_URL=http://localhost:4001
    export WS_BASE_URL=ws://localhost:4001
    
    print_success "Test environment setup complete"
}

# Function to run integration tests
run_integration_tests() {
    print_status "Running integration tests..."
    
    npx jest \
        --config=tests/jest.task64.config.js \
        --testPathPattern="integration/mining-control-operations.test.js" \
        --verbose \
        --coverage \
        --coverageDirectory=tests/coverage/task64/integration
    
    if [ $? -eq 0 ]; then
        print_success "Integration tests passed"
    else
        print_error "Integration tests failed"
        return 1
    fi
}

# Function to run frontend tests
run_frontend_tests() {
    print_status "Running frontend React component tests..."
    
    npx jest \
        --config=tests/jest.task64.config.js \
        --testPathPattern="frontend/mining-dashboard-components.test.jsx" \
        --verbose \
        --coverage \
        --coverageDirectory=tests/coverage/task64/frontend
    
    if [ $? -eq 0 ]; then
        print_success "Frontend tests passed"
    else
        print_error "Frontend tests failed"
        return 1
    fi
}

# Function to run performance tests
run_performance_tests() {
    print_status "Running performance and load tests..."
    
    npx jest \
        --config=tests/jest.task64.config.js \
        --testPathPattern="performance/mining-operations-performance.test.js" \
        --verbose \
        --testTimeout=60000 \
        --coverage \
        --coverageDirectory=tests/coverage/task64/performance
    
    if [ $? -eq 0 ]; then
        print_success "Performance tests passed"
    else
        print_error "Performance tests failed"
        return 1
    fi
}

# Function to run E2E tests
run_e2e_tests() {
    print_status "Running end-to-end tests..."
    
    # Check if Playwright is installed
    if ! command -v npx playwright &> /dev/null; then
        print_status "Installing Playwright..."
        npx playwright install
    fi
    
    npx playwright test \
        tests/e2e/mining-dashboard-e2e.test.js \
        --reporter=html \
        --output-dir=tests/coverage/task64/e2e
    
    if [ $? -eq 0 ]; then
        print_success "E2E tests passed"
    else
        print_error "E2E tests failed"
        return 1
    fi
}

# Function to run all tests
run_all_tests() {
    print_status "Running comprehensive Task 64.6 test suite..."
    
    local failed_tests=()
    
    # Run each test category
    if ! run_integration_tests; then
        failed_tests+=("integration")
    fi
    
    if ! run_frontend_tests; then
        failed_tests+=("frontend")
    fi
    
    if ! run_performance_tests; then
        failed_tests+=("performance")
    fi
    
    if ! run_e2e_tests; then
        failed_tests+=("e2e")
    fi
    
    # Report results
    if [ ${#failed_tests[@]} -eq 0 ]; then
        print_success "🎉 All Task 64.6 tests passed! Production ready!"
    else
        print_error "❌ Failed test categories: ${failed_tests[*]}"
        return 1
    fi
}

# Function to run comprehensive test runner
run_comprehensive_suite() {
    print_status "Running comprehensive test runner..."
    
    node tests/task-64-comprehensive-test-runner.js
    
    if [ $? -eq 0 ]; then
        print_success "Comprehensive test suite completed successfully"
    else
        print_error "Comprehensive test suite failed"
        return 1
    fi
}

# Function to generate test reports
generate_reports() {
    print_status "Generating test reports..."
    
    # Combine coverage reports
    if [ -d "tests/coverage/task64" ]; then
        print_status "Merging coverage reports..."
        npx nyc merge tests/coverage/task64/*/coverage-final.json tests/coverage/task64/merged-coverage.json
        npx nyc report --reporter=html --reporter=text --temp-dir=tests/coverage/task64 --report-dir=tests/coverage/task64/final
    fi
    
    # Generate comprehensive HTML report
    if [ -f "tests/reports/task-64-test-results.html" ]; then
        print_success "HTML report available at: tests/reports/task-64-test-results.html"
    fi
    
    # Generate badges
    if command -v npx coverage-badges-cli &> /dev/null; then
        npx coverage-badges-cli --output tests/coverage/task64/badges
    fi
    
    print_success "Test reports generated"
}

# Function to clean test artifacts
clean_test_artifacts() {
    print_status "Cleaning test artifacts..."
    
    rm -rf tests/coverage/task64
    rm -rf tests/reports/task-64-*
    rm -rf playwright-report
    rm -rf test-results
    
    print_success "Test artifacts cleaned"
}

# Function to show test status
show_test_status() {
    print_status "Task 64.6 Test Status:"
    echo ""
    echo "Available test commands:"
    echo "  integration  - Run integration tests"
    echo "  frontend     - Run React component tests"
    echo "  performance  - Run performance and load tests"
    echo "  e2e          - Run end-to-end tests"
    echo "  all          - Run all test categories"
    echo "  comprehensive - Run comprehensive test runner with reports"
    echo "  reports      - Generate test reports"
    echo "  clean        - Clean test artifacts"
    echo ""
    echo "Test files:"
    echo "  ✓ tests/integration/mining-control-operations.test.js"
    echo "  ✓ tests/frontend/mining-dashboard-components.test.jsx"
    echo "  ✓ tests/performance/mining-operations-performance.test.js"
    echo "  ✓ tests/e2e/mining-dashboard-e2e.test.js"
    echo "  ✓ tests/task-64-comprehensive-test-runner.js"
}

# Main execution logic
main() {
    check_dependencies
    setup_test_env
    
    case "${1:-status}" in
        "integration")
            run_integration_tests
            ;;
        "frontend")
            run_frontend_tests
            ;;
        "performance")
            run_performance_tests
            ;;
        "e2e")
            run_e2e_tests
            ;;
        "all")
            run_all_tests
            ;;
        "comprehensive")
            run_comprehensive_suite
            ;;
        "reports")
            generate_reports
            ;;
        "clean")
            clean_test_artifacts
            ;;
        "status"|"help"|*)
            show_test_status
            ;;
    esac
}

# Execute main function with all arguments
main "$@"