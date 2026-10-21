#!/bin/bash

# Wrfcoin Infrastructure Deployment Script
# This script deploys the Wrfcoin platform using Docker Compose or Kubernetes

set -e

DEPLOYMENT_TYPE=${1:-docker}
ENVIRONMENT=${2:-production}

echo "🚀 Deploying Wrfcoin Platform..."
echo "Deployment Type: $DEPLOYMENT_TYPE"
echo "Environment: $ENVIRONMENT"

case $DEPLOYMENT_TYPE in
  "docker")
    echo "📦 Deploying with Docker Compose..."
    
    # Check if .env file exists
    if [ ! -f "infrastructure/docker/.env" ]; then
      echo "⚠️  Creating .env file from template..."
      cp infrastructure/docker/.env.example infrastructure/docker/.env
      echo "Please edit infrastructure/docker/.env with your configuration before running again."
      exit 1
    fi
    
    # Build and deploy
    cd infrastructure/docker
    docker-compose down
    docker-compose build --no-cache
    docker-compose up -d
    
    echo "✅ Docker deployment complete!"
    echo "Frontend: http://localhost:5000"
    echo "API: http://localhost:5002"
    echo "IoT Networks: http://localhost:5006"
    echo "Compute Networks: http://localhost:5003"
    echo "Storage Networks: http://localhost:5004"
    echo "AI/ML Networks: http://localhost:5007"
    echo "Prometheus: http://localhost:9090"
    ;;
    
  "kubernetes")
    echo "☸️  Deploying with Kubernetes..."
    
    # Check if kubectl is available
    if ! command -v kubectl &> /dev/null; then
      echo "❌ kubectl is not installed or not in PATH"
      exit 1
    fi
    
    # Apply Kubernetes configurations
    kubectl apply -f infrastructure/kubernetes/base/
    
    # Wait for deployments to be ready
    echo "⏳ Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/wrfcoin-frontend
    kubectl wait --for=condition=available --timeout=300s deployment/wrfcoin-api
    kubectl wait --for=condition=available --timeout=300s deployment/wrfcoin-iot
    kubectl wait --for=condition=available --timeout=300s deployment/wrfcoin-compute
    
    echo "✅ Kubernetes deployment complete!"
    kubectl get services
    ;;
    
  "stop")
    echo "🛑 Stopping services..."
    if [ -f "infrastructure/docker/docker-compose.yml" ]; then
      cd infrastructure/docker
      docker-compose down
    fi
    echo "✅ Services stopped!"
    ;;
    
  *)
    echo "❌ Unknown deployment type: $DEPLOYMENT_TYPE"
    echo "Usage: $0 [docker|kubernetes|stop] [environment]"
    exit 1
    ;;
esac

echo "🎉 Deployment script completed!"