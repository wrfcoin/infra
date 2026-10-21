#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import sys

import yaml


ROOT = Path(__file__).resolve().parent


def load_yaml(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def fail(message: str) -> None:
    print(f"FAIL {message}")
    sys.exit(1)


def expect(condition: bool, message: str) -> None:
    if not condition:
      fail(message)
    print(f"PASS {message}")


def dashboard_targets(panel: dict) -> list[str]:
    return [target.get("expr", "") for target in panel.get("targets", [])]


def main() -> None:
    compose = load_yaml(ROOT / "docker-compose.yml")
    services = compose.get("services", {})
    expect(set(services.keys()) == {"prometheus", "grafana"}, "compose services = grafana,prometheus")

    prometheus = load_yaml(ROOT / "prometheus.yml")
    jobs = {job["job_name"]: job for job in prometheus.get("scrape_configs", [])}
    expect("wrf-compute-agent" in jobs, "prometheus job wrf-compute-agent present")
    expect(
        jobs["wrf-compute-agent"].get("metrics_path") == "/metrics",
        "prometheus wrf-compute-agent metrics_path=/metrics",
    )
    expect(
        jobs["wrf-compute-agent"]["static_configs"][0]["targets"] == [
            "host.docker.internal:3333"
        ],
        "prometheus wrf-compute-agent target host.docker.internal:3333",
    )
    expect("wrf-execution-engine" in jobs, "prometheus job wrf-execution-engine present")
    expect(
        jobs["wrf-execution-engine"].get("metrics_path") == "/metrics",
        "prometheus wrf-execution-engine metrics_path=/metrics",
    )
    expect(
        jobs["wrf-execution-engine"]["static_configs"][0]["targets"] == [
            "host.docker.internal:9100"
        ],
        "prometheus wrf-execution-engine target host.docker.internal:9100",
    )

    datasources = load_yaml(ROOT / "grafana" / "datasources.yml")
    configured = datasources.get("datasources", [])
    expect(len(configured) == 1, "grafana datasource count = 1")
    expect(configured[0]["uid"] == "prometheus-wrf", "grafana datasource uid = prometheus-wrf")

    providers = load_yaml(ROOT / "grafana" / "dashboards.yml").get("providers", [])
    expect(len(providers) == 1, "grafana dashboard provider count = 1")
    expect(
        providers[0]["options"]["path"] == "/etc/grafana/provisioning/dashboards/wrf",
        "grafana provider path = /etc/grafana/provisioning/dashboards/wrf",
    )

    dashboard_dir = ROOT / "grafana" / "dashboards"
    dashboard_paths = sorted(dashboard_dir.glob("*.json"))
    expect(len(dashboard_paths) == 2, "dashboard files = 2")

    overview = load_json(dashboard_paths[0])
    engine = load_json(dashboard_paths[1])
    dashboards = {overview["title"]: overview, engine["title"]: engine}

    expect("WRF Useful Work Overview" in dashboards, "dashboard title WRF Useful Work Overview")
    overview_exprs = "\n".join(
        expr for panel in dashboards["WRF Useful Work Overview"]["panels"] for expr in dashboard_targets(panel)
    )
    expect(
        "wrf_compute_agent_task_executions_total" in overview_exprs,
        "overview dashboard queries wrf_compute_agent_task_executions_total",
    )
    expect(
        "wrf_compute_agent_task_execution_duration_seconds_total" in overview_exprs,
        "overview dashboard queries wrf_compute_agent_task_execution_duration_seconds_total",
    )

    expect("WRF Execution Engine" in dashboards, "dashboard title WRF Execution Engine")
    engine_exprs = "\n".join(
        expr for panel in dashboards["WRF Execution Engine"]["panels"] for expr in dashboard_targets(panel)
    )
    expect(
        "wrf_execution_runs_total" in engine_exprs,
        "execution dashboard queries wrf_execution_runs_total",
    )
    expect(
        "wrf_execution_run_duration_seconds_bucket" in engine_exprs,
        "execution dashboard queries wrf_execution_run_duration_seconds_bucket",
    )
    expect(
        "wrf_execution_output_bytes_total" in engine_exprs,
        "execution dashboard queries wrf_execution_output_bytes_total",
    )

    print("PASS provisioning bundle is internally consistent")


if __name__ == "__main__":
    main()
