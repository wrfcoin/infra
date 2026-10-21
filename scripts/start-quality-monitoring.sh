#!/bin/bash

# WRFCoin Quality Monitoring Startup Script
# Starts the complete quality monitoring ecosystem

set -e

echo "🚀 Starting WRFCoin Quality Monitoring System..."

# Create necessary directories
mkdir -p logs reports

echo "📊 Starting Quality Dashboard Server..."
# Start quality dashboard in background
nohup node scripts/quality-dashboard-server.js > logs/quality-dashboard.log 2>&1 &
DASHBOARD_PID=$!

# Wait for dashboard to start
sleep 3

# Check if dashboard is running
if curl -s http://localhost:8090/health > /dev/null; then
    echo "✅ Quality Dashboard started successfully (PID: $DASHBOARD_PID)"
    echo "   Dashboard URL: http://localhost:8090"
else
    echo "❌ Failed to start Quality Dashboard"
    exit 1
fi

echo "🎯 Starting Quality Alert Monitoring..."
# Start alert monitoring in background
nohup node scripts/quality-alerting-system.js monitor 5 > logs/quality-alerts.log 2>&1 &
ALERT_PID=$!

echo "✅ Quality Alert Monitoring started (PID: $ALERT_PID)"

# Save PIDs for later cleanup
echo $DASHBOARD_PID > logs/dashboard.pid
echo $ALERT_PID > logs/alerts.pid

echo ""
echo "🎉 Quality Monitoring System Started Successfully!"
echo ""
echo "📊 Dashboard:     http://localhost:8090"
echo "📈 Metrics API:   http://localhost:8090/api/metrics"
echo "🚨 Alerts API:    http://localhost:8090/api/alerts"
echo "📊 Prometheus:    http://localhost:8090/metrics"
echo ""
echo "📁 Log Files:"
echo "   Dashboard:     logs/quality-dashboard.log"
echo "   Alerts:        logs/quality-alerts.log"
echo ""
echo "🛑 To stop: npm run quality:stop-monitoring"
echo ""

# Run initial quality check
echo "🔍 Running initial quality check..."
npm run quality:report

echo ""
echo "✅ Initial quality assessment completed!"
echo "The system is now monitoring code quality continuously."