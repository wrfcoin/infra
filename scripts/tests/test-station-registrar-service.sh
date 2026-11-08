#!/usr/bin/env bash
# CI entrypoint (scripts-tests.yml runs the reviewed shell suites): the station
# registrar service's own tests. No dependencies, no network, no keys: the core4
# CLI and the node are stand-ins.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v node >/dev/null || { echo "node is required" >&2; exit 1; }
cd "$TASK_REPO/testnet/services/station-registrar"
exec node --test
