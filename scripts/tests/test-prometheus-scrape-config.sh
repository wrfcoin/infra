#!/usr/bin/env bash
# infra#1078: the testnet Prometheus scrape set must match what is deployed.
#
# The r11 window (2026-09-26) found three permanently-down jobs: governance and
# iot were scraped at a /metrics route their servers never had (404), and the
# faucet's metrics token had drifted from the bearer file (403). ServiceDown
# then paged for healthy services. This suite checks, offline:
#
#   1. every static target is a service in docker-compose.testnet.yml, on a
#      port that service actually uses, and outside an inactive profile unless
#      the job is explicitly allowed to be;
#   2. every job has a declared /metrics source in METRICS_SOURCES below, and
#      the in-repo ones (faucet) really serve that path. Services known to have
#      no route (governance, iot) must not be scraped. With BACKEND_DIR set
#      (a backend checkout), backend-image jobs are checked against the entry
#      source that infra/docker/esbuild-backend.sh bundles into their command;
#   3. the ServiceDown job allowlist equals the scraped job set minus the
#      metrics-only jobs (a token-gated scrape failing is not an outage), each
#      metrics-only job has a warning-severity alert, and every service without
#      a liveness scrape (no /metrics route, or metrics-only) has its /health
#      probed by the wrfcoin-service-health blackbox job;
#   4. `promtool check config` and `promtool test rules` (every
#      testnet/*.test.yml) pass, run from the prometheus image tag the
#      compose file pins (exit 77 = UNVERIFIED when docker or the image is
#      unavailable; checks 1-3 must still have passed).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM="${PROM_CONFIG_UNDER_TEST:-${ROOT}/testnet/prometheus.testnet.yml}"
RULES="${ALERT_RULES_UNDER_TEST:-${ROOT}/testnet/alert-rules.yml}"

python3 - "$ROOT" "$PROM" "$RULES" "${BACKEND_DIR:-}" <<'PY' || { echo "PROMETHEUS_SCRAPE_TESTS=FAIL" >&2; exit 1; }
import os, re, sys
import yaml

root, prom_path, rules_path, backend_dir = sys.argv[1:5]
compose = yaml.safe_load(open(f"{root}/testnet/docker-compose.testnet.yml", encoding="utf-8"))["services"]
prom = yaml.safe_load(open(prom_path, encoding="utf-8"))
rules = yaml.safe_load(open(rules_path, encoding="utf-8"))
compose_text = open(f"{root}/testnet/docker-compose.testnet.yml", encoding="utf-8").read()

# Where each job's metrics come from. A new job needs an entry here, so adding
# a scrape target forces someone to name the code that serves it.
#   ("infra", file, regex)     checked here: the route must exist in this repo
#   ("backend", None, None)    backend-image service; checked when BACKEND_DIR is set
#   ("external", note, None)   another repo or a third-party exporter image
METRICS_SOURCES = {
    "wrfcoin-node": ("external", "core4 native-chain launch_api /metrics", None),
    "wrfcoin-backend": ("external", "backend main API (Dockerfile.backend-api, tsx) /metrics, backend#1234", None),
    "wrfcoin-weather-earnings": ("backend", None, None),
    "wrfcoin-faucet": ("infra", "testnet/services/faucet/server.js", r"app\.get\(\s*['\"]/metrics['\"]"),
    "loki": ("external", "grafana/loki image", None),
    "node-exporter": ("external", "prom/node-exporter image", None),
    "cadvisor": ("external", "cadvisor image", None),
    "postgres-exporter": ("external", "postgres-exporter image", None),
    "wrfcoin-backend-health": ("external", "prom/blackbox-exporter /probe", None),
    "wrfcoin-service-health": ("external", "prom/blackbox-exporter /probe", None),
    "chain-ops-exporter": ("infra", "testnet/services/chain-ops-exporter/chain_ops_exporter.py", r"self\.path == ['\"]/metrics['\"]"),
}
# Jobs whose failed scrape is NOT an outage (the /metrics route is token-gated
# and the token can drift). They are kept out of ServiceDown, must have their
# own non-paging alert on up == 0, and their service's /health must be probed.
METRICS_ONLY_JOBS = {"wrfcoin-faucet": "FaucetMetricsScrapeFailing"}
# The blackbox job that carries liveness for services not paged via `up`.
HEALTH_PROBE_JOB = "wrfcoin-service-health"
# Services with no /metrics route. Scraping them is a permanent false page.
NO_METRICS_ROUTE = {
    "wrfcoin-governance": "backend server/governance_server.js has no /metrics (infra#1078)",
    "wrfcoin-iot": "backend server/iot_sensor_networks_server.js has no /metrics (infra#1078)",
}
# Profile-gated services that may still be scraped by the default config.
PROFILED_TARGETS_ALLOWED = {
    "wrfcoin-faucet": "the deployed testnet always runs the seed profile",
}

problems = []
jobs = {}
for job in prom["scrape_configs"]:
    name = job["job_name"]
    targets = [t for sc in job.get("static_configs", []) for t in sc.get("targets", [])]
    jobs[name] = (job, targets)
if not jobs:
    problems.append("no scrape jobs parsed: every other check would be vacuous")

def service_ports(svc):
    """The ports the service itself listens on: the container side of `ports`,
    `expose`, PORT-named environment values, `--*listen*`/`--*port*` command
    flags, and localhost/127.0.0.1 URLs in its own healthcheck. URLs of OTHER
    services in its environment are deliberately not counted."""
    block = compose[svc]
    ports = set()
    for p in block.get("ports", []) or []:
        spec = str(p.get("target") if isinstance(p, dict) else p).split("/")[0]
        ports.add(spec.rsplit(":", 1)[-1])
    for p in block.get("expose", []) or []:
        ports.add(str(p))
    env = block.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
    for key, value in env.items():
        if re.fullmatch(r"(\w+_)?PORT", key) and re.fullmatch(r"\d{2,5}", str(value or "")):
            ports.add(str(value))
    command = block.get("command") or []
    for arg in command if isinstance(command, list) else str(command).split():
        m = re.match(r"--[\w.-]*(listen|port|address)[\w.-]*=\S*?:?(\d{2,5})$", str(arg))
        if m:
            ports.add(m.group(2))
    health = yaml.safe_dump((block.get("healthcheck") or {}).get("test"))
    ports.update(re.findall(r"(?:localhost|127\.0\.0\.1):(\d{2,5})", health))
    return ports

for name, (job, targets) in sorted(jobs.items()):
    if name in NO_METRICS_ROUTE:
        problems.append(f"{name}: scraped, but {NO_METRICS_ROUTE[name]}")
    if not targets:
        problems.append(f"{name}: no static targets")
    for target in targets:
        # blackbox: the probed URL is the target; the scrape goes to the exporter.
        address = re.sub(r"^https?://", "", target).split("/")[0]
        host, _, port = address.partition(":")
        if host not in compose:
            problems.append(f"{name}: target {target}: {host} is not a service in docker-compose.testnet.yml")
            continue
        profiles = compose[host].get("profiles") or []
        if profiles and host not in PROFILED_TARGETS_ALLOWED:
            problems.append(f"{name}: target {host} only runs under profile(s) {profiles}; scraping it pages whenever they are off")
        if port and port not in service_ports(host):
            problems.append(f"{name}: target port {port} is not a port {host} uses ({sorted(service_ports(host))})")
    for relabel in job.get("relabel_configs", []) or []:
        replacement = relabel.get("replacement", "")
        if relabel.get("target_label") == "__address__":
            host = replacement.split(":")[0]
            if host not in compose:
                problems.append(f"{name}: relabelled scrape address {replacement} is not a compose service")

    source = METRICS_SOURCES.get(name)
    if source is None:
        problems.append(f"{name}: no entry in METRICS_SOURCES; name the code that serves its {job.get('metrics_path', '/metrics')}")
        continue
    kind, where, pattern = source
    if kind == "infra":
        text = open(f"{root}/{where}", encoding="utf-8").read()
        if not re.search(pattern, text):
            problems.append(f"{name}: {where} does not serve {job.get('metrics_path')}")
    elif kind == "backend" and backend_dir:
        host = re.sub(r"^https?://", "", targets[0]).split(":")[0]
        command = compose[host].get("command") or []
        entry = next((c for c in command if str(c).startswith("dist/")), None)
        mapping = dict(
            reversed(line.strip().split(":", 1))
            for line in open(f"{root}/infra/docker/esbuild-backend.sh", encoding="utf-8")
            if re.match(r"\s*server/\S+:dist/\S+\s*$", line)
        )
        src = mapping.get(entry)
        if not src:
            problems.append(f"{name}: cannot map {host}'s command entry {entry} to a backend source via esbuild-backend.sh")
        elif not re.search(r"\.get\(\s*['\"]/metrics['\"]", open(os.path.join(backend_dir, src), encoding="utf-8").read()):
            problems.append(f"{name}: backend {src} has no /metrics route")
        else:
            print(f"  {name}: backend {src} serves /metrics")

for svc in NO_METRICS_ROUTE:
    if svc not in compose:
        problems.append(f"NO_METRICS_ROUTE names {svc}, which is not a compose service: stale entry")

# ServiceDown's allowlist must be exactly the scraped job set.
service_down = [r for g in rules["groups"] for r in g["rules"] if r.get("alert") == "ServiceDown"]
if len(service_down) != 1:
    problems.append(f"expected one ServiceDown rule, found {len(service_down)}")
else:
    m = re.search(r'up\{job=~"([^"]+)"\}\s*==\s*0', service_down[0]["expr"])
    if not m:
        problems.append("ServiceDown expression is not up{job=~\"...\"} == 0")
    else:
        allow = set(m.group(1).split("|"))
        want = set(jobs) - set(METRICS_ONLY_JOBS)
        if allow != want:
            problems.append(
                f"ServiceDown allowlist != scraped liveness jobs: only alerted {sorted(allow - want)}, "
                f"not alerted {sorted(want - allow)}")

all_rules = {r.get("alert"): r for g in rules["groups"] for r in g["rules"] if r.get("alert")}
for job, alert in METRICS_ONLY_JOBS.items():
    rule = all_rules.get(alert)
    if not rule or f'up{{job="{job}"}}' not in rule["expr"]:
        problems.append(f"{job}: metrics-only job needs alert {alert} on up{{job=\"{job}\"}}")
    elif (rule.get("labels") or {}).get("severity") == "critical":
        problems.append(f"{alert}: a token-gated scrape failure must not page (severity critical)")
probe = jobs.get(HEALTH_PROBE_JOB)
probed = {re.sub(r"^https?://", "", t).split(":")[0] for t in (probe[1] if probe else [])}
for svc in sorted(set(NO_METRICS_ROUTE) | set(METRICS_ONLY_JOBS)):
    if svc not in probed:
        problems.append(f"{svc}: no liveness scrape, and {HEALTH_PROBE_JOB} does not probe its /health")
probe_alert = [r for r in all_rules.values() if f'probe_success{{job="{HEALTH_PROBE_JOB}"}}' in r["expr"]]
if not probe_alert or (probe_alert[0].get("labels") or {}).get("severity") != "critical":
    problems.append(f"no critical alert on probe_success{{job=\"{HEALTH_PROBE_JOB}\"}} == 0")

for p in problems:
    print(f"FAIL: {p}", file=sys.stderr)
if problems:
    sys.exit(1)
print(f"  inventory: {len(jobs)} jobs, all targets are compose services on their ports, "
      f"ServiceDown allowlist == liveness jobs, health probes cover {sorted(probed)}" + ("" if backend_dir else " (BACKEND_DIR unset: backend routes not checked)"))
PY

# ---- promtool check config, with the image tag the compose file runs.
image="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["services"]["prometheus"]["image"])' \
  "$ROOT/testnet/docker-compose.testnet.yml")" || { echo "PROMETHEUS_SCRAPE_TESTS=FAIL cannot read the prometheus image" >&2; exit 1; }
if ! docker info >/dev/null 2>&1; then
  echo "PROMETHEUS_SCRAPE_TESTS=UNVERIFIED docker unavailable: promtool check config did not run (inventory checks passed)" >&2
  exit 77
fi
if ! docker image inspect "$image" >/dev/null 2>&1 && ! timeout 300 docker pull -q "$image" >/dev/null 2>&1; then
  echo "PROMETHEUS_SCRAPE_TESTS=UNVERIFIED cannot obtain $image: promtool check config did not run (inventory checks passed)" >&2
  exit 77
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The container sees the same /etc/prometheus layout the compose mounts give it.
cp "$PROM" "$TMP/prometheus.yml"
cp "$ROOT"/testnet/alert-rules*.yml "$TMP/"
cp "$RULES" "$TMP/alert-rules.yml"
printf 'fixture-token\n' > "$TMP/bearer_token"
chmod -R a+rX "$TMP"
if ! docker run --rm -v "$TMP:/etc/prometheus:ro" --entrypoint promtool "$image" \
    check config /etc/prometheus/prometheus.yml > "$TMP/promtool.out" 2>&1; then
  sed 's/^/    /' "$TMP/promtool.out" >&2
  echo "PROMETHEUS_SCRAPE_TESTS=FAIL promtool check config ($image)" >&2
  exit 1
fi
echo "  promtool check config ($image): $(grep -c 'SUCCESS' "$TMP/promtool.out") SUCCESS line(s)"
# Rule unit tests (alert-rules-gate.yml runs these on a hosted runner, which is
# VOID while hosted minutes are unavailable; this is the CT102 copy).
cp "$ROOT"/testnet/*.test.yml "$TMP/"
chmod -R a+rX "$TMP"
ntests=0
for t in "$TMP"/*.test.yml; do
  ntests=$((ntests + 1))
  if ! docker run --rm -v "$TMP:/t:ro" -w /t --entrypoint promtool "$image" \
      test rules "/t/$(basename "$t")" > "$TMP/ruletest.out" 2>&1; then
    sed 's/^/    /' "$TMP/ruletest.out" >&2
    echo "PROMETHEUS_SCRAPE_TESTS=FAIL promtool test rules $(basename "$t")" >&2
    exit 1
  fi
  echo "  promtool test rules $(basename "$t"): SUCCESS"
done
[[ $ntests -gt 0 ]] || { echo "PROMETHEUS_SCRAPE_TESTS=FAIL no testnet/*.test.yml found" >&2; exit 1; }
echo PROMETHEUS_SCRAPE_TESTS=PASS
