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
echo "📊 Grafana Dashboard: http://localhost:3001"
echo "   Username: admin"
echo "   Password: wrfcoin2024"
echo ""
echo "📈 Prometheus: http://localhost:9090"
echo "🚨 Alertmanager: http://localhost:9093"
echo "💻 Node Exporter: http://localhost:9100"
echo ""
echo "🏃 Run performance tests with: ./scripts/run-performance-tests.sh"
