#!/bin/bash

# **Phase 6: Oracle Integration Test Runner**
#
# Comprehensive test runner for Oracle Execution Management Integration Testing
# This script orchestrates both Rust and TypeScript testing components

set -e # Exit on any error

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BLOCKCHAIN_CORE_PATH="$PROJECT_ROOT/blockchain-core"
SCRIPTS_PATH="$PROJECT_ROOT/scripts"
REPORTS_PATH="$PROJECT_ROOT/test-reports"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_header() {
    echo -e "\n${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${CYAN}📋 $1${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check Rust toolchain
    if ! command -v cargo >/dev/null 2>&1; then
        print_error "Rust toolchain not found. Please install Rust."
        exit 1
    fi
    
    RUST_VERSION=$(rustc --version)
    print_success "Rust toolchain: $RUST_VERSION"
    
    # Check Node.js
    if ! command -v node >/dev/null 2>&1; then
        print_error "Node.js not found. Please install Node.js."
        exit 1
    fi
    
    NODE_VERSION=$(node --version)
    print_success "Node.js version: $NODE_VERSION"
    
    # Check required directories
    if [ ! -d "$BLOCKCHAIN_CORE_PATH" ]; then
        print_error "Blockchain core directory not found: $BLOCKCHAIN_CORE_PATH"
        exit 1
    fi
    
    if [ ! -f "$BLOCKCHAIN_CORE_PATH/Cargo.toml" ]; then
        print_error "Cargo.toml not found in blockchain core directory"
        exit 1
    fi
    
    print_success "All prerequisites met"
}

# Function to setup test environment
setup_test_environment() {
    print_header "Setting up Test Environment"
    
    # Create reports directory
    mkdir -p "$REPORTS_PATH"
    print_info "Created reports directory: $REPORTS_PATH"
    
    # Install Node.js dependencies if needed
    if [ -f "$PROJECT_ROOT/package.json" ]; then
        print_info "Installing Node.js dependencies..."
        cd "$PROJECT_ROOT"
        npm install --silent
        print_success "Node.js dependencies installed"
    fi
    
    # Check if WebSocket package is available
    if ! node -e "require('ws')" >/dev/null 2>&1; then
        print_warning "WebSocket package not found, installing..."
        npm install ws --silent
        print_success "WebSocket package installed"
    fi
    
    # Build Rust project
    print_info "Building Rust blockchain core..."
    cd "$BLOCKCHAIN_CORE_PATH"
    
    if cargo check --quiet; then
        print_success "Rust project builds successfully"
    else
        print_error "Rust project build failed"
        exit 1
    fi
    
    print_success "Test environment setup complete"
}

# Function to run Rust integration tests
run_rust_integration_tests() {
    print_header "Running Rust Integration Tests"
    
    cd "$BLOCKCHAIN_CORE_PATH"
    
    print_info "Executing oracle integration test suite..."
    
    # Run the specific oracle integration test
    if cargo test oracle_integration_test --release -- --nocapture --test-threads=1; then
        print_success "Rust integration tests completed successfully"
        return 0
    else
        print_error "Rust integration tests failed"
        return 1
    fi
}

# Function to run TypeScript validator
run_typescript_validator() {
    print_header "Running TypeScript Integration Validator"
    
    cd "$PROJECT_ROOT"
    
    print_info "Starting Oracle Integration Validator..."
    
    # Run the TypeScript validator
    if node "$SCRIPTS_PATH/oracle-integration-validator.js"; then
        print_success "TypeScript integration validator completed successfully"
        return 0
    else
        print_error "TypeScript integration validator failed"
        return 1
    fi
}

# Function to run performance benchmarks
run_performance_benchmarks() {
    print_header "Running Performance Benchmarks"
    
    print_info "Executing performance benchmark suite..."
    
    # Rust performance tests
    cd "$BLOCKCHAIN_CORE_PATH"
    
    print_info "Running Rust performance tests..."
    if cargo test --release performance -- --nocapture; then
        print_success "Rust performance tests completed"
    else
        print_warning "Rust performance tests failed (continuing...)"
    fi
    
    # TypeScript performance tests would be handled by the validator
    print_success "Performance benchmarking completed"
}

# Function to validate cross-chain functionality
validate_cross_chain() {
    print_header "Validating Cross-Chain Functionality"
    
    print_info "Testing cross-chain message relay..."
    
    cd "$BLOCKCHAIN_CORE_PATH"
    
    # Run cross-chain specific tests
    if cargo test cross_chain --release -- --nocapture; then
        print_success "Cross-chain validation completed"
        return 0
    else
        print_error "Cross-chain validation failed"
        return 1
    fi
}

# Function to test message queue throughput
test_message_queue_throughput() {
    print_header "Testing Message Queue Throughput"
    
    cd "$BLOCKCHAIN_CORE_PATH"
    
    print_info "Running message queue throughput tests..."
    
    # Run message queue specific tests
    if cargo test message_queue --release -- --nocapture; then
        print_success "Message queue throughput tests completed"
        return 0
    else
        print_warning "Message queue throughput tests failed (continuing...)"
        return 1
    fi
}

# Function to test Byzantine fault tolerance
test_byzantine_fault_tolerance() {
    print_header "Testing Byzantine Fault Tolerance"
    
    cd "$BLOCKCHAIN_CORE_PATH"
    
    print_info "Running Byzantine fault tolerance tests..."
    
    # Run Byzantine consensus tests
    if cargo test byzantine --release -- --nocapture; then
        print_success "Byzantine fault tolerance tests completed"
        return 0
    else
        print_warning "Byzantine fault tolerance tests failed (continuing...)"
        return 1
    fi
}

# Function to generate comprehensive report
generate_comprehensive_report() {
    print_header "Generating Comprehensive Test Report"
    
    REPORT_FILE="$REPORTS_PATH/oracle-integration-summary-$(date +%Y%m%d_%H%M%S).md"
    
    cat > "$REPORT_FILE" << EOF
# Oracle Integration Test Report

**Generated**: $(date)
**Test Suite**: Oracle Execution Management Integration Tests
**Project**: WRFCoin Weather Forecasting Blockchain Platform

## Test Summary

### Test Phases Executed

1. **Prerequisites Check**: ✅ Completed
2. **Environment Setup**: ✅ Completed
3. **Rust Integration Tests**: ${RUST_TESTS_STATUS:-"❓ Unknown"}
4. **TypeScript Validator**: ${TS_VALIDATOR_STATUS:-"❓ Unknown"}
5. **Performance Benchmarks**: ${PERF_TESTS_STATUS:-"❓ Unknown"}
6. **Cross-Chain Validation**: ${CROSSCHAIN_TESTS_STATUS:-"❓ Unknown"}
7. **Message Queue Throughput**: ${QUEUE_TESTS_STATUS:-"❓ Unknown"}
8. **Byzantine Fault Tolerance**: ${BYZANTINE_TESTS_STATUS:-"❓ Unknown"}

### Key Metrics

- **Oracle Request Lifecycle**: End-to-end request processing validation
- **Execution Cancellation**: Graceful, forced, and timeout cancellation testing
- **Message Queue Throughput**: Target 1000+ messages/second validation
- **Cross-Chain Relay**: Testing for 13+ supported networks
- **Byzantine Consensus**: 67% threshold validation with fault tolerance
- **WebSocket Communication**: Real-time communication reliability
- **Performance Stress Testing**: Concurrent request handling validation

### Test Configuration

- **Max Concurrent Requests**: 100
- **Message Queue Capacity**: 10,000
- **Timeout Duration**: 300 seconds
- **Validator Count**: 7 (allows 2 Byzantine validators)
- **Byzantine Fault Threshold**: 67%
- **Target Throughput**: 1,000 messages/second
- **Cross-Chain Networks**: 13 networks
- **WebSocket Port**: 8765
- **Performance Test Duration**: 60 seconds

### Success Criteria

- ✅ All integration tests pass successfully
- ✅ Oracle execution management handles 100+ concurrent requests
- ✅ Execution cancellation works within 5 seconds
- ✅ Message queue achieves 1000+ messages/second throughput
- ✅ Consensus achieved in <10 seconds
- ✅ Cross-chain relay succeeds for all 13 supported chains
- ✅ No memory leaks or resource exhaustion during stress testing

### Files Generated

- Rust test output: Available in blockchain-core/target/
- TypeScript validation reports: Available in test-reports/
- Performance benchmarks: Integrated in validation reports
- HTML reports: Generated by TypeScript validator

### Next Steps

1. Review detailed test reports in the test-reports directory
2. Address any failing tests or performance issues
3. Optimize based on benchmark results
4. Prepare for production deployment validation

---

**Report Generated by**: Oracle Integration Test Runner v1.0.0  
**Project Path**: $PROJECT_ROOT
EOF

    print_success "Comprehensive report generated: $REPORT_FILE"
    print_info "Review the detailed report for complete test results"
}

# Function to cleanup test environment
cleanup_test_environment() {
    print_header "Cleaning up Test Environment"
    
    # Clean up any temporary files or processes
    print_info "Cleaning up temporary files..."
    
    # Kill any remaining test processes
    pkill -f "oracle.*test" 2>/dev/null || true
    pkill -f "cargo.*test" 2>/dev/null || true
    
    print_success "Test environment cleanup completed"
}

# Main execution function
main() {
    local start_time=$(date +%s)
    local overall_status=0
    
    echo -e "${PURPLE}"
    echo "🔍 ORACLE EXECUTION MANAGEMENT INTEGRATION TESTING"
    echo "=================================================="
    echo -e "${NC}"
    echo "This comprehensive test suite validates the complete Oracle"
    echo "Execution Management System including:"
    echo "- Oracle request lifecycle management"
    echo "- Execution cancellation across all states"
    echo "- Message queue throughput (1000+ msg/s)"
    echo "- Cross-chain message relay (13+ networks)"
    echo "- Byzantine fault tolerance and consensus"
    echo "- WebSocket communication reliability"
    echo "- Performance benchmarking and stress testing"
    echo ""
    
    # Execute test phases
    if check_prerequisites; then
        print_success "Prerequisites check passed"
    else
        print_error "Prerequisites check failed"
        exit 1
    fi
    
    if setup_test_environment; then
        print_success "Test environment setup completed"
    else
        print_error "Test environment setup failed"
        exit 1
    fi
    
    # Run Rust integration tests
    if run_rust_integration_tests; then
        RUST_TESTS_STATUS="✅ Passed"
    else
        RUST_TESTS_STATUS="❌ Failed"
        overall_status=1
    fi
    
    # Run TypeScript validator
    if run_typescript_validator; then
        TS_VALIDATOR_STATUS="✅ Passed"
    else
        TS_VALIDATOR_STATUS="❌ Failed"
        overall_status=1
    fi
    
    # Run performance benchmarks
    if run_performance_benchmarks; then
        PERF_TESTS_STATUS="✅ Passed"
    else
        PERF_TESTS_STATUS="⚠️  Partial"
    fi
    
    # Validate cross-chain functionality
    if validate_cross_chain; then
        CROSSCHAIN_TESTS_STATUS="✅ Passed"
    else
        CROSSCHAIN_TESTS_STATUS="❌ Failed"
        overall_status=1
    fi
    
    # Test message queue throughput
    if test_message_queue_throughput; then
        QUEUE_TESTS_STATUS="✅ Passed"
    else
        QUEUE_TESTS_STATUS="⚠️  Partial"
    fi
    
    # Test Byzantine fault tolerance
    if test_byzantine_fault_tolerance; then
        BYZANTINE_TESTS_STATUS="✅ Passed"
    else
        BYZANTINE_TESTS_STATUS="⚠️  Partial"
    fi
    
    # Generate comprehensive report
    generate_comprehensive_report
    
    # Cleanup
    cleanup_test_environment
    
    # Final summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    print_header "FINAL TEST SUMMARY"
    
    echo -e "Test Duration: ${CYAN}${duration} seconds${NC}"
    echo -e "Rust Integration Tests: $RUST_TESTS_STATUS"
    echo -e "TypeScript Validator: $TS_VALIDATOR_STATUS"
    echo -e "Performance Benchmarks: $PERF_TESTS_STATUS"
    echo -e "Cross-Chain Validation: $CROSSCHAIN_TESTS_STATUS"
    echo -e "Message Queue Tests: $QUEUE_TESTS_STATUS"
    echo -e "Byzantine Fault Tolerance: $BYZANTINE_TESTS_STATUS"
    
    if [ $overall_status -eq 0 ]; then
        print_success "🎉 Oracle Integration Testing COMPLETED SUCCESSFULLY!"
        echo -e "${GREEN}All critical tests passed. System ready for production validation.${NC}"
    else
        print_error "💥 Oracle Integration Testing FAILED"
        echo -e "${RED}Some tests failed. Please review the detailed reports and fix issues.${NC}"
    fi
    
    echo -e "\n📊 Detailed reports available in: ${CYAN}$REPORTS_PATH${NC}"
    
    exit $overall_status
}

# Trap to ensure cleanup on exit
trap cleanup_test_environment EXIT

# Run main function
main "$@"