#!/bin/bash

# WRFCoin Quality Monitoring Shutdown Script
# Gracefully stops the quality monitoring ecosystem

echo "🛑 Stopping WRFCoin Quality Monitoring System..."

# Function to stop process by PID file
stop_process() {
    local service_name=$1
    local pid_file=$2
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if ps -p $pid > /dev/null 2>&1; then
            echo "🛑 Stopping $service_name (PID: $pid)..."
            kill $pid
            
            # Wait for graceful shutdown
            local count=0
            while ps -p $pid > /dev/null 2>&1 && [ $count -lt 10 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            # Force kill if still running
            if ps -p $pid > /dev/null 2>&1; then
                echo "⚠️ Force killing $service_name..."
                kill -9 $pid
            fi
            
            echo "✅ $service_name stopped"
        else
            echo "ℹ️ $service_name was not running"
        fi
        rm -f "$pid_file"
    else
        echo "ℹ️ No PID file found for $service_name"
    fi
}

# Stop Dashboard Server
stop_process "Quality Dashboard" "logs/dashboard.pid"

# Stop Alert Monitoring
stop_process "Alert Monitoring" "logs/alerts.pid"

# Alternative cleanup using pkill (fallback)
echo "🔍 Cleaning up any remaining processes..."

if pgrep -f "quality-dashboard-server.js" > /dev/null; then
    echo "🛑 Stopping remaining dashboard processes..."
    pkill -f "quality-dashboard-server.js"
fi

if pgrep -f "quality-alerting-system.js monitor" > /dev/null; then
    echo "🛑 Stopping remaining alert monitoring processes..."
    pkill -f "quality-alerting-system.js monitor"
fi

# Verify cleanup
echo "🔍 Verifying cleanup..."
sleep 2

dashboard_running=$(pgrep -f "quality-dashboard-server.js" | wc -l)
alerts_running=$(pgrep -f "quality-alerting-system.js monitor" | wc -l)

if [ $dashboard_running -eq 0 ] && [ $alerts_running -eq 0 ]; then
    echo "✅ Quality Monitoring System stopped successfully!"
else
    echo "⚠️ Some processes may still be running:"
    if [ $dashboard_running -gt 0 ]; then
        echo "   - Dashboard processes: $dashboard_running"
    fi
    if [ $alerts_running -gt 0 ]; then
        echo "   - Alert processes: $alerts_running"
    fi
fi

echo ""
echo "📁 Log files preserved:"
echo "   - logs/quality-dashboard.log"
echo "   - logs/quality-alerts.log"
echo "   - logs/alert-history.json"
echo ""
echo "🔄 To restart: npm run quality:start-monitoring"