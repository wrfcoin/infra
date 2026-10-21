#!/usr/bin/env bash
# Evaluate desktop + N5 testnet launch readiness from deploy-status snapshots.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: bash $0 --n5 deploy-status-n5-pro.json --desktop deploy-status-desktop.json [options]

Options:
  --mode MODE           public-release (default) or developer-demo.
  --json-out PATH       Also write the machine-readable report JSON to PATH.
  --markdown-out PATH   Also write the human-readable report Markdown to PATH.
  --max-height-gap N    Maximum allowed N5/desktop height gap. Defaults to 5.
  --help                Show this help.

The input files are produced by testnet/scripts/deploy-status-snapshot.sh. This
gate is read-only: it does not SSH, fetch, deploy, restart, or mutate services.
Public-release mode requires a synthetic-free window with at least one observed
real contribution. Developer-demo mode remains permissive and is always
classified SIMULATED. The gate exits 0 on PASS and 1 on FAIL.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

python3 - "$@" <<'PY'
import argparse
import datetime
import json
import os
import re
import sys


CRITICAL_REPOS = ("infra", "backend", "core4", "frontend")
BLOCKER_LOG_PATTERN = re.compile(
    r"(panic|error|validation|min_work_factor|orphan|genesis|fork|reorg)",
    re.IGNORECASE,
)
ALERT_DELIVERY_MAX_AGE_SECONDS = int(
    os.environ.get("ALERT_DELIVERY_MAX_AGE_SECONDS", "300")
)
ALERT_DELIVERY_FUTURE_SKEW_SECONDS = 30


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--n5")
    parser.add_argument("--desktop")
    parser.add_argument("--json-out")
    parser.add_argument("--markdown-out")
    parser.add_argument("--mode", choices=("public-release", "developer-demo"), default="public-release")
    parser.add_argument("--max-height-gap", type=int, default=int(os.environ.get("MAX_HEIGHT_GAP", "5")))
    args = parser.parse_args()
    if not args.n5 or not args.desktop:
        print("ERROR: --n5 and --desktop snapshots are required", file=sys.stderr)
        sys.exit(2)
    return args


def load_snapshot(path):
    with open(path, "r", encoding="utf-8") as handle:
        snapshot = json.load(handle)
    snapshot["_path"] = path
    return snapshot


def unwrap(value):
    if isinstance(value, dict) and isinstance(value.get("data"), dict):
        return value["data"]
    return value


def endpoint(snapshot, name):
    for item in snapshot.get("endpoints", []):
        if item.get("name") == name:
            return item
    return {"name": name, "ok": False, "error": "missing endpoint snapshot"}


def body(snapshot, name):
    return unwrap(endpoint(snapshot, name).get("body"))


def first_number(*values):
    for value in values:
        if isinstance(value, bool):
            continue
        if isinstance(value, int):
            return value
        if isinstance(value, float):
            return int(value)
        if isinstance(value, str) and value.isdigit():
            return int(value)
    return None


def first_text(*values):
    for value in values:
        if isinstance(value, str) and value:
            return value
    return None


def peer_count(network_body):
    if not isinstance(network_body, dict):
        return None
    connected = network_body.get("connected_peers")
    if isinstance(connected, list):
        return len(connected)
    return first_number(network_body.get("peer_count"), connected, network_body.get("peers"))


def chain_height(snapshot):
    network = body(snapshot, "node_network_info")
    chain = body(snapshot, "node_blockchain")
    health = body(snapshot, "node_health")
    values = []
    for payload in (network, chain, health):
        if isinstance(payload, dict):
            values.extend(
                [
                    payload.get("chain_height"),
                    payload.get("block_height"),
                    payload.get("height"),
                    payload.get("current_height"),
                ]
            )
    return first_number(*values)


def tip_hash(snapshot):
    chain = body(snapshot, "node_blockchain")
    network = body(snapshot, "node_network_info")
    for payload in (chain, network):
        if isinstance(payload, dict):
            value = first_text(
                payload.get("tip_hash"),
                payload.get("latest_block_hash"),
                payload.get("block_hash"),
                payload.get("head_hash"),
            )
            if value:
                return value
    return None


def sync_status(snapshot):
    network = body(snapshot, "node_network_info")
    health = body(snapshot, "node_health")
    chain = body(snapshot, "node_blockchain")
    for payload in (network, health, chain):
        if isinstance(payload, dict):
            value = first_text(payload.get("sync_status"), payload.get("status"))
            if value:
                return value
    return None


def snapshot_summary(snapshot):
    network = body(snapshot, "node_network_info")
    return {
        "node_name": snapshot.get("node_name"),
        "path": snapshot.get("_path"),
        "height": chain_height(snapshot),
        "tip_hash": tip_hash(snapshot),
        "peer_count": peer_count(network),
        "sync_status": sync_status(snapshot),
    }


def check(result, name, ok, details, severity="blocker"):
    status = "pass" if ok else ("warn" if severity == "warning" else "fail")
    result["checks"].append({"name": name, "status": status, "details": details})
    if status == "fail" and not result["first_blocking_reason"]:
        result["first_blocking_reason"] = details


def check_snapshot_schema(result, label, snapshot):
    ok = snapshot.get("schema") == "wrfcoin.testnet.deploy_status_snapshot.v1"
    check(result, f"{label}: snapshot schema", ok, f"schema={snapshot.get('schema')!r}")


def check_source_repos(result, label, snapshot):
    repos = {repo.get("name"): repo for repo in snapshot.get("source_repos", [])}
    failures = []
    for name in CRITICAL_REPOS:
        repo = repos.get(name)
        if not repo:
            failures.append(f"{name}: missing from snapshot")
            continue
        if not repo.get("exists"):
            failures.append(f"{name}: repo missing at {repo.get('path')}")
            continue
        if repo.get("detached"):
            failures.append(f"{name}: detached HEAD")
        if repo.get("dirty"):
            failures.append(f"{name}: dirty working tree")
        if repo.get("ahead") not in (0, None):
            failures.append(f"{name}: ahead={repo.get('ahead')}")
        if repo.get("behind") not in (0, None):
            failures.append(f"{name}: behind={repo.get('behind')}")
        if not repo.get("sha"):
            failures.append(f"{name}: missing sha")
    if failures:
        check(result, f"{label}: repo provenance", False, "; ".join(failures))
    else:
        shas = ", ".join(f"{name}={repos[name].get('short_sha')}" for name in CRITICAL_REPOS)
        check(result, f"{label}: repo provenance", True, shas)


def check_endpoints(result, label, snapshot):
    required = ("node_readyz", "node_health", "node_network_info", "node_blockchain", "backend_health", "alert_receiver_health")
    failures = []
    for name in required:
        item = endpoint(snapshot, name)
        if not item.get("ok"):
            failures.append(f"{name}: {item.get('status') or item.get('error') or 'not ok'}")
    check(result, f"{label}: required endpoints", not failures, "; ".join(failures) if failures else "all required endpoints ok")


def compose_rows(snapshot):
    ps = snapshot.get("compose", {}).get("ps", {}).get("data")
    if isinstance(ps, dict):
        return [ps]
    if isinstance(ps, list):
        return [row for row in ps if isinstance(row, dict)]
    return []


def row_text(row):
    return " ".join(str(row.get(key, "")) for key in ("Name", "Service", "State", "Status", "Health")).lower()


def check_services(result, label, snapshot):
    compose = snapshot.get("compose", {})
    if not compose.get("available"):
        check(result, f"{label}: compose status", False, compose.get("error") or "compose unavailable")
        return
    rows = compose_rows(snapshot)
    critical = {
        "wrfcoin-node": False,
        "prometheus": False,
        "alertmanager": False,
        "alert-receiver": False,
    }
    failures = []
    for row in rows:
        text = row_text(row)
        for key in critical:
            if key in text:
                critical[key] = True
                if any(word in text for word in ("restarting", "unhealthy", "exited", "dead")):
                    failures.append(f"{key}: {text}")
    for key, seen in critical.items():
        if not seen:
            failures.append(f"{key}: missing from compose ps")
    check(result, f"{label}: supporting services", not failures, "; ".join(failures) if failures else "critical services present and not unhealthy/restarting")


def check_peers_and_sync(result, label, summary):
    failures = []
    if summary["peer_count"] is None:
        failures.append("peer_count missing")
    elif summary["peer_count"] <= 0:
        failures.append(f"peer_count={summary['peer_count']}")
    if summary["height"] is None:
        failures.append("chain height missing")
    if first_text(summary["sync_status"]) is None:
        failures.append("sync_status missing")
    check(result, f"{label}: node peer/sync fields", not failures, "; ".join(failures) if failures else f"height={summary['height']} peers={summary['peer_count']} sync={summary['sync_status']}")


def check_convergence(result, n5, desktop, max_gap):
    n5_h = n5["height"]
    desktop_h = desktop["height"]
    if n5_h is None or desktop_h is None:
        check(result, "pair: height convergence", False, f"missing heights n5={n5_h} desktop={desktop_h}")
        return
    if n5_h > 0 and desktop_h == 0:
        check(result, "pair: height convergence", False, f"desktop remains at genesis while N5 is at height {n5_h}")
        return
    if desktop_h > n5_h:
        check(result, "pair: height convergence", False, f"desktop height {desktop_h} is ahead of N5 height {n5_h}")
        return
    gap = n5_h - desktop_h
    if gap > max_gap:
        check(result, "pair: height convergence", False, f"desktop is {gap} blocks behind N5 (max allowed {max_gap})")
        return
    if n5_h == desktop_h and n5["tip_hash"] and desktop["tip_hash"] and n5["tip_hash"] != desktop["tip_hash"]:
        check(result, "pair: height convergence", False, "heights match but tip hashes differ")
        return
    check(result, "pair: height convergence", True, f"n5={n5_h} desktop={desktop_h} gap={gap}")


def check_log_scan(result, label, snapshot):
    scan = snapshot.get("node_log_scan", {})
    matches = scan.get("matches") or []
    blockers = [line for line in matches if BLOCKER_LOG_PATTERN.search(line)]
    if blockers:
        check(result, f"{label}: targeted node log scan", False, blockers[0][:300])
    elif matches:
        check(result, f"{label}: targeted node log scan", True, f"{len(matches)} non-blocking sync-related match(es)")
    else:
        check(result, f"{label}: targeted node log scan", True, "no blocker log matches")


def check_alert_delivery(result, label, snapshot):
    health = body(snapshot, "alert_receiver_health")
    if not isinstance(health, dict):
        check(result, f"{label}: alert delivery", False, "alert receiver health body missing")
        return
    evidence = health.get("last_successful_critical_delivery")
    if not isinstance(evidence, dict):
        check(result, f"{label}: alert delivery", False, "last successful critical delivery evidence missing")
        return
    stages = {
        name: value.get("status") if isinstance(value, dict) else None
        for name, value in evidence.items()
    }
    result.setdefault("alert_delivery", {})[label] = {
        "forwarding_enabled": health.get("forwarding") is True,
        "rule_firing": stages.get("rule_firing", "missing"),
        "receiver_acceptance": stages.get("receiver_acceptance", "missing"),
        "outbound_forwarding": stages.get("outbound_forwarding", "missing"),
        "human_delivery": stages.get("human_delivery", "missing"),
        "evidence_age_seconds": None,
    }
    failures = []
    if health.get("forwarding") is not True:
        failures.append("forwarding disabled")
    if stages.get("receiver_acceptance") != "accepted":
        failures.append(f"receiver acceptance={stages.get('receiver_acceptance', 'missing')}")
    acceptance = evidence.get("receiver_acceptance", {})
    if not isinstance(acceptance, dict) or acceptance.get("critical_firing") is not True:
        failures.append("receiver acceptance did not observe a firing critical canary")
    if stages.get("outbound_forwarding") != "succeeded":
        failures.append(f"outbound forwarding={stages.get('outbound_forwarding', 'missing')}")
    forwarding = evidence.get("outbound_forwarding", {})
    acceptance_request = acceptance.get("request_id") if isinstance(acceptance, dict) else None
    forwarding_request = forwarding.get("request_id") if isinstance(forwarding, dict) else None
    if not acceptance_request or acceptance_request != forwarding_request:
        failures.append("receiver acceptance and outbound forwarding are not correlated to one request")
    snapshot_at = snapshot.get("generated_at")
    forwarded_at = forwarding.get("observed_at") if isinstance(forwarding, dict) else None
    try:
        snapshot_time = datetime.datetime.fromisoformat(str(snapshot_at).replace("Z", "+00:00"))
        forwarded_time = datetime.datetime.fromisoformat(str(forwarded_at).replace("Z", "+00:00"))
        evidence_age = (snapshot_time - forwarded_time).total_seconds()
        result["alert_delivery"][label]["evidence_age_seconds"] = evidence_age
        if evidence_age < -ALERT_DELIVERY_FUTURE_SKEW_SECONDS:
            failures.append(f"delivery evidence is {abs(evidence_age):.0f}s after snapshot time")
        elif evidence_age > ALERT_DELIVERY_MAX_AGE_SECONDS:
            failures.append(
                f"delivery evidence is stale ({evidence_age:.0f}s old; max={ALERT_DELIVERY_MAX_AGE_SECONDS}s)"
            )
    except (TypeError, ValueError):
        failures.append("delivery evidence or snapshot timestamp is missing/invalid")
    if stages.get("human_delivery") != "operator_verification_required":
        failures.append("human delivery boundary not explicitly operator-verified")
    details = "; ".join(failures) if failures else "receiver accepted critical canary and local outbound boundary returned 2xx; human delivery remains operator-verified"
    check(result, f"{label}: alert delivery", not failures, details)


def production_observation(snapshot):
    value = snapshot.get("production_observation")
    return value if isinstance(value, dict) else {}


def check_production_evidence(result, snapshots, mode):
    observations = [production_observation(snapshot) for snapshot in snapshots]
    missing = [snapshot.get("node_name") or snapshot.get("_path") for snapshot, observation in zip(snapshots, observations) if not observation]
    synthetic_nodes = []
    synthetic_activity_nodes = []
    synthetic_log_unavailable_nodes = []
    synthetic_cycles = 0
    real_count = 0
    windows = []
    for snapshot, observation in zip(snapshots, observations):
        node = snapshot.get("node_name") or snapshot.get("_path")
        window = observation.get("observation_window") or {}
        windows.append({"node": node, **window})
        synthetic = observation.get("synthetic_collector", {})
        log_evidence = synthetic.get("log_evidence", {})
        if log_evidence.get("available") is not True:
            synthetic_log_unavailable_nodes.append(node)
        if synthetic.get("enabled") is True:
            synthetic_nodes.append(node)
        cycles = synthetic.get("successful_cycles", 0)
        if isinstance(cycles, int) and not isinstance(cycles, bool) and cycles > 0:
            synthetic_activity_nodes.append(node)
            synthetic_cycles += cycles
        count = observation.get("real_collectors", {}).get("contributions_observed", 0)
        if isinstance(count, int) and not isinstance(count, bool) and count > 0:
            real_count += count

    result["production_evidence"] = {
        "observation_windows": windows,
        "synthetic_collector": "enabled" if synthetic_nodes else "disabled",
        "synthetic_nodes": synthetic_nodes,
        "synthetic_activity_nodes": synthetic_activity_nodes,
        "synthetic_log_unavailable_nodes": synthetic_log_unavailable_nodes,
        "synthetic_successful_cycles": synthetic_cycles,
        "real_contributions_observed": real_count,
    }
    if missing:
        check(result, "pair: production evidence present", False, f"missing production_observation for: {', '.join(missing)}")
        return
    check(result, "pair: production evidence present", True, f"attributed windows={len(windows)}")
    if mode == "developer-demo":
        check(result, "pair: developer/demo proof class", True, f"SIMULATED; synthetic collector {'enabled' if synthetic_nodes else 'disabled'}; synthetic log evidence unavailable on {len(synthetic_log_unavailable_nodes)} node(s); synthetic cycles={synthetic_cycles}; real contributions={real_count}")
        return
    check(result, "pair: synthetic log evidence available", not synthetic_log_unavailable_nodes, f"synthetic collector logs unavailable on: {', '.join(synthetic_log_unavailable_nodes)}" if synthetic_log_unavailable_nodes else "synthetic logs inspected throughout attributed windows")
    check(result, "pair: synthetic collector disabled", not synthetic_nodes, f"synthetic collector active on: {', '.join(synthetic_nodes)}" if synthetic_nodes else "disabled throughout attributed windows")
    check(result, "pair: synthetic-free observation windows", not synthetic_activity_nodes, f"synthetic production observed on: {', '.join(synthetic_activity_nodes)} ({synthetic_cycles} successful cycles)" if synthetic_activity_nodes else "no successful synthetic cycles in attributed windows")
    check(result, "pair: real contribution observed", real_count > 0, f"real contributions observed={real_count}")


def markdown_report(report):
    lines = [
        "# WRFCoin Testnet Launch Readiness",
        "",
        f"Overall: **{report['overall'].upper()}**",
        f"Mode: **{report['mode']}**",
        f"Proof class: **{report['proof_class']}**",
        f"Generated: `{report['generated_at']}`",
        f"First blocking reason: {report['first_blocking_reason'] or 'none'}",
        "",
        "## Node Summary",
        "",
        "| Node | Height | Peers | Sync | Tip | Snapshot |",
        "|---|---:|---:|---|---|---|",
    ]
    for key in ("n5", "desktop"):
        item = report["nodes"][key]
        tip = (item.get("tip_hash") or "")[:12] or "?"
        lines.append(
            f"| {key} | {item.get('height')} | {item.get('peer_count')} | {item.get('sync_status')} | {tip} | `{item.get('path')}` |"
        )
    lines.extend(["", "## Checks", "", "| Check | Result | Details |", "|---|---|---|"])
    for item in report["checks"]:
        details = str(item["details"]).replace("\n", " ")
        lines.append(f"| {item['name']} | {item['status']} | {details} |")
    lines.append("")
    lines.extend([
        "## Alert Delivery Evidence",
        "",
        "| Node | Rule firing | Receiver acceptance | Outbound forwarding | Human/live delivery |",
        "|---|---|---|---|---|",
    ])
    for key in ("n5", "desktop"):
        evidence = report.get("alert_delivery", {}).get(key, {})
        lines.append(
            f"| {key} | {evidence.get('rule_firing', 'missing')} | {evidence.get('receiver_acceptance', 'missing')} | {evidence.get('outbound_forwarding', 'missing')} | {evidence.get('human_delivery', 'missing')} |"
        )
    lines.append("")
    next_action = "Proceed to the next launch-readiness gate." if report["overall"] == "pass" else "Stop deploy promotion and fix the first blocking reason."
    lines.extend(["## Suggested Next Action", "", next_action, ""])
    return "\n".join(lines)


args = parse_args()
n5_snapshot = load_snapshot(args.n5)
desktop_snapshot = load_snapshot(args.desktop)
report = {
    "schema": "wrfcoin.testnet.launch_readiness_report.v1",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "max_height_gap": args.max_height_gap,
    "mode": args.mode,
    "proof_class": "SIMULATED" if args.mode == "developer-demo" else "PUBLIC_RELEASE",
    "overall": "pass",
    "first_blocking_reason": None,
    "nodes": {
        "n5": snapshot_summary(n5_snapshot),
        "desktop": snapshot_summary(desktop_snapshot),
    },
    "checks": [],
}

for label, snapshot in (("n5", n5_snapshot), ("desktop", desktop_snapshot)):
    check_snapshot_schema(report, label, snapshot)
    check_source_repos(report, label, snapshot)
    check_endpoints(report, label, snapshot)
    check_services(report, label, snapshot)
    check_alert_delivery(report, label, snapshot)
    check_peers_and_sync(report, label, report["nodes"][label])
    check_log_scan(report, label, snapshot)
check_convergence(report, report["nodes"]["n5"], report["nodes"]["desktop"], args.max_height_gap)
check_production_evidence(report, (n5_snapshot, desktop_snapshot), args.mode)

if any(item["status"] == "fail" for item in report["checks"]):
    report["overall"] = "fail"

markdown = markdown_report(report)
if args.json_out:
    with open(args.json_out, "w", encoding="utf-8") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
        handle.write("\n")
if args.markdown_out:
    with open(args.markdown_out, "w", encoding="utf-8") as handle:
        handle.write(markdown)

print(markdown)
sys.exit(0 if report["overall"] == "pass" else 1)
PY
