#!/usr/bin/env bash
# Verify that an N5/testnet reboot has fully settled.
#
# This script is read-only. It waits for the core stack, authenticated canonical
# node/seed parity, P2P peer recovery, Prometheus target health, and an empty
# Alertmanager/Prometheus alert state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTNET_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${TESTNET_ENV_FILE:-${TESTNET_DIR}/.env}"
TIMEOUT_SECS="${POST_REBOOT_VERIFY_TIMEOUT_SECS:-360}"
INTERVAL_SECS="${POST_REBOOT_VERIFY_INTERVAL_SECS:-10}"
NODE_URL="${NODE_URL:-http://127.0.0.1:8556}"
SEED_URL="${SEED_URL:-http://127.0.0.1:8557}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://127.0.0.1:9090}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
POST_REBOOT_ALLOWED_ALERTS="${POST_REBOOT_ALLOWED_ALERTS:-BftFinalityInert,ValidatorParticipationZero}"
POST_REBOOT_REORG_DEPTH="${POST_REBOOT_REORG_DEPTH:-100}"
POST_REBOOT_MAX_RECOVERY_LAG="${POST_REBOOT_MAX_RECOVERY_LAG:-100}"
POST_REBOOT_VERIFY_ONCE="${POST_REBOOT_VERIFY_ONCE:-false}"

# shellcheck source=testnet/lib/compose-inputs.sh
source "${TESTNET_DIR}/lib/compose-inputs.sh"
wrfcoin_init_compose_inputs "${TESTNET_DIR}"

env_value() {
  local key="$1"
  [ -f "${ENV_FILE}" ] || return 0
  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value=$0
      sub(/^[^=]*=/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^["\047]|["\047]$/, "", value)
      print value
      exit
    }
  ' "${ENV_FILE}"
}

compose_runner() {
  wrfcoin_compose "$@"
}

log() {
  printf '%s %s\n' "$(date -Is)" "$*"
}

fail() {
  log "REBOOT NO-GO: $*"
  return 1
}

curl_body() {
  local url="$1"
  shift
  curl -fsS --connect-timeout 3 --max-time 5 "$@" "$url"
}

# infra#1073: credential headers reach curl on stdin (-H @-) from the builtin
# printf, never through argv, so ps and /proc/<pid>/cmdline cannot read them.
curl_body_with_header() { # curl_body_with_header <url> <header-line> [curl args...]
  local url="$1" header="$2"
  shift 2
  printf '%s\n' "$header" | curl_body "$url" -H @- "$@"
}

json_field_number() {
  local field="$1"
  python3 -c '
import json, sys
field = sys.argv[1]
def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result
try:
    payload = json.load(sys.stdin, object_pairs_hook=reject_duplicates)
except Exception:
    sys.exit(1)
value = payload.get(field)
if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
    print(value)
else:
    sys.exit(1)
' "$field"
}

check_loopback_ports() {
  local ports
  ports="$(docker ps --format '{{.Names}}	{{.Ports}}')"

  # infra#918: every check reads the CAPTURED value through a here-string, never
  # `printf | grep -q`. Under pipefail, grep -q exits on its first match; a
  # writer still writing then gets EPIPE ("printf: write error: Broken pipe"),
  # and the pipeline fails a check whose pattern DID match.
  grep -q $'wrfcoin-testnet-node\t.*127.0.0.1:8556->8556/tcp' <<<"$ports" \
    || { fail "wrfcoin-testnet-node API is not loopback-bound on 127.0.0.1:8556"; return 1; }
  grep -q $'wrfcoin-testnet-node\t.*0.0.0.0:9000->9000/tcp' <<<"$ports" \
    || { fail "wrfcoin-testnet-node P2P is not published on 0.0.0.0:9000"; return 1; }
  grep -q $'wrfcoin-testnet-prometheus\t.*127.0.0.1:9090->9090/tcp' <<<"$ports" \
    || { fail "Prometheus is not loopback-bound on 127.0.0.1:9090"; return 1; }
  grep -q $'wrfcoin-testnet-alertmanager\t.*127.0.0.1:9093->9093/tcp' <<<"$ports" \
    || { fail "Alertmanager is not loopback-bound on 127.0.0.1:9093"; return 1; }
  grep -q $'wrfcoin-testnet-grafana\t.*127.0.0.1:3100->3000/tcp' <<<"$ports" \
    || { fail "Grafana is not loopback-bound on 127.0.0.1:3100"; return 1; }
}

check_canonical_seed_parity() {
  local reader node_network seed_network node_height seed_height settled_height
  local node_block seed_block node_snapshot seed_snapshot comparison compare_rc=0

  # Seed retired (infra#1057 Q4, owner ruling 2026-09-27): with no "seed"
  # profile there is no second node to compare against. Said out loud, never
  # silently passed: the OK line below also names the missing parity.
  if ! wrfcoin_seed_profile_active; then
    log "SEED PARITY: SKIP (seed profile not active: seed retired, infra#1057)"
    return 0
  fi

  reader="$(env_value WRFCOIN_READER_TOKEN)"
  [ -n "$reader" ] \
    || { fail "WRFCOIN_READER_TOKEN missing from ${ENV_FILE}"; return 3; }

  node_network="$(curl_body_with_header "${NODE_URL}/network/info" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: node /network/info"; return 3; }
  seed_network="$(curl_body_with_header "${SEED_URL}/network/info" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: seed /network/info"; return 3; }

  node_height="$(printf '%s' "$node_network" | json_field_number chain_height)" \
    || { fail "canonical response is malformed: node /network/info chain_height"; return 3; }
  seed_height="$(printf '%s' "$seed_network" | json_field_number chain_height)" \
    || { fail "canonical response is malformed: seed /network/info chain_height"; return 3; }

  if (( node_height < seed_height )); then
    settled_height=$((node_height - POST_REBOOT_REORG_DEPTH))
  else
    settled_height=$((seed_height - POST_REBOOT_REORG_DEPTH))
  fi
  (( settled_height >= 1 )) \
    || { fail "canonical history is shallower than POST_REBOOT_REORG_DEPTH=${POST_REBOOT_REORG_DEPTH}"; return 3; }

  node_block="$(curl_body_with_header "${NODE_URL}/chain/block/${settled_height}" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: node /chain/block/${settled_height}"; return 3; }
  seed_block="$(curl_body_with_header "${SEED_URL}/chain/block/${settled_height}" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: seed /chain/block/${settled_height}"; return 3; }
  node_snapshot="$(curl_body_with_header "${NODE_URL}/state/snapshot" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: node /state/snapshot"; return 3; }
  seed_snapshot="$(curl_body_with_header "${SEED_URL}/state/snapshot" "Authorization: Bearer ${reader}")" \
    || { fail "authenticated canonical endpoint failed: seed /state/snapshot"; return 3; }

  comparison="$(
    NODE_NETWORK_PAYLOAD="$node_network" \
    SEED_NETWORK_PAYLOAD="$seed_network" \
    NODE_BLOCK_PAYLOAD="$node_block" \
    SEED_BLOCK_PAYLOAD="$seed_block" \
    NODE_SNAPSHOT_PAYLOAD="$node_snapshot" \
    SEED_SNAPSHOT_PAYLOAD="$seed_snapshot" \
    python3 - "$settled_height" "$POST_REBOOT_MAX_RECOVERY_LAG" "$POST_REBOOT_REORG_DEPTH" <<'PY'
import json
import os
import re
import sys

settled_height = int(sys.argv[1])
max_recovery_lag = int(sys.argv[2])
reorg_depth = int(sys.argv[3])

class PayloadError(ValueError):
    pass

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PayloadError(f"duplicate key {key}")
        result[key] = value
    return result

def load(name):
    try:
        value = json.loads(os.environ[name], object_pairs_hook=reject_duplicates)
    except Exception as exc:
        raise PayloadError(f"{name}: {exc}") from exc
    if not isinstance(value, dict):
        raise PayloadError(f"{name}: expected object")
    return value

def unwrap_block(payload, source):
    if "data" not in payload:
        return payload
    if "height" in payload or "hash" in payload or not isinstance(payload["data"], dict):
        raise PayloadError(f"{source}: ambiguous response envelope")
    return payload["data"]

def text_field(payload, name, source):
    value = payload.get(name)
    if not isinstance(value, str) or not value.strip() or value.strip().lower() == "unknown":
        raise PayloadError(f"{source}.{name}: expected known non-empty string")
    return value.strip()

def uint_field(payload, name, source):
    value = payload.get(name)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PayloadError(f"{source}.{name}: expected unsigned integer")
    return value

def digest_field(payload, name, source):
    value = text_field(payload, name, source).lower()
    if value.startswith("0x"):
        value = value[2:]
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise PayloadError(f"{source}.{name}: expected 32-byte hex digest")
    return value

def no_go(message):
    print(f"NO_GO|{message}")
    raise SystemExit(1)

try:
    node_network = load("NODE_NETWORK_PAYLOAD")
    seed_network = load("SEED_NETWORK_PAYLOAD")
    node_block = unwrap_block(load("NODE_BLOCK_PAYLOAD"), "node block")
    seed_block = unwrap_block(load("SEED_BLOCK_PAYLOAD"), "seed block")
    node_snapshot = load("NODE_SNAPSHOT_PAYLOAD")
    seed_snapshot = load("SEED_SNAPSHOT_PAYLOAD")

    identities = {}
    for field in ("chain_id", "network_id"):
        identities[("node", field)] = text_field(node_network, field, "node network")
        identities[("seed", field)] = text_field(seed_network, field, "seed network")
    identities[("node", "genesis_hash")] = digest_field(node_network, "genesis_hash", "node network")
    identities[("seed", "genesis_hash")] = digest_field(seed_network, "genesis_hash", "seed network")

    for field in ("chain_id", "network_id", "genesis_hash"):
        if identities[("node", field)] != identities[("seed", field)]:
            no_go(f"{field} mismatch between node and seed")

    node_height = uint_field(node_network, "chain_height", "node network")
    seed_height = uint_field(seed_network, "chain_height", "seed network")
    recovery_reasons = []
    for label, payload in (("node", node_network), ("seed", seed_network)):
        peer_count = uint_field(payload, "peer_count", f"{label} network")
        sync_status = text_field(payload, "sync_status", f"{label} network")
        if peer_count == 0:
            recovery_reasons.append(f"{label} peer_count=0")
        if sync_status != "synced":
            recovery_reasons.append(f"{label} sync_status={sync_status}")

    expected_settled = min(node_height, seed_height) - reorg_depth
    if settled_height != expected_settled:
        no_go("settled height is ambiguous")

    for label, payload in (("node", node_block), ("seed", seed_block)):
        if uint_field(payload, "height", f"{label} block") != settled_height:
            no_go(f"{label} block height does not match settled height")
    node_hash = digest_field(node_block, "hash", "node block")
    seed_hash = digest_field(seed_block, "hash", "seed block")
    if node_hash != seed_hash:
        print(f"DIVERGED|canonical block hash mismatch at settled height {settled_height}")
        raise SystemExit(1)

    state_roots = {}
    for label, payload, tip in (
        ("node", node_snapshot, node_height),
        ("seed", seed_snapshot, seed_height),
    ):
        if uint_field(payload, "height", f"{label} snapshot") != tip:
            no_go(f"{label} snapshot height does not match canonical tip")
        uint_field(payload, "entry_count", f"{label} snapshot")
        state_roots[label] = digest_field(payload, "state_root_hex", f"{label} snapshot")
        # snapshot_root_hex includes non-consensus telemetry; validate the API
        # field but do not turn legitimate telemetry differences into DIVERGED.
        digest_field(payload, "snapshot_root_hex", f"{label} snapshot")

    lag = abs(node_height - seed_height)
    if lag == 0:
        if state_roots["node"] != state_roots["seed"]:
            print(f"DIVERGED|state_root_hex mismatch at converged tip height {node_height}")
            raise SystemExit(1)
        if recovery_reasons:
            print(
                f"RECOVERING|{'; '.join(recovery_reasons)}; node_height={node_height} "
                f"seed_height={seed_height} settled_height={settled_height} block_hash={node_hash}"
            )
            raise SystemExit(2)
        print(
            f"PASS|height={node_height} settled_height={settled_height} "
            f"block_hash={node_hash} state_root={state_roots['node']}"
        )
        raise SystemExit(0)

    if recovery_reasons or lag <= max_recovery_lag:
        reason = "; ".join(recovery_reasons) if recovery_reasons else f"bounded tip lag={lag}"
        print(
            f"RECOVERING|{reason}; node_height={node_height} seed_height={seed_height} lag={lag} "
            f"settled_height={settled_height} block_hash={node_hash}"
        )
        raise SystemExit(2)

    no_go(f"canonical tip lag {lag} exceeds bounded recovery limit {max_recovery_lag}")
except PayloadError as exc:
    no_go(f"canonical response is malformed or ambiguous: {exc}")
PY
  )" || compare_rc=$?

  case "$compare_rc" in
    0)
      log "canonical parity: ${comparison#PASS|}"
      ;;
    2)
      log "SEED RECOVERING: ${comparison#RECOVERING|}"
      return 2
      ;;
    *)
      if [[ "$comparison" == DIVERGED\|* ]]; then
        log "SEED DIVERGED: ${comparison#DIVERGED|}" >&2
      else
        fail "${comparison#NO_GO|}"
      fi
      return 3
      ;;
  esac
}

check_prometheus_state() {
  local password auth_header result
  password="$(env_value PROMETHEUS_ADMIN_PASSWORD)"
  [ -n "$password" ] \
    || { fail "PROMETHEUS_ADMIN_PASSWORD missing from ${ENV_FILE}"; return 1; }
  auth_header="Authorization: Basic $(printf 'admin:%s' "$password" | base64 | tr -d '\n')"

  result="$(curl_body_with_header "${PROMETHEUS_URL}/api/v1/targets" "$auth_header" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
bad = []
for target in payload.get("data", {}).get("activeTargets", []):
    labels = target.get("labels", {})
    job = labels.get("job", "")
    if target.get("health") != "up":
        bad.append("{}:{}:{}".format(job, labels.get("instance", ""), target.get("lastError", "")))
    if job in {"wrfcoin-cross-chain", "wrfcoin-compute", "wrfcoin-ml", "wrfcoin-storage", "wrfcoin-node-discovery", "prometheus"}:
        bad.append(f"unexpected-target:{job}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print("targets-up")
')" || { fail "Prometheus target check failed"; return 1; }
  [ "$result" = "targets-up" ] \
    || { fail "Prometheus target check failed: ${result}"; return 1; }

  result="$(curl_body_with_header "${PROMETHEUS_URL}/api/v1/alerts" "$auth_header" | python3 -c '
import json, sys
allowed = {item for item in sys.argv[1].split(",") if item}
payload = json.load(sys.stdin)
firing = [
    a.get("labels", {}).get("alertname", "unknown")
    for a in payload.get("data", {}).get("alerts", [])
    if a.get("state") == "firing"
    and a.get("labels", {}).get("alertname", "unknown") not in allowed
]
if firing:
    print(",".join(firing))
    sys.exit(1)
print("no-firing-alerts")
' "${POST_REBOOT_ALLOWED_ALERTS}")" \
    || { fail "Prometheus alert response is unavailable or malformed"; return 1; }
  [ "$result" = "no-firing-alerts" ] \
    || { fail "Prometheus firing alerts: ${result}"; return 1; }
}

check_alertmanager_state() {
  local result
  result="$(curl_body "${ALERTMANAGER_URL}/api/v2/alerts" | python3 -c '
import json, sys
allowed = {item for item in sys.argv[1].split(",") if item}
alerts = json.load(sys.stdin)
active = [
    a.get("labels", {}).get("alertname", "unknown")
    for a in alerts
    if a.get("status", {}).get("state") == "active"
    and a.get("labels", {}).get("alertname", "unknown") not in allowed
]
if active:
    print(",".join(active))
    sys.exit(1)
print("no-active-alerts")
' "${POST_REBOOT_ALLOWED_ALERTS}")" \
    || { fail "Alertmanager response is unavailable or malformed"; return 1; }
  [ "$result" = "no-active-alerts" ] \
    || { fail "Alertmanager active alerts: ${result}"; return 1; }
}

check_metrics_token_alignment() {
  local reader token_file
  reader="$(env_value WRFCOIN_READER_TOKEN)"
  [ -n "$reader" ] \
    || { fail "WRFCOIN_READER_TOKEN missing from ${ENV_FILE}"; return 1; }
  token_file="$(cat "${TESTNET_DIR}/prometheus-bearer-token" 2>/dev/null || true)"
  [ "$reader" = "$token_file" ] \
    || { fail "prometheus-bearer-token does not match WRFCOIN_READER_TOKEN"; return 1; }
}

check_once() {
  systemctl is-active --quiet wrfcoin-testnet.service \
    || { fail "wrfcoin-testnet.service is not active"; return 1; }

  compose_runner config --quiet \
    || { fail "docker compose config is invalid"; return 1; }

  check_loopback_ports || return 1
  check_metrics_token_alignment || return 1

  # Captured first, then matched without a pipe (infra#918, see check_loopback_ports).
  local body names
  body="$(curl_body "${NODE_URL}/readyz" 2>/dev/null)" || body=""
  grep -q '"status"[[:space:]]*:[[:space:]]*"ready"' <<<"$body" \
    || { fail "main node /readyz is not ready"; return 1; }

  if wrfcoin_seed_profile_active; then
    names="$(docker ps --format '{{.Names}}')" || names=""
    grep -qx 'wrfcoin-testnet-seed' <<<"$names" \
      || { fail "wrfcoin-testnet-seed container is absent"; return 1; }
    body="$(curl_body "${SEED_URL}/readyz" 2>/dev/null)" || body=""
    grep -q '"status"[[:space:]]*:[[:space:]]*"ready"' <<<"$body" \
      || { fail "seed node /readyz is not ready"; return 1; }
  fi

  check_canonical_seed_parity || return $?
  check_prometheus_state || return 1
  check_alertmanager_state || return 1
}

main() {
  local deadline
  local last_error=""
  local check_rc=0

  [[ "$TIMEOUT_SECS" =~ ^[0-9]+$ ]] \
    || { fail "POST_REBOOT_VERIFY_TIMEOUT_SECS must be a non-negative integer"; return 1; }
  [[ "$INTERVAL_SECS" =~ ^[0-9]+$ ]] \
    || { fail "POST_REBOOT_VERIFY_INTERVAL_SECS must be a non-negative integer"; return 1; }
  [[ "$POST_REBOOT_REORG_DEPTH" =~ ^[1-9][0-9]*$ ]] \
    || { fail "POST_REBOOT_REORG_DEPTH must be a positive integer"; return 1; }
  [[ "$POST_REBOOT_MAX_RECOVERY_LAG" =~ ^[0-9]+$ ]] \
    || { fail "POST_REBOOT_MAX_RECOVERY_LAG must be a non-negative integer"; return 1; }
  [[ "$POST_REBOOT_VERIFY_ONCE" == true || "$POST_REBOOT_VERIFY_ONCE" == false ]] \
    || { fail "POST_REBOOT_VERIFY_ONCE must be true or false"; return 1; }
  deadline=$((SECONDS + TIMEOUT_SECS))

  while true; do
    output="$(check_once 2>&1)" && check_rc=0 || check_rc=$?
    if (( check_rc == 0 )); then
      [ -z "$output" ] || printf '%s\n' "$output"
      if ! wrfcoin_seed_profile_active; then
        log "REBOOT OK (NO SEED PARITY: seed retired): main node ready, no reboot-blocking alerts (allowed non-reboot alerts: ${POST_REBOOT_ALLOWED_ALERTS:-<none>})"
      elif [ -n "${POST_REBOOT_ALLOWED_ALERTS}" ]; then
        log "REBOOT OK: canonical node/seed parity at a reorg-settled common height, peers connected, no reboot-blocking alerts (allowed non-reboot alerts: ${POST_REBOOT_ALLOWED_ALERTS})"
      else
        log "REBOOT OK: canonical node/seed parity at a reorg-settled common height, peers connected, alerts clear"
      fi
      return 0
    fi

    last_error="$output"
    if (( check_rc == 3 )); then
      printf '%s\n' "$last_error" >&2
      return 1
    fi
    if [[ "$POST_REBOOT_VERIFY_ONCE" == true ]]; then
      printf '%s\n' "$last_error" >&2
      if (( check_rc == 2 )); then
        return 2
      fi
      return 1
    fi
    if (( SECONDS >= deadline )); then
      printf '%s\n' "$last_error" >&2
      fail "timed out after ${TIMEOUT_SECS}s"
      return 1
    fi

    log "waiting: ${last_error//$'\n'/; }"
    sleep "$INTERVAL_SECS"
  done
}

main "$@"
