#!/usr/bin/env bash
# The block-producing synthetic collector must refuse a missing payout before
# waiting for the node or making any HTTP request. This executes the production
# entrypoint; it is not a source grep.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/testnet/services/synthetic-collector/submit-synthetic-contribution.cjs"

output="$({
  env -u SYNTH_MINER_ADDRESS \
    WRFCOIN_OPERATOR_TOKEN=test-only \
    WRFCOIN_CONTRIBUTOR_TOKEN=contributor-test-only \
    WRFCOIN_API_HOST=127.0.0.1 \
    WRFCOIN_API_PORT=9 \
    SYNTH_INTERVAL_SECONDS=0 \
    node "${SCRIPT}"
} 2>&1)"
rc=$?

if [[ ${rc} -eq 0 ]]; then
  echo "FAIL: synthetic collector accepted a missing SYNTH_MINER_ADDRESS" >&2
  exit 1
fi
if [[ "${output}" != *"SYNTH_MINER_ADDRESS must be a 20-byte 0x-prefixed address"* ]]; then
  echo "FAIL: missing miner address did not produce the expected fatal diagnostic" >&2
  echo "${output}" >&2
  exit 1
fi
if [[ "${output}" == *"waiting for node"* ]]; then
  echo "FAIL: collector touched the network path before validating its miner address" >&2
  exit 1
fi

echo "PASS: synthetic collector fails closed before network work"
