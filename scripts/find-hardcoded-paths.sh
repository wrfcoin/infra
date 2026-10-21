#!/bin/bash
# WRFCoin Hardcoded Paths Detection Script
# Scans codebase for hardcoded paths that should be parameterized
#
# Usage: ./scripts/find-hardcoded-paths.sh [--fix] [--ci]
#
# Options:
#   --fix    Attempt to auto-fix common patterns (creates .backup files)
#   --ci     Exit with error code if hardcoded paths are found

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Patterns to detect
HARDCODED_PATTERNS=(
    "/home/[^/]+"
    "/home/user"
    "/Users/"
    "C:\\\\Users\\\\"
    "192\\.168\\.[0-9]+\\.[0-9]+"  # Local IP addresses (excluding env files)
    "10\\.[0-9]+\\.[0-9]+\\.[0-9]+"  # Private IP addresses
)

# File patterns to scan
FILE_PATTERNS=(
    "*.ts"
    "*.js"
    "*.json"
    "*.sh"
    "*.md"
    "*.yaml"
    "*.yml"
    "*.toml"
    "*.env.example"
)

# Directories to exclude
EXCLUDE_DIRS=(
    ".git"
    "node_modules"
    "target"
    "dist"
    ".taskmaster"
    "sbom"
    ".claude"
    "coverage"
    ".turbo"
    "logs"
    "backups"
    "reports"
    ".next"
    ".vite"
    "__pycache__"
    ".zen_venv"
)

# Files to exclude (generated or expected to have paths)
EXCLUDE_FILES=(
    "*.cdx.json"
    "*.spdx.json"
    "package-lock.json"
    "yarn.lock"
    "Cargo.lock"
    "*.log"
    "*.log.*"
    "*-report.json"
    "*-inventory.json"
    "storybook-*.json"
    "component-*.json"
    "security-audit*.json"
    "smart-contracts-graph.json"
)

# Build exclude arguments for grep
build_exclude_args() {
    local args=""
    for dir in "${EXCLUDE_DIRS[@]}"; do
        args="$args --exclude-dir=$dir"
    done
    for file in "${EXCLUDE_FILES[@]}"; do
        args="$args --exclude=$file"
    done
    echo "$args"
}

# Count findings
TOTAL_FINDINGS=0
declare -A PATTERN_COUNTS

echo "=============================================="
echo "WRFCoin Hardcoded Paths Detection"
echo "=============================================="
echo ""
echo "Project Root: $PROJECT_ROOT"
echo "Scanning for hardcoded paths..."
echo ""

cd "$PROJECT_ROOT"

# Build exclude args
EXCLUDE_ARGS=$(build_exclude_args)

# Scan for each pattern
for pattern in "${HARDCODED_PATTERNS[@]}"; do
    echo -e "${YELLOW}Checking for pattern: ${pattern}${NC}"

    # Run grep with exclude patterns
    MATCHES=$(grep -r -n -E "$pattern" . $EXCLUDE_ARGS 2>/dev/null || true)

    if [ -n "$MATCHES" ]; then
        COUNT=$(echo "$MATCHES" | wc -l)
        PATTERN_COUNTS["$pattern"]=$COUNT
        TOTAL_FINDINGS=$((TOTAL_FINDINGS + COUNT))

        echo -e "${RED}Found $COUNT occurrences:${NC}"
        echo "$MATCHES" | head -20
        if [ $COUNT -gt 20 ]; then
            echo "... and $((COUNT - 20)) more"
        fi
        echo ""
    else
        echo -e "${GREEN}No matches found${NC}"
        echo ""
    fi
done

# Summary
echo "=============================================="
echo "Summary"
echo "=============================================="
echo ""

if [ $TOTAL_FINDINGS -eq 0 ]; then
    echo -e "${GREEN}No hardcoded paths detected!${NC}"
    exit 0
else
    echo -e "${RED}Total findings: $TOTAL_FINDINGS${NC}"
    echo ""
    echo "Breakdown by pattern:"
    for pattern in "${!PATTERN_COUNTS[@]}"; do
        echo "  $pattern: ${PATTERN_COUNTS[$pattern]} occurrences"
    done
    echo ""
    echo "Recommendations:"
    echo "  1. Replace absolute paths with environment variables"
    echo "  2. Use \${PROJECT_ROOT} or relative paths"
    echo "  3. Move IP addresses to .env files"
    echo "  4. Update .env.example with placeholder values"
    echo ""

    # CI mode - fail if findings exist
    if [ "$1" == "--ci" ]; then
        echo -e "${RED}CI check failed: Hardcoded paths detected${NC}"
        exit 1
    fi
fi

echo "=============================================="
echo "Scan complete"
echo "=============================================="
