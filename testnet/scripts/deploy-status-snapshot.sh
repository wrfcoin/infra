#!/usr/bin/env bash
# Emit a machine-readable post-deploy provenance and health snapshot.
set -euo pipefail

usage() {
  cat <<USAGE
Usage: NODE_NAME=n5-pro WRFCOIN_ROOT=<deploy-root> bash $0 > deploy-status.json

Environment:
  NODE_NAME       Human-readable node label. Defaults to the host name.
  WRFCOIN_ROOT    Parent directory containing infra/backend/core4/frontend.
                  Defaults to <deploy-root>.
  TESTNET_DIR     Compose directory. Defaults to \$WRFCOIN_ROOT/infra/testnet.
  NODE_API        Node API base URL. Defaults to http://localhost:8556.
  BACKEND_API     Backend API base URL. Defaults to http://localhost:4001.
  ALERT_RECEIVER_API Alert receiver base URL. Defaults to http://localhost:19093.
  COMPOSE_FILES   Colon-separated compose files relative to TESTNET_DIR.
                  Defaults to docker-compose.testnet.yml, docker-compose.override.yml,
                  and docker-compose.local-paths.yml when present.
  LOG_SINCE       docker compose log window. Defaults to 30m.

The script does not fetch, deploy, restart, or mutate services. Run it on each
testnet node after deploy and attach the JSON to the launch-readiness note.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

python3 - "$@" <<'PY'
import datetime
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request


ROOT = os.environ.get("WRFCOIN_ROOT") or os.environ.get("WRFCOIN_DEPLOY_ROOT") or "/path/to/wrfcoin-deploy"
TESTNET_DIR = os.environ.get("TESTNET_DIR", os.path.join(ROOT, "infra", "testnet"))
NODE_NAME = os.environ.get("NODE_NAME") or socket.gethostname()
NODE_API = os.environ.get("NODE_API", "http://localhost:8556").rstrip("/")
BACKEND_API = os.environ.get("BACKEND_API", "http://localhost:4001").rstrip("/")
ALERT_RECEIVER_API = os.environ.get("ALERT_RECEIVER_API", "http://localhost:19093").rstrip("/")
LOG_SINCE = os.environ.get("LOG_SINCE", "30m")
REPOS = os.environ.get("WRFCOIN_REPOS", "infra backend core4 frontend").split()
LOG_PATTERN = re.compile(
    r"(orphan|genesis|fork|reorg|validation|min_work_factor|sync|panic|error)",
    re.IGNORECASE,
)


def run(cmd, cwd=None, timeout=15):
    try:
        completed = subprocess.run(
            cmd,
            cwd=cwd,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except FileNotFoundError as exc:
        return {"ok": False, "returncode": 127, "stdout": "", "stderr": str(exc)}
    except subprocess.TimeoutExpired as exc:
        return {
            "ok": False,
            "returncode": 124,
            "stdout": exc.stdout or "",
            "stderr": exc.stderr or "command timed out",
        }
    return {
        "ok": completed.returncode == 0,
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def git_value(path, *args):
    result = run(["git", "-C", path, *args], timeout=8)
    if result["ok"]:
        return result["stdout"]
    return None


def source_repo(name):
    path = os.path.join(ROOT, name)
    item = {"name": name, "path": path, "exists": os.path.isdir(os.path.join(path, ".git"))}
    if not item["exists"]:
        item["status"] = "missing"
        return item

    branch = git_value(path, "symbolic-ref", "--quiet", "--short", "HEAD")
    sha = git_value(path, "rev-parse", "HEAD")
    short_sha = git_value(path, "rev-parse", "--short", "HEAD")
    status = git_value(path, "status", "--porcelain")
    upstream = git_value(path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    item.update(
        {
            "branch": branch,
            "detached": branch is None,
            "sha": sha,
            "short_sha": short_sha,
            "dirty": bool(status),
            "status_porcelain": status or "",
            "upstream": upstream,
        }
    )
    if upstream:
        counts = git_value(path, "rev-list", "--left-right", "--count", f"HEAD...{upstream}")
        if counts:
            parts = counts.split()
            if len(parts) == 2:
                item["ahead"] = int(parts[0])
                item["behind"] = int(parts[1])
    return item


def compose_files():
    raw = os.environ.get("COMPOSE_FILES")
    if raw:
        candidates = raw.split(":")
    else:
        candidates = [
            "docker-compose.testnet.yml",
            "docker-compose.override.yml",
            "docker-compose.local-paths.yml",
        ]
    files = []
    for candidate in candidates:
        path = candidate if os.path.isabs(candidate) else os.path.join(TESTNET_DIR, candidate)
        if os.path.exists(path):
            files.append(path)
    return files


def compose_cmd(files, *args):
    cmd = ["docker", "compose"]
    for path in files:
        cmd.extend(["-f", path])
    cmd.extend(args)
    return cmd


def parse_json_or_lines(text):
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        rows = []
        for line in text.splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                return text
        return rows


def compose_status(files):
    if not files:
        return {"available": False, "error": "no compose files found"}
    ps = run(compose_cmd(files, "ps", "--format", "json"), cwd=TESTNET_DIR, timeout=20)
    images = run(compose_cmd(files, "images", "--format", "json"), cwd=TESTNET_DIR, timeout=20)
    return {
        "available": ps["ok"] or images["ok"],
        "files": files,
        "ps": {
            "ok": ps["ok"],
            "returncode": ps["returncode"],
            "data": parse_json_or_lines(ps["stdout"]),
            "stderr": ps["stderr"],
        },
        "images": {
            "ok": images["ok"],
            "returncode": images["returncode"],
            "data": parse_json_or_lines(images["stdout"]),
            "stderr": images["stderr"],
        },
    }


def service_is_running(compose, service):
    data = compose.get("ps", {}).get("data")
    rows = data if isinstance(data, list) else ([data] if isinstance(data, dict) else [])
    for row in rows:
        row_service = str(row.get("Service", "")).lower()
        row_name = str(row.get("Name", "")).lower()
        state = str(row.get("State", "")).lower()
        status = str(row.get("Status", "")).lower()
        expected = service.lower()
        matches = row_service == expected if row_service else (row_name == expected or row_name.endswith(f"-{expected}"))
        if matches:
            return state == "running" or status.startswith("up")
    return False


def service_logs(files, service):
    result = run(compose_cmd(files, "logs", "--since", LOG_SINCE, service), cwd=TESTNET_DIR, timeout=30)
    return {
        "available": result["ok"],
        "returncode": result["returncode"],
        "stdout": result["stdout"],
        "stderr": result["stderr"],
    }


def count_real_contributions(text):
    count = 0
    for line in text.splitlines():
        single = re.search(r"Submission complete:\s+(\d+) committed.*MINED", line, re.IGNORECASE)
        multi = re.search(r"(\d+) submitted\s*/.*\bMINED\b", line, re.IGNORECASE)
        if single:
            count += int(single.group(1))
        elif multi:
            count += int(multi.group(1))
    return count


def production_observation(files, compose, ended_at):
    synthetic_running = service_is_running(compose, "synthetic-collector")
    real_services = ("weather-collector", "weather-collector-multi")
    running_real = [service for service in real_services if service_is_running(compose, service)]
    # A collector may mine during the attributed window and stop before this
    # snapshot. Query every known producer independently of its end-of-window
    # state, and retain command failures so missing evidence cannot look empty.
    synthetic_logs = service_logs(files, "synthetic-collector")
    real_logs = {service: service_logs(files, service) for service in real_services}
    real_counts = {
        service: count_real_contributions(evidence["stdout"])
        for service, evidence in real_logs.items()
        if evidence["available"]
    }
    real_count = sum(real_counts.values())
    synthetic_count = (
        len(re.findall(r"COMMIT\+REVEAL INCLUDED:", synthetic_logs["stdout"]))
        if synthetic_logs["available"]
        else 0
    )
    return {
        "observation_window": {
            "since": LOG_SINCE,
            "ended_at": ended_at,
            "attribution": "docker compose ps plus service logs",
        },
        "synthetic_collector": {
            "enabled": synthetic_running,
            "successful_cycles": synthetic_count,
            "log_evidence": {
                "available": synthetic_logs["available"],
                "returncode": synthetic_logs["returncode"],
                "stderr": synthetic_logs["stderr"],
            },
        },
        "real_collectors": {
            "enabled": bool(running_real),
            "running_services": running_real,
            "services": [service for service, count in real_counts.items() if count > 0],
            "inspected_services": list(real_services),
            "contributions_by_service": real_counts,
            "contributions_observed": real_count,
            "log_evidence": {
                service: {
                    "available": evidence["available"],
                    "returncode": evidence["returncode"],
                    "stderr": evidence["stderr"],
                }
                for service, evidence in real_logs.items()
            },
        },
    }


def endpoint(name, url):
    try:
        with urllib.request.urlopen(url, timeout=6) as response:
            body = response.read(65536).decode("utf-8", "replace")
            parsed = None
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = body[:4000]
            return {
                "name": name,
                "url": url,
                "ok": 200 <= response.status < 300,
                "status": response.status,
                "body": parsed,
            }
    except urllib.error.HTTPError as exc:
        body = exc.read(8192).decode("utf-8", "replace")
        return {"name": name, "url": url, "ok": False, "status": exc.code, "body": body[:4000]}
    except Exception as exc:
        return {"name": name, "url": url, "ok": False, "error": str(exc)}


def log_scan(files):
    if not files:
        return {"ok": False, "matches": [], "error": "no compose files found"}
    result = run(compose_cmd(files, "logs", "--since", LOG_SINCE, "wrfcoin-node"), cwd=TESTNET_DIR, timeout=30)
    matches = []
    if result["stdout"]:
        for line in result["stdout"].splitlines():
            if LOG_PATTERN.search(line):
                matches.append(line[:1000])
            if len(matches) >= 40:
                break
    return {
        "ok": result["ok"],
        "returncode": result["returncode"],
        "since": LOG_SINCE,
        "match_count": len(matches),
        "matches": matches,
        "stderr": result["stderr"],
    }


files = compose_files()
generated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
compose = compose_status(files)
snapshot = {
    "schema": "wrfcoin.testnet.deploy_status_snapshot.v1",
    "generated_at": generated_at,
    "node_name": NODE_NAME,
    "host": socket.gethostname(),
    "root": ROOT,
    "testnet_dir": TESTNET_DIR,
    "source_repos": [source_repo(name) for name in REPOS],
    "compose": compose,
    "production_observation": production_observation(files, compose, generated_at),
    "endpoints": [
        endpoint("node_readyz", f"{NODE_API}/readyz"),
        endpoint("node_health", f"{NODE_API}/health"),
        endpoint("node_network_info", f"{NODE_API}/network/info"),
        endpoint("node_blockchain", f"{NODE_API}/blockchain"),
        endpoint("backend_health", f"{BACKEND_API}/health"),
        endpoint("alert_receiver_health", f"{ALERT_RECEIVER_API}/health"),
    ],
    "node_log_scan": log_scan(files),
}

json.dump(snapshot, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
