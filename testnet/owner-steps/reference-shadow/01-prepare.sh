#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then echo 'STOP: expected absolute config and new receipt paths' >&2; exit 1; fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec python3 "$root/scripts/check-reference-shadow.py" prepare --config "$1" --receipt "$2"
