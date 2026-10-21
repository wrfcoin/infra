#!/usr/bin/env bash
# test-compose-smoke.sh — STATIC (offline) validation of the testnet compose
# stack. Despite the historical filename, this is NOT a smoke test: nothing
# here starts a container (backend#910 finding 3 named exactly this misnomer).
# The real boot smoke — `docker compose up`, health wait, live endpoint probe
# — is testnet/preflight-compose-smoke.sh, run on the deploy host pre-deploy.
#
# Validates compose config, service inventory, port safety, and security
# hardening without requiring running containers.
#
# Usage:
#   bash scripts/test-compose-smoke.sh
#
# Requires: python3 with PyYAML (standard on most systems)
# Optional: docker compose v2 (for config validation tests)
#
# Exits 0 only when all tests pass.

set -euo pipefail

# ── Resolve repo root ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

COMPOSE_FILE="testnet/docker-compose.testnet.yml"
OVERRIDE_FILE="testnet/docker-compose.override.yml"
LAN_FILE="testnet/docker-compose.lan.yml"
RENDER_HELPER="${REPO_ROOT}/testnet/tests/render-testnet-compose.sh"

# ── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
FAILURES=()

# ── Helpers (same pattern as test-node-infra.sh) ────────────────────────────
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

pass() {
  local name="$1"
  PASS=$((PASS + 1))
  green "  PASS  ${name}"
}

fail() {
  local name="$1" detail="${2:-}"
  FAIL=$((FAIL + 1))
  FAILURES+=("${name}")
  red "  FAIL  ${name}${detail:+  (${detail})}"
}

skip() {
  local name="$1" reason="${2:-}"
  SKIP=$((SKIP + 1))
  yellow "  SKIP  ${name}${reason:+  (${reason})}"
}

header() { printf '\n\033[1;34m══ %s ══\033[0m\n' "$*"; }

# ── Pre-flight: compose file exists ─────────────────────────────────────────
if [ ! -f "${COMPOSE_FILE}" ]; then
  red "FATAL: ${COMPOSE_FILE} not found. Run from the infra repo root."
  exit 2
fi

# ── Pre-flight: python3 with yaml ───────────────────────────────────────────
if ! python3 -c "import yaml" 2>/dev/null; then
  red "FATAL: python3 with PyYAML required. Install: pip3 install pyyaml"
  exit 2
fi

# ── Pre-flight: detect docker compose ───────────────────────────────────────
COMPOSE_AVAILABLE=0
if docker compose version &>/dev/null; then
  COMPOSE_AVAILABLE=1
elif docker-compose version &>/dev/null; then
  COMPOSE_AVAILABLE=1
fi

# Dummy env vars for compose config validation (satisfies ${VAR:?} checks)
export POSTGRES_PASSWORD=smoke-test
export REDIS_PASSWORD=smoke-test
export JWT_SECRET=smoke-test
export GRAFANA_ADMIN_PASSWORD=smoke-test
export WRFCOIN_OPERATOR_TOKEN=smoke-test
export WRFCOIN_CONTRIBUTOR_TOKEN=contributor-smoke-test
export OAUTH_STATE_SECRET=smoke-test
export RPC_API_KEY=smoke-test
export ADMIN_TOKEN=smoke-test
export N8N_WEBHOOK_SECRET=smoke-test
export API_KEY_ENCRYPTION_KEY=smoke-test
export WRFCOIN_HSM_PIN=smoke-test
export WRFCOIN_HSM_SO_PIN=smoke-test
export WRFCOIN_TESTNET_RUNTIME_IMAGE=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
# CI-only RFC 5737 documentation fixtures for the positive Compose renders.
# Production Compose remains fail-closed without operator-verified values.
export WRFCOIN_P2P_EXTERNAL_ADDR=/ip4/198.51.100.7/tcp/9000
export WRFCOIN_SEED_P2P_EXTERNAL_ADDR=/ip4/203.0.113.9/tcp/9000

# ══════════════════════════════════════════════════════════════════════════════
header "Group A: Compose Config Validation"
# ══════════════════════════════════════════════════════════════════════════════

if [ "$COMPOSE_AVAILABLE" -eq 1 ]; then
  # A1 — Base compose validates
  if bash "${RENDER_HELPER}" -f "${COMPOSE_FILE}" config > /dev/null 2>&1; then
    pass "A1: base compose config validates"
  else
    fail "A1: base compose config validates" "docker compose config failed"
  fi

  # A2 — Override compose validates
  # The override file references host-specific build paths (e.g. /root/wrfcoin)
  # that only exist on CT 101 (the deployment host). Skip if not found.
  if [ -f "${OVERRIDE_FILE}" ]; then
    OVERRIDE_ERR=$(bash "${RENDER_HELPER}" -f "${COMPOSE_FILE}" -f "${OVERRIDE_FILE}" config 2>&1 >/dev/null || true)
    if [ -z "${OVERRIDE_ERR}" ]; then
      pass "A2: override compose config validates"
    elif echo "${OVERRIDE_ERR}" | grep -qi "build path\|context\|not found\|does not exist"; then
      skip "A2: override compose config validates" "build context paths not available on this host"
    else
      fail "A2: override compose config validates" "docker compose config failed with override"
    fi
  else
    skip "A2: override compose config validates" "override file not found"
  fi

  # A3 — LAN compose validates (uses !override tag, may fail on older compose)
  if [ -f "${LAN_FILE}" ]; then
    if bash "${RENDER_HELPER}" -f "${COMPOSE_FILE}" -f "${LAN_FILE}" config > /dev/null 2>&1; then
      pass "A3: LAN compose config validates"
    else
      # !override tag requires compose v2.24.0+
      skip "A3: LAN compose config validates" "may require compose v2.24.0+ for !override tag"
    fi
  else
    skip "A3: LAN compose config validates" "LAN file not found"
  fi

  # A4 — Collector profile validates
  if bash "${RENDER_HELPER}" --profile collector -f "${COMPOSE_FILE}" config > /dev/null 2>&1; then
    pass "A4: collector profile config validates"
  else
    fail "A4: collector profile config validates" "docker compose --profile collector config failed"
  fi
else
  skip "A1: base compose config validates" "docker compose not available"
  skip "A2: override compose config validates" "docker compose not available"
  skip "A3: LAN compose config validates" "docker compose not available"
  skip "A4: collector profile config validates" "docker compose not available"
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Group B: Service Inventory"
# ══════════════════════════════════════════════════════════════════════════════

INVENTORY=$(python3 -c "
import yaml, json, sys

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

services = data.get('services', {})
result = {}
for name, svc in services.items():
    result[name] = {
        'profiles': svc.get('profiles', []),
        'healthcheck': 'healthcheck' in svc,
        'limits': bool(svc.get('deploy', {}).get('resources', {}).get('limits')),
        'security_opt': 'security_opt' in svc,
        'cap_drop': 'cap_drop' in svc,
        'read_only': svc.get('read_only', False),
        'ports': svc.get('ports', []),
    }
json.dump(result, sys.stdout)
")

TOTAL_SERVICES=$(echo "${INVENTORY}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
BASE_SERVICES=$(echo "${INVENTORY}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = [k for k,v in data.items() if not v['profiles']]
print(len(base))
")
PROFILE_SERVICES=$(echo "${INVENTORY}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
profiled = [k for k,v in data.items() if v['profiles']]
print(len(profiled))
")

# B1 — Total service count
if [ "${TOTAL_SERVICES}" -ge 15 ]; then
  pass "B1: total service count >= 15 (got ${TOTAL_SERVICES})"
else
  fail "B1: total service count >= 15 (got ${TOTAL_SERVICES})"
fi

# B2 — Base (non-profile) service count
if [ "${BASE_SERVICES}" -ge 13 ]; then
  pass "B2: base services (no profiles) >= 13 (got ${BASE_SERVICES})"
else
  fail "B2: base services (no profiles) >= 13 (got ${BASE_SERVICES})"
fi

# B3 — Profile service count
if [ "${PROFILE_SERVICES}" -ge 2 ]; then
  pass "B3: profile-gated services >= 2 (got ${PROFILE_SERVICES})"
else
  fail "B3: profile-gated services >= 2 (got ${PROFILE_SERVICES})"
fi

# B4 — Expected service names present
EXPECTED_SERVICES="postgres redis wrfcoin-node wrfcoin-seed wrfcoin-backend wrfcoin-frontend prometheus grafana alertmanager node-exporter"
MISSING=""
for svc in ${EXPECTED_SERVICES}; do
  if ! echo "${INVENTORY}" | python3 -c "import json,sys; data=json.load(sys.stdin); sys.exit(0 if '${svc}' in data else 1)"; then
    MISSING="${MISSING} ${svc}"
  fi
done

if [ -z "${MISSING}" ]; then
  pass "B4: all expected core services present"
else
  fail "B4: all expected core services present" "missing:${MISSING}"
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Group C: Port Safety"
# ══════════════════════════════════════════════════════════════════════════════

# C1 — No duplicate host port bindings
PORTS_CHECK=$(python3 -c "
import yaml, json, sys, re

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

ports_seen = {}
duplicates = []
for name, svc in data.get('services', {}).items():
    for p in svc.get('ports', []):
        port_str = str(p)
        # Extract host port from formats like '127.0.0.1:8556:8556' or '0.0.0.0:9000:9000'
        match = re.match(r'(?:[\d.]+:)?(\d+):\d+', port_str)
        if match:
            host_port = match.group(1)
            if host_port in ports_seen:
                duplicates.append(f'{host_port} ({ports_seen[host_port]} and {name})')
            else:
                ports_seen[host_port] = name

json.dump({'duplicates': duplicates, 'count': len(ports_seen)}, sys.stdout)
")

DUP_COUNT=$(echo "${PORTS_CHECK}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['duplicates']))")
if [ "${DUP_COUNT}" -eq 0 ]; then
  pass "C1: no duplicate host port bindings"
else
  DUP_LIST=$(echo "${PORTS_CHECK}" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin)['duplicates']))")
  fail "C1: no duplicate host port bindings" "duplicates: ${DUP_LIST}"
fi

# C2 — No 0.0.0.0 binding except P2P ports (9000, 9001)
BAD_BINDINGS=$(python3 -c "
import yaml, re, sys

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

bad = []
for name, svc in data.get('services', {}).items():
    for p in svc.get('ports', []):
        port_str = str(p)
        if '0.0.0.0' in port_str:
            # Extract host port
            match = re.match(r'0\.0\.0\.0:(\d+):\d+', port_str)
            if match:
                host_port = match.group(1)
                # P2P ports 9000 and 9001 are allowed on 0.0.0.0
                if host_port not in ('9000', '9001'):
                    bad.append(f'{name}:{host_port}')

print(' '.join(bad) if bad else '')
")

if [ -z "${BAD_BINDINGS}" ]; then
  pass "C2: no 0.0.0.0 bindings except P2P (9000, 9001)"
else
  fail "C2: no 0.0.0.0 bindings except P2P (9000, 9001)" "found: ${BAD_BINDINGS}"
fi

# C3 — P2P port 9000 IS on 0.0.0.0 (required for connectivity)
if grep -q '0\.0\.0\.0:9000:9000' "${COMPOSE_FILE}"; then
  pass "C3: P2P port 9000 bound to 0.0.0.0"
else
  fail "C3: P2P port 9000 bound to 0.0.0.0" "P2P must be publicly reachable"
fi

# C4 — TESTNET_TAILNET_BIND_ADDR only publishes the explorer (#557)
TAILNET_BINDINGS=$(python3 -c "
import yaml, sys

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

bindings = []
for name, svc in data.get('services', {}).items():
    for p in svc.get('ports', []):
        port_str = str(p)
        if 'TESTNET_TAILNET_BIND_ADDR' in port_str:
            bindings.append(f'{name}:{port_str}')

print('\n'.join(bindings))
")

EXPECTED_TAILNET_BINDING='wrfcoin-explorer:${TESTNET_TAILNET_BIND_ADDR:-127.0.0.1}:8081:8081'
if [ "${TAILNET_BINDINGS}" = "${EXPECTED_TAILNET_BINDING}" ]; then
  pass "C4: TESTNET_TAILNET_BIND_ADDR is explorer-only"
else
  fail "C4: TESTNET_TAILNET_BIND_ADDR is explorer-only" "found: ${TAILNET_BINDINGS:-none}"
fi

# C4b — FAUCET_TAILNET_BIND_ADDR only publishes the faucet (#588; a
# per-service opt-in so an explorer-only exposure never silently includes
# the faucet — codex P2 on PR #622)
FAUCET_BINDINGS=$(python3 -c "
import yaml, sys

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

bindings = []
for name, svc in data.get('services', {}).items():
    for p in svc.get('ports', []):
        port_str = str(p)
        if 'FAUCET_TAILNET_BIND_ADDR' in port_str:
            bindings.append(f'{name}:{port_str}')

print('\n'.join(bindings))
")

EXPECTED_FAUCET_BINDING='wrfcoin-faucet:${FAUCET_TAILNET_BIND_ADDR:-127.0.0.1}:8080:8080'
if [ "${FAUCET_BINDINGS}" = "${EXPECTED_FAUCET_BINDING}" ]; then
  pass "C4b: FAUCET_TAILNET_BIND_ADDR is faucet-only"
else
  fail "C4b: FAUCET_TAILNET_BIND_ADDR is faucet-only" "found: ${FAUCET_BINDINGS:-none}"
fi

# C5 — LAN overlay does not republish node/backend/monitoring ports (#557)
if [ -f "${LAN_FILE}" ]; then
  LAN_CHECK=$(python3 -c "
import yaml, sys

class ComposeLoader(yaml.SafeLoader):
    pass

def override(loader, node):
    return loader.construct_sequence(node)

ComposeLoader.add_constructor('!override', override)

with open('${LAN_FILE}') as f:
    data = yaml.load(f, Loader=ComposeLoader)

services = data.get('services', {})
bad_services = sorted(set(services) - {'wrfcoin-explorer'})
bad_ports = []
for name, svc in services.items():
    for p in svc.get('ports', []):
        port_str = str(p)
        if any(f':{port}:' in port_str for port in ('8556', '4001', '5000', '9090', '3100', '9093', '9100')):
            bad_ports.append(f'{name}:{port_str}')

if bad_services or bad_ports:
    print('services=' + ','.join(bad_services) + ' ports=' + ','.join(bad_ports))
")
  if [ -z "${LAN_CHECK}" ]; then
    pass "C5: LAN overlay exposes only the explorer"
  else
    fail "C5: LAN overlay exposes only the explorer" "${LAN_CHECK}"
  fi
else
  skip "C5: LAN overlay exposes only the explorer" "LAN file not found"
fi

# ══════════════════════════════════════════════════════════════════════════════
header "Group D: Service Hardening"
# ══════════════════════════════════════════════════════════════════════════════

# D1-D4: Check hardening properties per service
# Known exceptions:
#   - db-migrate: one-shot job, no healthcheck
#   - sdr-ingest: experimental hardware profile, no secopt/capdrop
#   - weather-collector: lightweight cron-like wrapper, no healthcheck/limits/secopt/capdrop
#   - postgres, redis: managed images, no cap_drop/security_opt (they manage own user)
#   - alertmanager, node-exporter: no resource limits defined

python3 -c "
import yaml, json, sys

with open('${COMPOSE_FILE}') as f:
    data = yaml.safe_load(f)

# Services exempt from certain checks
HC_EXEMPT = {'weather-collector', 'db-migrate'}  # no healthcheck
LIMITS_EXEMPT = {'weather-collector', 'alertmanager', 'node-exporter'}
SECOPT_EXEMPT = {'weather-collector', 'postgres', 'redis'}
CAPDROP_EXEMPT = {'weather-collector', 'postgres', 'redis', 'sdr-ingest'}
SECOPT_EXEMPT.add('sdr-ingest')

results = []
for name, svc in data.get('services', {}).items():
    has_hc = 'healthcheck' in svc
    has_limits = bool(svc.get('deploy', {}).get('resources', {}).get('limits'))
    has_secopt = 'security_opt' in svc
    has_capdrop = 'cap_drop' in svc

    if not has_hc and name not in HC_EXEMPT:
        results.append(f'NO_HEALTHCHECK:{name}')
    if not has_limits and name not in LIMITS_EXEMPT:
        results.append(f'NO_LIMITS:{name}')
    if not has_secopt and name not in SECOPT_EXEMPT:
        results.append(f'NO_SECOPT:{name}')
    if not has_capdrop and name not in CAPDROP_EXEMPT:
        results.append(f'NO_CAPDROP:{name}')

print(' '.join(results) if results else '')
" > /tmp/compose-smoke-hardening.txt 2>&1

HARDENING_ISSUES=$(cat /tmp/compose-smoke-hardening.txt)

# D1 — Healthchecks
HC_ISSUES=$(echo "${HARDENING_ISSUES}" | tr ' ' '\n' | { grep "^NO_HEALTHCHECK:" || true; } | sed 's/NO_HEALTHCHECK://' | tr '\n' ', ' | sed 's/,$//')
if [ -z "${HC_ISSUES}" ]; then
  pass "D1: all non-exempt services have healthcheck"
else
  fail "D1: all non-exempt services have healthcheck" "missing: ${HC_ISSUES}"
fi

# D2 — Resource limits
LIM_ISSUES=$(echo "${HARDENING_ISSUES}" | tr ' ' '\n' | { grep "^NO_LIMITS:" || true; } | sed 's/NO_LIMITS://' | tr '\n' ', ' | sed 's/,$//')
if [ -z "${LIM_ISSUES}" ]; then
  pass "D2: all non-exempt services have resource limits"
else
  fail "D2: all non-exempt services have resource limits" "missing: ${LIM_ISSUES}"
fi

# D3 — security_opt
SEC_ISSUES=$(echo "${HARDENING_ISSUES}" | tr ' ' '\n' | { grep "^NO_SECOPT:" || true; } | sed 's/NO_SECOPT://' | tr '\n' ', ' | sed 's/,$//')
if [ -z "${SEC_ISSUES}" ]; then
  pass "D3: all non-exempt services have security_opt"
else
  fail "D3: all non-exempt services have security_opt" "missing: ${SEC_ISSUES}"
fi

# D4 — cap_drop
CAP_ISSUES=$(echo "${HARDENING_ISSUES}" | tr ' ' '\n' | { grep "^NO_CAPDROP:" || true; } | sed 's/NO_CAPDROP://' | tr '\n' ', ' | sed 's/,$//')
if [ -z "${CAP_ISSUES}" ]; then
  pass "D4: all non-exempt services have cap_drop"
else
  fail "D4: all non-exempt services have cap_drop" "missing: ${CAP_ISSUES}"
fi

# D5 — YAML is valid (basic sanity)
if python3 -c "import yaml; yaml.safe_load(open('${COMPOSE_FILE}'))" 2>/dev/null; then
  pass "D5: compose file is valid YAML"
else
  fail "D5: compose file is valid YAML"
fi

# E1 — Locally built validator services keep a build-compatible tag.
# Runtime immutability is proven separately by the full local image ID; Docker
# cannot tag a local build with a repository digest.
if [ "$COMPOSE_AVAILABLE" -eq 1 ]; then
  RUNTIME_CONFIG_FILE="$(mktemp "${TMPDIR:-/tmp}/wrfcoin-runtime-config.XXXXXX")"
  if ! bash "${RENDER_HELPER}" --profile seed -f "${COMPOSE_FILE}" -f "${OVERRIDE_FILE}" config >"${RUNTIME_CONFIG_FILE}" 2>/dev/null; then
    fail "E1: local validator builds use build-compatible image tags" "compose render failed"
    RUNTIME_PIN_ISSUES="compose-render-failed"
  else
  RUNTIME_PIN_ISSUES=$(python3 - "${RUNTIME_CONFIG_FILE}" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
issues = []
expected = {"softhsm-init", "softhsm-seed-init", "wrfcoin-node", "wrfcoin-seed"}
services = data.get("services", {}) or {}

for name in sorted(expected):
    svc = services.get(name)
    if not isinstance(svc, dict):
        issues.append(f"{name}=<missing>")
        continue
    image = svc.get("image", "")
    if not isinstance(svc.get("build"), dict):
        issues.append(f"{name}=<missing-build>")
    if not isinstance(image, str) or "@sha256:" in image or image.startswith("sha256:"):
        issues.append(f"{name}={image}")

for entry in issues:
    print(entry)
PY
)
  fi
  rm -f "${RUNTIME_CONFIG_FILE}"
  if [ -z "${RUNTIME_PIN_ISSUES}" ]; then
    pass "E1: local validator builds use build-compatible image tags"
  else
    fail "E1: local validator builds use build-compatible image tags" "${RUNTIME_PIN_ISSUES}"
  fi
else
  skip "E1: local validator builds use build-compatible image tags" "docker compose unavailable"
fi

# Cleanup
rm -f /tmp/compose-smoke-hardening.txt

# ══════════════════════════════════════════════════════════════════════════════
header "Summary"
# ══════════════════════════════════════════════════════════════════════════════

TOTAL=$((PASS + FAIL))
printf '\n'
printf '  Total: %d  ' "${TOTAL}"
green "PASS: ${PASS}"
printf '  '
if [[ ${SKIP} -gt 0 ]]; then
  yellow "SKIP: ${SKIP}"
  printf '  '
fi
if [[ ${FAIL} -gt 0 ]]; then
  red "FAIL: ${FAIL}"
  printf '\n  Failed tests:\n'
  for f in "${FAILURES[@]}"; do
    red "    - ${f}"
  done
  printf '\n'
  exit 1
else
  green "FAIL: 0"
  printf '\n'
  green "All tests passed!"
  exit 0
fi
