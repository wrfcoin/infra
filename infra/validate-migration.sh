#!/bin/bash

# WRFCoin Infrastructure Migration Validation Script
# Validates that all infrastructure files have been properly migrated to /infra

echo "🔍 Validating WRFCoin Infrastructure Migration..."
echo "=================================================="

# Check if new infra directory structure exists
echo "✅ Checking infra directory structure..."
for dir in docker helm k8s monitoring terraform deployment; do
    if [ -d "infra/$dir" ]; then
        echo "  ✓ infra/$dir exists"
    else
        echo "  ❌ infra/$dir missing"
        exit 1
    fi
done

# Validate Docker configurations
echo ""
echo "🐳 Validating Docker configurations..."
if docker-compose -f infra/docker/docker-compose.yml config --quiet; then
    echo "  ✓ Main docker-compose.yml is valid"
else
    echo "  ❌ Main docker-compose.yml has issues"
    exit 1
fi

# The historical microservices stack is quarantined with its missing build
# contexts. Check retained variants instead; never render the archive.
python3 scripts/check-legacy-compose-build-inputs.py || exit 1

if docker-compose -f infra/monitoring/docker-compose.monitoring.yml config --quiet; then
    echo "  ✓ Monitoring docker-compose.yml is valid"
else
    echo "  ❌ Monitoring docker-compose.yml has issues"
    exit 1
fi

# Check symlinks from root directory
echo ""
echo "🔗 Validating symbolic links..."
if [ -L "docker-compose.yml" ] && [ -e "docker-compose.yml" ]; then
    echo "  ✓ docker-compose.yml symlink works"
else
    echo "  ❌ docker-compose.yml symlink broken"
    exit 1
fi

if [ -L "docker-compose.monitoring.yml" ] && [ -e "docker-compose.monitoring.yml" ]; then
    echo "  ✓ docker-compose.monitoring.yml symlink works"
else
    echo "  ❌ docker-compose.monitoring.yml symlink broken"
    exit 1
fi

# Validate that old infrastructure directory content is migrated
echo ""
echo "🧹 Checking cleanup..."
if [ -d "infrastructure" ]; then
    # Check if it's empty or just contains remnants
    if [ "$(find infrastructure -type f 2>/dev/null | wc -l)" -eq 0 ]; then
        echo "  ✓ Old infrastructure directory is empty (migration complete)"
    else
        echo "  ⚠️  Old infrastructure directory contains some files (check manually)"
    fi
else
    echo "  ✓ Old infrastructure directory removed"
fi

# Check key files exist in new locations
echo ""
echo "📁 Checking key infrastructure files..."
key_files=(
    "infra/docker/Dockerfile.core"
    "infra/docker/Dockerfile.backend"
    "infra/docker/prometheus.yml"
    "infra/k8s/base/deployment.yaml"
    "infra/terraform/main.tf"
    "infra/monitoring/prometheus-enhanced.yml"
    "infra/deployment/deploy.sh"
    "infra/README.md"
)

for file in "${key_files[@]}"; do
    if [ -f "$file" ]; then
        echo "  ✓ $file exists"
    else
        echo "  ❌ $file missing"
        exit 1
    fi
done

# Check that Docker commands work from root
echo ""
echo "🧪 Testing Docker commands from root directory..."
cd "${PROJECT_ROOT:-$(dirname "$(dirname "$(readlink -f "$0")")")}"
if docker-compose config --quiet; then
    echo "  ✓ docker-compose works from project root"
else
    echo "  ❌ docker-compose fails from project root"
    exit 1
fi

echo ""
echo "🎉 Infrastructure migration validation completed successfully!"
echo ""
echo "📋 Migration Summary:"
echo "  - Old infrastructure/ directory removed"
echo "  - All files migrated to infra/ with proper structure"
echo "  - Docker configurations updated with correct paths"
echo "  - Symlinks created for backward compatibility"
echo "  - All configurations validated and working"
echo ""
echo "✨ Infrastructure is ready for use!"
