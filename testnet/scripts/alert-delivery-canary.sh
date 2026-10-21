#!/usr/bin/env bash
# Generate fresh, visibly labelled critical-alert delivery evidence.
set -euo pipefail

RECEIVER_URL="${ALERT_RECEIVER_API:-http://127.0.0.1:19093}/alerts"

python3 - "${RECEIVER_URL}" <<'PY'
import datetime
import json
import sys
import urllib.error
import urllib.request
import uuid

url = sys.argv[1]
canary_id = uuid.uuid4().hex
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
payload = {
    "status": "firing",
    "groupLabels": {"alertname": "LaunchReadinessCanary"},
    "commonLabels": {"severity": "critical", "service": "launch-readiness"},
    "alerts": [
        {
            "status": "firing",
            "labels": {
                "alertname": "LaunchReadinessCanary",
                "severity": "critical",
                "service": "launch-readiness",
                "proof_class": "local-canary",
                "canary_id": canary_id,
            },
            "annotations": {
                "summary": "TEST: WRFCoin launch-readiness delivery canary",
                "description": "This is an expected test notification; no incident action is required.",
            },
            "startsAt": now,
            "endsAt": "0001-01-01T00:00:00Z",
        }
    ],
}
request = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(request, timeout=15) as response:
        result = json.loads(response.read().decode("utf-8"))
except urllib.error.HTTPError as error:
    detail = error.read().decode("utf-8", "replace")
    raise SystemExit(f"alert delivery canary failed: HTTP {error.code}: {detail}")
if result.get("forwarded") is not True:
    raise SystemExit(f"alert delivery canary was not forwarded: {result}")
print(f"alert delivery canary PASS: id={canary_id}")
PY
