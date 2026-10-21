#!/usr/bin/env bash
# Canonical non-runtime testnet Compose render interface.
set -euo pipefail

# These documentation-only RFC 5737 addresses are deliberately forced for
# test rendering. Production Compose remains fail-closed with its `:?` guards.
export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000

exec docker compose "$@"
