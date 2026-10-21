#!/usr/bin/env bash
# CI entrypoint for the OPT-IN real-CLI activation test. Exits 77 (UNVERIFIED, counted
# separately by scripts-tests.yml, not a pass) unless WRFCOIN_REAL_CLI names the binary.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$TASK_REPO/testnet/tests/test_real_cli_activation.sh"
