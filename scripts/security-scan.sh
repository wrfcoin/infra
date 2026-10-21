#!/bin/bash

# Comprehensive Security Scanning Script for Wrfcoin Smart Contracts
# This script runs multiple security analysis tools on the smart contracts

set -e

echo "🔒 Starting Comprehensive Smart Contract Security Analysis..."
echo "=================================================="

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Create reports directory
mkdir -p reports/security

# Compile contracts first
print_status "Compiling contracts..."
npx hardhat compile
print_success "Contracts compiled successfully"

# 1. Run Solhint (Linting)
print_status "Running Solhint static analysis..."
if npx hardhat check > reports/security/solhint-report.txt 2>&1; then
    print_success "Solhint analysis completed"
else
    print_warning "Solhint found issues - check reports/security/solhint-report.txt"
fi

# 2. Run Slither (if available via Python)
print_status "Checking for Slither availability..."
if command -v slither &> /dev/null; then
    print_status "Running Slither static analysis..."
    slither . --json reports/security/slither-report.json --print-summary > reports/security/slither-summary.txt 2>&1 || true
    print_success "Slither analysis completed - check reports/security/slither-*.json/txt"
else
    print_warning "Slither not found - attempting Hardhat Slither plugin..."
    if npx hardhat slither > reports/security/hardhat-slither-report.txt 2>&1; then
        print_success "Hardhat Slither analysis completed"
    else
        print_warning "Hardhat Slither had issues - check reports/security/hardhat-slither-report.txt"
    fi
fi

# 3. Check for MythX availability
print_status "Checking for MythX tools..."
if command -v mythos &> /dev/null; then
    print_status "Running MythX analysis..."
    print_warning "Note: MythX requires an API key. Set MYTHX_API_KEY environment variable."
    if [ -n "$MYTHX_API_KEY" ]; then
        mythos analyze contracts/ --timeout 600 --output reports/security/mythx-report.json || true
        print_success "MythX analysis completed"
    else
        print_warning "MYTHX_API_KEY not set - skipping MythX analysis"
        echo "To use MythX, set your API key: export MYTHX_API_KEY=your_api_key_here"
    fi
else
    print_warning "MythX tools not found - skipping MythX analysis"
fi

# 4. Generate summary report
print_status "Generating security summary report..."
{
    echo "# Smart Contract Security Analysis Report"
    echo "Generated on: $(date)"
    echo ""
    
    echo "## Contracts Analyzed"
    find contracts -name "*.sol" -not -path "*/node_modules/*" | while read -r file; do
        echo "- $file"
    done
    echo ""
    
    echo "## Analysis Tools Used"
    echo "- ✅ Solhint (Code quality and security linting)"
    
    if [ -f "reports/security/slither-report.json" ] || [ -f "reports/security/hardhat-slither-report.txt" ]; then
        echo "- ✅ Slither (Static analysis for vulnerability detection)"
    else
        echo "- ❌ Slither (Not available)"
    fi
    
    if [ -f "reports/security/mythx-report.json" ]; then
        echo "- ✅ MythX (Advanced security analysis)"
    else
        echo "- ❌ MythX (Not configured or not available)"
    fi
    
    echo ""
    echo "## Quick Results Summary"
    
    if [ -f "reports/security/solhint-report.txt" ]; then
        echo "### Solhint Results"
        if grep -q "error" reports/security/solhint-report.txt; then
            echo "- ⚠️  Issues found - see detailed report"
        else
            echo "- ✅ No critical issues found"
        fi
    fi
    
    echo ""
    echo "## Detailed Reports"
    echo "- Solhint: reports/security/solhint-report.txt"
    [ -f "reports/security/slither-report.json" ] && echo "- Slither: reports/security/slither-report.json"
    [ -f "reports/security/hardhat-slither-report.txt" ] && echo "- Hardhat Slither: reports/security/hardhat-slither-report.txt"
    [ -f "reports/security/mythx-report.json" ] && echo "- MythX: reports/security/mythx-report.json"
    
    echo ""
    echo "## Recommendations"
    echo "1. Review all flagged issues in the detailed reports"
    echo "2. Fix high and medium severity vulnerabilities immediately"
    echo "3. Consider gas optimizations for efficiency improvements"
    echo "4. Run security analysis after every major code change"
    echo "5. Consider professional audit for production deployment"
    
} > reports/security/security-summary.md

print_success "Security analysis completed!"
echo ""
echo "📊 Reports generated in reports/security/"
echo "📋 Summary: reports/security/security-summary.md"
echo ""
print_status "Next steps:"
echo "1. Review the security summary: cat reports/security/security-summary.md"
echo "2. Check individual tool reports for detailed findings"
echo "3. Fix any identified vulnerabilities"
echo "4. Re-run analysis after making changes"