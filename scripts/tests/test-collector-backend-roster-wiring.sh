#!/usr/bin/env bash
# The collector's backend roster wiring is OFF by default and stays internal.
# Source checks only: no docker, no network, no secret.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
compose = (root / "testnet/docker-compose.testnet.yml").read_text(encoding="utf-8")
failures = []


def check(name, ok):
    print(("ok   " if ok else "FAIL ") + name)
    if not ok:
        failures.append(name)


def service(name):
    match = re.search(rf"(?ms)^  {re.escape(name)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|^[a-z]+:\n|\Z)", compose)
    assert match, f"service {name} not found"
    # Comments are not configuration.
    return "\n".join(line for line in match.group(1).splitlines() if not line.lstrip().startswith("#"))


collector = service("weather-collector-multi")
backend = service("wrfcoin-backend")
command = " ".join(re.search(r"(?ms)^    command: >-\n(.*?)^    [a-z_]+:", collector).group(1).split())

OLD = ('-c "while true; do node tests/security/fetch-ambient-weather-multi.cjs '
       '--credentials-file /secrets/ambient-roster.json || true; sleep 300; done"')
check("the roster arguments come from MULTI_COLLECTOR_ROSTER_ARGS, empty by default",
      "--credentials-file /secrets/ambient-roster.json ${MULTI_COLLECTOR_ROSTER_ARGS:-} || true" in command)
check("with the variable unset the command is word for word what it was",
      " ".join(command.replace("${MULTI_COLLECTOR_ROSTER_ARGS:-}", "").split()) == OLD)
check("the hand-kept roster file is still read", "--credentials-file /secrets/ambient-roster.json" in command)
check("the collector reaches the backend by its service name on the compose network",
      re.search(r"(?m)^      BACKEND_HOST: wrfcoin-backend$", collector) is not None
      and re.search(r'(?m)^      BACKEND_PORT: "4001"$', collector) is not None)
check("both services are on the same internal network",
      re.search(r"(?m)^      - wrfcoin-testnet$", collector) is not None
      and re.search(r"(?m)^      wrfcoin-testnet: \{\}$", backend) is not None)
check("the collector is not on the ingress network the public proxies use", "wrfcoin-ingress" not in collector)
check("the backend can never stop the collector: no depends_on for it",
      "wrfcoin-backend" not in re.sub(r"(?m)^      BACKEND_HOST: wrfcoin-backend$", "", collector))
check("the backend switch is passed through and has no default that turns it on",
      re.search(r"(?m)^      COLLECTOR_ROSTER_ENABLED: \$\{COLLECTOR_ROSTER_ENABLED:-\}$", backend) is not None)
check("the collector is given no backend encryption key and no database address",
      not re.search(r"API_KEY_ENCRYPTION_KEY|DATABASE_URL|POSTGRES_PASSWORD", collector))
check("the collector publishes no port", re.search(r"(?m)^    ports:", collector) is None)

# Nothing in the tree switches it on: that is a deploy-kit step.
on = []
for path in sorted((root / "testnet").rglob("*")):
    if not path.is_file() or path.suffix in (".png", ".jpg", ".gz", ".zip") or path.stat().st_size > 2_000_000:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if re.search(r"COLLECTOR_ROSTER_ENABLED\s*[:=]\s*[\"']?true", stripped) or \
           re.search(r"MULTI_COLLECTOR_ROSTER_ARGS\s*[:=]\s*[\"']?\S*--backend-roster", stripped):
            on.append(f"{path.relative_to(root)}: {stripped[:80]}")
check("no file under testnet/ switches the backend roster on", not on)
for item in on:
    print("     " + item)

boundary = (root / "testnet/edge/verify_public_exposure_boundary.py").read_text(encoding="utf-8")
runtime = (root / "testnet/edge/verify_public_exposure_runtime.py").read_text(encoding="utf-8")
internal = re.search(r"(?ms)^INTERNAL_ONLY_PATHS = \((.*?)^\)", boundary).group(1)
denied = re.search(r"(?ms)^DENIED_PUBLIC_READS = \((.*?)^\)", runtime).group(1)
gate_on = re.search(r"(?ms)^READONLY_SIBLINGS_DENIED = \((.*?)^\)", runtime).group(1)
for path in ("/api/weather/stations/collector-roster", "/api/weather/stations/credentials"):
    check(f"the edge boundary check lists {path} as internal only", f'"{path}"' in internal)
    check(f"the edge runtime check expects 404 for {path}", f'"{path}"' in denied)
    check(f"and still 404 with the read-only gate on for {path}", f'"{path}"' in gate_on)

ledger = (root / "testnet/edge/route-ledger.yml").read_text(encoding="utf-8")
check("the route ledger still says the collector is never exposed",
      "weather-collector-multi: { exposure: never }" in ledger)

if failures:
    raise SystemExit(f"{len(failures)} check(s) failed")
print("PASS collector backend roster wiring")
PY
