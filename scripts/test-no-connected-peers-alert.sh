#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
alerts="${ROOT}/testnet/alert-rules-blockchain-health.yml"

python3 - "$alerts" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    document = yaml.safe_load(handle)

matches = [
    rule
    for group in document.get("groups", [])
    for rule in group.get("rules", [])
    if rule.get("alert") == "NoConnectedPeers"
]
if len(matches) != 1:
    raise SystemExit(
        f"FAIL: expected exactly one NoConnectedPeers rule, found {len(matches)}"
    )

rule = matches[0]
expected = {
    "expr": "wrfcoin_network_peer_count == 0",
    "for": "2m",
    "severity": "critical",
    "component": "p2p",
}
actual = {
    "expr": rule.get("expr"),
    "for": rule.get("for"),
    "severity": rule.get("labels", {}).get("severity"),
    "component": rule.get("labels", {}).get("component"),
}
if actual != expected:
    raise SystemExit(
        f"FAIL: NoConnectedPeers fields differ: expected {expected!r}, got {actual!r}"
    )

print("PASS: NoConnectedPeers is uniquely defined with the expected metric and hold")
PY
