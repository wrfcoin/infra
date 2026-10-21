#!/usr/bin/env bash
# CI entrypoint (scripts-tests.yml discovers scripts/tests/test-*.sh): the offline
# v2 activation controls (stub node, fake CLI, fake docker) and the producer fence.
set -euo pipefail
TASK_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$TASK_REPO/testnet/tests/test_activate_mobile_stations_v2.sh"
