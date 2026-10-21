#!/bin/bash

# System-Level Performance Profiling for Wrfcoin
# 
# Provides comprehensive system profiling capabilities including:
# - eBPF-based profiling for kernel and user space
# - perf integration for CPU and system profiling
# - SystemTap scripts for advanced tracing
# - Docker container profiling
# - Integration with existing monitoring infrastructure

set -euo pipefail

# Configuration
PROFILE_DIR="${PROFILE_DIR:-./profiles/system}"
RETENTION_HOURS="${RETENTION_HOURS:-24}"
SAMPLING_FREQUENCY="${SAMPLING_FREQUENCY:-99}"
PROFILE_DURATION="${PROFILE_DURATION:-60}"
ENABLE_EBPF="${ENABLE_EBPF:-true}"
ENABLE_PERF="${ENABLE_PERF:-true}"
ENABLE_CONTAINER_PROFILING="${ENABLE_CONTAINER_PROFILING:-true}"
WRFCOIN_PROCESSES="${WRFCOIN_PROCESSES:-node,wrfcoin,blockchain-core}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Check if running as root (required for many profiling tools)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root for system profiling"
        log_info "Use: sudo $0 $*"
        exit 1
    fi
}

# Check system dependencies
check_dependencies() {
    log_info "Checking system dependencies..."
    
    local missing_deps=()
    
    # Check for perf
    if ! command -v perf &> /dev/null; then
        missing_deps+=("linux-tools-$(uname -r)")
    fi
    
    # Check for bpftrace (eBPF)
    if [[ "$ENABLE_EBPF" == "true" ]] && ! command -v bpftrace &> /dev/null; then
        missing_deps+=("bpftrace")
    fi
    
    # Check for docker (if container profiling enabled)
    if [[ "$ENABLE_CONTAINER_PROFILING" == "true" ]] && ! command -v docker &> /dev/null; then
        log_warn "Docker not found, container profiling will be disabled"
        ENABLE_CONTAINER_PROFILING="false"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install with: apt-get update && apt-get install -y ${missing_deps[*]}"
        exit 1
    fi
    
    log_success "All dependencies satisfied"
}

# Create profile output directory
setup_directories() {
    log_info "Setting up profile directories..."
    
    mkdir -p "$PROFILE_DIR"/{perf,ebpf,container,flame-graphs}
    chmod 755 "$PROFILE_DIR"
    
    log_success "Profile directories created: $PROFILE_DIR"
}

# Get Wrfcoin process PIDs
get_wrfcoin_pids() {
    local pids=()
    
    IFS=',' read -ra PROCESSES <<< "$WRFCOIN_PROCESSES"
    for process in "${PROCESSES[@]}"; do
        local process_pids
        process_pids=$(pgrep -f "$process" 2>/dev/null || true)
        if [[ -n "$process_pids" ]]; then
            pids+=($process_pids)
        fi
    done
    
    echo "${pids[@]}"
}

# CPU profiling with perf
profile_cpu_perf() {
    if [[ "$ENABLE_PERF" != "true" ]]; then
        return
    fi
    
    log_info "Starting CPU profiling with perf..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$PROFILE_DIR/perf/cpu_profile_$timestamp.data"
    local flame_graph_file="$PROFILE_DIR/flame-graphs/cpu_flame_graph_$timestamp.svg"
    
    local pids
    pids=($(get_wrfcoin_pids))
    
    if [[ ${#pids[@]} -eq 0 ]]; then
        log_warn "No Wrfcoin processes found, profiling entire system"
        perf record -g -F "$SAMPLING_FREQUENCY" -o "$output_file" sleep "$PROFILE_DURATION" &
    else
        local pid_args=""
        for pid in "${pids[@]}"; do
            pid_args="$pid_args -p $pid"
        done
        perf record -g -F "$SAMPLING_FREQUENCY" $pid_args -o "$output_file" sleep "$PROFILE_DURATION" &
    fi
    
    local perf_pid=$!
    
    # Wait for profiling to complete
    wait $perf_pid
    
    # Generate flame graph if flamegraph tool is available
    if command -v flamegraph.pl &> /dev/null; then
        perf script -i "$output_file" | flamegraph.pl > "$flame_graph_file"
        log_success "Flame graph generated: $flame_graph_file"
    elif command -v perf &> /dev/null; then
        # Generate perf report
        perf report -i "$output_file" --stdio > "$PROFILE_DIR/perf/cpu_report_$timestamp.txt"
        log_success "Perf report generated: $PROFILE_DIR/perf/cpu_report_$timestamp.txt"
    fi
    
    log_success "CPU profiling completed: $output_file"
}

# Memory profiling with perf
profile_memory_perf() {
    if [[ "$ENABLE_PERF" != "true" ]]; then
        return
    fi
    
    log_info "Starting memory profiling with perf..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$PROFILE_DIR/perf/memory_profile_$timestamp.data"
    
    local pids
    pids=($(get_wrfcoin_pids))
    
    if [[ ${#pids[@]} -eq 0 ]]; then
        perf record -e cache-misses,cache-references,page-faults -o "$output_file" sleep "$PROFILE_DURATION" &
    else
        local pid_args=""
        for pid in "${pids[@]}"; do
            pid_args="$pid_args -p $pid"
        done
        perf record -e cache-misses,cache-references,page-faults $pid_args -o "$output_file" sleep "$PROFILE_DURATION" &
    fi
    
    wait $!
    
    # Generate report
    perf report -i "$output_file" --stdio > "$PROFILE_DIR/perf/memory_report_$timestamp.txt"
    
    log_success "Memory profiling completed: $output_file"
}

# eBPF-based profiling
profile_ebpf() {
    if [[ "$ENABLE_EBPF" != "true" ]]; then
        return
    fi
    
    log_info "Starting eBPF profiling..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    # CPU profiling with bpftrace
    cat > "$PROFILE_DIR/ebpf/cpu_profile_$timestamp.bt" << 'EOF'
#!/usr/bin/env bpftrace

profile:hz:99 {
    @[kstack, ustack, comm] = count();
}

interval:s:60 {
    exit();
}
EOF

    chmod +x "$PROFILE_DIR/ebpf/cpu_profile_$timestamp.bt"
    
    # Run CPU profiling
    bpftrace "$PROFILE_DIR/ebpf/cpu_profile_$timestamp.bt" > "$PROFILE_DIR/ebpf/cpu_output_$timestamp.txt" 2>&1 &
    local cpu_pid=$!
    
    # Memory allocation tracking
    cat > "$PROFILE_DIR/ebpf/memory_profile_$timestamp.bt" << 'EOF'
#!/usr/bin/env bpftrace

tracepoint:kmem:kmalloc {
    @malloc_size[comm] = hist(args->bytes_alloc);
    @malloc_count[comm] = count();
}

tracepoint:kmem:kfree {
    @free_count[comm] = count();
}

interval:s:60 {
    exit();
}
EOF

    chmod +x "$PROFILE_DIR/ebpf/memory_profile_$timestamp.bt"
    
    # Run memory profiling
    bpftrace "$PROFILE_DIR/ebpf/memory_profile_$timestamp.bt" > "$PROFILE_DIR/ebpf/memory_output_$timestamp.txt" 2>&1 &
    local memory_pid=$!
    
    # System call tracking
    cat > "$PROFILE_DIR/ebpf/syscall_profile_$timestamp.bt" << 'EOF'
#!/usr/bin/env bpftrace

tracepoint:raw_syscalls:sys_enter {
    @syscall_count[comm] = count();
    @syscall_latency[comm] = hist(nsecs);
}

interval:s:60 {
    exit();
}
EOF

    chmod +x "$PROFILE_DIR/ebpf/syscall_profile_$timestamp.bt"
    
    # Run syscall profiling
    bpftrace "$PROFILE_DIR/ebpf/syscall_profile_$timestamp.bt" > "$PROFILE_DIR/ebpf/syscall_output_$timestamp.txt" 2>&1 &
    local syscall_pid=$!
    
    # Wait for all eBPF programs to complete
    wait $cpu_pid $memory_pid $syscall_pid
    
    log_success "eBPF profiling completed"
}

# Container profiling
profile_containers() {
    if [[ "$ENABLE_CONTAINER_PROFILING" != "true" ]]; then
        return
    fi
    
    log_info "Starting container profiling..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$PROFILE_DIR/container/container_stats_$timestamp.json"
    
    # Get Wrfcoin-related containers
    local containers
    containers=$(docker ps --format "table {{.ID}}\t{{.Names}}" | grep -E "(wrfcoin|blockchain|node)" | cut -f1 || true)
    
    if [[ -z "$containers" ]]; then
        log_warn "No Wrfcoin-related containers found"
        return
    fi
    
    # Collect container stats
    {
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"containers\": ["
        
        local first=true
        while read -r container_id; do
            if [[ -n "$container_id" ]]; then
                if [[ "$first" != "true" ]]; then
                    echo ","
                fi
                first=false
                
                echo "    {"
                echo "      \"id\": \"$container_id\","
                echo "      \"stats\": $(docker stats --no-stream --format "table {{json .}}" "$container_id" | tail -n +2)"
                echo "    }"
            fi
        done <<< "$containers"
        
        echo "  ]"
        echo "}"
    } > "$output_file"
    
    # Collect container resource usage over time
    {
        echo "timestamp,container_id,container_name,cpu_percent,memory_usage,memory_limit,memory_percent,network_io,block_io"
        
        for i in {1..60}; do
            while read -r container_id; do
                if [[ -n "$container_id" ]]; then
                    local stats
                    stats=$(docker stats --no-stream --format "{{.Container}},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}},{{.NetIO}},{{.BlockIO}}" "$container_id" 2>/dev/null || true)
                    if [[ -n "$stats" ]]; then
                        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$stats"
                    fi
                fi
            done <<< "$containers"
            sleep 1
        done
    } > "$PROFILE_DIR/container/container_timeline_$timestamp.csv"
    
    log_success "Container profiling completed: $output_file"
}

# Network profiling
profile_network() {
    log_info "Starting network profiling..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$PROFILE_DIR/perf/network_profile_$timestamp.data"
    
    # Network event profiling with perf
    perf record -e net:netif_receive_skb,net:net_dev_xmit,net:net_dev_queue \
        -o "$output_file" sleep "$PROFILE_DURATION" &
    
    wait $!
    
    # Generate network report
    perf report -i "$output_file" --stdio > "$PROFILE_DIR/perf/network_report_$timestamp.txt"
    
    # Capture network statistics
    {
        echo "=== Network Interface Statistics ==="
        cat /proc/net/dev
        echo ""
        echo "=== Socket Statistics ==="
        ss -tuln
        echo ""
        echo "=== Network Connections ==="
        netstat -tulpn | grep -E "(wrfcoin|node|blockchain)"
    } > "$PROFILE_DIR/perf/network_stats_$timestamp.txt"
    
    log_success "Network profiling completed"
}

# System-wide resource monitoring
monitor_system_resources() {
    log_info "Starting system resource monitoring..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local output_file="$PROFILE_DIR/system_resources_$timestamp.log"
    
    {
        echo "=== System Resource Monitoring Started at $(date) ==="
        echo ""
        
        for i in {1..60}; do
            echo "--- Sample $i at $(date) ---"
            echo "CPU Usage:"
            top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}'
            
            echo "Memory Usage:"
            free -h
            
            echo "Load Average:"
            uptime
            
            echo "Disk I/O:"
            iostat -x 1 1 | tail -n +4
            
            echo "Top Processes:"
            ps aux --sort=-%cpu | head -10
            
            echo ""
            sleep 1
        done
        
        echo "=== System Resource Monitoring Completed at $(date) ==="
    } > "$output_file" &
    
    local monitor_pid=$!
    
    # Wait for monitoring to complete
    wait $monitor_pid
    
    log_success "System resource monitoring completed: $output_file"
}

# Generate comprehensive profiling report
generate_report() {
    log_info "Generating comprehensive profiling report..."
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="$PROFILE_DIR/profiling_report_$timestamp.md"
    
    {
        echo "# Wrfcoin System Profiling Report"
        echo "Generated on: $(date)"
        echo ""
        
        echo "## System Information"
        echo "- Hostname: $(hostname)"
        echo "- Kernel: $(uname -r)"
        echo "- OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')"
        echo "- CPU: $(lscpu | grep 'Model name' | cut -d':' -f2 | xargs)"
        echo "- Memory: $(free -h | grep 'Mem:' | awk '{print $2}')"
        echo ""
        
        echo "## Profiling Configuration"
        echo "- Profile Duration: ${PROFILE_DURATION}s"
        echo "- Sampling Frequency: ${SAMPLING_FREQUENCY}Hz"
        echo "- eBPF Enabled: $ENABLE_EBPF"
        echo "- Perf Enabled: $ENABLE_PERF"
        echo "- Container Profiling: $ENABLE_CONTAINER_PROFILING"
        echo ""
        
        echo "## Process Information"
        local pids
        pids=($(get_wrfcoin_pids))
        if [[ ${#pids[@]} -gt 0 ]]; then
            echo "- Wrfcoin Process PIDs: ${pids[*]}"
            echo "- Process Details:"
            for pid in "${pids[@]}"; do
                echo "  - PID $pid: $(ps -p $pid -o comm= 2>/dev/null || echo 'Process not found')"
            done
        else
            echo "- No Wrfcoin processes found during profiling"
        fi
        echo ""
        
        echo "## Generated Profiles"
        echo "### Perf Profiles"
        find "$PROFILE_DIR/perf" -name "*.data" -newer "$report_file" 2>/dev/null | while read -r file; do
            echo "- $(basename "$file")"
        done
        echo ""
        
        echo "### eBPF Profiles"
        find "$PROFILE_DIR/ebpf" -name "*.txt" -newer "$report_file" 2>/dev/null | while read -r file; do
            echo "- $(basename "$file")"
        done
        echo ""
        
        echo "### Container Profiles"
        find "$PROFILE_DIR/container" -name "*.json" -o -name "*.csv" -newer "$report_file" 2>/dev/null | while read -r file; do
            echo "- $(basename "$file")"
        done
        echo ""
        
        echo "### Flame Graphs"
        find "$PROFILE_DIR/flame-graphs" -name "*.svg" -newer "$report_file" 2>/dev/null | while read -r file; do
            echo "- $(basename "$file")"
        done
        echo ""
        
        echo "## Analysis and Recommendations"
        echo "1. Review CPU flame graphs for hot code paths"
        echo "2. Check memory allocation patterns in eBPF output"
        echo "3. Analyze container resource usage for optimization opportunities"
        echo "4. Monitor system resource trends for capacity planning"
        echo ""
        
        echo "## Next Steps"
        echo "1. Use 'perf report' to analyze detailed CPU profiles"
        echo "2. Visualize flame graphs in a web browser"
        echo "3. Correlate profiling data with application metrics"
        echo "4. Implement performance optimizations based on findings"
    } > "$report_file"
    
    log_success "Profiling report generated: $report_file"
}

# Cleanup old profiles
cleanup_old_profiles() {
    log_info "Cleaning up profiles older than $RETENTION_HOURS hours..."
    
    find "$PROFILE_DIR" -type f -mtime +$(( RETENTION_HOURS / 24 )) -delete 2>/dev/null || true
    
    log_success "Cleanup completed"
}

# Main profiling function
run_profiling() {
    log_info "Starting comprehensive system profiling..."
    
    # Run profiling tasks in parallel
    profile_cpu_perf &
    local cpu_pid=$!
    
    profile_memory_perf &
    local memory_pid=$!
    
    profile_ebpf &
    local ebpf_pid=$!
    
    profile_containers &
    local container_pid=$!
    
    profile_network &
    local network_pid=$!
    
    monitor_system_resources &
    local monitor_pid=$!
    
    # Wait for all profiling tasks to complete
    wait $cpu_pid $memory_pid $ebpf_pid $container_pid $network_pid $monitor_pid
    
    # Generate comprehensive report
    generate_report
    
    # Cleanup old profiles
    cleanup_old_profiles
    
    log_success "System profiling completed successfully!"
}

# Usage information
usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  start     Start continuous profiling"
    echo "  once      Run profiling once and exit"
    echo "  report    Generate report from existing profiles"
    echo "  cleanup   Clean up old profile files"
    echo "  check     Check system dependencies"
    echo ""
    echo "Environment Variables:"
    echo "  PROFILE_DIR              Profile output directory (default: ./profiles/system)"
    echo "  RETENTION_HOURS          Profile retention in hours (default: 24)"
    echo "  SAMPLING_FREQUENCY       CPU sampling frequency in Hz (default: 99)"
    echo "  PROFILE_DURATION         Profiling duration in seconds (default: 60)"
    echo "  ENABLE_EBPF              Enable eBPF profiling (default: true)"
    echo "  ENABLE_PERF              Enable perf profiling (default: true)"
    echo "  ENABLE_CONTAINER_PROFILING Enable container profiling (default: true)"
    echo "  WRFCOIN_PROCESSES        Comma-separated process names (default: node,wrfcoin,blockchain-core)"
}

# Main entry point
main() {
    local command="${1:-once}"
    
    case "$command" in
        "start")
            check_root
            check_dependencies
            setup_directories
            log_info "Starting continuous profiling (press Ctrl+C to stop)..."
            while true; do
                run_profiling
                sleep 300  # Wait 5 minutes between profiling runs
            done
            ;;
        "once")
            check_root
            check_dependencies
            setup_directories
            run_profiling
            ;;
        "report")
            generate_report
            ;;
        "cleanup")
            cleanup_old_profiles
            ;;
        "check")
            check_dependencies
            ;;
        "help"|"-h"|"--help")
            usage
            ;;
        *)
            log_error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"