#!/usr/bin/env bash
# Render-only root selection and systemd template controls. No daemon access.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/tests/test-deploy-roots.py"
