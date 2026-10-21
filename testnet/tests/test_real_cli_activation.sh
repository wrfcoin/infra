#!/usr/bin/env bash
# Opt-in real-CLI test. Without WRFCOIN_REAL_CLI naming the binary it is SKIPPED:
# exit 77 ("could not check"), never 0, so a skip cannot read as coverage.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ -z "${WRFCOIN_REAL_CLI:-}" || ! -f "${WRFCOIN_REAL_CLI}" ]]; then
    echo "SKIPPED (not coverage): real-CLI activation test needs WRFCOIN_REAL_CLI=<pinned wrfcoin binary>"
    exit 77
fi
exec python3 test_real_cli_activation.py
