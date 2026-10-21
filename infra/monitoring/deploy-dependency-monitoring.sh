#!/bin/bash
WRFCOIN_SCRIPT_ROOT="${WRFCOIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

# WRFCoin Service Dependency Monitoring Deployment Script
# This script sets up comprehensive service dependency monitoring

set -e

echo "🚀 WRFCoin Service Dependency Monitoring Deployment"
echo "=================================================="

# Configuration
MONITORING_DIR="${WRFCOIN_SCRIPT_ROOT}/infra/monitoring"
DOCKER_COMPOSE_FILE="docker-compose.dependency-monitoring.yml"

# Function to print colored output
print_status() {
    echo -e "\033[1;34m[INFO]\033[0m $1"
}

print_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

print_warning() {
    echo -e "\033[1;33m[WARNING]\033[0m $1"
}

print_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
}

# Check prerequisites
print_status "Checking prerequisites..."

# Check if Docker is installed and running
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! docker info &> /dev/null; then
    print_error "Docker daemon is not running. Please start Docker."
    exit 1
fi

# Check if Docker Compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    print_error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

print_success "Prerequisites check passed"

# Navigate to monitoring directory
cd "$MONITORING_DIR"

# Generate service dependency maps
print_status "Generating service dependency maps..."
if [ -f "generate-service-dependency-map.js" ]; then
    # Install Node.js dependencies if needed
    if [ ! -d "node_modules" ]; then
        npm install
    fi
    
    # Generate dependency maps
    node generate-service-dependency-map.js
    print_success "Service dependency maps generated"
else
    print_warning "Service map generator not found, skipping map generation"
fi

# Create necessary directories
print_status "Creating necessary directories..."
mkdir -p dependency-maps logs grafana/dashboards

# Set permissions
chmod +x health-check.sh
chmod +x generate-service-dependency-map.js

# Build custom dependency monitor image
print_status "Building dependency monitor image..."
if docker build -t wrfcoin/dependency-monitor:latest -f Dockerfile.dependency-monitor .; then
    print_success "Dependency monitor image built successfully"
else
    print_error "Failed to build dependency monitor image"
    exit 1
fi

# Stop existing monitoring services if running
print_status "Stopping existing dependency monitoring services..."
docker-compose -f "$DOCKER_COMPOSE_FILE" down 2>/dev/null || true

# Start the dependency monitoring stack
print_status "Starting dependency monitoring services..."
if docker-compose -f "$DOCKER_COMPOSE_FILE" up -d; then
    print_success "Dependency monitoring services started successfully"
else
    print_error "Failed to start dependency monitoring services"
    exit 1
fi

# Wait for services to be ready
print_status "Waiting for services to be ready..."
sleep 30

# Verify service health
print_status "Verifying service health..."

services=(
    "prometheus-deps:9091"
    "grafana-deps:3001"
    "alertmanager-deps:9094"
    "blackbox-exporter:9115"
    "dependency-monitor:9200"
)

all_healthy=true
for service in "${services[@]}"; do
    service_name=$(echo "$service" | cut -d: -f1)
    port=$(echo "$service" | cut -d: -f2)
    
    if curl -s -f "http://localhost:$port/health" > /dev/null 2>&1 || curl -s -f "http://localhost:$port" > /dev/null 2>&1; then
        print_success "$service_name is healthy"
    else
        print_warning "$service_name health check failed"
        all_healthy=false
    fi
done

# Display access information
echo ""
echo "🎉 Deployment Complete!"
echo "======================"
echo ""
echo "Service Access URLs:"
echo "-------------------"
echo "📊 Grafana Dashboard: http://localhost:3001 (admin/wrfcoin-deps-admin)"
echo "📈 Prometheus (Dependencies): http://localhost:9091"
echo "🚨 Alertmanager: http://localhost:9094"
echo "🔍 Blackbox Exporter: http://localhost:9115"
echo "📋 Dependency Monitor: http://localhost:9200"
echo "📊 System Metrics (cAdvisor): http://localhost:8080"
echo "🖥️  Node Metrics: http://localhost:9100"
echo ""
echo "API Endpoints:"
echo "-------------"
echo "📋 Service Status: http://localhost:9200/services"
echo "🔗 Dependencies: http://localhost:9200/dependencies"
echo "📊 Metrics: http://localhost:9200/metrics"
echo "🗺️  Visual Map: http://localhost:9200/map"
echo "⚠️  Cascade Analysis: http://localhost:9200/cascade-analysis"
echo ""

if [ "$all_healthy" = true ]; then
    echo "✅ All monitoring services are healthy and running!"
else
    echo "⚠️  Some services may need a few more moments to fully initialize."
    echo "   Check individual service logs with: docker-compose -f $DOCKER_COMPOSE_FILE logs [service-name]"
fi

echo ""
echo "🔧 Management Commands:"
echo "----------------------"
echo "View logs: docker-compose -f $DOCKER_COMPOSE_FILE logs -f"
echo "Stop services: docker-compose -f $DOCKER_COMPOSE_FILE down"
echo "Restart services: docker-compose -f $DOCKER_COMPOSE_FILE restart"
echo "Update configuration: ./deploy-dependency-monitoring.sh"
echo ""

# Generate initial dependency report
print_status "Generating initial dependency report..."
if curl -s "http://localhost:9200/cascade-analysis" > dependency-health-report.json; then
    print_success "Initial dependency report saved to dependency-health-report.json"
fi

print_success "WRFCoin Service Dependency Monitoring deployment completed successfully!"