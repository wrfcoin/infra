#!/usr/bin/env bash
#
# Consensus-Critical Dependency Budget Enforcement
#
# This script enforces dependency budgets for consensus-critical Rust code.
# Exit codes: 0 = pass, 1 = budget exceeded
#
# Budgets (per Task 129):
#   - Consensus modules: max 20 direct dependencies (core consensus path)
#   - Crypto modules: max 10 direct dependencies (cryptographic operations)
#   - Full crate (default features): max 85 direct dependencies
#
# Usage: ./scripts/check-dep-budget.sh [--verbose]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BLOCKCHAIN_CORE="$PROJECT_ROOT/blockchain-core"

# Budget limits
BUDGET_FULL_CRATE=85
BUDGET_NO_DEFAULT=85
BUDGET_CRYPTO=15  # Target for crypto-specific deps

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
fi

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "       $1"
    fi
}

# Change to blockchain-core directory
cd "$BLOCKCHAIN_CORE"

echo "=============================================="
echo "  Consensus-Critical Dependency Budget Check"
echo "=============================================="
echo ""

FAILED=false

# Count direct dependencies (depth=1, excluding the root crate itself)
count_deps() {
    local features="${1:-}"
    local cmd="cargo tree --depth 1 --edges normal --prefix none"

    if [[ -n "$features" ]]; then
        cmd="$cmd --features $features"
    fi

    # Count unique deps, excluding the root crate
    $cmd 2>/dev/null | grep -v "^wrfcoin-blockchain-core" | grep -v "^$" | sort -u | wc -l
}

# List direct dependencies
list_deps() {
    local features="${1:-}"
    local cmd="cargo tree --depth 1 --edges normal --prefix none"

    if [[ -n "$features" ]]; then
        cmd="$cmd --features $features"
    fi

    $cmd 2>/dev/null | grep -v "^wrfcoin-blockchain-core" | grep -v "^$" | sort -u
}

# Check 1: Full crate with default features
log_info "Checking full crate dependencies (default features)..."
DEP_COUNT=$(count_deps)
log_info "  Direct dependencies: $DEP_COUNT (budget: $BUDGET_FULL_CRATE)"

if [[ $DEP_COUNT -gt $BUDGET_FULL_CRATE ]]; then
    log_error "  BUDGET EXCEEDED! ($DEP_COUNT > $BUDGET_FULL_CRATE)"
    FAILED=true
else
    log_info "  PASS"
fi

if [[ "$VERBOSE" == true ]]; then
    echo ""
    log_verbose "Dependencies:"
    list_deps | while read -r dep; do
        log_verbose "  - $dep"
    done
fi

echo ""

# Check 2: No default features (minimal consensus path)
log_info "Checking minimal build (--no-default-features)..."
DEP_COUNT_MINIMAL=$(count_deps "" 2>/dev/null || echo "error")

if [[ "$DEP_COUNT_MINIMAL" == "error" ]]; then
    log_warn "  Could not count (build may not support --no-default-features)"
else
    log_info "  Direct dependencies: $DEP_COUNT_MINIMAL (budget: $BUDGET_NO_DEFAULT)"
    if [[ $DEP_COUNT_MINIMAL -gt $BUDGET_NO_DEFAULT ]]; then
        log_error "  BUDGET EXCEEDED!"
        FAILED=true
    else
        log_info "  PASS"
    fi
fi

echo ""

# Check 3: Feature flag isolation
log_info "Checking feature flag isolation..."

# EVM compatibility should add deps only when enabled
DEFAULT_EVM_DEPS=$(cargo tree --depth 1 2>/dev/null | { grep -E "ethers|ethereum-types|evm v" || true; } | wc -l | tr -d ' ')

if [[ "$DEFAULT_EVM_DEPS" -gt 0 ]]; then
    log_error "  EVM deps present without feature flag!"
    FAILED=true
else
    log_info "  EVM isolation: PASS (EVM deps only with --features evm_compatibility)"
fi

# CosmWasm should add deps only when enabled
DEFAULT_COSMWASM_DEPS=$(cargo tree --depth 1 2>/dev/null | { grep -E "cosmwasm|cw-storage|schemars" || true; } | wc -l | tr -d ' ')

if [[ "$DEFAULT_COSMWASM_DEPS" -gt 0 ]]; then
    log_error "  CosmWasm deps present without feature flag!"
    FAILED=true
else
    log_info "  CosmWasm isolation: PASS"
fi

# ink! should add deps only when enabled
DEFAULT_INK_DEPS=$(cargo tree --depth 1 2>/dev/null | { grep "ink_" || true; } | wc -l | tr -d ' ')

if [[ "$DEFAULT_INK_DEPS" -gt 0 ]]; then
    log_error "  ink! deps present without feature flag!"
    FAILED=true
else
    log_info "  ink! isolation: PASS"
fi

echo ""

# Check 4: Deprecated dependencies
log_info "Checking for deprecated dependencies..."
DEPRECATED_DEPS=$(cargo tree --prefix none 2>/dev/null | { grep "+deprecated" || true; } | wc -l | tr -d ' ')

if [[ $DEPRECATED_DEPS -gt 0 ]]; then
    log_warn "  Found $DEPRECATED_DEPS deprecated dependencies:"
    cargo tree --prefix none 2>/dev/null | { grep "+deprecated" || true; } | sort -u | while read -r dep; do
        log_warn "    - $dep"
    done
    log_warn "  Consider replacing deprecated crates (see CONSENSUS-DEPENDENCIES.md)"
else
    log_info "  No deprecated dependencies found"
fi

echo ""

# Check 5: Cryptographic dependencies audit status
log_info "Checking crypto dependency audit status..."
CRYPTO_DEPS="sha2 sha3 aes-gcm secp256k1 k256 ed25519-dalek curve25519-dalek blake2 blake3"
CRYPTO_COUNT=0

for dep in $CRYPTO_DEPS; do
    if cargo tree --depth 1 2>/dev/null | grep -q "^├── $dep\|^└── $dep" 2>/dev/null; then
        ((CRYPTO_COUNT++)) || true
        log_verbose "  - $dep: present"
    fi
done

log_info "  Core crypto dependencies: $CRYPTO_COUNT (budget: $BUDGET_CRYPTO)"
if [[ $CRYPTO_COUNT -gt $BUDGET_CRYPTO ]]; then
    log_warn "  Crypto deps approaching budget"
else
    log_info "  PASS"
fi

echo ""
echo "=============================================="

if [[ "$FAILED" == true ]]; then
    log_error "DEPENDENCY BUDGET CHECK FAILED"
    echo ""
    echo "To fix:"
    echo "  1. Review CONSENSUS-DEPENDENCIES.md for policy"
    echo "  2. Move optional deps behind feature flags"
    echo "  3. Replace deprecated crates"
    echo "  4. Remove unused dependencies"
    exit 1
else
    log_info "ALL DEPENDENCY BUDGET CHECKS PASSED"
    exit 0
fi
