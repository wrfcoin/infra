#!/usr/bin/env bash
# Read-only gate for the owner-run immutable infra snapshot transition.
set -euo pipefail

TESTNET_DIR=""
CUSTODY_OVERRIDE=""
EXPECTED_NODE_IMAGE=""
WALLET_DISPOSITION=""
RENDERED_CONFIG=""

usage() {
  echo 'usage: preflight-infra-snapshot-move.sh --testnet-dir DIR --custody-override FILE --expected-node-image IMAGE --wallet-disposition retire [--rendered-config FILE]'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --testnet-dir) TESTNET_DIR="$2"; shift 2 ;;
    --custody-override) CUSTODY_OVERRIDE="$2"; shift 2 ;;
    --expected-node-image) EXPECTED_NODE_IMAGE="$2"; shift 2 ;;
    --wallet-disposition) WALLET_DISPOSITION="$2"; shift 2 ;;
    --rendered-config) RENDERED_CONFIG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "INFRA_SNAPSHOT_PREFLIGHT=FAIL unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$TESTNET_DIR" ]] || { echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL testnet directory missing' >&2; exit 1; }
[[ -r "$TESTNET_DIR/.env" ]] || { echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL .env missing' >&2; exit 1; }
[[ "$CUSTODY_OVERRIDE" == /* && -r "$CUSTODY_OVERRIDE" ]] || {
  echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL custody override must be an absolute readable file' >&2
  exit 1
}
[[ -n "$EXPECTED_NODE_IMAGE" ]] || { echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL expected node image missing' >&2; exit 1; }
# Owner ruling 2026-09-21: the legacy wallet container is retired (wallet
# features live in the main backend; infra#984 removed wallet_server.js).
[[ "$WALLET_DISPOSITION" == retire ]] || {
  echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL wallet disposition must be retire (owner ruling 2026-09-21)' >&2
  exit 1
}

env_value() {
  awk -F= -v key="$1" '$0 ~ "^" key "=" {print substr($0, index($0, "=") + 1); exit}' "$TESTNET_DIR/.env"
}

STATION="$(env_value WRFCOIN_ATTESTER_NWS_STATION)"
[[ "$STATION" == KDLH ]] || {
  echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL .env must carry WRFCOIN_ATTESTER_NWS_STATION=KDLH before the move' >&2
  exit 1
}
# Owner ruling 2026-09-21: the synthetic collector is retired. Blocks come from
# the real collectors (profile "collector"), which mine after a
# quorum-qualified reveal.
PROFILES="$(env_value COMPOSE_PROFILES)"
case " ${PROFILES//,/ } " in
  *' synthetic '*) echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL COMPOSE_PROFILES must not include synthetic (retired 2026-09-21)' >&2; exit 1 ;;
esac
case " ${PROFILES//,/ } " in
  *' collector '*) ;;
  *) echo 'INFRA_SNAPSHOT_PREFLIGHT=FAIL COMPOSE_PROFILES must include collector (real weather collectors)' >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/config.json"
if [[ -n "$RENDERED_CONFIG" ]]; then
  cp "$RENDERED_CONFIG" "$CONFIG"
else
  (
    cd "$TESTNET_DIR"
    docker compose --env-file .env \
      -f docker-compose.testnet.yml \
      -f docker-compose.override.yml \
      -f docker-compose.local-paths.yml \
      -f "$CUSTODY_OVERRIDE" \
      config --format json > "$CONFIG"
  )
fi

python3 - "$CONFIG" "$EXPECTED_NODE_IMAGE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
services = payload.get("services", {})
required = {"wrfcoin-node", "alert-receiver", "wrfcoin-faucet", "wrfcoin-explorer"}
missing = sorted(required - services.keys())
if missing:
    raise SystemExit("INFRA_SNAPSHOT_PREFLIGHT=FAIL rendered services missing: " + ",".join(missing))
real = sorted({"weather-collector", "weather-collector-multi"} & services.keys())
if not real:
    raise SystemExit("INFRA_SNAPSHOT_PREFLIGHT=FAIL no real collector rendered (need weather-collector and/or weather-collector-multi)")
if "synthetic-collector" in services:
    raise SystemExit("INFRA_SNAPSHOT_PREFLIGHT=FAIL synthetic-collector is rendered but retired (2026-09-21)")
print("real_collectors=" + ",".join(real))
actual = services["wrfcoin-node"].get("image")
if actual != sys.argv[2]:
    raise SystemExit(f"INFRA_SNAPSHOT_PREFLIGHT=FAIL node image {actual!r} != expected {sys.argv[2]!r}")
PY

echo "INFRA_SNAPSHOT_PREFLIGHT=PASS node_image=$EXPECTED_NODE_IMAGE wallet_disposition=$WALLET_DISPOSITION profiles=$PROFILES"
