#!/usr/bin/env bash
# activate-mobile-stations.py v2 registration format + fresh nonce reads, against a stubbed node.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
exec python3 test_activate_mobile_stations_v2.py
