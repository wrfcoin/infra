#!/usr/bin/env bash
# Offline owner-command corpus for --source website. Every external command is a fake.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 "$TASK_REPO/scripts/tests/website-station-activation-fixtures.py" "$TASK_REPO"
