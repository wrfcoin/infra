#!/bin/bash
set -e

echo "🚀 Deploying Wrfcoin Node OS Services..."

# Build and start services
docker-compose up -d --build

# Wait for services to be ready
echo "⏳ Waiting for services to start..."
sleep 30

# Check service health
echo "🔍 Checking service health..."
docker-compose ps

# Show logs
echo "📋 Recent logs:"
docker-compose logs --tail=20

echo "✅ Deployment complete!"
echo "Dashboard available at: http://localhost:5000"
echo "Prometheus metrics at: http://localhost:9090"
