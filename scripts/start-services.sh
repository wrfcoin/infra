#!/bin/bash
# WRFCoin Service Starter
# Starts backend and frontend services

# Determine project root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Starting WRFCoin services..."
echo "Project root: $PROJECT_ROOT"

# Kill any existing processes on our ports
echo "Cleaning up existing processes..."
lsof -ti:3001 | xargs kill -9 2>/dev/null
lsof -ti:5000 | xargs kill -9 2>/dev/null

# Start backend API
echo "Starting backend API on port 3001..."
cd "$PROJECT_ROOT/backend"
PORT=3001 nohup npm run dev > backend.log 2>&1 &
BACKEND_PID=$!
echo "Backend PID: $BACKEND_PID"

# Wait for backend to start
sleep 5

# Start frontend
echo "Starting frontend on port 5000..."
cd "$PROJECT_ROOT/frontend"
nohup npm run dev > frontend.log 2>&1 &
FRONTEND_PID=$!
echo "Frontend PID: $FRONTEND_PID"

# Save PIDs to file for stopping later
echo "BACKEND_PID=$BACKEND_PID" > "$PROJECT_ROOT/services.pid"
echo "FRONTEND_PID=$FRONTEND_PID" >> "$PROJECT_ROOT/services.pid"

echo ""
echo "Services started successfully!"
echo "Frontend: http://localhost:5000"
echo "Backend API: http://localhost:3001"
echo ""
echo "To view logs:"
echo "  Backend: tail -f $PROJECT_ROOT/backend/backend.log"
echo "  Frontend: tail -f $PROJECT_ROOT/frontend/frontend.log"
echo ""
echo "To stop services: $PROJECT_ROOT/scripts/stop-services.sh"
