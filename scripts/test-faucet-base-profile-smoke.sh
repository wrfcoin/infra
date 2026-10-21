#!/usr/bin/env bash
# Validate the base seed-profile faucet build context without pushing images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/testnet/docker-compose.testnet.yml"
RENDERED_CONFIG="$(mktemp "${TMPDIR:-/tmp}/faucet-base-profile.XXXXXX.json")"
trap 'rm -f "${RENDERED_CONFIG}"' EXIT

export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ci}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-ci}"
export WRFCOIN_OPERATOR_TOKEN="${WRFCOIN_OPERATOR_TOKEN:-ci}"
export WRFCOIN_CONTRIBUTOR_TOKEN="${WRFCOIN_CONTRIBUTOR_TOKEN:-contributor-ci}"
export JWT_SECRET="${JWT_SECRET:-ci}"
export OAUTH_STATE_SECRET="${OAUTH_STATE_SECRET:-ci}"
export RPC_API_KEY="${RPC_API_KEY:-ci}"
export ADMIN_TOKEN="${ADMIN_TOKEN:-ci}"
export N8N_WEBHOOK_SECRET="${N8N_WEBHOOK_SECRET:-ci}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-ci}"
# HSM PINs are now mandatory (no insecure defaults); supply CI placeholders so
# `docker compose config` interpolation succeeds during the smoke render.
export WRFCOIN_HSM_PIN="${WRFCOIN_HSM_PIN:-ci}"
export WRFCOIN_HSM_SO_PIN="${WRFCOIN_HSM_SO_PIN:-ci}"
# CI-only RFC 5737 documentation fixtures for this positive seed-profile
# render. Production Compose still requires operator-verified values.
export WRFCOIN_P2P_EXTERNAL_ADDR="${WRFCOIN_P2P_EXTERNAL_ADDR:-/ip4/198.51.100.7/tcp/9000}"
export WRFCOIN_SEED_P2P_EXTERNAL_ADDR="${WRFCOIN_SEED_P2P_EXTERNAL_ADDR:-/ip4/203.0.113.9/tcp/9000}"

cd "${REPO_ROOT}"

bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile seed -f "${COMPOSE_FILE}" config --format json > "${RENDERED_CONFIG}"

python3 - "${REPO_ROOT}" "${RENDERED_CONFIG}" <<'PY'
import json
import shlex
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
rendered_config = Path(sys.argv[2])

with rendered_config.open("r", encoding="utf-8") as handle:
    compose = json.load(handle)

services = compose.get("services", {})
faucet = services.get("wrfcoin-faucet")
if not faucet:
    raise SystemExit("wrfcoin-faucet missing from base seed-profile render")

build = faucet.get("build") or {}
context = Path(build.get("context", "")).resolve()
dockerfile = build.get("dockerfile")

if context != repo_root:
    raise SystemExit(f"wrfcoin-faucet base build context drifted: {context} != {repo_root}")

if dockerfile != "testnet/services/faucet/Dockerfile":
    raise SystemExit(f"wrfcoin-faucet base Dockerfile drifted: {dockerfile!r}")

dockerfile_path = context / dockerfile
if not dockerfile_path.is_file():
    raise SystemExit(f"wrfcoin-faucet Dockerfile missing: {dockerfile_path}")

copy_sources = []
for raw_line in dockerfile_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    instruction, _, rest = line.partition(" ")
    if instruction.upper() != "COPY" or not rest:
        continue

    tokens = shlex.split(rest)
    while tokens and tokens[0].startswith("--"):
        flag = tokens.pop(0)
        if flag.startswith("--from"):
            tokens = []
            break
    if len(tokens) < 2:
        continue

    copy_sources.extend(tokens[:-1])

missing = [
    source
    for source in copy_sources
    if "://" not in source and not (context / source).exists()
]

if missing:
    raise SystemExit(
        "wrfcoin-faucet Dockerfile COPY sources missing from base context: "
        + ", ".join(missing)
    )

print(
    "PASS: wrfcoin-faucet base seed-profile context renders and COPY sources exist"
)
PY

# Seed retired on CT101 (owner ruling 2026-09-27, infra#1057 Q4): the faucet
# must run under its own "faucet" profile WITHOUT the seed.
FAUCET_ONLY_SERVICES="$(bash "${REPO_ROOT}/testnet/tests/render-testnet-compose.sh" --profile faucet -f "${COMPOSE_FILE}" config --services)"
grep -qx 'wrfcoin-faucet' <<< "${FAUCET_ONLY_SERVICES}" \
  || { echo "FAIL: wrfcoin-faucet does not render under --profile faucet" >&2; exit 1; }
if grep -qxE 'wrfcoin-seed|softhsm-seed-init' <<< "${FAUCET_ONLY_SERVICES}"; then
  echo "FAIL: --profile faucet also renders the retired seed" >&2; exit 1
fi
echo "PASS: wrfcoin-faucet renders under --profile faucet without the retired seed"
