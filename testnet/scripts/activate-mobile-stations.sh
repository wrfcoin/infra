#!/usr/bin/env bash
# OWNER ONLY: signs and submits. Defaults/runbook: docs/MOBILE_STATION_ACTIVATION.md.
set +x
set -euo pipefail
TASK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$TASK_SCRIPT_DIR/activate-mobile-stations.py" "$@"
