#!/bin/bash
# WRFCoin Service Stopper
# Stops backend and frontend services

# Determine project root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Stopping WRFCoin services..."

# Read PIDs from file
if [ -f "$PROJECT_ROOT/services.pid" ]; then
    source "$PROJECT_ROOT/services.pid"

    if [ ! -z "$BACKEND_PID" ]; then
        echo "Stopping backend (PID: $BACKEND_PID)..."
        kill $BACKEND_PID 2>/dev/null
    fi

    if [ ! -z "$FRONTEND_PID" ]; then
        echo "Stopping frontend (PID: $FRONTEND_PID)..."
        kill $FRONTEND_PID 2>/dev/null
    fi

    rm "$PROJECT_ROOT/services.pid"
else
    echo "No PID file found. Killing processes by port..."
    lsof -ti:3001 | xargs kill -9 2>/dev/null
    lsof -ti:5000 | xargs kill -9 2>/dev/null
fi

echo "Services stopped."
