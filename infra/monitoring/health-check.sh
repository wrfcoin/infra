#!/bin/bash

# Health check script for the dependency monitor container

set -e

# Check if the service is responding
response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:9200/health || echo "000")

if [ "$response" = "200" ]; then
    echo "✅ Dependency monitor is healthy"
    exit 0
else
    echo "❌ Dependency monitor health check failed (HTTP $response)"
    exit 1
fi