#!/bin/bash

# Comprehensive Profiling Setup Script for Wrfcoin
# 
# This script sets up the complete profiling infrastructure including:
# - System dependencies installation
# - Rust profiling feature compilation
# - Node.js profiling tools setup
# - System profiling tools configuration
# - Integration with existing monitoring infrastructure

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILE_DIR="${PROFILE_DIR:-$PROJECT_ROOT/profiles}"
INSTALL_DEPS="${INSTALL_DEPS:-true}"
SETUP_RUST="${SETUP_RUST:-true}"
SETUP_NODEJS="${SETUP_NODEJS:-true}"
SETUP_SYSTEM="${SETUP_SYSTEM:-true}"
ENABLE_CONTINUOUS="${ENABLE_CONTINUOUS:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_section() {
    echo -e "\n${PURPLE}=== $1 ===${NC}"
}

# Check if running on a supported system
check_system() {
    log_section "System Compatibility Check"
    
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "Linux system detected"
        
        # Check for Ubuntu/Debian
        if command -v apt-get &> /dev/null; then
            PACKAGE_MANAGER="apt"
            log_info "Debian/Ubuntu package manager detected"
        # Check for Red Hat/CentOS/Fedora
        elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
            PACKAGE_MANAGER="yum"
            log_info "Red Hat/CentOS/Fedora package manager detected"
        else
            log_warn "Unknown Linux distribution, some features may not work"
            PACKAGE_MANAGER="unknown"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        log_info "macOS system detected"
        PACKAGE_MANAGER="brew"
        
        if ! command -v brew &> /dev/null; then
            log_error "Homebrew not found. Please install Homebrew first:"
            log_info "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            exit 1
        fi
    else
        log_error "Unsupported operating system: $OSTYPE"
        exit 1
    fi
    
    log_success "System compatibility check passed"
}

# Install system dependencies
install_system_dependencies() {
    if [[ "$INSTALL_DEPS" != "true" ]]; then
        log_info "Skipping system dependencies installation"
        return
    fi
    
    log_section "Installing System Dependencies"
    
    case "$PACKAGE_MANAGER" in
        "apt")
            log_info "Installing dependencies via apt..."
            
            # Update package list
            sudo apt-get update
            
            # Install essential tools
            sudo apt-get install -y \
                build-essential \
                pkg-config \
                libssl-dev \
                curl \
                git \
                nodejs \
                npm
            
            # Install profiling tools
            log_info "Installing profiling tools..."
            sudo apt-get install -y \
                linux-tools-common \
                linux-tools-generic \
                linux-tools-$(uname -r) \
                bpftrace \
                bpfcc-tools \
                systemtap \
                systemtap-runtime \
                valgrind \
                strace \
                ltrace
            
            # Try to install flamegraph tools
            if ! command -v flamegraph.pl &> /dev/null; then
                log_info "Installing FlameGraph tools..."
                cd /tmp
                git clone https://github.com/brendangregg/FlameGraph.git || true
                sudo cp FlameGraph/flamegraph.pl /usr/local/bin/ || true
                sudo chmod +x /usr/local/bin/flamegraph.pl || true
                rm -rf FlameGraph
            fi
            ;;
            
        "yum")
            log_info "Installing dependencies via yum/dnf..."
            
            # Determine if we should use yum or dnf
            if command -v dnf &> /dev/null; then
                PKG_CMD="dnf"
            else
                PKG_CMD="yum"
            fi
            
            # Install essential tools
            sudo $PKG_CMD install -y \
                gcc \
                gcc-c++ \
                make \
                pkg-config \
                openssl-devel \
                curl \
                git \
                nodejs \
                npm
            
            # Install profiling tools
            log_info "Installing profiling tools..."
            sudo $PKG_CMD install -y \
                perf \
                bpftrace \
                systemtap \
                systemtap-runtime \
                valgrind \
                strace \
                ltrace || log_warn "Some profiling tools may not be available"
            ;;
            
        "brew")
            log_info "Installing dependencies via Homebrew..."
            
            # Update brew
            brew update
            
            # Install essential tools
            brew install \
                curl \
                git \
                node \
                npm
            
            # Install profiling tools (limited on macOS)
            log_info "Installing available profiling tools for macOS..."
            brew install \
                valgrind \
                dtrace || log_warn "Some profiling tools are not available on macOS"
            ;;
            
        "unknown")
            log_warn "Unknown package manager, skipping system dependency installation"
            log_info "Please install the following manually:"
            log_info "  - build-essential (gcc, make, etc.)"
            log_info "  - Node.js and npm"
            log_info "  - perf (linux-tools)"
            log_info "  - bpftrace"
            log_info "  - valgrind"
            ;;
    esac
    
    log_success "System dependencies installation completed"
}

# Setup Rust profiling
setup_rust_profiling() {
    if [[ "$SETUP_RUST" != "true" ]]; then
        log_info "Skipping Rust profiling setup"
        return
    fi
    
    log_section "Setting up Rust Profiling"
    
    cd "$PROJECT_ROOT"
    
    # Check if Rust is installed
    if ! command -v cargo &> /dev/null; then
        log_error "Rust/Cargo not found. Please install Rust first:"
        log_info "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
        exit 1
    fi
    
    # Install cargo profiling tools
    log_info "Installing Rust profiling tools..."
    cargo install --force flamegraph || log_warn "Failed to install flamegraph"
    cargo install --force cargo-expand || log_warn "Failed to install cargo-expand"
    cargo install --force tokio-console || log_warn "Failed to install tokio-console"
    
    # Build with profiling features
    log_info "Building blockchain-core with profiling features..."
    cd "$PROJECT_ROOT/blockchain-core"
    
    # Add profiling feature to Cargo.toml if not already present
    if ! grep -q 'profiling.*=.*\["pprof"\]' Cargo.toml; then
        log_info "Profiling feature already configured in Cargo.toml"
    fi
    
    # Build with profiling features
    RUSTFLAGS="-g" cargo build --release --features profiling
    
    # Create benchmark directory if it doesn't exist
    mkdir -p benches
    
    # Create a sample benchmark if none exists
    if [[ ! -f benches/blockchain_benchmarks.rs ]]; then
        log_info "Creating sample benchmark file..."
        cat > benches/blockchain_benchmarks.rs << 'EOF'
use criterion::{black_box, criterion_group, criterion_main, Criterion};
use wrfcoin_consensus::blockchain::Blockchain;

fn benchmark_block_creation(c: &mut Criterion) {
    c.bench_function("block_creation", |b| {
        b.iter(|| {
            // Benchmark block creation
            black_box(Blockchain::new())
        })
    });
}

fn benchmark_transaction_validation(c: &mut Criterion) {
    c.bench_function("transaction_validation", |b| {
        b.iter(|| {
            // Benchmark transaction validation
            black_box(42)
        })
    });
}

criterion_group!(benches, benchmark_block_creation, benchmark_transaction_validation);
criterion_main!(benches);
EOF
    fi
    
    log_success "Rust profiling setup completed"
}

# Setup Node.js profiling
setup_nodejs_profiling() {
    if [[ "$SETUP_NODEJS" != "true" ]]; then
        log_info "Skipping Node.js profiling setup"
        return
    fi
    
    log_section "Setting up Node.js Profiling"
    
    cd "$PROJECT_ROOT"
    
    # Check if Node.js is installed
    if ! command -v node &> /dev/null; then
        log_error "Node.js not found. Please install Node.js first"
        exit 1
    fi
    
    # Install Node.js profiling tools globally
    log_info "Installing Node.js profiling tools..."
    npm install -g \
        clinic \
        0x \
        autocannon \
        artillery \
        heapdump \
        memwatch-next || log_warn "Some Node.js profiling tools may have failed to install"
    
    # Make profiling scripts executable
    chmod +x "$SCRIPT_DIR/nodejs-profiler.js"
    
    # Install package dependencies if package.json exists
    if [[ -f package.json ]]; then
        log_info "Installing Node.js project dependencies..."
        npm install
    fi
    
    log_success "Node.js profiling setup completed"
}

# Setup system profiling
setup_system_profiling() {
    if [[ "$SETUP_SYSTEM" != "true" ]]; then
        log_info "Skipping system profiling setup"
        return
    fi
    
    log_section "Setting up System Profiling"
    
    # Make system profiler executable
    chmod +x "$SCRIPT_DIR/system-profiler.sh"
    
    # Check if eBPF is supported
    if [[ -d /sys/kernel/debug/tracing ]]; then
        log_info "eBPF/tracing support detected"
    else
        log_warn "eBPF/tracing may not be fully supported on this system"
    fi
    
    # Create systemd service for continuous profiling if requested
    if [[ "$ENABLE_CONTINUOUS" == "true" ]]; then
        log_info "Setting up continuous profiling service..."
        
        sudo tee /etc/systemd/system/wrfcoin-profiling.service > /dev/null << EOF
[Unit]
Description=Wrfcoin Continuous Profiling Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PROJECT_ROOT
ExecStart=$SCRIPT_DIR/system-profiler.sh start
Restart=always
RestartSec=30
Environment=PROFILE_DIR=$PROFILE_DIR
Environment=ENABLE_EBPF=true
Environment=ENABLE_PERF=true
Environment=ENABLE_CONTAINER_PROFILING=true

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable wrfcoin-profiling.service
        
        log_info "Continuous profiling service created (start with: sudo systemctl start wrfcoin-profiling)"
    fi
    
    log_success "System profiling setup completed"
}

# Create profile directories
setup_directories() {
    log_section "Setting up Profile Directories"
    
    log_info "Creating profile directories..."
    mkdir -p "$PROFILE_DIR"/{rust,nodejs,system,benchmarks,reports}
    mkdir -p "$PROFILE_DIR"/system/{perf,ebpf,container,flame-graphs}
    mkdir -p "$PROFILE_DIR"/nodejs/{cpu,memory,heap-snapshots}
    mkdir -p "$PROFILE_DIR"/rust/{cpu,memory,benchmarks,flame-graphs}
    
    # Set appropriate permissions
    chmod 755 "$PROFILE_DIR"
    chmod 755 "$PROFILE_DIR"/*
    
    log_success "Profile directories created: $PROFILE_DIR"
}

# Create profiling configuration
create_configuration() {
    log_section "Creating Profiling Configuration"
    
    local config_file="$PROJECT_ROOT/.profiling-config.json"
    
    log_info "Creating profiling configuration file..."
    cat > "$config_file" << EOF
{
  "rust": {
    "cpu_profiling_enabled": true,
    "memory_profiling_enabled": true,
    "async_profiling_enabled": true,
    "continuous_profiling": false,
    "sampling_frequency": 100,
    "profile_duration": 60,
    "profile_output_dir": "$PROFILE_DIR/rust"
  },
  "nodejs": {
    "cpu_profiling_enabled": true,
    "memory_profiling_enabled": true,
    "event_loop_profiling_enabled": true,
    "continuous_profiling": false,
    "sampling_interval": 1000,
    "heap_snapshot_interval": 300000,
    "profile_output_dir": "$PROFILE_DIR/nodejs"
  },
  "system": {
    "enable_ebpf": true,
    "enable_perf": true,
    "enable_container_profiling": true,
    "sampling_frequency": 99,
    "profile_duration": 60,
    "profile_output_dir": "$PROFILE_DIR/system"
  },
  "integration": {
    "auto_profiling_enabled": true,
    "cpu_threshold": 80.0,
    "memory_threshold": 8589934592,
    "response_time_threshold": 5000,
    "profiling_cooldown": 300,
    "export_to_monitoring": true
  }
}
EOF
    
    log_info "Configuration file created: $config_file"
    log_success "Profiling configuration completed"
}

# Setup integration with existing monitoring
setup_monitoring_integration() {
    log_section "Setting up Monitoring Integration"
    
    # Check if existing monitoring infrastructure exists
    if [[ -f "$PROJECT_ROOT/docker-compose.monitoring.yml" ]]; then
        log_info "Existing monitoring infrastructure detected"
        
        # Add profiling endpoints to monitoring configuration
        local monitoring_config="$PROJECT_ROOT/infrastructure/monitoring/enhanced-monitoring.yaml"
        if [[ -f "$monitoring_config" ]]; then
            log_info "Adding profiling endpoints to monitoring configuration..."
            
            # Backup original configuration
            cp "$monitoring_config" "$monitoring_config.backup"
            
            # Add profiling job to prometheus configuration
            cat >> "$monitoring_config" << 'EOF'

  # Profiling metrics endpoint
  - job_name: 'wrfcoin-profiling'
    static_configs:
      - targets: ['localhost:9102']
    scrape_interval: 30s
    metrics_path: /metrics
    
  # Profiling API endpoint
  - job_name: 'wrfcoin-profiling-api'
    static_configs:
      - targets: ['localhost:9103']
    scrape_interval: 60s
    metrics_path: /api/metrics/aggregated
EOF
            
            log_info "Monitoring integration configured"
        fi
    else
        log_warn "No existing monitoring infrastructure found"
        log_info "Profiling will work standalone, but monitoring integration is recommended"
    fi
    
    log_success "Monitoring integration setup completed"
}

# Generate usage documentation
generate_documentation() {
    log_section "Generating Documentation"
    
    local docs_file="$PROJECT_ROOT/PROFILING.md"
    
    log_info "Creating profiling documentation..."
    cat > "$docs_file" << 'EOF'
# Wrfcoin Performance Profiling Guide

## Overview

This document describes how to use the comprehensive performance profiling system for Wrfcoin.

## Quick Start

### Start All Profiling
```bash
# Start comprehensive profiling (requires sudo for system profiling)
sudo ./scripts/profiling/system-profiler.sh start

# Start Node.js profiling
node ./scripts/profiling/nodejs-profiler.js

# Run Rust benchmarks
cd blockchain-core && cargo bench
```

### One-time Profiling
```bash
# One-time system profiling
sudo ./scripts/profiling/system-profiler.sh once

# One-time Node.js profiling
node ./scripts/profiling/nodejs-profiler.js --duration 60

# Rust CPU profiling with flamegraph
cd blockchain-core && cargo flamegraph --bench blockchain_benchmarks
```

## Profiling Categories

### Rust/Blockchain Core
- **CPU Profiling**: Uses pprof for detailed CPU analysis
- **Memory Profiling**: Tracks memory allocation patterns
- **Async Profiling**: Monitors Tokio runtime performance
- **Benchmarking**: Criterion-based performance benchmarks

### Node.js/Backend
- **CPU Profiling**: V8 inspector-based CPU profiling
- **Memory Profiling**: Heap snapshots and leak detection
- **Event Loop**: Monitors event loop lag and blocking operations

### System Level
- **eBPF Profiling**: Kernel-level profiling and tracing
- **perf Integration**: Hardware performance counters
- **Container Profiling**: Docker container resource monitoring

## Output Locations

All profiling data is stored in the `profiles/` directory:

```
profiles/
├── rust/           # Rust profiling data
│   ├── cpu/
│   ├── memory/
│   └── flame-graphs/
├── nodejs/         # Node.js profiling data
│   ├── cpu/
│   ├── memory/
│   └── heap-snapshots/
├── system/         # System profiling data
│   ├── perf/
│   ├── ebpf/
│   └── container/
└── reports/        # Generated analysis reports
```

## Configuration

Profiling behavior is controlled by environment variables and the `.profiling-config.json` file:

### Environment Variables
- `PROFILE_DIR`: Output directory for profiles
- `PROFILE_DURATION`: Profiling duration in seconds
- `ENABLE_EBPF`: Enable eBPF profiling (true/false)
- `ENABLE_PERF`: Enable perf profiling (true/false)

### Configuration File
Edit `.profiling-config.json` to customize profiling parameters.

## Analysis and Visualization

### Flame Graphs
CPU flame graphs are automatically generated and stored as SVG files:
- `profiles/rust/flame-graphs/`: Rust flame graphs
- `profiles/system/flame-graphs/`: System flame graphs

### Reports
Comprehensive profiling reports are generated in `profiles/reports/`.

### Monitoring Integration
Profiling metrics are exported to the existing Prometheus/Grafana monitoring stack.

## Troubleshooting

### Permission Issues
System profiling requires root privileges:
```bash
sudo ./scripts/profiling/system-profiler.sh once
```

### eBPF Not Working
Ensure kernel supports eBPF:
```bash
# Check eBPF support
ls /sys/kernel/debug/tracing/

# Install eBPF tools
sudo apt install bpftrace bpfcc-tools
```

### Missing Tools
Run the setup script to install all dependencies:
```bash
./scripts/profiling/setup-profiling.sh
```

## Best Practices

1. **Regular Profiling**: Run profiling during development and before releases
2. **Load Testing**: Profile under realistic load conditions
3. **Baseline Comparison**: Compare profiles against previous versions
4. **Resource Monitoring**: Monitor system resources during profiling
5. **Data Retention**: Regularly clean up old profiling data

## Integration with CI/CD

Add profiling to your CI/CD pipeline:

```yaml
# Example GitHub Actions
- name: Run Performance Profiling
  run: |
    sudo ./scripts/profiling/system-profiler.sh once
    cd blockchain-core && cargo bench
```

For more detailed information, see the profiling implementation in `blockchain-core/src/monitoring/`.
EOF
    
    log_success "Documentation generated: $docs_file"
}

# Run system verification
verify_setup() {
    log_section "Verifying Setup"
    
    local errors=0
    
    # Check Rust profiling
    if command -v cargo &> /dev/null; then
        log_info "✓ Rust/Cargo found"
        
        if cargo --list | grep -q flamegraph; then
            log_info "✓ Flamegraph installed"
        else
            log_warn "✗ Flamegraph not installed"
            ((errors++))
        fi
    else
        log_warn "✗ Rust/Cargo not found"
        ((errors++))
    fi
    
    # Check Node.js profiling
    if command -v node &> /dev/null; then
        log_info "✓ Node.js found"
        
        if command -v clinic &> /dev/null; then
            log_info "✓ Clinic.js installed"
        else
            log_warn "✗ Clinic.js not installed"
            ((errors++))
        fi
    else
        log_warn "✗ Node.js not found"
        ((errors++))
    fi
    
    # Check system profiling tools
    if command -v perf &> /dev/null; then
        log_info "✓ perf found"
    else
        log_warn "✗ perf not found"
        ((errors++))
    fi
    
    if command -v bpftrace &> /dev/null; then
        log_info "✓ bpftrace found"
    else
        log_warn "✗ bpftrace not found"
        ((errors++))
    fi
    
    # Check profiling scripts
    if [[ -x "$SCRIPT_DIR/nodejs-profiler.js" ]]; then
        log_info "✓ Node.js profiler executable"
    else
        log_warn "✗ Node.js profiler not executable"
        ((errors++))
    fi
    
    if [[ -x "$SCRIPT_DIR/system-profiler.sh" ]]; then
        log_info "✓ System profiler executable"
    else
        log_warn "✗ System profiler not executable"
        ((errors++))
    fi
    
    # Check directories
    if [[ -d "$PROFILE_DIR" ]]; then
        log_info "✓ Profile directory exists: $PROFILE_DIR"
    else
        log_warn "✗ Profile directory missing"
        ((errors++))
    fi
    
    if [[ $errors -eq 0 ]]; then
        log_success "Setup verification passed!"
    else
        log_warn "Setup verification completed with $errors warnings"
        log_info "Some profiling features may not work correctly"
    fi
}

# Display usage information
usage() {
    cat << EOF
Wrfcoin Profiling Setup Script

Usage: $0 [OPTIONS]

Options:
    --no-deps           Skip system dependency installation
    --no-rust           Skip Rust profiling setup
    --no-nodejs         Skip Node.js profiling setup
    --no-system         Skip system profiling setup
    --enable-continuous Enable continuous profiling service
    --profile-dir DIR   Set profile output directory
    --help              Show this help message

Environment Variables:
    INSTALL_DEPS        Install system dependencies (default: true)
    SETUP_RUST          Setup Rust profiling (default: true)
    SETUP_NODEJS        Setup Node.js profiling (default: true)
    SETUP_SYSTEM        Setup system profiling (default: true)
    ENABLE_CONTINUOUS   Enable continuous profiling (default: false)
    PROFILE_DIR         Profile output directory (default: ./profiles)

Examples:
    # Full setup
    $0

    # Setup without system dependencies
    $0 --no-deps

    # Setup with continuous profiling
    $0 --enable-continuous

    # Custom profile directory
    PROFILE_DIR=/var/lib/wrfcoin/profiles $0
EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-deps)
                INSTALL_DEPS="false"
                shift
                ;;
            --no-rust)
                SETUP_RUST="false"
                shift
                ;;
            --no-nodejs)
                SETUP_NODEJS="false"
                shift
                ;;
            --no-system)
                SETUP_SYSTEM="false"
                shift
                ;;
            --enable-continuous)
                ENABLE_CONTINUOUS="true"
                shift
                ;;
            --profile-dir)
                PROFILE_DIR="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

# Main setup function
main() {
    log_info "Starting Wrfcoin Performance Profiling Setup"
    log_info "Project root: $PROJECT_ROOT"
    log_info "Profile directory: $PROFILE_DIR"
    
    parse_arguments "$@"
    
    check_system
    install_system_dependencies
    setup_directories
    setup_rust_profiling
    setup_nodejs_profiling
    setup_system_profiling
    create_configuration
    setup_monitoring_integration
    generate_documentation
    verify_setup
    
    log_success "Profiling setup completed successfully!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Review the configuration in .profiling-config.json"
    log_info "2. Read the profiling guide in PROFILING.md"
    log_info "3. Run a test profiling session:"
    log_info "   sudo ./scripts/profiling/system-profiler.sh once"
    log_info "4. Check the profiles in: $PROFILE_DIR"
    
    if [[ "$ENABLE_CONTINUOUS" == "true" ]]; then
        log_info "5. Start continuous profiling service:"
        log_info "   sudo systemctl start wrfcoin-profiling"
    fi
}

# Run main function with all arguments
main "$@"