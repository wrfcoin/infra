#!/usr/bin/env bash
# =============================================================================
# Testnet Credential Smoke Test
#
# Verifies that backend can authenticate to Postgres, Redis, and the node.
# This test would have caught the Postgres credential mismatch bug that
# stopped the N5 Pro testnet deployment.
#
# Usage:
#   bash testnet/scripts/tdd/credential-smoke.sh
#
# Exit codes:
#   0 = all credentials verified
#   1 = at least one credential check failed
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

status_line() {
  local level="$1"
  shift
  printf '%-5s %s\n' "$level" "$*"
}

mark_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  status_line PASS "$*"
}

mark_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  status_line FAIL "$*"
}

# Check if containers are running
check_containers() {
  local container
  for container in wrfcoin-testnet-backend wrfcoin-testnet-postgres wrfcoin-testnet-redis; do
    if docker ps --filter "name=$container" --filter "status=running" --quiet | grep -q .; then
      mark_pass "Container running: $container"
    else
      mark_fail "Container not running: $container"
      return 1
    fi
  done
  return 0
}

# Test backend → postgres authentication
test_postgres_auth() {
  status_line INFO "Testing backend → Postgres authentication..."

  if ! docker ps --filter "name=wrfcoin-testnet-backend" --filter "status=running" --quiet | grep -q .; then
    mark_fail "Backend container not running"
    return 1
  fi

  # Try a simple query through the Node.js database connection
  if docker compose -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" 2>/dev/null \
    exec -T wrfcoin-backend node -e "
      const { Pool } = require('pg');
      const pool = new Pool({
        user: 'wrfcoin',
        password: process.env.POSTGRES_PASSWORD || 'wrfcoin',
        host: 'postgres',
        port: 5432,
        database: 'wrfcoin',
        idleTimeoutMillis: 30000,
        connectionTimeoutMillis: 5000,
      });
      pool.query('SELECT 1 as test')
        .then(() => { console.log('OK'); process.exit(0); })
        .catch((err) => { console.error(err.message); process.exit(1); });
    " > /dev/null 2>&1; then
    mark_pass "Backend can authenticate to Postgres"
    return 0
  else
    mark_fail "Backend cannot authenticate to Postgres (check DATABASE_URL and POSTGRES_PASSWORD)"
    return 1
  fi
}

# Test backend → redis authentication
test_redis_auth() {
  status_line INFO "Testing backend → Redis authentication..."

  if ! docker ps --filter "name=wrfcoin-testnet-redis" --filter "status=running" --quiet | grep -q .; then
    mark_fail "Redis container not running"
    return 1
  fi

  if docker compose -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" 2>/dev/null \
    exec -T wrfcoin-backend node -e "
      const redis = require('redis');
      const client = redis.createClient({
        host: 'redis',
        port: 6379,
        password: process.env.REDIS_PASSWORD || 'wrfcoin',
        socket: { connectTimeout: 5000 },
      });
      client.on('error', (err) => { console.error(err.message); process.exit(1); });
      client.connect()
        .then(() => client.ping())
        .then(() => { console.log('OK'); process.exit(0); })
        .catch((err) => { console.error(err.message); process.exit(1); });
    " > /dev/null 2>&1; then
    mark_pass "Backend can authenticate to Redis"
    return 0
  else
    mark_fail "Backend cannot authenticate to Redis (check REDIS_URL and REDIS_PASSWORD)"
    return 1
  fi
}

# Test node → RPC port reachability
test_node_rpc() {
  status_line INFO "Testing backend → Node RPC reachability..."

  if ! docker ps --filter "name=wrfcoin-testnet-node" --filter "status=running" --quiet | grep -q .; then
    mark_fail "Node container not running"
    return 1
  fi

  if docker compose -f "${TESTNET_DIR}/docker-compose.testnet.yml" \
    -f "${TESTNET_DIR}/docker-compose.override.yml" 2>/dev/null \
    exec -T wrfcoin-backend curl -sf http://wrfcoin-node:8556/node/sync/status > /dev/null 2>&1; then
    mark_pass "Backend can reach Node RPC port"
    return 0
  else
    mark_fail "Backend cannot reach Node RPC (check WRFCOIN_API_HOST and BLOCKCHAIN_NODE_URL)"
    return 1
  fi
}

main() {
  status_line INFO "Credential Smoke Test — Backend authentication verification"
  status_line INFO ""

  # Check if containers are running first
  if ! check_containers; then
    status_line WARN "Not all containers are running. Make sure docker compose stack is up:"
    status_line WARN "  cd testnet && docker compose up -d"
    echo ""
    status_line SUMMARY "FAIL — containers not running"
    return 1
  fi

  echo ""
  test_postgres_auth || true
  test_redis_auth || true
  test_node_rpc || true

  echo ""
  if [ "$FAIL_COUNT" -eq 0 ]; then
    status_line SUMMARY "PASS — all credentials verified"
    return 0
  else
    status_line SUMMARY "FAIL — $FAIL_COUNT credential check(s) failed"
    return 1
  fi
}

main "$@"
