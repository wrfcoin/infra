#!/usr/bin/env bash
# Validate the launch-readiness gate with synthetic N5/desktop snapshots.
set -euo pipefail

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wrfcoin-launch-readiness-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${REPO_ROOT}/testnet/scripts/launch-readiness-gate.sh"
SNAPSHOT="${REPO_ROOT}/testnet/scripts/deploy-status-snapshot.sh"

bash -n "$GATE" "$SNAPSHOT"

python3 - "$ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]


def snapshot(node_name, height, peers=1, sync_status="synced", log_matches=None, real_contributions=0):
    repos = []
    for name in ("infra", "backend", "core4", "frontend"):
        repos.append(
            {
                "name": name,
                "path": f"/tmp/{name}",
                "exists": True,
                "branch": "main",
                "detached": False,
                "dirty": False,
                "sha": f"{name}-sha",
                "short_sha": f"{name[:4]}123",
                "upstream": "origin/main",
                "ahead": 0,
                "behind": 0,
            }
        )
    return {
        "schema": "wrfcoin.testnet.deploy_status_snapshot.v1",
        "generated_at": "2026-09-17T12:04:00+00:00",
        "node_name": node_name,
        "source_repos": repos,
        "compose": {
            "available": True,
            "ps": {
                "data": [
                    {"Name": "wrfcoin-testnet-node", "Service": "wrfcoin-node", "State": "running", "Status": "Up (healthy)"},
                    {"Name": "wrfcoin-testnet-prometheus", "Service": "prometheus", "State": "running", "Status": "Up (healthy)"},
                    {"Name": "wrfcoin-testnet-alertmanager", "Service": "alertmanager", "State": "running", "Status": "Up (healthy)"},
                    {"Name": "wrfcoin-alert-receiver", "Service": "alert-receiver", "State": "running", "Status": "Up (healthy)"},
                ]
            },
        },
        "endpoints": [
            {"name": "node_readyz", "ok": True, "status": 200, "body": {"ok": True}},
            {"name": "node_health", "ok": True, "status": 200, "body": {"status": "ready", "chain_height": height}},
            {
                "name": "node_network_info",
                "ok": True,
                "status": 200,
                "body": {"peer_count": peers, "chain_height": height, "sync_status": sync_status},
            },
            {
                "name": "node_blockchain",
                "ok": True,
                "status": 200,
                "body": {"height": height, "tip_hash": f"tip-{height}"},
            },
            {"name": "backend_health", "ok": True, "status": 200, "body": {"status": "healthy"}},
            {
                "name": "alert_receiver_health",
                "ok": True,
                "status": 200,
                "body": {
                    "status": "ok",
                    "forwarding": True,
                    "delivery_evidence": {
                        "rule_firing": {"status": "injected_local_canary"},
                        "receiver_acceptance": {
                            "status": "accepted",
                            "critical_firing": True,
                            "observed_at": "2026-09-17T12:00:00+00:00",
                            "request_id": "canary-1",
                        },
                        "outbound_forwarding": {"status": "succeeded", "http_status": 204, "observed_at": "2026-09-17T12:00:00+00:00", "request_id": "canary-1"},
                        "human_delivery": {"status": "operator_verification_required"},
                    },
                    "last_successful_critical_delivery": {
                        "status": "succeeded",
                        "request_id": "canary-1",
                        "rule_firing": {"status": "injected_local_canary", "request_id": "canary-1"},
                        "receiver_acceptance": {
                            "status": "accepted",
                            "critical_firing": True,
                            "observed_at": "2026-09-17T12:00:00+00:00",
                            "request_id": "canary-1",
                        },
                        "outbound_forwarding": {"status": "succeeded", "http_status": 204, "observed_at": "2026-09-17T12:00:00+00:00", "request_id": "canary-1"},
                        "human_delivery": {"status": "operator_verification_required", "request_id": "canary-1"},
                    },
                },
            },
        ],
        "node_log_scan": {"ok": True, "match_count": len(log_matches or []), "matches": log_matches or []},
        "production_observation": {
            "observation_window": {
                "since": "30m",
                "ended_at": "2026-09-17T12:00:00+00:00",
                "attribution": "fixture",
            },
            "synthetic_collector": {
                "enabled": False,
                "successful_cycles": 0,
                "log_evidence": {"available": True, "returncode": 0, "stderr": ""},
            },
            "real_collectors": {
                "enabled": real_contributions > 0,
                "services": ["weather-collector"] if real_contributions > 0 else [],
                "contributions_observed": real_contributions,
            },
        },
    }


fixtures = {
    "n5.json": snapshot("n5-pro", 100, real_contributions=2),
    "desktop-pass.json": snapshot("desktop", 98, sync_status="syncing"),
    "desktop-genesis.json": snapshot("desktop", 0, sync_status="genesis"),
    "desktop-log-blocker.json": snapshot("desktop", 100, log_matches=["wrfcoin-node panic: validation error"]),
    "n5-no-real.json": snapshot("n5-pro", 100),
    "n5-synthetic-with-real.json": snapshot("n5-pro", 100, real_contributions=2),
    "n5-stopped-synthetic-with-real.json": snapshot("n5-pro", 100, real_contributions=2),
}
fixtures["n5-blank-forward.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-blank-forward.json"]["endpoints"][-1]["body"]["forwarding"] = False
fixtures["n5-absent-receiver.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-absent-receiver.json"]["compose"]["ps"]["data"] = fixtures["n5-absent-receiver.json"]["compose"]["ps"]["data"][:-1]
fixtures["n5-non-2xx.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-non-2xx.json"]["endpoints"][-1]["body"]["last_successful_critical_delivery"]["outbound_forwarding"] = {"status": "http_error", "http_status": 503}
fixtures["n5-timeout.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-timeout.json"]["endpoints"][-1]["body"]["last_successful_critical_delivery"]["outbound_forwarding"] = {"status": "timeout"}
fixtures["n5-noncritical.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-noncritical.json"]["endpoints"][-1]["body"]["last_successful_critical_delivery"]["receiver_acceptance"]["critical_firing"] = False
fixtures["n5-mismatched-request.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-mismatched-request.json"]["endpoints"][-1]["body"]["last_successful_critical_delivery"]["outbound_forwarding"]["request_id"] = "another-request"
fixtures["n5-stale.json"] = snapshot("n5-pro", 100, real_contributions=2)
fixtures["n5-stale.json"]["endpoints"][-1]["body"]["last_successful_critical_delivery"]["outbound_forwarding"]["observed_at"] = "2026-09-17T11:00:00+00:00"
fixtures["n5-synthetic-with-real.json"]["production_observation"]["synthetic_collector"] = {
    "enabled": True,
    "successful_cycles": 30,
    "log_evidence": {"available": True, "returncode": 0, "stderr": ""},
}
fixtures["n5-stopped-synthetic-with-real.json"]["production_observation"]["synthetic_collector"] = {
    "enabled": False,
    "successful_cycles": 1,
    "log_evidence": {"available": True, "returncode": 0, "stderr": ""},
}
for name, payload in fixtures.items():
    with open(os.path.join(root, name), "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
PY

bash "$GATE" --n5 "${ROOT}/n5.json" --desktop "${ROOT}/desktop-pass.json" \
  --json-out "${ROOT}/pass.json" --markdown-out "${ROOT}/pass.md"
python3 - "${ROOT}/pass.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    report = json.load(handle)
assert report["schema"] == "wrfcoin.testnet.launch_readiness_report.v1"
assert report["overall"] == "pass"
assert report["alert_delivery"]["n5"] == {
    "forwarding_enabled": True,
    "rule_firing": "injected_local_canary",
    "receiver_acceptance": "accepted",
    "outbound_forwarding": "succeeded",
    "human_delivery": "operator_verification_required",
    "evidence_age_seconds": 240.0,
}
assert report["mode"] == "public-release"
assert report["proof_class"] == "PUBLIC_RELEASE"
assert report["production_evidence"]["synthetic_collector"] == "disabled"
assert report["production_evidence"]["real_contributions_observed"] == 2
PY

for failure in blank-forward absent-receiver non-2xx timeout noncritical mismatched-request stale; do
  if bash "$GATE" --n5 "${ROOT}/n5-${failure}.json" --desktop "${ROOT}/desktop-pass.json" \
    --json-out "${ROOT}/${failure}-report.json" >/dev/null 2>&1; then
    echo "FAIL: gate passed alert delivery failure: ${failure}"
    exit 1
  fi
done
grep -q 'forwarding disabled' "${ROOT}/blank-forward-report.json"
grep -q 'alert-receiver: missing from compose ps' "${ROOT}/absent-receiver-report.json"
grep -q 'outbound forwarding=http_error' "${ROOT}/non-2xx-report.json"
grep -q 'outbound forwarding=timeout' "${ROOT}/timeout-report.json"
grep -q 'did not observe a firing critical canary' "${ROOT}/noncritical-report.json"
grep -q 'not correlated to one request' "${ROOT}/mismatched-request-report.json"

if bash "$GATE" --n5 "${REPO_ROOT}/scripts/fixtures/launch-readiness/synthetic-only-n5.json" \
  --desktop "${REPO_ROOT}/scripts/fixtures/launch-readiness/synthetic-only-desktop.json" \
  --json-out "${ROOT}/synthetic-release.json" >/dev/null 2>&1; then
  echo "FAIL: synthetic-only height growth produced public-release PASS"
  exit 1
fi
grep -q 'synthetic collector active' "${ROOT}/synthetic-release.json"
grep -q 'real contributions observed=0' "${ROOT}/synthetic-release.json"

bash "$GATE" --mode developer-demo \
  --n5 "${REPO_ROOT}/scripts/fixtures/launch-readiness/synthetic-only-n5.json" \
  --desktop "${REPO_ROOT}/scripts/fixtures/launch-readiness/synthetic-only-desktop.json" \
  --json-out "${ROOT}/synthetic-demo.json" >/dev/null
grep -q '"proof_class": "SIMULATED"' "${ROOT}/synthetic-demo.json"

if bash "$GATE" --n5 "${ROOT}/n5-synthetic-with-real.json" --desktop "${ROOT}/desktop-pass.json" \
  --json-out "${ROOT}/synthetic-with-real.json" >/dev/null 2>&1; then
  echo "FAIL: public-release passed while synthetic production was active"
  exit 1
fi
grep -q 'synthetic collector active' "${ROOT}/synthetic-with-real.json"
if grep -q 'real contributions observed=0' "${ROOT}/synthetic-with-real.json"; then
  echo "FAIL: synthetic-active control did not contain independent real evidence"
  exit 1
fi

if bash "$GATE" --n5 "${ROOT}/n5-stopped-synthetic-with-real.json" --desktop "${ROOT}/desktop-pass.json" \
  --json-out "${ROOT}/stopped-synthetic-with-real.json" >/dev/null 2>&1; then
  echo "FAIL: public-release passed after synthetic production stopped inside the observation window"
  exit 1
fi
grep -q 'synthetic production observed' "${ROOT}/stopped-synthetic-with-real.json"

if bash "$GATE" --n5 "${ROOT}/n5-no-real.json" --desktop "${ROOT}/desktop-pass.json" \
  --json-out "${ROOT}/no-real.json" >/dev/null 2>&1; then
  echo "FAIL: public-release passed without a real contribution"
  exit 1
fi
grep -q 'real contributions observed=0' "${ROOT}/no-real.json"
if grep -q 'synthetic collector active' "${ROOT}/no-real.json"; then
  echo "FAIL: no-real control unexpectedly depended on synthetic production"
  exit 1
fi

if bash "$GATE" --n5 "${ROOT}/n5.json" --desktop "${ROOT}/desktop-genesis.json" \
  --json-out "${ROOT}/genesis.json" >/dev/null 2>&1; then
  echo "FAIL: gate passed when desktop remained at genesis"
  exit 1
fi
grep -q 'desktop remains at genesis while N5 is at height 100' "${ROOT}/genesis.json"

if bash "$GATE" --n5 "${ROOT}/n5.json" --desktop "${ROOT}/desktop-log-blocker.json" \
  --json-out "${ROOT}/log-blocker.json" >/dev/null 2>&1; then
  echo "FAIL: gate passed with blocking node log"
  exit 1
fi
grep -q 'validation error' "${ROOT}/log-blocker.json"

# Snapshot attribution control: a mocked Compose runtime has both producer
# classes active and one successfully mined real contribution batch.
mkdir -p "${ROOT}/bin"
cat > "${ROOT}/bin/docker" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ps --format json "*)
    if [ "${MOCK_REAL_STOPPED:-0}" = "1" ]; then
      printf '%s\n' '[{"Name":"wrfcoin-testnet-node","Service":"wrfcoin-node","State":"running","Status":"Up (healthy)"},{"Name":"wrfcoin-testnet-synthetic-collector","Service":"synthetic-collector","State":"running","Status":"Up (healthy)"}]'
    elif [ "${MOCK_SYNTH_STOPPED:-0}" = "1" ]; then
      printf '%s\n' '[{"Name":"wrfcoin-testnet-node","Service":"wrfcoin-node","State":"running","Status":"Up (healthy)"},{"Name":"wrfcoin-testnet-weather-collector","Service":"weather-collector","State":"running","Status":"Up (healthy)"}]'
    else
      printf '%s\n' '[{"Name":"wrfcoin-testnet-node","Service":"wrfcoin-node","State":"running","Status":"Up (healthy)"},{"Name":"wrfcoin-testnet-synthetic-collector","Service":"synthetic-collector","State":"running","Status":"Up (healthy)"},{"Name":"wrfcoin-testnet-weather-collector","Service":"weather-collector","State":"running","Status":"Up (healthy)"}]'
    fi
    ;;
  *" images --format json "*) printf '%s\n' '[]' ;;
  *" logs --since 30m synthetic-collector "*)
    if [ "${MOCK_SYNTH_LOG_FAILURE:-0}" = "1" ]; then
      printf '%s\n' 'synthetic logs unavailable' >&2
      exit 1
    fi
    printf '%s\n' 'COMMIT+REVEAL INCLUDED: fixture -> MINED block 500'
    ;;
  *" logs --since 30m weather-collector "*) printf '%s\n' 'Submission complete: 3 committed, 0 failed out of 3 current readings -- MINED QUORUM-QUALIFIED REVEALS' ;;
  *" logs --since 30m weather-collector-multi "*) : ;;
  *" logs --since 30m wrfcoin-node "*) : ;;
  *) exit 1 ;;
esac
SH
chmod +x "${ROOT}/bin/docker"
PATH="${ROOT}/bin:${PATH}" TESTNET_DIR="${REPO_ROOT}/testnet" \
  WRFCOIN_ROOT="${ROOT}/missing-repos" WRFCOIN_REPOS="" \
  NODE_API="http://127.0.0.1:1" BACKEND_API="http://127.0.0.1:1" \
  bash "$SNAPSHOT" > "${ROOT}/snapshot-attribution.json"
python3 - "${ROOT}/snapshot-attribution.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    observation = json.load(handle)["production_observation"]
assert observation["observation_window"]["since"] == "30m"
assert observation["observation_window"]["attribution"] == "docker compose ps plus service logs"
assert observation["synthetic_collector"]["enabled"] is True
assert observation["synthetic_collector"]["successful_cycles"] == 1
assert observation["synthetic_collector"]["log_evidence"]["available"] is True
assert observation["real_collectors"]["services"] == ["weather-collector"]
assert observation["real_collectors"]["contributions_observed"] == 3
PY

PATH="${ROOT}/bin:${PATH}" TESTNET_DIR="${REPO_ROOT}/testnet" \
  MOCK_SYNTH_STOPPED=1 WRFCOIN_ROOT="${ROOT}/missing-repos" WRFCOIN_REPOS="" \
  NODE_API="http://127.0.0.1:1" BACKEND_API="http://127.0.0.1:1" \
  bash "$SNAPSHOT" > "${ROOT}/snapshot-stopped-synthetic.json"
python3 - "${ROOT}/snapshot-stopped-synthetic.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    observation = json.load(handle)["production_observation"]
assert observation["synthetic_collector"]["enabled"] is False
assert observation["synthetic_collector"]["successful_cycles"] == 1
PY

PATH="${ROOT}/bin:${PATH}" TESTNET_DIR="${REPO_ROOT}/testnet" \
  MOCK_REAL_STOPPED=1 WRFCOIN_ROOT="${ROOT}/missing-repos" WRFCOIN_REPOS="" \
  NODE_API="http://127.0.0.1:1" BACKEND_API="http://127.0.0.1:1" \
  bash "$SNAPSHOT" > "${ROOT}/snapshot-stopped-real.json"
python3 - "${ROOT}/snapshot-stopped-real.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    observation = json.load(handle)["production_observation"]
assert observation["real_collectors"]["enabled"] is False
assert observation["real_collectors"]["services"] == ["weather-collector"]
assert observation["real_collectors"]["contributions_observed"] == 3
PY

PATH="${ROOT}/bin:${PATH}" TESTNET_DIR="${REPO_ROOT}/testnet" \
  MOCK_SYNTH_LOG_FAILURE=1 WRFCOIN_ROOT="${ROOT}/missing-repos" WRFCOIN_REPOS="" \
  NODE_API="http://127.0.0.1:1" BACKEND_API="http://127.0.0.1:1" \
  bash "$SNAPSHOT" > "${ROOT}/snapshot-synthetic-logs-unavailable.json"
python3 - "${ROOT}/snapshot-synthetic-logs-unavailable.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    observation = json.load(handle)["production_observation"]
assert observation["synthetic_collector"]["log_evidence"]["available"] is False
assert observation["synthetic_collector"]["log_evidence"]["returncode"] == 1
assert "synthetic logs unavailable" in observation["synthetic_collector"]["log_evidence"]["stderr"]
PY
if bash "$GATE" --n5 "${ROOT}/snapshot-synthetic-logs-unavailable.json" \
  --desktop "${ROOT}/desktop-pass.json" --json-out "${ROOT}/unavailable-synthetic-logs.json" >/dev/null 2>&1; then
  echo "FAIL: public-release passed without synthetic log evidence"
  exit 1
fi
grep -q 'synthetic collector logs unavailable' "${ROOT}/unavailable-synthetic-logs.json"

echo "PASS: launch readiness gate validates"
