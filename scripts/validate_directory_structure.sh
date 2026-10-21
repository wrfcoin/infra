#!/bin/bash
#
# WRFCoin Directory Structure Validation Script
# This script validates that the project follows the standardized directory structure
# and detects any unexpected top-level directories.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Expected top-level directories
EXPECTED_DIRS=(
    "backend"
    "blockchain-core" 
    "contracts"
    "frontend"
    "infra"
    "tests"
    "docs"
    "scripts"
    "security"
    "node_modules"
    ".git"
    ".github"
    ".taskmaster"
    ".claude"
    ".vscode"
    ".cursor"
    ".roo"
    ".serena"
    ".windsurf"
    ".trae"
    ".clinerules"
    ".gemini"
    ".memory"
    ".rag-cache"
    ".husky"
    "artifacts"
    "cache"
    "coverage"
    "dist"
    "logs"
    "target"
    "reports"
    "templates"
    "sdks"
    "archive"
    "configs"
)

# Expected top-level files (patterns)
EXPECTED_FILE_PATTERNS=(
    "*.md"
    "*.json"
    "*.js"
    "*.ts"
    "*.yml"
    "*.yaml"
    "*.toml"
    "*.lock"
    "*.html"
    "*.png"
    "*.jpg"
    "*.jpeg"
    "*.svg"
    "*.pdf"
    "*.txt"
    "*.sh"
    ".*"
    "LICENSE"
    "CODEOWNERS"
)

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

echo -e "${GREEN}WRFCoin Directory Structure Validation${NC}"
echo "========================================"
echo "Project root: $PROJECT_ROOT"
echo ""

validation_errors=0
warnings=0

# Function to check if a directory name is expected
is_expected_dir() {
    local dir_name="$1"
    for expected in "${EXPECTED_DIRS[@]}"; do
        if [[ "$dir_name" == "$expected" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to check if a file matches expected patterns
is_expected_file() {
    local file_name="$1"
    for pattern in "${EXPECTED_FILE_PATTERNS[@]}"; do
        if [[ "$file_name" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# Check for unexpected top-level directories
echo "🔍 Checking for unexpected top-level directories..."
for item in */; do
    dir_name="${item%/}"
    if ! is_expected_dir "$dir_name"; then
        # Check if directory is git-ignored
        if git check-ignore "$dir_name" >/dev/null 2>&1; then
            echo -e "${YELLOW}⚠️  Git-ignored directory (legacy): $dir_name${NC}"
            echo "   This directory is ignored by git but still present"
            ((warnings++))
        else
            echo -e "${RED}❌ UNEXPECTED DIRECTORY: $dir_name${NC}"
            echo "   This directory should be moved to an appropriate location:"
            echo "   - Backend code → backend/"
            echo "   - Smart contracts → contracts/"
            echo "   - Tests → tests/"
            echo "   - Documentation → docs/"
            echo "   - Infrastructure → infra/"
            echo ""
            ((validation_errors++))
        fi
    fi
done

# Check for unexpected top-level files
echo "🔍 Checking for unexpected top-level files..."
for item in *; do
    if [[ -f "$item" ]]; then
        if ! is_expected_file "$item"; then
            echo -e "${YELLOW}⚠️  UNEXPECTED FILE: $item${NC}"
            echo "   Consider moving this file to an appropriate directory"
            echo ""
            ((warnings++))
        fi
    fi
done

# Validate expected directory structure exists
echo "🔍 Validating required directories exist..."
required_dirs=("backend" "blockchain-core" "contracts" "frontend" "infra" "tests" "docs")
for dir in "${required_dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}❌ MISSING REQUIRED DIRECTORY: $dir${NC}"
        ((validation_errors++))
    else
        echo -e "${GREEN}✅ $dir${NC}"
    fi
done

# Validate subdirectory structure
echo ""
echo "🔍 Validating subdirectory structure..."

# Check infra subdirectories
if [[ -d "infra" ]]; then
    expected_infra_subdirs=("docker" "terraform" "helm" "k8s" "monitoring" "deployment")
    for subdir in "${expected_infra_subdirs[@]}"; do
        if [[ ! -d "infra/$subdir" ]]; then
            echo -e "${YELLOW}⚠️  Missing infra subdirectory: infra/$subdir${NC}"
            ((warnings++))
        fi
    done
fi

# Check tests subdirectories  
if [[ -d "tests" ]]; then
    expected_test_subdirs=("unit" "integration" "e2e" "fuzz" "performance" "archive")
    for subdir in "${expected_test_subdirs[@]}"; do
        if [[ ! -d "tests/$subdir" ]]; then
            echo -e "${YELLOW}⚠️  Missing tests subdirectory: tests/$subdir${NC}"
            ((warnings++))
        fi
    done
fi

# Check docs subdirectories
if [[ -d "docs" ]]; then
    expected_docs_subdirs=("architecture" "api" "security" "development" "user-guides" "specifications" "visualization" "testing")
    for subdir in "${expected_docs_subdirs[@]}"; do
        if [[ ! -d "docs/$subdir" ]]; then
            echo -e "${YELLOW}⚠️  Missing docs subdirectory: docs/$subdir${NC}"
            ((warnings++))
        fi
    done
fi

# Summary
echo ""
echo "========================================="
echo "VALIDATION SUMMARY"
echo "========================================="

if [[ $validation_errors -eq 0 && $warnings -eq 0 ]]; then
    echo -e "${GREEN}✅ VALIDATION PASSED: Directory structure is compliant${NC}"
    exit 0
elif [[ $validation_errors -eq 0 ]]; then
    echo -e "${YELLOW}⚠️  VALIDATION PASSED WITH WARNINGS: $warnings warnings found${NC}"
    echo "Consider addressing the warnings above for optimal organization."
    exit 0
else
    echo -e "${RED}❌ VALIDATION FAILED: $validation_errors errors found${NC}"
    if [[ $warnings -gt 0 ]]; then
        echo -e "${YELLOW}Additionally, $warnings warnings were found${NC}"
    fi
    echo ""
    echo "Please address the errors above before proceeding."
    echo "Run this script again after making corrections."
    exit 1
fi