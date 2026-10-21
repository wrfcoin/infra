#!/bin/bash
#
# WRFCoin Codebase Index Generator
# Automatically generates CODEBASE_INDEX.md with complete project structure
#

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_FILE="$PROJECT_ROOT/CODEBASE_INDEX.md"

cd "$PROJECT_ROOT"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}Generating CODEBASE_INDEX.md...${NC}"

# Start writing the index file
cat > "$OUTPUT_FILE" << 'EOF'
# WRFCoin Codebase Index

> 🔄 **Auto-generated file** - Last updated: $(date '+%Y-%m-%d %H:%M:%S UTC')
> 
> This file provides a comprehensive overview of the WRFCoin project structure.
> **Do not edit manually** - regenerate using `./scripts/generate_codebase_index.sh`

## Table of Contents

- [Project Overview](#project-overview)
- [Directory Structure](#directory-structure)
- [Core Components](#core-components)
- [Configuration Files](#configuration-files)
- [Documentation](#documentation)
- [Testing](#testing)
- [Development Tools](#development-tools)

## Project Overview

WRFCoin is a comprehensive weather forecasting blockchain platform that combines climate data collection, carbon credit trading, and DeFi features.

### Technology Stack
- **Blockchain Core**: Rust (quantum-resistant cryptography, AI/ML integration)
- **Backend Services**: Node.js/TypeScript (15+ microservices)
- **Frontend**: React/TypeScript with Vite
- **Smart Contracts**: Solidity (DeFi suite, NFTs, governance)
- **Infrastructure**: Docker/Kubernetes, monitoring systems

---

## Directory Structure

EOF

# Function to get directory tree with file counts
generate_tree() {
    local dir="$1"
    local prefix="$2"
    local max_depth="${3:-3}"
    
    if [[ $max_depth -le 0 ]]; then
        return
    fi
    
    if [[ ! -d "$dir" ]]; then
        return
    fi
    
    local file_count=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
    local dir_count=$(find "$dir" -maxdepth 1 -type d 2>/dev/null | grep -v "^$dir$" | wc -l)
    
    echo "${prefix}📁 **$(basename "$dir")/** (${file_count} files, ${dir_count} subdirs)"
    
    # List key files and subdirectories
    find "$dir" -maxdepth 1 -type d 2>/dev/null | grep -v "^$dir$" | sort | while read -r subdir; do
        if [[ $(basename "$subdir") != "node_modules" && $(basename "$subdir") != ".git" && $(basename "$subdir") != "target" ]]; then
            generate_tree "$subdir" "${prefix}  " $((max_depth - 1))
        fi
    done
    
    # List important files
    find "$dir" -maxdepth 1 -type f 2>/dev/null | grep -E '\.(md|js|ts|rs|sol|json|yml|yaml|toml)$' | sort | head -10 | while read -r file; do
        echo "${prefix}  📄 $(basename "$file")"
    done
}

# Generate main directory structure
echo "### Main Directories" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

for dir in backend blockchain-core contracts frontend infra tests docs scripts security; do
    if [[ -d "$dir" ]]; then
        echo "Scanning $dir..." >&2
        generate_tree "$dir" "" 2 >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    fi
done

# Core components section
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Core Components

### 🔗 Blockchain Core (`blockchain-core/`)
- **Language**: Rust
- **Features**: Quantum-resistant cryptography, consensus mechanisms, cross-chain bridges
- **Key Modules**: consensus, crypto, cross_chain, governance, mining, nft

### 🏗️ Backend Services (`backend/`)
- **Language**: Node.js/TypeScript  
- **Architecture**: Microservices (15+ services)
- **Key Services**: API server, cross-chain protocol, wallet service, IoT networks
- **Ports**: 3000-9001 (see CLAUDE.md for full port registry)

### 🎨 Frontend (`frontend/`)
- **Framework**: React + TypeScript + Vite
- **Features**: Real-time dashboards, NFT marketplace, DeFi trading interface
- **Components**: Weather data visualization, governance tools, carbon credit trading

### 📜 Smart Contracts (`contracts/`)
- **Language**: Solidity
- **Features**: DeFi suite (AMM, yield farming), carbon credit trading, computational NFTs
- **Governance**: DAO proposals, treasury management, voting mechanisms

### 🏗️ Infrastructure (`infra/`)
- **Orchestration**: Docker Compose, Kubernetes manifests
- **Monitoring**: Grafana, Prometheus, custom metrics
- **Deployment**: Multi-environment configs, CI/CD pipelines

---

## Configuration Files

EOF

# Add configuration files section
echo "### Root Configuration Files" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

find . -maxdepth 1 -type f -name "*.json" -o -name "*.js" -o -name "*.ts" -o -name "*.yml" -o -name "*.yaml" -o -name "*.toml" -o -name "*.config.*" | sort | while read -r file; do
    filename=$(basename "$file")
    case "$filename" in
        "package.json") echo "- **$filename**: Node.js dependencies and scripts" ;;
        "tsconfig.json") echo "- **$filename**: TypeScript compiler configuration" ;;
        "hardhat.config.js") echo "- **$filename**: Hardhat smart contract framework config" ;;
        "docker-compose.yml") echo "- **$filename**: Docker services orchestration" ;;
        "Cargo.toml") echo "- **$filename**: Rust workspace configuration" ;;
        "jest.config.js") echo "- **$filename**: Jest testing framework configuration" ;;
        "eslint.config.js") echo "- **$filename**: ESLint code quality rules" ;;
        "playwright.config.js") echo "- **$filename**: Playwright end-to-end testing config" ;;
        *) echo "- **$filename**: Configuration file" ;;
    esac
done >> "$OUTPUT_FILE"

# Documentation section
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Documentation

### 📚 Main Documentation (`docs/`)
EOF

if [[ -d "docs" ]]; then
    find docs -name "*.md" | sort | while read -r file; do
        echo "- **$(basename "$file")**: $(head -n 1 "$file" 2>/dev/null | sed 's/^#*\s*//' || echo "Documentation file")" >> "$OUTPUT_FILE"
    done
fi

# Add root level docs
echo "" >> "$OUTPUT_FILE"
echo "### 📋 Root Documentation" >> "$OUTPUT_FILE"
find . -maxdepth 1 -name "*.md" | sort | while read -r file; do
    filename=$(basename "$file")
    if [[ "$filename" != "CODEBASE_INDEX.md" ]]; then
        first_line=$(head -n 1 "$file" 2>/dev/null | sed 's/^#*\s*//' || echo "Documentation file")
        echo "- **$filename**: $first_line" >> "$OUTPUT_FILE"
    fi
done

# Testing section  
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Testing

### 🧪 Test Structure (`tests/`)
EOF

if [[ -d "tests" ]]; then
    for test_dir in tests/*/; do
        if [[ -d "$test_dir" ]]; then
            dir_name=$(basename "$test_dir")
            test_count=$(find "$test_dir" -name "*.test.*" -o -name "*.spec.*" | wc -l)
            echo "- **$dir_name/**: $test_count test files" >> "$OUTPUT_FILE"
        fi
    done
fi

# Add other test directories
for test_dir in test consolidated-tests fuzz-testing; do
    if [[ -d "$test_dir" ]]; then
        test_count=$(find "$test_dir" -name "*.test.*" -o -name "*.spec.*" | wc -l)
        echo "- **$test_dir/**: $test_count test files (legacy location)" >> "$OUTPUT_FILE"
    fi
done

# Development tools section
cat >> "$OUTPUT_FILE" << 'EOF'

---

## Development Tools

### 🛠️ Scripts (`scripts/`)
EOF

if [[ -d "scripts" ]]; then
    find scripts -name "*.js" -o -name "*.sh" -o -name "*.py" | sort | while read -r file; do
        filename=$(basename "$file")
        # Try to get description from first comment line
        description=$(grep -m 1 -E "^#.*|^//.*|^\/\*.*" "$file" 2>/dev/null | sed 's/^[#\/\*]*\s*//' | sed 's/\*\///' || echo "Development script")
        echo "- **$filename**: $description" >> "$OUTPUT_FILE"
    done
fi

cat >> "$OUTPUT_FILE" << 'EOF'

### 📋 Development Environment
- **Node.js**: v20+ required
- **Rust**: v1.70+ required  
- **Database**: PostgreSQL 15+ with Redis 7+
- **Container**: Docker & Docker Compose

### 🔧 Key Commands
```bash
# Start all services
docker-compose up -d

# Run tests
npm test

# Build blockchain core
cd blockchain-core && cargo build

# Deploy contracts
npx hardhat deploy

# Start development
npm run dev
```

---

## File Statistics

EOF

# Generate file statistics
echo "### 📊 Project Statistics" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

total_files=$(find . -type f -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./target/*" | wc -l)
echo "- **Total Files**: $total_files" >> "$OUTPUT_FILE"

# Count by file type
echo "- **By File Type**:" >> "$OUTPUT_FILE"
for ext in rs ts js sol md json yml yaml toml; do
    count=$(find . -name "*.$ext" -not -path "./node_modules/*" -not -path "./.git/*" -not -path "./target/*" | wc -l)
    if [[ $count -gt 0 ]]; then
        echo "  - .$ext files: $count" >> "$OUTPUT_FILE"
    fi
done

# Count by directory
echo "- **By Main Directory**:" >> "$OUTPUT_FILE"
for dir in backend blockchain-core contracts frontend infra tests docs scripts; do
    if [[ -d "$dir" ]]; then
        count=$(find "$dir" -type f | wc -l)
        echo "  - $dir/: $count files" >> "$OUTPUT_FILE"
    fi
done

cat >> "$OUTPUT_FILE" << 'EOF'

---

## Quick Navigation

### 🚀 Getting Started
1. Read [README.md](./README.md) for project overview
2. Check [CLAUDE.md](./CLAUDE.md) for development guide  
3. Review [docs/getting-started.md](./docs/getting-started.md) for setup

### 🔍 Find Code
- **Backend APIs**: `backend/api/` and `backend/routes/`
- **Blockchain Logic**: `blockchain-core/` (Rust modules)
- **Smart Contracts**: `contracts/` (Solidity files)
- **Frontend Components**: `frontend/src/`
- **Tests**: `tests/` (organized by type)

### 🏗️ Infrastructure  
- **Docker**: `docker-compose.yml` and `infra/docker/`
- **Monitoring**: `docker-compose.monitoring.yml`
- **Scripts**: `scripts/` (deployment, utilities)

---

*Generated automatically by `./scripts/generate_codebase_index.sh`*
*Last update: $(date '+%Y-%m-%d %H:%M:%S UTC')*
EOF

# Replace the date placeholder with actual date
sed -i "s/\$(date '+%Y-%m-%d %H:%M:%S UTC')/$(date '+%Y-%m-%d %H:%M:%S UTC')/g" "$OUTPUT_FILE"

echo -e "${GREEN}✅ CODEBASE_INDEX.md generated successfully!${NC}"
echo -e "${BLUE}📄 Output: $OUTPUT_FILE${NC}"
echo -e "${BLUE}📊 Total lines: $(wc -l < "$OUTPUT_FILE")${NC}"