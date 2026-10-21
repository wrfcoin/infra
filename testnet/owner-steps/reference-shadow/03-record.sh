#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 ]]; then echo 'STOP: expected absolute config, prepared receipt and new evidence paths' >&2; exit 1; fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
exec python3 "$root/scripts/check-reference-shadow.py" record --config "$1" --receipt "$2" --evidence "$3"
