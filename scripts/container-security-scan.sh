#!/bin/bash

# Wrfcoin Container Security Scanner
echo "🔍 Running container security scan..."

# Create scan report directory
mkdir -p security-reports

# Dockerfile security check with hadolint
if command -v hadolint &> /dev/null; then
    echo "📋 Scanning Dockerfile..."
    hadolint Dockerfile > security-reports/dockerfile-scan.txt 2>&1
else
    echo "⚠️  hadolint not found, install with: brew install hadolint"
fi

# Image vulnerability scanning with trivy
if command -v trivy &> /dev/null; then
    echo "🔍 Scanning for vulnerabilities..."
    trivy image --format json --output security-reports/vulnerability-scan.json wrfcoin:latest
else
    echo "⚠️  trivy not found, install with: brew install aquasecurity/trivy/trivy"
fi

# Container runtime security with docker-bench
if [ -f docker-bench-security.sh ]; then
    echo "🛡️  Running Docker bench security..."
    ./docker-bench-security.sh > security-reports/docker-bench.txt 2>&1
else
    echo "📥 Downloading Docker bench security..."
    curl -L https://github.com/docker/docker-bench-security/archive/master.tar.gz | tar -xz --strip-components=1 docker-bench-security-master/docker-bench-security.sh
fi

# Package vulnerability check
echo "📦 Checking package vulnerabilities..."
npm audit --audit-level moderate --json > security-reports/npm-audit.json 2>&1

# Generate security summary
echo "📊 Generating security summary..."
cat > security-reports/summary.txt << EOF
Wrfcoin Container Security Report
Generated: $(date)

Files scanned:
- Dockerfile (hadolint)
- Container image (trivy)
- Docker configuration (docker-bench)
- Node.js packages (npm audit)

Review all files in security-reports/ directory for detailed findings.
EOF

echo "✅ Security scan complete. Check security-reports/ directory."