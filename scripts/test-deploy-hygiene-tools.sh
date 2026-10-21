#!/usr/bin/env bash
# Validate deploy hygiene scripts without requiring a live testnet.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-deploy-hygiene-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFLIGHT="${REPO_ROOT}/testnet/scripts/deploy-hygiene-preflight.sh"
SNAPSHOT="${REPO_ROOT}/testnet/scripts/deploy-status-snapshot.sh"
COMPOSE_FILE="${REPO_ROOT}/testnet/docker-compose.testnet.yml"
OVERRIDE_FILE="${REPO_ROOT}/testnet/docker-compose.override.yml"
SEED_RENDER="${ROOT}/seed-compose.json"

for script in "$PREFLIGHT" "$SNAPSHOT"; do
  if [[ ! -f "$script" ]]; then
    echo "FAIL: missing $script"
    exit 1
  fi
  bash -n "$script"
done

grep -A5 '^  softhsm-init:' "$COMPOSE_FILE" | grep -q 'user: "1001:1001"' || {
  echo "FAIL: softhsm-init does not run as the application volume owner"
  exit 1
}

grep -A8 '^  softhsm-seed-init:' "$COMPOSE_FILE" | grep -q 'profiles: \["seed"\]' || {
  echo "FAIL: softhsm-seed-init is not scoped to the seed profile"
  exit 1
}

grep -A9 '^  softhsm-seed-init:' "$COMPOSE_FILE" | grep -q 'user: "1001:1001"' || {
  echo "FAIL: softhsm-seed-init does not run as the application volume owner"
  exit 1
}

grep -A80 '^  softhsm-seed-init:' "$COMPOSE_FILE" | grep -q 'seed-data:/app/data' || {
  echo "FAIL: softhsm-seed-init does not bootstrap the seed-data volume"
  exit 1
}

grep -A8 '^  softhsm-seed-init:' "$OVERRIDE_FILE" | grep -q 'wrfcoin/native-chain:testnet-local' || {
  echo "FAIL: softhsm-seed-init does not use the local native-chain build override"
  exit 1
}

grep -A12 '^  wrfcoin-seed:' "$OVERRIDE_FILE" | grep -q 'security_opt: !reset \[\]' || {
  echo "FAIL: wrfcoin-seed override does not reset no-new-privileges for gosu"
  exit 1
}

grep -A16 '^  wrfcoin-seed:' "$OVERRIDE_FILE" | grep -q 'SETUID' || {
  echo "FAIL: wrfcoin-seed override does not add SETUID for gosu"
  exit 1
}

grep -A16 '^  wrfcoin-seed:' "$OVERRIDE_FILE" | grep -q 'SETGID' || {
  echo "FAIL: wrfcoin-seed override does not add SETGID for gosu"
  exit 1
}

POSTGRES_PASSWORD=dummy REDIS_PASSWORD=dummy JWT_SECRET=dummy-jwt \
  OAUTH_STATE_SECRET=dummy-oauth GRAFANA_ADMIN_PASSWORD=dummy-grafana \
  RPC_API_KEY=dummy-rpc ADMIN_TOKEN=dummy-admin N8N_WEBHOOK_SECRET=dummy-n8n \
  WRFCOIN_OPERATOR_TOKEN=dummy-operator \
  WRFCOIN_CONTRIBUTOR_TOKEN=dummy-contributor \
  WRFCOIN_HSM_TOKEN_LABEL=dummy-token WRFCOIN_HSM_PIN=dummy-pin \
  WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000 \
  WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000 \
  bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile seed \
    -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" \
    -f "${REPO_ROOT}/testnet/docker-compose.yubikey.n5.yml" \
    config --format json > "$SEED_RENDER"

python3 - "$SEED_RENDER" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    compose = json.load(handle)

services = compose["services"]
seed_init = services["softhsm-seed-init"]
seed = services["wrfcoin-seed"]

assert seed_init["user"] == "1001:1001", seed_init.get("user")
assert seed_init["profiles"] == ["seed"], seed_init.get("profiles")
assert seed_init["image"] == "wrfcoin/native-chain:testnet-local", seed_init.get("image")
assert seed_init["volumes"][0]["source"].endswith("seed-data"), seed_init.get("volumes")
assert seed_init["volumes"][0]["target"] == "/app/data", seed_init.get("volumes")

depends_on = seed["depends_on"]
assert depends_on["softhsm-seed-init"]["condition"] == "service_healthy", depends_on
assert seed.get("security_opt") is None, seed.get("security_opt")
cap_add = set(seed["cap_add"])
assert {"NET_BIND_SERVICE", "SETUID", "SETGID"}.issubset(cap_add), cap_add
PY

make_repo() {
  local name="$1"
  local origin="${ROOT}/${name}.git"
  local clone="${ROOT}/src/${name}"

  git init --bare --initial-branch=main "$origin" >/dev/null
  git clone "$origin" "$clone" >/dev/null 2>&1
  git -C "$clone" switch -c main >/dev/null 2>&1
  printf '%s\n' "$name" > "${clone}/README.md"
  git -C "$clone" add README.md
  git -C "$clone" -c user.name='WRFCoin Test' -c user.email='test@example.invalid' \
    commit -m "Initial ${name}" >/dev/null
  git -C "$clone" push -u origin main >/dev/null 2>&1
}

mkdir -p "${ROOT}/src"
for repo in infra backend core4 frontend; do
  make_repo "$repo"
done

WRFCOIN_ROOT="${ROOT}/src" DEPLOY_BRANCH=main bash "$PREFLIGHT"

printf 'dirty\n' > "${ROOT}/src/backend/untracked.txt"
if WRFCOIN_ROOT="${ROOT}/src" DEPLOY_BRANCH=main bash "$PREFLIGHT" >"${ROOT}/dirty-preflight.out" 2>&1; then
  echo "FAIL: preflight passed with dirty backend checkout"
  exit 1
fi
grep -q 'FAIL backend: working tree has local changes' "${ROOT}/dirty-preflight.out"
rm "${ROOT}/src/backend/untracked.txt"

git -C "${ROOT}/src/core4" checkout --detach HEAD >/dev/null 2>&1
if WRFCOIN_ROOT="${ROOT}/src" DEPLOY_BRANCH=main bash "$PREFLIGHT" >"${ROOT}/detached-preflight.out" 2>&1; then
  echo "FAIL: preflight passed with detached core4 checkout"
  exit 1
fi
grep -q 'FAIL core4: detached HEAD' "${ROOT}/detached-preflight.out"
git -C "${ROOT}/src/core4" switch main >/dev/null 2>&1

WRFCOIN_ROOT="${ROOT}/src" TESTNET_DIR="${ROOT}/missing-testnet" \
  NODE_NAME=unit-test bash "$SNAPSHOT" > "${ROOT}/snapshot.json"

python3 - "${ROOT}/snapshot.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    snapshot = json.load(handle)

assert snapshot["schema"] == "wrfcoin.testnet.deploy_status_snapshot.v1"
assert len(snapshot["source_repos"]) == 4
for repo in snapshot["source_repos"]:
    assert repo["exists"], repo
    assert repo["branch"] == "main", repo
    assert repo["dirty"] is False, repo
    assert repo["ahead"] == 0, repo
    assert repo["behind"] == 0, repo
assert snapshot["compose"]["available"] is False
PY

echo "PASS: deploy hygiene tools validate"
