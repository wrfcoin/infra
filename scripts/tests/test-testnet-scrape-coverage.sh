#!/usr/bin/env bash
# Static verifier for the infra#476 scrape-coverage guardrails.
#
# Formerly scripts/verify-testnet-scrape-coverage.sh. That copy depended on
# `rg`, which the CT102 runner and the workstation do not have, so all 9
# checks failed, and nothing ran it. It now lives under scripts/tests/, so the
# Scripts Tests job on CT102 discovers it, and it matches with python.
#
# Division of labour with scripts/tests/test-prometheus-scrape-config.sh
# (infra#1078):
#   that suite:  every scrape target is a real compose service on its port,
#                every job has a /metrics source, the ServiceDown allowlist
#                equals the liveness jobs, promtool check config + test rules;
#   this suite:  the infra#476 coverage floor. node-exporter and cadvisor
#                must be scraped; their dedicated scrape-down alerts must exist;
#                node-exporter is pinned; the coverage matrix keeps its three
#                documented decisions. It also checks that node-discovery, if it
#                is ever re-added, is scraped on its container port 9001.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM_FILE="${PROM_CONFIG_UNDER_TEST:-$ROOT/testnet/prometheus.testnet.yml}"
ALERT_FILE="${ALERT_RULES_UNDER_TEST:-$ROOT/testnet/alert-rules.yml}"
COMPOSE_FILE="$ROOT/infra/monitoring/docker-compose.comprehensive-monitoring.yml"
TESTNET_COMPOSE="$ROOT/testnet/docker-compose.testnet.yml"
MATRIX_FILE="${MATRIX_UNDER_TEST:-$ROOT/testnet/docs/scrape-coverage-matrix.md}"

python3 - "$PROM_FILE" "$ALERT_FILE" "$COMPOSE_FILE" "$TESTNET_COMPOSE" "$MATRIX_FILE" <<'PY'
import re, sys
import yaml

prom_path, alert_path, compose_path, testnet_compose_path, matrix_path = sys.argv[1:6]
prom = yaml.safe_load(open(prom_path, encoding="utf-8"))
alerts = yaml.safe_load(open(alert_path, encoding="utf-8"))
matrix = open(matrix_path, encoding="utf-8").read()

jobs = {
    j["job_name"]: [t for sc in j.get("static_configs", []) for t in sc.get("targets", [])]
    for j in prom.get("scrape_configs", [])
}
alert_names = {r.get("alert") for g in alerts["groups"] for r in g["rules"]}
passed, failed = 0, 0

def check(ok, label):
    global passed, failed
    print(f"[{'PASS' if ok else 'FAIL'}] {label}")
    if ok:
        passed += 1
    else:
        failed += 1

def image(path, service):
    services = yaml.safe_load(open(path, encoding="utf-8")).get("services") or {}
    return (services.get(service) or {}).get("image")

nd = jobs.get("wrfcoin-node-discovery")
check(nd is None or nd == ["wrfcoin-node-discovery:9001"],
      "wrfcoin-node-discovery, if scraped, uses container port 9001 "
      + ("(not scraped: full profile)" if nd is None else f"(targets {nd})"))
check(jobs.get("node-exporter") == ["node-exporter:9100"], "prometheus scrapes node-exporter:9100")
check(jobs.get("cadvisor") == ["cadvisor:8080"], "prometheus scrapes cadvisor:8080")
check("NodeExporterScrapeDown" in alert_names, "alert-rules defines NodeExporterScrapeDown")
check("CAdvisorScrapeDown" in alert_names, "alert-rules defines CAdvisorScrapeDown")
check(image(compose_path, "node-exporter") == "prom/node-exporter:v1.8.0",
      "comprehensive monitoring pins prom/node-exporter:v1.8.0")
check(image(testnet_compose_path, "node-exporter") == "prom/node-exporter:v1.8.0",
      "testnet compose pins prom/node-exporter:v1.8.0")
check(re.search(r"wrfcoin-explorer[\s\S]*no `/metrics` endpoint", matrix) is not None,
      "coverage matrix documents the explorer metrics exclusion")
check(re.search(r"core4#1620[\s\S]*wrfcoin_state_divergence_total", matrix) is not None,
      "coverage matrix documents the infra#475/core4#1620 divergence dependency")
check(re.search(r"cadvisor[\s\S]*127\.0\.0\.1:8082:8080", matrix) is not None,
      "coverage matrix documents the cAdvisor host-port conflict status")

print(f"\n  infra#476 scrape-coverage verifier: PASS={passed} FAIL={failed}")
sys.exit(1 if failed or passed == 0 else 0)
PY
