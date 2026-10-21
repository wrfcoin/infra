#!/usr/bin/env bash
# =============================================================================
# Testnet TDD Test Suite Runner
#
# Executes all TDD test scripts and generates a summary report.
#
# Usage:
#   bash testnet/scripts/tdd/run-all.sh
#
# Exit codes:
#   0 = all tests passed
#   1 = at least one test failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

print_header() {
  printf '\n'
  printf '=%.0s' {1..75}
  printf '\n'
  printf '%s\n' "$1"
  printf '=%.0s' {1..75}
  printf '\n'
}

run_test() {
  local test_name="$1"
  local test_script="$2"

  TOTAL_TESTS=$((TOTAL_TESTS + 1))

  if [ ! -f "$test_script" ]; then
    printf 'SKIP %s (not found: %s)\n' "$test_name" "$test_script"
    return 0
  fi

  if [ ! -x "$test_script" ]; then
    chmod +x "$test_script"
  fi

  printf '\n>>> Running: %s\n' "$test_name"
  printf '>>> Script: %s\n\n' "$test_script"

  if bash "$test_script"; then
    PASSED_TESTS=$((PASSED_TESTS + 1))
    printf '✓ PASSED: %s\n' "$test_name"
    return 0
  else
    FAILED_TESTS=$((FAILED_TESTS + 1))
    printf '✗ FAILED: %s\n' "$test_name"
    return 1
  fi
}

main() {
  print_header "Testnet TDD Test Suite"

  run_test "Credential Smoke Test" "${SCRIPT_DIR}/credential-smoke.sh" || true
  run_test "Cold-Start Smoke Test" "${SCRIPT_DIR}/cold-start-smoke.sh" || true
  run_test "Dependency Chain Test" "${SCRIPT_DIR}/dependency-chain.sh" || true

  # Summary
  print_header "Test Summary"
  printf 'Total:  %d\n' "$TOTAL_TESTS"
  printf 'Passed: %d\n' "$PASSED_TESTS"
  printf 'Failed: %d\n' "$FAILED_TESTS"
  printf '\n'

  if [ "$FAILED_TESTS" -eq 0 ]; then
    printf '✓ ALL TESTS PASSED\n\n'
    return 0
  else
    printf '✗ SOME TESTS FAILED\n\n'
    return 1
  fi
}

main "$@"
