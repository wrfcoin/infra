#!/usr/bin/env bash
# Offline end-to-end owner-command corpus. Every external command is a fake.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$TASK_REPO/scripts/tests/mobile-station-activation-fixtures.py" "$TASK_REPO"
