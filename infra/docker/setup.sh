#!/bin/bash

# Wrfcoin NAS Storage Setup Script
# Simple "one-click" setup for earning WRF tokens with your NAS devices

set -e

echo "🗄️ Wrfcoin NAS Storage Setup"
echo "================================"
echo "This script will set up your storage devices to earn WRF tokens automatically."
echo ""

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first:"
    echo "   Visit: https://docs.docker.com/get-docker/"
    exit 1
fi

# Check if Docker Compose is available
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not available. Please install Docker Compose:"
    echo "   Visit: https://docs.docker.com/compose/install/"
    exit 1
fi

echo "✅ Docker environment ready"

# Get user's wallet address
read -p "Enter your WRF wallet address (or press Enter for default): " WALLET_ADDRESS
WALLET_ADDRESS=${WALLET_ADDRESS:-wrf717d72395303fcb2aed4df368f32f1078d18e9cc}

# Get storage allocation preference
echo ""
echo "How much of your NAS storage would you like to allocate for earning?"
echo "1) 50% (Conservative)"
echo "2) 80% (Recommended)"
echo "3) 90% (Aggressive)"
read -p "Choose (1-3) [default: 2]: " STORAGE_CHOICE

case $STORAGE_CHOICE in
    1) MAX_ALLOCATION="50%" ;;
    3) MAX_ALLOCATION="90%" ;;
    *) MAX_ALLOCATION="80%" ;;
esac

# Create environment file
cat > .env << EOF
WALLET_ADDRESS=$WALLET_ADDRESS
MAX_STORAGE_ALLOCATION=$MAX_ALLOCATION
AUTO_DISCOVERY=true
AUTO_REGISTER=true
COLLECTION_INTERVAL=120000
NETWORK_INTERFACE=eth0
EOF

echo ""
echo "🚀 Starting NAS Storage Services..."
echo "   Wallet: $WALLET_ADDRESS"
echo "   Storage Allocation: $MAX_ALLOCATION"
echo ""

# Use docker-compose or docker compose based on availability
if command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

# Build and start services
$COMPOSE_CMD build --no-cache
$COMPOSE_CMD up -d

# Wait for services to start
echo "⏳ Waiting for services to initialize..."
sleep 15

# Check service health
if docker ps | grep -q "wrfcoin-nas-storage"; then
    echo "✅ NAS Storage Server: Running"
else
    echo "❌ NAS Storage Server: Failed to start"
    echo "💡 Check logs: $COMPOSE_CMD logs nas-storage-server"
    exit 1
fi

if docker ps | grep -q "wrfcoin-nas-collector"; then
    echo "✅ Auto-Collector: Running"
else
    echo "❌ Auto-Collector: Failed to start"
    echo "💡 Check logs: $COMPOSE_CMD logs nas-auto-collector"
    exit 1
fi

echo ""
echo "🎉 Setup Complete!"
echo "================================"
echo "Your NAS storage earning system is now active!"
echo ""
echo "📊 Management URLs:"
echo "   Storage API: http://localhost:7001"
echo "   Health Check: http://localhost:7001/health"
echo "   Main Dashboard: http://localhost:5000/settings"
echo ""
echo "📱 Next Steps:"
echo "1. Open your Wrfcoin dashboard at http://localhost:5000"
echo "2. Go to Settings > NAS Storage tab"
echo "3. Click 'Discover NAS Devices' to find your storage devices"
echo "4. Register discovered devices to start earning"
echo ""
echo "💰 Your devices will automatically:"
echo "   - Discover compatible NAS devices on your network"
echo "   - Register them for storage rewards"
echo "   - Participate in storage validation challenges"
echo "   - Accumulate WRF tokens in your wallet"
echo ""
echo "🔍 To monitor your earnings:"
echo "   $COMPOSE_CMD logs -f nas-auto-collector"
echo ""
echo "🛑 To stop the services:"
echo "   $COMPOSE_CMD down"
echo ""
echo "🔧 Protected Earnings:"
echo "   Your weather station earnings continue unaffected"
echo "   NAS storage adds additional income stream"
echo ""
echo "Happy earning! 🚀"