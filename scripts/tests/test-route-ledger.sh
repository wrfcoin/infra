#!/usr/bin/env bash
# =============================================================================
# Route-ledger enforcement (infra#598)
# =============================================================================
# Renders the testnet compose config and holds it to testnet/edge/route-ledger.yml:
#
#   1. Every compose service MUST appear in the ledger — adding a service forces
#      an explicit exposure decision; silence is a failure, not a default.
#   2. Every ledger service MUST exist in compose — the ledger cannot rot into
#      documenting services that are gone.
#   3. No service may publish a host port off 127.0.0.1 unless it is on the
#      explicit public-TCP allowlist (P2P by design: node:9000, seed:9001).
#      This is the check the owner asked for on #598: a private route acquiring
#      a public host port is a FAILURE, wherever it comes from.
#   4. `never`-class services may publish no host port at all.
#   5. The ledger is valid YAML (yaml.safe_load), and the strict parse yields
#      the same services and exposure classes as the line reader (infra#1086).
#
# The render uses --profile '*': profile-gated services (the seed-profile
# faucet above all) are exactly the ones this gate must see.
#
# Tailnet-bind env vars (FAUCET_TAILNET_BIND_ADDR etc.) default to 127.0.0.1 in
# .env.testnet.example, so the rendered config is the loopback baseline; a
# deploy that overrides them is a deliberate operator act outside this gate.
#
# --self-test proves the gate can fail: it renders mutated configs (a `never`
# service acquiring a public port; a service missing from the ledger) and
# requires the corresponding check to refuse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="${ROOT}/testnet/docker-compose.testnet.yml"
ENV_FILE="${ROOT}/testnet/.env.testnet.example"
LEDGER="${ROOT}/testnet/edge/route-ledger.yml"

render() { # compose-file -> JSON on stdout
  bash "${ROOT}/testnet/tests/render-testnet-compose.sh" --env-file "$ENV_FILE" --profile '*' -f "$1" config --format json
}

check() { # rendered-json ledger-file -> exit 0/1, findings on stdout
  # The python body only parses the rendered JSON; it never runs docker.
    # dynamic-payload-reviewed: route-ledger-python-json-reader
  RENDERED="$1" LEDGER_FILE="$2" python3 - <<'PY'
import json, os, re, sys

config = json.loads(open(os.environ["RENDERED"]).read())
services = config["services"]

ledger, current = {}, None
for line in open(os.environ["LEDGER_FILE"]):
    if line.startswith('#') or not line.strip():
        continue
    m = re.match(r'^  ([\w-]+):', line)
    if m:
        current = m.group(1)
        ledger.setdefault(current, None)
    m = re.search(r'exposure:\s*([\w-]+)', line)
    if m and current:
        ledger[current] = m.group(1)

PUBLIC_TCP_ALLOWLIST = {("wrfcoin-node", "9000"), ("wrfcoin-seed", "9001")}
failures = []

# infra#1086: the ledger must also be valid YAML, and a strict parse must agree
# with the line reader above. Any consumer that loads it as YAML (yq, PyYAML, an
# admission gate) must see the same services and exposure classes.
import yaml
try:
    doc = yaml.safe_load(open(os.environ["LEDGER_FILE"]))
except yaml.YAMLError as exc:
    doc = None
    failures.append(f"route ledger is not valid YAML: {' '.join(str(exc).split())}")
if doc is not None:
    parsed = doc.get("services") if isinstance(doc, dict) else None
    if not isinstance(parsed, dict):
        failures.append("route ledger YAML has no 'services' mapping")
    else:
        strict = {name: (entry or {}).get("exposure") for name, entry in parsed.items()}
        if strict != ledger:
            diff = sorted(set(strict.items()) ^ set(ledger.items()))
            failures.append(f"strict YAML parse disagrees with the line reader: {diff}")

for name in services:
    if name not in ledger:
        failures.append(f"compose service '{name}' has NO ledger entry — exposure undecided")
for name, exposure in ledger.items():
    if name not in services:
        failures.append(f"ledger entry '{name}' does not exist in compose — stale ledger")
    if exposure is None:
        failures.append(f"ledger entry '{name}' has no exposure class")

for name, service in services.items():
    exposure = ledger.get(name)
    for port in service.get("ports", []):
        published = str(port.get("published", ""))
        host_ip = port.get("host_ip", "")
        if exposure == "never":
            failures.append(f"'{name}' is exposure=never but publishes host port {host_ip}:{published}")
            continue
        if host_ip != "127.0.0.1" and (name, published) not in PUBLIC_TCP_ALLOWLIST:
            failures.append(
                f"'{name}' publishes {host_ip or '<all interfaces>'}:{published} — "
                f"off-loopback bind outside the public-TCP allowlist (ledger exposure: {exposure})"
            )

if failures:
    print("ROUTE-LEDGER: FAIL")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
print(f"ROUTE-LEDGER: PASS — {len(services)} compose services all ledgered; no off-loopback binds outside the P2P allowlist")
PY
}

self_test() {
  tmp="$(mktemp -d)"; trap 'rm -rf "${tmp:-}"' EXIT
  render "$COMPOSE_FILE" > "$tmp/base.json"

  echo "=== self-test A: current compose + ledger -> expect PASS ==="
  check "$tmp/base.json" "$LEDGER"

  echo "=== self-test B (RED): 'never' service acquires a public port -> expect FAIL ==="
  python3 - "$tmp/base.json" "$tmp/leak.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["services"]["postgres"]["ports"] = [
    {"mode": "ingress", "target": 5432, "published": "5432", "protocol": "tcp", "host_ip": "0.0.0.0"}
]
json.dump(config, open(sys.argv[2], "w"))
PY
  if check "$tmp/leak.json" "$LEDGER"; then
    echo "SELF-TEST: FAIL — a public postgres port was accepted" >&2; exit 1
  fi

  echo "=== self-test C (RED): service missing from the ledger -> expect FAIL ==="
  grep -v '^  wrfcoin-ml:' "$LEDGER" > "$tmp/ledger-missing.yml"
  if check "$tmp/base.json" "$tmp/ledger-missing.yml"; then
    echo "SELF-TEST: FAIL — an unledgered service was accepted" >&2; exit 1
  fi

  echo "=== self-test D (RED): loopback bind widened to 0.0.0.0 -> expect FAIL ==="
  python3 - "$tmp/base.json" "$tmp/widen.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
for port in config["services"]["wrfcoin-faucet"]["ports"]:
    port["host_ip"] = "0.0.0.0"
json.dump(config, open(sys.argv[2], "w"))
PY
  if check "$tmp/widen.json" "$LEDGER"; then
    echo "SELF-TEST: FAIL — a widened faucet bind was accepted" >&2; exit 1
  fi

  echo "SELF-TEST: PASS — the gate passes today's config and refuses all three mutations."
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
else
  tmp_json="$(mktemp)"; trap 'rm -f "$tmp_json"' EXIT
  render "$COMPOSE_FILE" > "$tmp_json"
  check "$tmp_json" "$LEDGER"
fi
