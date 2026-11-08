#!/usr/bin/env python3
"""
WRFCoin Node Dashboard
======================
Live metrics for the testnet node host (Proxmox, physical console).

Runs on the Proxmox host and displays on the physical monitor (tty1).
Queries ZFS/system directly; queries the active Docker CT via pct exec for Docker/services.
Shows blockchain state via HTTP API once infra#77 deploys native-chain.
The WRFCOIN section invokes wrfcoin-cli once the node is running.

Controls
--------
  q / Q / ESC  — quit
  r / R        — force refresh now
  resize       — auto-adjusts to new terminal size

Install
-------
  bash /opt/wrfcoin/node-dashboard-install.sh
"""

import base64
import curses
import json
import os
import re
import socket
import subprocess
import threading
import time
from collections import deque
from datetime import datetime, timezone

# ── Configuration ─────────────────────────────────────────────────────────────
REFRESH      = 5       # seconds between auto-refresh
CT_ID        = 101     # Default Proxmox CT ID for docker-host
CHAIN_PORT   = 8556    # native-chain REST API (inside the active Docker CT)
BACKEND_PORT = 4001    # backend API (inside the active Docker CT)
CT_CANDIDATES = [101, 100]
CT_RESOLVE_TTL = 15
BOOT_SETTLE_SECONDS = 180
# Blocks are produced on a ~60s collector cadence; flag the chain as STALLED once
# the tip is older than this (well clear of normal jitter, catches the halt class).
CHAIN_STALL_SECONDS = 180
# Weather readings older than this are shown as stale (station likely offline).
WEATHER_STALE_SECONDS = 3600
# CI runners (self-hosted GitHub Actions runners live in their own CT, not the Docker CT).
RUNNER_CT_ID = 102
RUNNER_QUEUE_REPOS = ["wrfcoin/core4", "wrfcoin/infra", "wrfcoin/backend"]
RUNNER_QUEUE_TTL = 60          # seconds between GitHub API polls for the queue
RUNNER_QUEUE_SHOW = 5          # "next up" rows drawn
RUNNER_QUEUE_PROBE = 10        # oldest queued runs whose jobs are inspected for self-hosted labels
RUNNER_LABEL = "self-hosted"
RUNNER_TOKEN_ENV_FILE = "/etc/wrfcoin/dashboard.env"   # WRFCOIN_GH_TOKEN=<actions:read token>
RUNNER_TOKEN_ENV_KEYS = ("WRFCOIN_GH_TOKEN", "GITHUB_TOKEN")

# Real weather contributors whose earnings the dashboard reports.
#
# The weather station roster is discovered from the collector's data directory,
# rather than hardcoding a station filename. The backend endpoint that would
# serve the roster (GET /api/weather/stations/credentials) currently 500s, see
# backend#1042, so discovery remains the safe fallback until that is repaired.
#
# An address here that has never earned is NOT an error. It renders as an
# explicit zero, which is the entire point: "no account yet" and "no data" must
# never look the same.
#
# Contributor labels and addresses are operator data, not code: they are read
# from a host-local JSON file that is never committed, e.g.
#   {"title": "my-node", "contributors": [["alice", "0x<40 hex>"], ...]}
LOCAL_CONFIG_PATH = os.environ.get(
    "WRFCOIN_DASHBOARD_CONFIG", "/opt/wrfcoin/node-dashboard.local.json"
)


def _load_local_config(path=LOCAL_CONFIG_PATH):
    """Host-local settings as a dict; {} when the file is absent or unreadable."""
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def _contributors_from_config(cfg):
    """[(label, address)] from the local config, skipping malformed rows."""
    out = []
    for row in (cfg or {}).get("contributors") or []:
        if not isinstance(row, (list, tuple)) or len(row) != 2:
            continue
        label, addr = row
        if (isinstance(label, str) and label.strip() and isinstance(addr, str)
                and re.fullmatch(r"0x[0-9a-fA-F]{40}", addr)):
            out.append((label.strip(), addr.lower()))
    return out


def _title_host(cfg=None):
    """Console title host: the local config's "title", else the hostname."""
    cfg = LOCAL_CONFIG if cfg is None else cfg
    title = cfg.get("title")
    if isinstance(title, str) and title.strip():
        return title.strip()
    try:
        return socket.gethostname() or "node"
    except OSError:
        return "node"


LOCAL_CONFIG = _load_local_config()
CONTRIBUTOR_ADDRESSES = _contributors_from_config(LOCAL_CONFIG)

SERVICE_DEFS = [
    {"key": "postgres",         "container": "wrfcoin-testnet-postgres",         "label": "Postgres",          "port": "5432", "required": True},
    {"key": "redis",            "container": "wrfcoin-testnet-redis",            "label": "Redis",             "port": "6379", "required": True},
    {"key": "db-migrate",       "container": "wrfcoin-testnet-db-migrate",       "label": "DB migrate",        "port": "init", "required": True,  "one_shot": True},
    {"key": "node",             "container": "wrfcoin-testnet-node",             "label": "native-chain",      "port": "8556", "required": True},
    {"key": "backend",          "container": "wrfcoin-testnet-backend",          "label": "Backend",           "port": "4001", "required": True},
    {"key": "frontend",         "container": "wrfcoin-testnet-frontend",         "label": "Frontend",          "port": "5000", "required": True},
    {"key": "explorer",         "container": "wrfcoin-testnet-explorer",         "label": "Explorer",          "port": "8080", "required": True},
    {"key": "governance",       "container": "wrfcoin-testnet-governance",       "label": "Governance",        "port": "8000", "required": True},
    {"key": "iot",              "container": "wrfcoin-testnet-iot",              "label": "IoT",               "port": "3002", "required": True},
    {"key": "weather-earnings", "container": "wrfcoin-testnet-weather-earnings", "label": "Weather earnings",  "port": "8001", "required": True},
    {"key": "weather-collector","container": "wrfcoin-testnet-weather-collector","label": "Weather collector", "port": "job",  "required": False, "profile": "collector"},
    {"key": "seed",             "container": "wrfcoin-testnet-seed",             "label": "Seed node",         "port": "8557", "required": False, "profile": "seed"},
    {"key": "prometheus",       "container": "wrfcoin-testnet-prometheus",       "label": "Prometheus",        "port": "9090", "required": True},
    {"key": "loki",             "container": "wrfcoin-testnet-loki",             "label": "Loki",              "port": "3100", "required": True},
    {"key": "promtail",         "container": "wrfcoin-testnet-promtail",         "label": "Promtail",          "port": "logs", "required": True},
    {"key": "grafana",          "container": "wrfcoin-testnet-grafana",          "label": "Grafana",           "port": "3100", "required": True},
    {"key": "alertmanager",     "container": "wrfcoin-testnet-alertmanager",     "label": "Alertmanager",      "port": "9093", "required": True},
    {"key": "node-exporter",    "container": "wrfcoin-testnet-node-exporter",    "label": "Node exporter",     "port": "9100", "required": True},
]
CONTAINER_TO_KEY = {svc["container"]: svc["key"] for svc in SERVICE_DEFS}
HEADLINE_SERVICE_DEFS = [svc for svc in SERVICE_DEFS if not svc.get("profile")]
_CT_CACHE = {"expires_at": 0.0, "meta": None}

# ── Docker collector script ────────────────────────────────────────────────────
# Base64-encoded and piped to bash inside the active Docker CT via pct exec.
# Emits one tab-separated line per expected container:
# name, status, health, started_at, finished_at, exit_code, restart_count,
# image, cpu_pct, mem_usage, mem_pct, net_io, block_io, pids
_DOCKER_COLLECTOR_TEMPLATE = r"""
set -e
CTRS="__CTR_NAMES__"
STATS_FILE=$(mktemp)
docker ps --format '{{.Names}}' | grep '^wrfcoin-testnet-' | \
  xargs -r docker stats --no-stream --no-trunc \
    --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}' \
    > "$STATS_FILE" 2>/dev/null || true
for ctr in $CTRS; do
  inspect=$(docker inspect --type container \
    --format '{{.State.Status}}\t{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}\t{{.State.StartedAt}}\t{{.State.FinishedAt}}\t{{.State.ExitCode}}\t{{.RestartCount}}\t{{.Config.Image}}' \
    "$ctr" 2>/dev/null || true)
  if [ -z "$inspect" ]; then
    printf '%s\tmissing\tmissing\t\t\t\t\t\t\t\t\t\t\t\n' "$ctr"
    continue
  fi
  stats=$(grep -F "$ctr	" "$STATS_FILE" 2>/dev/null || true)
  if [ -n "$stats" ]; then
    stats=${stats#"$ctr	"}
  fi
  printf '%s\t%s\t%s\n' "$ctr" "$(printf '%b' "$inspect")" "$stats"
done
rm -f "$STATS_FILE"
"""
_DOCKER_COLLECTOR_SH = _DOCKER_COLLECTOR_TEMPLATE.replace(
    "__CTR_NAMES__",
    " ".join(svc["container"] for svc in SERVICE_DEFS),
)

# ── Drive SMART + I/O collector script ───────────────────────────────────────
# Runs on the Proxmox host (not in CT). Parallel smartctl calls for all drives.
# Returns a single JSON object keyed by device name.
_DRIVE_COLLECTOR_SH = r"""
collect_hdd() {
  local dev="$1" out
  out=$(smartctl -A "/dev/$dev" 2>/dev/null)
  local temp hours bad_real bad_pend
  temp=$(    echo "$out" | awk '/194 Temperature_Celsius/{print $10}')
  hours=$(   echo "$out" | awk '/9 Power_On_Hours/{print $10}')
  bad_real=$(echo "$out" | awk '/5 Reallocated_Sector_Ct/{print $10}')
  bad_pend=$(echo "$out" | awk '/197 Current_Pending_Sector/{print $10}')
  local rs ws
  rs=$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats)
  ws=$(awk -v d="$dev" '$3==d{print $10}' /proc/diskstats)
  printf '"%s":{"type":"hdd","temp":"%s","hours":"%s","reallocated":"%s","pending":"%s","rs":"%s","ws":"%s"}' \
    "$dev" "${temp:-?}" "${hours:-?}" "${bad_real:-0}" "${bad_pend:-0}" "${rs:-0}" "${ws:-0}"
}

collect_nvme() {
  local dev="$1" out
  out=$(smartctl -A "/dev/$dev" 2>/dev/null)
  local temp pct
  temp=$(echo "$out" | awk '/^Temperature:/{print $2}')
  pct=$( echo "$out" | awk '/Percentage Used:/{gsub(/%/,"",$3); print $3}')
  local rs ws
  rs=$(awk -v d="$dev" '$3==d{print $6}' /proc/diskstats)
  ws=$(awk -v d="$dev" '$3==d{print $10}' /proc/diskstats)
  printf '"%s":{"type":"nvme","temp":"%s","pct_used":"%s","rs":"%s","ws":"%s"}' \
    "$dev" "${temp:-?}" "${pct:-?}" "${rs:-0}" "${ws:-0}"
}

TMPD=$(mktemp -d)
for dev in sda sdb sdc sdd sde; do
  [ -b "/dev/$dev" ] && (collect_hdd "$dev" > "$TMPD/$dev") &
done
for dev in nvme0n1 nvme1n1; do
  [ -b "/dev/$dev" ] && (collect_nvme "$dev" > "$TMPD/$dev") &
done
wait

printf '{'
first=1
for dev in nvme0n1 nvme1n1 sda sdb sdc sdd sde; do
  [ -f "$TMPD/$dev" ] || continue
  [ $first -eq 1 ] || printf ','
  cat "$TMPD/$dev"
  first=0
done
printf '}'
rm -rf "$TMPD"
"""

# ── Shell helpers ─────────────────────────────────────────────────────────────
def _run(cmd, timeout=8):
    """Run command on Proxmox host. Returns stdout string or '' on any error."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""

def _parse_ct_config(text, ct_id):
    meta = {"id": ct_id, "hostname": f"CT {ct_id}", "ip": "?", "running": False}
    for line in text.splitlines():
        if line.startswith("hostname:"):
            meta["hostname"] = line.split(":", 1)[1].strip()
        elif line.startswith("net0:"):
            net = line.split(":", 1)[1]
            for part in net.split(","):
                if part.startswith("ip="):
                    value = part.split("=", 1)[1].strip()
                    meta["ip"] = value.split("/", 1)[0]
    return meta

def _resolve_ct(force=False):
    now = time.time()
    cached = _CT_CACHE.get("meta")
    if not force and cached and now < _CT_CACHE.get("expires_at", 0):
        return dict(cached)

    best = None
    for ct_id in CT_CANDIDATES:
        status_out = _run(f"pct status {ct_id}", timeout=4)
        running = "running" in status_out
        config_out = _run(f"pct config {ct_id}", timeout=4)
        meta = _parse_ct_config(config_out, ct_id)
        meta["running"] = running
        if not running:
            score = 0
        else:
            probe = _run(
                f"pct exec {ct_id} -- bash -lc 'command -v docker >/dev/null && "
                "docker ps --format \"{{.Names}}\" | grep -q \"^wrfcoin-testnet-\" && echo wrf'",
                timeout=8,
            )
            if probe == "wrf":
                score = 3
            else:
                docker_ok = _run(
                    f"pct exec {ct_id} -- bash -lc 'command -v docker >/dev/null && echo docker'",
                    timeout=6,
                )
                score = 2 if docker_ok == "docker" else 1
        meta["_score"] = score
        if best is None or meta["_score"] > best["_score"]:
            best = meta

    if best is None:
        best = {"id": CT_ID, "hostname": f"CT {CT_ID}", "ip": "?", "running": False, "_score": 0}

    _CT_CACHE["meta"] = dict(best)
    _CT_CACHE["expires_at"] = now + CT_RESOLVE_TTL
    best.pop("_score", None)
    return best

def _pct(cmd, timeout=12, ct_id=None):
    """Run a simple command inside CT via pct exec. Returns stdout or ''."""
    safe = cmd.replace("'", r"'\''")
    target = ct_id if ct_id is not None else _resolve_ct().get("id", CT_ID)
    return _run(f"pct exec {target} -- bash -c '{safe}'", timeout=timeout)

def _pct_script(script, timeout=15, ct_id=None):
    """Base64-encode a bash script and pipe it to bash inside the active Docker CT."""
    b64 = base64.b64encode(script.encode()).decode()
    target = ct_id if ct_id is not None else _resolve_ct().get("id", CT_ID)
    return _run(f"pct exec {target} -- bash -c 'echo {b64} | base64 -d | bash'", timeout=timeout)

# Reads the node's token from INSIDE the container, at collect time.
#
# Two properties matter and neither is incidental:
#   - the token never lands on the Proxmox host's filesystem, so this adds no
#     new secret to back up, leak, or forget to rotate;
#   - `$TOK` is expanded inside the container and piped to `curl --config`, so
#     it never appears in an argv on the host or in the CT. The previous shape
#     interpolated it into the `pct exec` command line, where any `ps` would
#     have shown it - harmless only because the variable was never set.
#
# `-f` is deliberately NOT used. It makes curl exit silently on 4xx, which is
# what made an auth failure indistinguishable from a healthy zero: the body was
# discarded, the caller saw None, and every field fell to its default. The
# status code is what tells those two apart, so it is captured explicitly.
_CURL_SH = r"""
set -eu
TOK="$(docker exec {node} printenv WRFCOIN_READER_TOKEN 2>/dev/null || true)"
URL="http://localhost:{port}{path}"
if [ -n "$TOK" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$TOK" \
    | curl -s --config - --max-time 3 -w '\n%{{http_code}}' "$URL"
else
  curl -s --max-time 3 -w '\n%{{http_code}}' "$URL"
fi
"""

NODE_CONTAINER = os.environ.get("WRFCOIN_NODE_CONTAINER", "wrfcoin-testnet-node")


def _curl_ex(path, port=CHAIN_PORT, timeout=5, ct_id=None):
    """GET inside the CT. Returns (payload, error) - exactly one is non-None.

    `error` is a short code for display: an HTTP status, "unreachable" when the
    command produced nothing at all, or "malformed" when the body did not parse.
    """
    out = _pct_script(
        _CURL_SH.format(node=NODE_CONTAINER, port=port, path=path),
        timeout=timeout,
        ct_id=ct_id,
    )
    if not out or "\n" not in out.strip():
        return None, "unreachable"
    body, _, status = out.rstrip("\n").rpartition("\n")
    status = status.strip()
    if status != "200":
        return None, f"HTTP {status}" if status.isdigit() else "unreachable"
    try:
        return json.loads(body), None
    except json.JSONDecodeError:
        return None, "malformed"


def _curl(path, port=CHAIN_PORT, timeout=5, ct_id=None):
    """Back-compat shape: parsed JSON, or None on any failure."""
    payload, _ = _curl_ex(path, port=port, timeout=timeout, ct_id=ct_id)
    return payload

def _envelope_error(payload):
    """Error code from an API error envelope, or None if this is not one.

    `ok: false` carries no `data`, so treating the envelope as data is how an
    error becomes a screenful of zeros.
    """
    if isinstance(payload, dict) and payload.get("ok") is False:
        return ((payload.get("error") or {}).get("code") or "ERROR")
    return None

def _unwrap_envelope(payload):
    if isinstance(payload, dict) and payload.get("ok") is True and "data" in payload:
        return payload.get("data")
    if _envelope_error(payload):
        return None
    return payload

def _json_get_ex(path, port=CHAIN_PORT, timeout=5, ct_id=None):
    """(data, error) - for callers that must not render a failure as a zero."""
    payload, err = _curl_ex(path, port=port, timeout=timeout, ct_id=ct_id)
    if err:
        return None, err
    env_err = _envelope_error(payload)
    if env_err:
        return None, env_err
    return _unwrap_envelope(payload), None

def _json_get(path, port=CHAIN_PORT, timeout=5, ct_id=None):
    data, _ = _json_get_ex(path, port=port, timeout=timeout, ct_id=ct_id)
    return data

def _parse_percent(value):
    if value is None:
        return None
    txt = str(value).strip().replace("%", "")
    if not txt or txt == "--":
        return None
    try:
        return float(txt)
    except ValueError:
        return None

def _parse_int(value, default=0):
    try:
        return int(str(value).strip())
    except Exception:
        return default

def _parse_iso8601(value):
    if not value or value.startswith("0001-01-01"):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None

def _age_seconds(iso_ts):
    dt = _parse_iso8601(iso_ts)
    if not dt:
        return None
    now = datetime.now(timezone.utc)
    return max(int((now - dt).total_seconds()), 0)

# ── Collectors ────────────────────────────────────────────────────────────────
def _collect_zfs():
    d = {}

    out = _run("zpool status tank")
    d["exists"] = bool(out)
    if "state: ONLINE"   in out: d["state"] = "ONLINE"
    elif "state: DEGRADED" in out: d["state"] = "DEGRADED"
    elif "state: FAULTED"  in out: d["state"] = "FAULTED"
    elif out:                       d["state"] = "UNKNOWN"
    else:                           d["state"] = "MISSING"

    out = _run("zfs get -Hp available tank")
    try:    d["avail"] = int(out.split()[2])
    except: d["avail"] = 0

    out = _run("zfs get -Hp used tank")
    try:    d["used"] = int(out.split()[2])
    except: d["used"] = 0

    out = _run(
        "zfs list -Hp -o name,used "
        "tank/docker tank/postgres tank/redis tank/blockchain tank/backups 2>/dev/null"
    )
    datasets = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            name = parts[0].split("/")[-1]
            try: datasets[name] = int(parts[1])
            except ValueError: pass
    d["datasets"] = datasets

    # 1-second I/O sample
    out = _run("zpool iostat -Hp tank 1 1 2>/dev/null | tail -1")
    parts = out.split()
    if len(parts) >= 7:
        try:
            d["read_bps"]  = int(parts[5])
            d["write_bps"] = int(parts[6])
        except Exception:
            pass

    return d


def _collect_system():
    d = {}

    # Uptime
    out = _run("cat /proc/uptime")
    try:
        secs = float(out.split()[0])
        d["uptime_secs"] = int(secs)
        dy, r  = divmod(int(secs), 86400)
        hr, r  = divmod(r, 3600)
        mn     = r // 60
        d["uptime"] = f"{dy}d {hr}h {mn}m"
    except Exception:
        d["uptime_secs"] = 0
        d["uptime"] = "?"

    # Load average
    out = _run("cat /proc/loadavg")
    try:
        p = out.split()
        d["load"] = f"{p[0]}  {p[1]}  {p[2]}"
    except Exception:
        d["load"] = "?"

    # CPU — 2-sample /proc/stat method (no external tools needed)
    def _cpu_snap():
        try:
            with open("/proc/stat") as f:
                vals = list(map(int, f.readline().split()[1:]))
            idle  = vals[3] + vals[4]
            total = sum(vals)
            return idle, total
        except Exception:
            return 0, 1

    i1, t1 = _cpu_snap()
    time.sleep(0.25)
    i2, t2 = _cpu_snap()
    dt = max(t2 - t1, 1)
    d["cpu_pct"] = round(100.0 * (1.0 - (i2 - i1) / dt), 1)

    # RAM
    try:
        mem = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k.strip()] = int(v.split()[0]) * 1024
        d["ram_total"] = mem.get("MemTotal", 0)
        d["ram_avail"] = mem.get("MemAvailable", 0)
        d["ram_used"]  = d["ram_total"] - d["ram_avail"]
    except Exception:
        d["ram_total"] = d["ram_used"] = d["ram_avail"] = 0

    # Temperature (try hwmon first, then thermal_zone)
    for path in (
        "/sys/class/hwmon/hwmon0/temp1_input",
        "/sys/class/thermal/thermal_zone0/temp",
        "/sys/class/thermal/thermal_zone1/temp",
    ):
        try:
            with open(path) as f:
                d["temp_c"] = int(f.read().strip()) / 1000
            break
        except Exception:
            pass

    # Network counters (vmbr0 is the Proxmox bridge)
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if "vmbr0" in line:
                    cols = line.split()
                    d["net_rx_bytes"] = int(cols[1])
                    d["net_tx_bytes"] = int(cols[9])
                    break
    except Exception:
        pass

    return d


def _collect_ct():
    meta = _resolve_ct(force=True)
    meta["configured_id"] = CT_ID
    return meta


def _collect_docker(ct_id=None):
    out = _pct_script(_DOCKER_COLLECTOR_SH, timeout=25, ct_id=ct_id)
    if not out:
        return {}
    services = {}
    for line in out.splitlines():
        # Docker's Go template renderer preserves "\t" as literal bytes in
        # some versions, so tolerate that shape as well as real tab output.
        line = line.replace("\\t", "\t")
        parts = line.split("\t")
        parts += [""] * (14 - len(parts))
        (
            container,
            status,
            health,
            started_at,
            finished_at,
            exit_code,
            restart_count,
            image,
            cpu_pct,
            mem_usage,
            mem_pct,
            net_io,
            block_io,
            pids,
        ) = parts[:14]
        key = CONTAINER_TO_KEY.get(container)
        if not key:
            continue
        services[key] = {
            "container": container,
            "status": status or "missing",
            "health": health or "missing",
            "started_at": started_at,
            "finished_at": finished_at,
            "exit_code": _parse_int(exit_code, default=0),
            "restart_count": _parse_int(restart_count, default=0),
            "image": image,
            "cpu_pct": _parse_percent(cpu_pct),
            "mem_usage": mem_usage,
            "mem_pct": _parse_percent(mem_pct),
            "net_io": net_io,
            "block_io": block_io,
            "pids": _parse_int(pids, default=0) if pids else None,
        }
    return services


def _weather_reading_is_fresh(latest, reading_count):
    if not reading_count:
        return False
    recorded_at = latest.get("recorded_at")
    if recorded_at is None:
        return True
    try:
        age = time.time() - float(recorded_at) / 1000
    except (TypeError, ValueError):
        return False
    return age <= WEATHER_STALE_SECONDS


def _collect_blockchain(ct_id=None):
    d = {"online": False, "status": "offline"}

    # ── Try native-chain HTTP API ────────────────────────────────────────────
    health = _json_get("/health", port=CHAIN_PORT, timeout=4, ct_id=ct_id)
    if isinstance(health, dict):
        d["online"] = True
        d["source"] = "http"
        d["status"] = health.get("status", "online")
        d["uptime_seconds"] = health.get("uptime_seconds")

        ready = _json_get("/readyz", timeout=5, ct_id=ct_id) or {}
        if isinstance(ready, dict):
            d["status"] = ready.get("status", d["status"])
            checks = ready.get("checks", {}) or {}
            block_check = checks.get("block_production", {}) or {}
            peer_check = checks.get("peers", {}) or {}
            d["block_age_seconds"] = block_check.get("block_age_seconds", 0)
            d["peer_check_status"] = peer_check.get("status")
            d["peer_check_count"] = peer_check.get("connected")
            d["storage_height"] = (checks.get("storage", {}) or {}).get("height")

        bc = _json_get("/blockchain", timeout=5, ct_id=ct_id) or {}
        if isinstance(bc, dict):
            d["height"] = bc.get("height", d.get("storage_height", "?"))
            d["pending"] = bc.get("pending_transactions", 0)
            d["accounts"] = bc.get("accounts", 0)
            d["nfts"] = bc.get("nfts", 0)
            d["tip"] = bc.get("tip")

        net = _json_get("/network/info", timeout=5, ct_id=ct_id) or {}
        if isinstance(net, dict):
            d["peers"] = net.get("peer_count", d.get("peer_check_count", "?"))
            d["sync_status"] = net.get("sync_status")
            d["chain_height"] = net.get("chain_height")
            d["network_id"] = net.get("network_id")
            d["chain_id"] = net.get("chain_id")
            d["node_version"] = net.get("node_version")

        d["node_release"] = _collect_node_version(ct_id=ct_id)

        sync = _json_get("/node/sync/status", timeout=5, ct_id=ct_id) or {}
        if isinstance(sync, dict):
            d["sync_status"] = sync.get("sync_status", d.get("sync_status"))
            d["height"] = sync.get("chain_height", d.get("height", "?"))
            d["block_age_seconds"] = sync.get("block_age_secs", d.get("block_age_seconds", 0))
            d["blocks_in_memory"] = sync.get("blocks_in_memory", 0)
            d["peers"] = sync.get("peer_count", d.get("peers", "?"))

        resources = _json_get("/node/resources", timeout=5, ct_id=ct_id) or {}
        if isinstance(resources, dict):
            d["uptime_seconds"] = resources.get("uptime_secs", d.get("uptime_seconds"))
            d["blocks_in_memory"] = resources.get("blocks_in_memory", d.get("blocks_in_memory", 0))
            d["accounts"] = resources.get("account_count", d.get("accounts", 0))
            d["nfts"] = resources.get("nft_count", d.get("nfts", 0))
            d["pending"] = resources.get("pending_transactions", d.get("pending", 0))

        mine = _json_get("/mining/stats", timeout=5, ct_id=ct_id) or {}
        if isinstance(mine, dict):
            d["difficulty"] = mine.get("difficulty", 0)
            d["avg_block_time_secs"] = mine.get("avg_block_time_secs", 0.0)
            d["total_transactions"] = mine.get("total_transactions", 0)

        oracle, oracle_err = _json_get_ex(
            "/transactions/oracle/status", timeout=5, ct_id=ct_id
        )
        d["oracle_query_error"] = oracle_err
        oracle = oracle or {}
        if isinstance(oracle, dict):
            d["oracle_quorum"] = oracle.get("oracle_quorum", 0)
            d["oracle_set_size"] = len(oracle.get("oracle_set", []) or [])
            d["tracked_commit_count"] = oracle.get("tracked_commit_count", 0)
            d["commits_with_quorum"] = oracle.get("commits_with_quorum", 0)
            d["commits_pending_quorum"] = oracle.get("commits_pending_quorum", 0)

        d["contributor_earnings"] = _collect_contributor_earnings(ct_id=ct_id)

        net_stats = _json_get("/network/stats", timeout=5, ct_id=ct_id) or {}
        if isinstance(net_stats, dict):
            d["blocks_received"] = net_stats.get("blocks_received", 0)
            d["blocks_published"] = net_stats.get("blocks_published", 0)
            d["txs_received"] = net_stats.get("txs_received", 0)
            d["txs_published"] = net_stats.get("txs_published", 0)
            d["weather_msgs_received"] = net_stats.get("weather_msgs_received", 0)
            d["weather_msgs_published"] = net_stats.get("weather_msgs_published", 0)
            d["bytes_inbound"] = net_stats.get("bytes_inbound", 0)
            d["bytes_outbound"] = net_stats.get("bytes_outbound", 0)
            d["network_uptime_secs"] = net_stats.get("uptime_secs", 0)

    # ── Weather station data from collector ─────────────────────────────────
    # The collector owns the roster in /app/data. Discover latest files so a
    # new station is visible without another dashboard code change.
    d["weather_stations"] = []
    d["weather_latest"] = {}
    d["weather_accuracy"] = {}
    d["weather_fetched_at"] = {}
    weather_files = _pct(
        "docker exec wrfcoin-testnet-weather-collector "
        "sh -c 'for path in /app/data/ambient-weather-*-latest.json; do "
        "[ -f \"$path\" ] && basename \"$path\"; done'",
        timeout=6, ct_id=ct_id,
    )
    latest_suffix = "-latest.json"
    latest_prefix = "ambient-weather-"
    for filename in weather_files.splitlines():
        filename = filename.strip()
        if not (filename.startswith(latest_prefix) and filename.endswith(latest_suffix)):
            continue
        station_key = filename[len(latest_prefix):-len(latest_suffix)]
        weather_json = _pct(
            "docker exec wrfcoin-testnet-weather-collector "
            f"cat /app/data/{filename} 2>/dev/null",
            timeout=6, ct_id=ct_id,
        )
        if not weather_json:
            continue
        try:
            # `.get(k) or {}`/`or []` guards present-but-null fields (see the
            # accuracy block below) so a partial payload never crashes collect.
            wdata = json.loads(weather_json) or {}
            station = wdata.get("station") or {}
            readings = wdata.get("normalized") or []
            latest = readings[0] or {} if readings else {}
            latest_data = {
                "temperature_c": latest.get("temperature_c"),
                "humidity_pct": latest.get("humidity_pct"),
                "pressure_hpa": latest.get("pressure_hpa"),
                "wind_speed_ms": latest.get("wind_speed_ms"),
                "wind_dir_deg": latest.get("wind_direction_deg"),
                "wind_gust_ms": latest.get("wind_gust_ms"),
                "solar_wm2": latest.get("solar_radiation_wm2"),
                "uv_index": latest.get("uv_index"),
                "dew_point_c": latest.get("dew_point_c"),
                "recorded_at": latest.get("recorded_at"),
            }
            d["weather_stations"].append({
                "key": station_key,
                "name": station.get("name", station_key),
                "location": station.get("location", "?"),
                "device": station.get("device_model", "?"),
                "lat": station.get("lat"),
                "lon": station.get("lon"),
                "elevation_m": station.get("elevation_m"),
                "reading_count": len(readings),
                "fresh": _weather_reading_is_fresh(latest_data, len(readings)),
            })
            if readings:
                d["weather_latest"][station_key] = latest_data
            d["weather_fetched_at"][station_key] = wdata.get("fetched_at")
        except (json.JSONDecodeError, KeyError, IndexError, AttributeError, TypeError):
            continue

        # ── Accuracy data from NWS comparison ───────────────────────────────
        acc_json = _pct(
            "docker exec wrfcoin-testnet-weather-collector "
            f"cat /app/data/ambient-weather-{station_key}-accuracy.json 2>/dev/null",
            timeout=6, ct_id=ct_id,
        )
        if acc_json:
            try:
                # `.get(k) or {}`, NOT `.get(k, {})`: a present-but-null field (e.g.
                # "metrics": null before the station has readings — the normal
                # post-reboot state) returns None, and `.get(k, {})` would not
                # substitute the default. Guarding each level keeps a partial
                # accuracy payload from crashing the whole collect.
                adata = json.loads(acc_json) or {}
                metrics = adata.get("metrics") or {}
                temp_m = metrics.get("temperature") or {}
                pres_m = metrics.get("pressure") or {}
                hum_m = metrics.get("humidity") or {}
                wind_m = metrics.get("wind_speed") or {}
                d["weather_accuracy"][station_key] = {
                    "nws_station": adata.get("nws_station", "?"),
                    "temp_score": temp_m.get("accuracy_score"),
                    "temp_band": temp_m.get("band"),
                    "pressure_score": pres_m.get("accuracy_score"),
                    "pressure_band": pres_m.get("band"),
                    "humidity_score": hum_m.get("accuracy_score"),
                    "wind_score": wind_m.get("accuracy_score"),
                    "computed_at": adata.get("computed_at"),
                }
            except (json.JSONDecodeError, KeyError, AttributeError, TypeError):
                pass

    # ── Fall back to wrfcoin-cli ─────────────────────────────────────────────
    # (available once infra#77 deploys the CLI binary to the active Docker CT)
    if not d.get("online"):
        node_out = _pct("wrfcoin node info --json 2>/dev/null", timeout=8, ct_id=ct_id)
        if node_out:
            try:
                nj = json.loads(node_out)
                d["online"] = True
                d["status"] = "online (cli)"
                d["source"] = "cli"
                d["peers"]  = nj.get("peer_count", nj.get("peers", "?"))
            except Exception:
                pass

        chain_out = _pct("wrfcoin chain info --json 2>/dev/null", timeout=8, ct_id=ct_id)
        if chain_out:
            try:
                cj = json.loads(chain_out)
                d["online"] = True
                d["height"] = cj.get("height", cj.get("block_height", "?"))
                d["pending"] = cj.get("pending_transactions", "?")
            except Exception:
                pass

    return d


# ── Node epoch ──────────────────────────────────────────────────────────────
# Node-pay epochs on chain 888 are 512 blocks. Epoch e covers heights
# e*512+1 .. (e+1)*512 and closes (settles) at height (e+1)*512+1.
# No unauthenticated node route reports the current epoch, so it is derived
# from the tip height.
NODE_EPOCH_BLOCKS = 512
# Widest left-hand content of the two banner rows (CHAIN / PEER) plus a gap.
BANNER_LEFT_WIDTH = 80
EXPECTED_BLOCK_SECONDS = 77   # chain 888 heartbeat cadence, for the ETA only


def _epoch_info(height, epoch_blocks=NODE_EPOCH_BLOCKS,
                block_seconds=EXPECTED_BLOCK_SECONDS):
    """Epoch position for a tip height, or None when the height is unknown."""
    if isinstance(height, bool) or not isinstance(height, int) or height < 1:
        return None
    epoch = (height - 1) // epoch_blocks
    first = epoch * epoch_blocks + 1
    last = (epoch + 1) * epoch_blocks
    close = last + 1
    to_close = close - height
    return {
        "epoch": epoch,
        "first_height": first,
        "last_height": last,
        "close_height": close,
        "blocks_to_close": to_close,
        "eta_seconds": to_close * block_seconds,
        "progress": (height - first + 1) / epoch_blocks,
    }


def _tip_height(bc):
    height = bc.get("chain_height")
    if isinstance(height, bool) or not isinstance(height, int):
        height = bc.get("height")
    return height if isinstance(height, int) and not isinstance(height, bool) else None


def _epoch_row(bc):
    """EPOCH banner line: epoch number, blocks to the close, rough time left."""
    info = _epoch_info(_tip_height(bc))
    if info is None:
        return "EPOCH  — (height unknown)"
    return (
        f"EPOCH  {info['epoch']}  ·  h{info['first_height']}..h{info['last_height']}"
        f"  ·  {info['blocks_to_close']} blocks to close at h{info['close_height']}"
        f"  ·  ~{_fmt_duration(info['eta_seconds'])} @{EXPECTED_BLOCK_SECONDS}s/blk"
    )


# ── Node release (from the running container's image) ──────────────────────
# Only these fields are read: the image reference, the image id, a fixed set
# of labels, and the image's repo tags. `docker inspect` of the whole
# container would include Config.Env, which must never leave the CT.
NODE_RELEASE_TTL = 60
RELEASE_LABEL = "io.wrfcoin.release"
REVISION_LABEL = "org.opencontainers.image.revision"
_NODE_VERSION_SH = r"""
set -u
line="$(docker inspect --type container --format '{{{{.Config.Image}}}}{{{{"\t"}}}}{{{{.Image}}}}{{{{"\t"}}}}{{{{index .Config.Labels "{release}"}}}}{{{{"\t"}}}}{{{{index .Config.Labels "{revision}"}}}}' {node} 2>/dev/null || true)"
[ -n "$line" ] || exit 0
printf '%s\n' "$line"
img="$(printf '%s' "$line" | cut -f2)"
docker image inspect --format '{{{{json .RepoTags}}}}' "$img" 2>/dev/null || echo '[]'
"""
_NODE_VERSION_CACHE = {"expires_at": 0.0, "value": None, "ct_id": None}


def _short_hex(value, n=12):
    if not isinstance(value, str):
        return None
    value = value.strip()
    if value.startswith("sha256:"):
        value = value[len("sha256:"):]
    if value in ("", "<no value>") or not re.fullmatch(r"[0-9a-fA-F]+", value):
        return None
    return value[:n].lower()


def _image_tag(ref):
    """Tag part of an image reference like repo/name:tag, else None."""
    if not isinstance(ref, str) or not ref or ref.startswith("sha256:") or "@" in ref:
        return None
    name = ref.rsplit("/", 1)[-1]
    if ":" not in name:
        return None
    tag = name.split(":", 1)[1]
    return tag or None


def _parse_node_version(text):
    """Parse the _NODE_VERSION_SH output. Returns a dict, or None if empty.

    Line 1: image-ref TAB image-id TAB release-label TAB revision-label
    Line 2: JSON list of the image's repo tags.
    Missing labels render as "<no value>" from docker's template and are
    treated as absent.
    """
    if not text or not text.strip():
        return None
    lines = text.strip("\n").split("\n")
    fields = (lines[0].split("\t") + ["", "", "", ""])[:4]
    ref, image_id, release, revision = (f.strip() for f in fields)
    if release in ("", "<no value>"):
        release = None
    tags = []
    if len(lines) > 1:
        try:
            parsed = json.loads(lines[1])
            if isinstance(parsed, list):
                tags = [t for t in parsed if isinstance(t, str) and t and "<none>" not in t]
        except ValueError:
            pass
    tag = _image_tag(ref)
    if tag is None:
        for t in tags:
            tag = _image_tag(t)
            if tag:
                break
    return {
        "release": release,
        "tag": tag,
        "revision": _short_hex(revision),
        # An image pinned by id has the id as its reference too.
        "image_id": _short_hex(image_id) or _short_hex(ref),
    }


def _collect_node_version(ct_id=None, now=None):
    now = time.time() if now is None else now
    cache = _NODE_VERSION_CACHE
    if cache["value"] is not None and cache["ct_id"] == ct_id and now < cache["expires_at"]:
        return dict(cache["value"])
    out = _pct_script(
        _NODE_VERSION_SH.format(node=NODE_CONTAINER, release=RELEASE_LABEL,
                                revision=REVISION_LABEL),
        timeout=8, ct_id=ct_id,
    )
    value = _parse_node_version(out)
    if value is not None:
        cache.update({"value": dict(value), "ct_id": ct_id,
                      "expires_at": now + NODE_RELEASE_TTL})
    return value


def _release_row(bc):
    """NODE banner line: release label (or image tag), revision, image id."""
    rel = bc.get("node_release")
    ver = bc.get("node_version")
    prefix = f"NODE   v{ver}  ·  " if ver else "NODE   "
    if not rel:
        return prefix + "release unknown (container not inspectable)"
    name = rel.get("release") or rel.get("tag") or "untagged"
    return (
        f"{prefix}{name}  ·  rev {rel.get('revision') or '—'}"
        f"  ·  image {rel.get('image_id') or '—'}"
    )


def _oracle_is_inert(bc):
    """True when an oracle set exists but has never seen a single attestation.

    Every oracle counter reading 0 is ambiguous: it is what a perfectly healthy
    chain with nothing outstanding looks like, AND what a chain where nothing
    has ever attested looks like. The two are distinguished by whether an oracle
    set exists at all - a populated set tracking zero commits means no
    attestation has ever arrived, so no contribution can ever be rewarded.

    Measured on the live testnet 2026-08-05 at height 366: oracle_set_size 3,
    quorum 2, tracked/quorum/pending all 0, zero OracleAttestation transactions
    in the chain's entire history. The panel read "pend 0". See core4#2464.
    """
    if not bc.get("online"):
        return False
    if (bc.get("oracle_set_size") or 0) <= 0:
        return False
    return (bc.get("tracked_commit_count") or 0) == 0


def _collect_contributor_earnings(ct_id=None):
    """Per-contributor reward totals, with absence reported as an explicit zero.

    A contributor address with no account 404s. That is not missing information
    - it means nothing has ever been paid to it - so it is rendered as 0 with
    `exists: False` rather than omitted. Omission is how a month of zero
    earnings stayed invisible (core4#2737).
    """
    rows = []
    for label, addr in CONTRIBUTOR_ADDRESSES:
        info, err = _json_get_ex(f"/addresses/{addr}", timeout=5, ct_id=ct_id)
        if err:
            # NOT_FOUND is an answer: the account has never been paid, so zero
            # is the truth. Anything else - 401, a timeout, a malformed body -
            # means the question was never answered, and reporting that as a
            # zero is the bug this function exists to avoid.
            if err in ("NOT_FOUND", "HTTP 404"):
                rows.append({"label": label, "address": addr, "exists": False,
                             "paid": 0, "decisions": 0, "error": None})
            else:
                rows.append({"label": label, "address": addr, "exists": None,
                             "paid": None, "decisions": None, "error": err})
            continue
        if not isinstance(info, dict):
            rows.append({"label": label, "address": addr, "exists": None,
                         "paid": None, "decisions": None, "error": "malformed"})
            continue
        cr = info.get("contribution_rewards") or {}
        rows.append({
            "label": label,
            "address": addr,
            "exists": True,
            "paid": _parse_int(cr.get("real_paid"), 0),
            "decisions": _parse_int(cr.get("real_decision_count"), 0),
            "error": None,
        })
    return rows


# ── CI runners (CT 102) ──────────────────────────────────────────────────────
# Runs inside the runner CT via pct exec. Emits one HOST line plus one line per
# runner directory (/opt/gh-runner*): name, repo, systemd state, busy flag, CPU
# of the Runner.Worker process subtree (percent of ONE core, 0.5 s sample),
# seconds since the worker started, and the job name from the listener log.
_RUNNER_COLLECTOR_PY = r"""
import glob
import os
import re
import subprocess
import time


def _read(path, tail_bytes=None):
    try:
        with open(path, "rb") as f:
            if tail_bytes:
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - tail_bytes))
            return f.read().decode("utf-8", "replace")
    except Exception:
        return ""


def _procs():
    table = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            stat = _read(f"/proc/{pid}/stat")
            rp = stat.rindex(")")
            fields = stat[rp + 2:].split()
            ppid = int(fields[1])
            cpu_ticks = int(fields[11]) + int(fields[12])
            start_ticks = int(fields[19])
            cmd = _read(f"/proc/{pid}/cmdline").replace("\0", " ").strip()
            table[int(pid)] = (ppid, cpu_ticks, start_ticks, cmd)
        except Exception:
            pass
    return table


def _subtree(table, root):
    kids = {}
    for pid, (ppid, _, _, _) in table.items():
        kids.setdefault(ppid, []).append(pid)
    seen, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid in seen:
            continue
        seen.add(pid)
        stack.extend(kids.get(pid, []))
    return seen


CLK = os.sysconf("SC_CLK_TCK")
SAMPLE = 0.5
p1 = _procs()
time.sleep(SAMPLE)
p2 = _procs()
uptime = float((_read("/proc/uptime").split() or ["0"])[0])
load = (_read("/proc/loadavg").split() + ["?", "?"])[:2]
mem = {}
for line in _read("/proc/meminfo").splitlines():
    if ":" in line:
        k, v = line.split(":", 1)
        try:
            mem[k.strip()] = int(v.split()[0]) * 1024
        except Exception:
            pass
print("\t".join(["HOST", str(os.cpu_count() or 0), load[0], load[1],
                 str(mem.get("MemTotal", 0)), str(mem.get("MemAvailable", 0))]))

units = {svc: _read(svc) for svc in glob.glob("/etc/systemd/system/actions.runner.*.service")}
for d in sorted(glob.glob("/opt/gh-runner*")):
    cfg = _read(d + "/.runner")
    if not cfg:
        continue
    m = re.search(r'"agentName":\s*"([^"]*)"', cfg)
    name = m.group(1) if m else os.path.basename(d)
    m = re.search(r'"gitHubUrl":\s*"https://github.com/([^"]*)"', cfg)
    repo = m.group(1).rstrip("/") if m else ""
    unit = next((os.path.basename(s) for s, body in units.items() if d + "/" in body), "")
    active = "unknown"
    if unit:
        try:
            active = subprocess.run(["systemctl", "is-active", unit], capture_output=True,
                                    text=True, timeout=3).stdout.strip() or "unknown"
        except Exception:
            pass
    lpid = next((pid for pid, (_, _, _, cmd) in p2.items()
                 if cmd.startswith(d + "/bin/Runner.Listener")), None)
    wpid = None
    if lpid is not None:
        wpid = next((pid for pid, (ppid, _, _, cmd) in p2.items()
                     if ppid == lpid and "Runner.Worker" in cmd), None)
    busy = wpid is not None
    cpu = 0.0
    elapsed = 0
    if busy:
        tree = _subtree(p2, wpid)
        t1 = sum(p1[x][1] for x in tree if x in p1)
        t2 = sum(p2[x][1] for x in tree)
        cpu = max(0.0, (t2 - t1) / CLK / SAMPLE * 100.0)   # percent of ONE core
        elapsed = max(0, int(uptime - p2[wpid][2] / CLK))
    job = ""
    logs = sorted(glob.glob(d + "/_diag/Runner_*.log"), key=os.path.getmtime)
    if logs:
        for line in reversed(_read(logs[-1], tail_bytes=65536).splitlines()):
            if "Running job: " in line:
                job = line.split("Running job: ", 1)[1].strip()
                break
            if "completed with result" in line:
                break
    if not busy:
        job = ""
    print("\t".join([name, repo, active, "1" if busy else "0", f"{cpu:.1f}", str(elapsed),
                     job.replace("\t", " ")]))
"""

_RUNNER_COLLECTOR_SH = "python3 - <<'WRFCOIN_RUNNER_COLLECTOR'\n" + _RUNNER_COLLECTOR_PY + "\nWRFCOIN_RUNNER_COLLECTOR\n"


def _parse_runner_report(text):
    """Decode the collector's TSV. Pure, so the shape is pinned by tests."""
    host, runners = {}, []
    for line in (text or "").splitlines():
        parts = line.split("\t")
        if parts[0] == "HOST":
            parts += [""] * (6 - len(parts))
            host = {
                "nproc": _parse_int(parts[1], default=0),
                "load1": parts[2] or "?",
                "load5": parts[3] or "?",
                "mem_total": _parse_int(parts[4], default=0),
                "mem_avail": _parse_int(parts[5], default=0),
            }
            continue
        if len(parts) < 7:
            continue
        name, repo, service, busy, cpu, elapsed, job = parts[:7]
        try:
            cpu_pct = float(cpu)
        except (TypeError, ValueError):
            cpu_pct = 0.0
        runners.append({
            "name": name,
            "repo": repo,
            "service": service or "unknown",
            "busy": busy == "1",
            "cpu_pct": cpu_pct,            # percent of one core
            "elapsed": _parse_int(elapsed, default=0),
            "job": job,
        })
    # core4 runners first (the build lane), then the per-repo singles.
    runners.sort(key=lambda r: (0 if r["repo"].endswith("/core4") else 1, r["name"]))
    return {"host": host, "runners": runners}


def _collect_runners(ct_id=RUNNER_CT_ID):
    out = _pct_script(_RUNNER_COLLECTOR_SH, timeout=15, ct_id=ct_id)
    if not out:
        return {"host": {}, "runners": [], "error": f"no data from CT {ct_id}"}
    report = _parse_runner_report(out)
    report["error"] = None if report["runners"] else f"no runners found in CT {ct_id}"
    return report


def _ci_token(env=None, env_file=RUNNER_TOKEN_ENV_FILE):
    """A read-only GitHub token from the environment or a KEY=VALUE env file."""
    env = os.environ if env is None else env
    for key in RUNNER_TOKEN_ENV_KEYS:
        value = (env.get(key) or "").strip()
        if value:
            return value
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key.strip() in RUNNER_TOKEN_ENV_KEYS:
                    value = value.strip().strip('"').strip("'")
                    if value:
                        return value
    except Exception:
        pass
    return ""


def _gh_get(path, token, timeout=6):
    import urllib.request
    req = urllib.request.Request(
        "https://api.github.com" + path,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "wrfcoin-node-dashboard",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def _order_ci_queue(runs):
    """Oldest first — that is the order the runners pick work up in."""
    return sorted(runs, key=lambda r: (r.get("created_at") or "", r.get("id") or 0))


def _fetch_ci_queue(token, repos=RUNNER_QUEUE_REPOS, get=_gh_get, probe=RUNNER_QUEUE_PROBE):
    """Queued/in-progress workflow runs, plus the self-hosted JOBS waiting in the oldest runs.

    The runs API cannot say which runner a queued run needs, so the oldest `probe` runs
    get one jobs call each and only jobs labelled RUNNER_LABEL are listed as "next up" —
    those are the ones the CT 102 runners will pick, in this order. Hosted-runner work
    is counted in the run totals but never drawn as next up.
    """
    queued, running = [], []
    for repo in repos:
        short = repo.split("/")[-1]
        for status, bucket in (("queued", queued), ("in_progress", running)):
            data = get(f"/repos/{repo}/actions/runs?status={status}&per_page=50", token) or {}
            for run in data.get("workflow_runs") or []:
                bucket.append({
                    "repo": short,
                    "id": run.get("id"),
                    "name": run.get("name") or "?",
                    "number": run.get("run_number"),
                    "branch": run.get("head_branch") or "",
                    "title": run.get("display_title") or "",
                    "created_at": run.get("created_at") or "",
                    "event": run.get("event") or "",
                    "jobs": [],
                })
    queued = _order_ci_queue(queued)
    running = _order_ci_queue(running)

    def _jobs(run):
        try:
            return (get(f"/repos/wrfcoin/{run['repo']}/actions/runs/{run['id']}/jobs?per_page=50",
                        token) or {}).get("jobs") or []
        except Exception:
            return []

    queued_jobs = []
    for run in queued[:probe]:
        for j in _jobs(run):
            labels = [str(x) for x in (j.get("labels") or [])]
            if j.get("status") == "queued" and RUNNER_LABEL in labels:
                queued_jobs.append({
                    "repo": run["repo"], "workflow": run["name"], "job": j.get("name") or "?",
                    "branch": run["branch"], "created_at": run["created_at"], "labels": labels,
                })
    for run in running[:6]:
        run["jobs"] = [
            {"name": j.get("name") or "?", "runner": j.get("runner_name") or "",
             "self_hosted": RUNNER_LABEL in [str(x) for x in (j.get("labels") or [])]}
            for j in _jobs(run) if j.get("status") == "in_progress"
        ]
    return {"queued": queued, "running": running, "queued_jobs": queued_jobs,
            "probed": min(probe, len(queued)), "error": None}


_CI_QUEUE_CACHE = {"expires_at": 0.0, "data": None}


def _collect_ci_queue():
    """Cached GitHub queue view; degrades to the last good answer plus an error tag."""
    now = time.time()
    cache = _CI_QUEUE_CACHE
    if cache["data"] is not None and now < cache["expires_at"]:
        return cache["data"]
    previous = cache["data"] or {"queued": [], "running": []}
    token = _ci_token()
    if not token:
        data = {"queued": [], "running": [], "queued_jobs": [], "probed": 0, "error": "no token"}
    else:
        try:
            data = _fetch_ci_queue(token)
        except Exception as e:                       # network, 401, rate limit, ...
            data = {"queued": previous.get("queued", []), "running": previous.get("running", []),
                    "queued_jobs": previous.get("queued_jobs", []), "probed": previous.get("probed", 0),
                    "error": type(e).__name__}
    data["fetched_at"] = now
    cache["data"] = data
    cache["expires_at"] = now + RUNNER_QUEUE_TTL
    return data


def _collect_drives():
    """SMART data + diskstats for all drives. Runs parallel smartctl on host."""
    b64 = base64.b64encode(_DRIVE_COLLECTOR_SH.encode()).decode()
    out = _run(f"echo {b64} | base64 -d | bash", timeout=20)
    if not out:
        return {}
    try:
        return json.loads(out)
    except Exception:
        return {}


# ── Thread-safe state ────────────────────────────────────────────────────────
class NodeState:
    def __init__(self):
        self._lock      = threading.Lock()
        self.zfs        = {}
        self.system     = {}
        self.ct         = {}
        self.docker     = {}
        self.blockchain = {}
        self.drives     = {}
        self.disk_rates = {}   # dev -> (read_bps, write_bps)
        self.runners    = {}
        self.ci_queue   = {}
        self.updated    = None
        self._busy      = False
        # Network rate tracking
        self._prev_rx   = 0
        self._prev_tx   = 0
        self._prev_t    = 0.0
        self.rx_rate    = 0.0
        self.tx_rate    = 0.0
        # Disk I/O rate tracking
        self._prev_disk = {}   # dev -> (read_sectors, write_sectors)
        # Block-rate tracking: (timestamp, height) samples over a short window so
        # blocks/min is smooth despite the ~60s block cadence vs 5s refresh.
        self._height_hist = deque()
        # Peer block-flow tracking: seconds since blocks_received last climbed
        # (blocks arrive ~every 60s, so track "time since last" not instantaneous).
        self._prev_blocks_rx = None
        self._last_rx_increase_t = 0.0

    def collect(self):
        with self._lock:
            if self._busy:
                return
            self._busy = True
        try:
            zfs    = _collect_zfs()
            sys_d  = _collect_system()
            ct     = _collect_ct()
            active_ct_id = ct.get("id")
            docker = _collect_docker(active_ct_id) if ct.get("running") else {}
            bc     = _collect_blockchain(active_ct_id) if ct.get("running") else {"online": False, "status": "offline"}
            drives = _collect_drives()
            runners = _collect_runners()
            ci_queue = _collect_ci_queue()

            now    = time.time()
            rx_rate = tx_rate = 0.0
            if self._prev_t:
                dt = max(now - self._prev_t, 0.001)
                rx_rate = (sys_d.get("net_rx_bytes", 0) - self._prev_rx) / dt
                tx_rate = (sys_d.get("net_tx_bytes", 0) - self._prev_tx) / dt

            # Per-drive I/O rates (sectors × 512 = bytes)
            disk_rates = {}
            for dev, info in drives.items():
                try:
                    rs = int(info.get("rs", 0))
                    ws = int(info.get("ws", 0))
                    if dev in self._prev_disk and self._prev_t:
                        prs, pws = self._prev_disk[dev]
                        dt2 = max(now - self._prev_t, 0.001)
                        disk_rates[dev] = (
                            max(0.0, (rs - prs) * 512 / dt2),
                            max(0.0, (ws - pws) * 512 / dt2),
                        )
                    self._prev_disk[dev] = (rs, ws)
                except Exception:
                    pass

            # ── Derived chain/peer signals (stored inside bc so the snapshot
            #    tuple stays a fixed shape) ──────────────────────────────────
            height = bc.get("chain_height")
            if not isinstance(height, int):
                height = bc.get("height")
            if isinstance(height, int):
                self._height_hist.append((now, height))
                # Keep a ~5 min window.
                while self._height_hist and now - self._height_hist[0][0] > 300:
                    self._height_hist.popleft()
                if len(self._height_hist) >= 2:
                    t0, h0 = self._height_hist[0]
                    dt_h = max(now - t0, 1e-6)
                    bc["blocks_per_min"] = max(0.0, (height - h0) / dt_h * 60.0)
                else:
                    bc["blocks_per_min"] = None
            else:
                bc["blocks_per_min"] = None

            blocks_rx = bc.get("blocks_received")
            if isinstance(blocks_rx, int):
                if self._prev_blocks_rx is not None and blocks_rx > self._prev_blocks_rx:
                    self._last_rx_increase_t = now
                self._prev_blocks_rx = blocks_rx
                bc["peer_rx_age"] = (
                    (now - self._last_rx_increase_t) if self._last_rx_increase_t else None
                )
            else:
                bc["peer_rx_age"] = None

            with self._lock:
                self.zfs        = zfs
                self.system     = sys_d
                self.ct         = ct
                self.docker     = docker
                self.blockchain = bc
                self.drives     = drives
                self.disk_rates = disk_rates
                self.runners    = runners
                self.ci_queue   = ci_queue
                self.updated    = datetime.now().strftime("%H:%M:%S")
                self.rx_rate    = max(0.0, rx_rate)
                self.tx_rate    = max(0.0, tx_rate)
                self._prev_rx   = sys_d.get("net_rx_bytes", 0)
                self._prev_tx   = sys_d.get("net_tx_bytes", 0)
                self._prev_t    = now
        finally:
            with self._lock:
                self._busy = False

    def snapshot(self):
        with self._lock:
            return (
                dict(self.zfs),
                dict(self.system),
                dict(self.ct),
                dict(self.docker),
                dict(self.blockchain),
                {k: dict(v) for k, v in self.drives.items()},
                dict(self.disk_rates),
                dict(self.runners),
                dict(self.ci_queue),
                self.updated,
                self.rx_rate,
                self.tx_rate,
            )


# ── Formatting helpers ────────────────────────────────────────────────────────
def _oracle_row(bc):
    """Oracle line that distinguishes 'nothing outstanding' from 'nothing works'.

    Three states, not two. A query that failed is not a chain with nothing
    outstanding, and rendering it as `pend 0` is how this panel reported a
    healthy oracle set while every request was being refused for lack of a
    token.
    """
    err = bc.get("oracle_query_error")
    if err:
        return f"Oracle  UNAVAILABLE ({err})"
    q = bc.get("oracle_quorum", "?")
    tracked = bc.get("tracked_commit_count", 0) or 0
    if _oracle_is_inert(bc):
        return f"Oracle  q{q}  \u00b7  set {bc.get('oracle_set_size', 0)}  \u00b7  NO ATTESTATIONS"
    return (f"Oracle  q{q}  \u00b7  trk {tracked}  \u00b7  "
            f"quorum {bc.get('commits_with_quorum', 0)}  \u00b7  "
            f"pend {bc.get('commits_pending_quorum', 0)}")


def _earnings_row(bc):
    """One line answering 'is anyone actually earning?' - the question that was
    silently 'no' for a month while every other panel looked healthy.

    A contributor whose query failed contributes NOTHING to the total and is
    named as unavailable instead. Summing an unanswered question as 0 is the
    same defect one line down.
    """
    rows = bc.get("contributor_earnings") or []
    if not rows:
        return "Earned  no contributors configured"
    failed = [r for r in rows if r.get("error")]
    answered = [r for r in rows if not r.get("error")]
    if not answered:
        codes = sorted({str(r["error"]) for r in failed})
        return f"Earned  UNAVAILABLE ({', '.join(codes)})"
    paid = [r for r in answered if (r.get("paid") or 0) > 0]
    if paid:
        head = "Earned  " + "  \u00b7  ".join(
            f"{r['label']} {r['paid'] / 100000000:.2f}" for r in paid
        ) + " WRF"
    else:
        head = f"Earned  0 WRF across {len(answered)} contributor(s)"
    if failed:
        head += f"  \u00b7  {len(failed)} unavailable"
    return head


def _fmt_bytes(b, dp=1):
    if b is None or b < 0:
        return "?"
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB":
            return f"{b:.{dp}f} {u}"
        b /= 1024
    return "?"

def _fmt_rate(bps):
    if bps is None or bps < 0:
        return "0 B/s"
    for u in ("B/s", "KB/s", "MB/s", "GB/s"):
        if bps < 1024 or u == "GB/s":
            return f"{bps:.0f} {u}"
        bps /= 1024
    return "?"

def _bar(pct, width=12):
    pct = max(0.0, min(100.0, pct))
    filled = round(pct / 100 * width)
    return "█" * filled + "░" * (width - filled)

def _dot(healthy):
    return "●" if healthy else "○"

def _fmt_duration(secs):
    if secs is None:
        return "?"
    try:
        secs = int(secs)
    except Exception:
        return "?"
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m"
    if secs < 86400:
        return f"{secs // 3600}h {(secs % 3600) // 60}m"
    return f"{secs // 86400}d {(secs % 86400) // 3600}h"

def _fmt_age(iso_ts):
    dt = _parse_iso8601(iso_ts)
    if not dt:
        return "?"
    now = datetime.now(timezone.utc)
    delta = max(int((now - dt).total_seconds()), 0)
    return _fmt_duration(delta)

def _compact_mem_usage(mem_usage):
    if not mem_usage:
        return "?"
    return mem_usage.split("/")[0].strip()

def _service_bucket(svc_def, svc):
    status = (svc or {}).get("status", "missing")
    restarts = (svc or {}).get("restart_count", 0)
    started_at = (svc or {}).get("started_at")
    restart_loop = (
        status in ("running", "created", "restarting")
        and restarts > 5
        and (
            (age := _age_seconds(started_at)) is not None
            and age <= 3600
        )
    )
    if status == "missing":
        return "optional_off" if not svc_def.get("required", True) else "missing"
    if restart_loop:
        return "problem"
    if svc_def.get("one_shot"):
        if status == "exited" and (svc or {}).get("exit_code", 1) == 0:
            return "init_done"
        if status in ("running", "created", "restarting"):
            return "starting"
        return "problem"
    if status == "running":
        health = (svc or {}).get("health", "none")
        if health in ("healthy", "none"):
            return "up"
        if health == "starting":
            return "starting"
        return "problem"
    if status in ("created", "restarting"):
        return "starting"
    return "problem"

def _service_line(svc_def, svc):
    bucket = _service_bucket(svc_def, svc)
    if bucket == "up":
        extra = []
        cpu = (svc or {}).get("cpu_pct")
        mem = _compact_mem_usage((svc or {}).get("mem_usage"))
        if cpu is not None:
            extra.append(f"{cpu:.1f}%CPU")
        if mem != "?":
            extra.append(mem)
        return "●", P_GREEN, "up", " ".join(extra)
    if bucket == "starting":
        if svc_def.get("one_shot"):
            return "●", P_WARN, "init", "running"
        restarts = (svc or {}).get("restart_count", 0)
        detail = f"restarts {restarts}" if restarts else "starting"
        return "●", P_WARN, "starting", detail
    if bucket == "init_done":
        return "●", P_GREEN, "done", f"exit 0 · {_fmt_age((svc or {}).get('finished_at'))}"
    if bucket == "optional_off":
        profile = svc_def.get("profile", "optional")
        return "○", P_DIM, "profile off", profile
    if bucket == "missing":
        return "○", P_RED, "missing", ""
    exit_code = (svc or {}).get("exit_code")
    if exit_code is not None and (svc or {}).get("status") == "exited":
        return "○", P_RED, f"exit {exit_code}", f"after {_fmt_age((svc or {}).get('finished_at'))}"
    health = (svc or {}).get("health")
    status = (svc or {}).get("status", "down")
    restarts = (svc or {}).get("restart_count", 0)
    detail = health if health not in ("none", "missing", None, "") else status
    if restarts:
        detail += f" · r{restarts}"
    return "○", P_RED, status, detail

def _service_summary(docker):
    counts = {"up": 0, "starting": 0, "problem": 0, "missing": 0, "optional_off": 0, "init_done": 0}
    for svc_def in SERVICE_DEFS:
        counts[_service_bucket(svc_def, docker.get(svc_def["key"], {}))] += 1
    return counts


def _headline_service_summary(docker):
    good = 0
    for svc_def in HEADLINE_SERVICE_DEFS:
        if _service_bucket(svc_def, docker.get(svc_def["key"], {})) in ("up", "init_done"):
            good += 1
    return {"up": good, "total": len(HEADLINE_SERVICE_DEFS)}

def _build_alerts(zfs, sys_d, ct, docker, bc, runners=None):
    alerts = []
    for rr in (runners or {}).get("runners") or []:
        if rr.get("service") not in ("active", "unknown"):
            alerts.append((f"CI runner {rr.get('name', '?')} service is {rr.get('service')}", P_RED))
    host_uptime = int(sys_d.get("uptime_secs", 0) or 0)
    node_uptime = int(bc.get("uptime_seconds", 0) or 0)
    boot_settling = host_uptime > 0 and (
        host_uptime < BOOT_SETTLE_SECONDS
        or (node_uptime > 0 and node_uptime < BOOT_SETTLE_SECONDS)
    )

    if not ct.get("running"):
        alerts.append((f"CT {ct.get('configured_id', CT_ID)} is stopped", P_RED))
    elif ct.get("id") != ct.get("configured_id", CT_ID):
        alerts.append((f"Using active Docker host CT {ct.get('id')} ({ct.get('hostname', 'docker-host')})", P_WARN))

    if zfs.get("state") not in ("ONLINE", None):
        alerts.append((f"ZFS tank is {zfs.get('state', 'unknown')}", P_RED))

    required_missing = [
        svc["label"]
        for svc in SERVICE_DEFS
        if svc.get("required", True) and _service_bucket(svc, docker.get(svc["key"], {})) == "missing"
    ]
    required_problem = [
        svc["label"]
        for svc in SERVICE_DEFS
        if svc.get("required", True) and _service_bucket(svc, docker.get(svc["key"], {})) == "problem"
    ]
    required_starting = [
        svc["label"]
        for svc in SERVICE_DEFS
        if svc.get("required", True) and _service_bucket(svc, docker.get(svc["key"], {})) == "starting"
    ]
    if boot_settling:
        settling_bits = []
        if required_starting:
            settling_bits.append(f"{len(required_starting)} starting")
        if required_problem:
            settling_bits.append(f"{len(required_problem)} unhealthy")
        if required_missing:
            settling_bits.append(f"{len(required_missing)} missing")
        if settling_bits:
            alerts.append((f"Boot settling: {', '.join(settling_bits)}", P_WARN))
    else:
        if required_missing:
            alerts.append((f"Missing required services: {', '.join(required_missing[:3])}", P_RED))
        if required_problem:
            alerts.append((f"Unhealthy services: {', '.join(required_problem[:3])}", P_RED))

    if bc.get("online"):
        status = bc.get("status", "")
        if status == "not_ready":
            if boot_settling:
                alerts.append(("native-chain still warming up after reboot", P_WARN))
            else:
                alerts.append(("native-chain readyz reports not_ready", P_RED))
        elif bc.get("sync_status") == "syncing":
            alerts.append(("native-chain is syncing", P_WARN))
        if bc.get("block_age_seconds", 0) and bc.get("block_age_seconds", 0) > 300:
            alerts.append((f"Last block is {_fmt_duration(bc.get('block_age_seconds'))} old", P_RED))
        if bc.get("peers") == 0:
            if boot_settling:
                alerts.append(("P2P discovery still warming up", P_WARN))
            else:
                alerts.append(("No connected P2P peers", P_WARN))
        if bc.get("commits_pending_quorum", 0) > 0:
            alerts.append((f"{bc.get('commits_pending_quorum')} oracle commits pending quorum", P_WARN))
        # An oracle set that has never seen an attestation cannot reward anything.
        # Without this the same counters render as "pend 0" and read as healthy.
        if _oracle_is_inert(bc):
            alerts.append(("Oracle set seated but NOTHING ATTESTING - no contribution can be rewarded", P_RED))
    else:
        if boot_settling:
            alerts.append(("native-chain API warming up after reboot", P_WARN))
        else:
            alerts.append(("native-chain API offline", P_WARN))

    cpu = sys_d.get("cpu_pct", 0.0)
    ram_total = sys_d.get("ram_total", 1) or 1
    ram_pct = (sys_d.get("ram_used", 0) / ram_total) * 100
    temp = sys_d.get("temp_c", 0)
    if temp and temp >= 80:
        alerts.append((f"Host temperature high: {temp:.0f}C", P_RED))
    elif temp and temp >= 70:
        alerts.append((f"Host temperature warm: {temp:.0f}C", P_WARN))
    if cpu >= 90:
        alerts.append((f"CPU saturation: {cpu:.1f}%", P_RED))
    if ram_pct >= 90:
        alerts.append((f"RAM pressure: {ram_pct:.0f}% used", P_RED))

    return alerts[:4]


# ── Color palette IDs ─────────────────────────────────────────────────────────
P_TITLE = 1   # cyan
P_GREEN = 2
P_RED   = 3
P_WARN  = 4   # yellow
P_DIM   = 5   # white
P_BOLD  = 6   # bright white (bold)

def _init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(P_TITLE, curses.COLOR_CYAN,   -1)
    curses.init_pair(P_GREEN, curses.COLOR_GREEN,  -1)
    curses.init_pair(P_RED,   curses.COLOR_RED,    -1)
    curses.init_pair(P_WARN,  curses.COLOR_YELLOW, -1)
    curses.init_pair(P_DIM,   curses.COLOR_WHITE,  -1)
    curses.init_pair(P_BOLD,  curses.COLOR_WHITE,  -1)


# ── Rendering ─────────────────────────────────────────────────────────────────
def _draw(scr, state: NodeState):
    zfs, sys_d, ct, docker, bc, drives, disk_rates, runners, ci_queue, updated, rx_rate, tx_rate = state.snapshot()
    alerts = _build_alerts(zfs, sys_d, ct, docker, bc, runners=runners)
    svc_counts = _service_summary(docker)

    scr.erase()
    H, W = scr.getmaxyx()

    def p(row, col, text, pair=P_DIM, bold=False):
        if row < 0 or row >= H - 1 or col < 0 or col >= W - 1:
            return
        text = text[:max(0, W - col - 1)]
        if not text:
            return
        attr = curses.color_pair(pair) | (curses.A_BOLD if bold else 0)
        try:
            scr.addstr(row, col, text, attr)
        except curses.error:
            pass

    def side(row):
        p(row, 0,     "│", P_TITLE)
        p(row, W - 1, "│", P_TITLE)

    def sep(row):
        p(row, 0, "├" + "─" * (W - 2) + "┤", P_TITLE)

    def render_service(row, col, svc_def, col_w):
        svc = docker.get(svc_def["key"], {})
        dot, color, status_text, detail = _service_line(svc_def, svc)
        label = svc_def["label"]
        if str(svc_def.get("port", "")).isdigit():
            label = f"{label} :{svc_def['port']}"
        label_w = max(12, min(20, col_w // 2 - 2))
        state_col = col + label_w + 4
        p(row, col, dot, color)
        p(row, col + 2, f"{label[:label_w]:<{label_w}}", P_DIM, bold=True)
        p(row, state_col, status_text, color, bold=True)
        if detail:
            p(row, state_col + len(status_text) + 1, detail, P_DIM)

    r = 0   # current row counter

    # ── Title box ─────────────────────────────────────────────────────────────
    p(r, 0, "┌" + "─" * (W - 2) + "┐", P_TITLE); r += 1

    title = f"WRFCoin Node  ·  {_title_host()}"
    p(r, max(1, (W - len(title)) // 2), title, P_TITLE, bold=True); side(r); r += 1

    active_ct = f"CT {ct.get('id', CT_ID)}"
    headline_counts = _headline_service_summary(docker)
    sub = (
        f"TESTNET NODE  ·  {active_ct}  ·  Up {sys_d.get('uptime', '?')}  ·  "
        f"svc up {headline_counts['up']}/{headline_counts['total']}  ·  "
        f"alerts {len(alerts)}"
    )
    p(r, max(1, (W - len(sub)) // 2), sub, P_WARN); side(r); r += 1

    sep(r); r += 1

    # ── Headline banner: chain production + peer link, at a glance ─────────────
    # The EPOCH / NODE lines sit at the right of the two banner rows when the
    # console is wide enough (the physical console is 200 columns and every
    # row is already used), otherwise on two rows of their own.
    epoch_line = _epoch_row(bc)
    release_line = _release_row(bc)
    epoch_attr = (P_TITLE, True) if bc.get("online") else (P_DIM, False)
    release_attr = (P_TITLE, False) if bc.get("node_release") else (P_DIM, False)
    right_col = W - 2 - max(len(epoch_line), len(release_line))
    inline_meta = right_col >= BANNER_LEFT_WIDTH
    banner_row = r
    online    = bc.get("online")
    block_age = bc.get("block_age_seconds")
    bpm       = bc.get("blocks_per_min")
    height_str = bc.get("height", "—")
    if not online:
        p(r, 2, "○ CHAIN OFFLINE", P_RED, bold=True)
        p(r, 20, "native-chain API not reachable", P_DIM)
    else:
        stalled = isinstance(block_age, (int, float)) and block_age > CHAIN_STALL_SECONDS
        if stalled:
            p(r, 2, "✗ CHAIN STALLED", P_RED, bold=True)
            p(r, 20, f"last block {_fmt_duration(block_age)} ago", P_RED, bold=True)
            p(r, 46, f"height {height_str}", P_DIM)
        else:
            p(r, 2, "● CHAIN PRODUCING", P_GREEN, bold=True)
            col = 22
            p(r, col, f"height {height_str}", P_GREEN, bold=True); col += 16
            if bpm is not None:
                p(r, col, f"{bpm:.1f} blk/min", P_DIM); col += 15
            age_txt = _fmt_duration(block_age) if block_age is not None else "?"
            p(r, col, f"last block {age_txt} ago", P_DIM)
    side(r); r += 1

    # Peer / convergence link (from this node's P2P view — see writeup on the
    # authoritative state_root check via verify-two-node-convergence.sh).
    if not online:
        p(r, 2, "PEER  —", P_DIM)
    else:
        try:
            npeers = int(bc.get("peers"))
        except (TypeError, ValueError):
            npeers = None
        rx_age  = bc.get("peer_rx_age")
        rx_ok   = rx_age is None or rx_age < CHAIN_STALL_SECONDS
        synced  = bc.get("sync_status") == "synced"
        p(r, 2, "PEER  ", P_DIM)
        if npeers == 0:
            p(r, 8, "0 connected", P_RED, bold=True)
            p(r, 22, "no peer to sync/converge with", P_WARN)
        else:
            pc_txt = f"{npeers if npeers is not None else bc.get('peers')} connected"
            p(r, 8, pc_txt, P_GREEN, bold=True)
            col = 8 + len(pc_txt) + 3
            if rx_age is not None and rx_age >= CHAIN_STALL_SECONDS:
                p(r, col, f"no blocks rx {_fmt_duration(rx_age)}", P_WARN); col += 22
            else:
                p(r, col, "blocks flowing ✓", P_GREEN); col += 19
            in_sync = bool(synced) and bool(npeers) and rx_ok and not (
                isinstance(block_age, (int, float)) and block_age > CHAIN_STALL_SECONDS)
            if synced:
                p(r, col, "in sync ✓" if in_sync else "syncing…",
                  P_GREEN if in_sync else P_WARN, bold=in_sync)
    side(r); r += 1

    # Epoch position and the node's running release.
    if inline_meta:
        p(banner_row, right_col, epoch_line, epoch_attr[0], bold=epoch_attr[1])
        p(banner_row + 1, right_col, release_line, release_attr[0], bold=release_attr[1])
    else:
        p(r, 2, epoch_line, epoch_attr[0], bold=epoch_attr[1])
        side(r); r += 1
        p(r, 2, release_line, release_attr[0], bold=release_attr[1])
        side(r); r += 1

    sep(r); r += 1

    # ── Three-column row: ZFS | SYSTEM | BLOCKCHAIN ───────────────────────────
    zfs_w  = max(30, W // 3)
    sys_w  = max(30, W // 3)
    bc_w   = W - zfs_w - sys_w - 2
    c_zfs  = 1
    c_sys  = c_zfs + zfs_w
    c_bc   = c_sys + sys_w

    # Column headers
    p(r, c_zfs, "ZFS POOL",   P_TITLE, bold=True)
    p(r, c_sys, "SYSTEM",     P_TITLE, bold=True)
    p(r, c_bc,  "BLOCKCHAIN", P_TITLE, bold=True)
    side(r); r += 1

    # ── Row: pool state | CPU | height ────────────────────────────────────────
    pool_state = zfs.get("state", "?")
    avail_t    = zfs.get("avail", 0) / (1024 ** 4)
    sc = P_GREEN if pool_state == "ONLINE" else (P_WARN if pool_state in ("DEGRADED",) else P_RED)
    p(r, c_zfs, "tank  ")
    p(r, c_zfs + 6, f"{pool_state:<8}", sc, bold=True)
    p(r, c_zfs + 15, f"{avail_t:.1f}T free")

    cpu     = sys_d.get("cpu_pct", 0.0)
    cpu_col = P_GREEN if cpu < 60 else (P_WARN if cpu < 85 else P_RED)
    p(r, c_sys, f"CPU  {cpu:5.1f}%  {_bar(cpu, 10)}", cpu_col)

    bc_status = bc.get("sync_status") or bc.get("status", "offline")
    bc_color = P_GREEN if bc.get("status") == "ready" else (P_WARN if bc.get("online") else P_RED)
    p(r, c_bc, f"Height  {bc.get('height', '—')}", bc_color if bc.get("online") else P_DIM)
    p(r, c_bc + 16, str(bc_status), bc_color, bold=bc.get("online"))
    side(r); r += 1

    # ── Datasets vs metrics: 5 rows ───────────────────────────────────────────
    ds_order  = ["docker", "postgres", "redis", "blockchain", "backups"]
    ds_data   = zfs.get("datasets", {})

    ram_tot = sys_d.get("ram_total", 1) or 1
    ram_use = sys_d.get("ram_used", 0)
    ram_pct = ram_use / ram_tot * 100
    ram_col = P_GREEN if ram_pct < 75 else (P_WARN if ram_pct < 90 else P_RED)

    sys_rows = [
        (f"RAM  {_fmt_bytes(ram_use):>9}  {_bar(ram_pct, 10)}", ram_col),
        (f"Temp  {sys_d['temp_c']:.0f}°C" if sys_d.get("temp_c") else "Temp  N/A",
         P_GREEN if sys_d.get("temp_c", 0) < 65 else (P_WARN if sys_d.get("temp_c", 0) < 80 else P_RED)),
        (f"Load  {sys_d.get('load', '?')}", P_DIM),
        (f"Net  ↑{_fmt_rate(tx_rate):>9}  ↓{_fmt_rate(rx_rate):>9}", P_DIM),
        (f"Uptime  {sys_d.get('uptime', '?')}", P_DIM),
    ]

    bc_rows_online = [
        f"Peers   {bc.get('peers', '?')}  ·  age {_fmt_duration(bc.get('block_age_seconds', 0))}",
        f"Mempool {bc.get('pending', '?')}  ·  tx {bc.get('total_transactions', '?')}",
        f"Avg blk {bc.get('avg_block_time_secs', 0.0):.1f}s  ·  {('%.1f' % bpm) if bpm is not None else '?'} blk/min",
        f"State   acct {bc.get('accounts', '?')}  ·  nft {bc.get('nfts', '?')}",
        _oracle_row(bc),
        _earnings_row(bc),
    ]
    bc_rows_offline = [
        "Peers   —",
        "Mempool —",
        "Avg blk —",
        "State   offline",
        "Oracle  offline",
    ]

    for i, ds in enumerate(ds_order):
        used = ds_data.get(ds)
        p(r, c_zfs, f"  {ds:<16}  {_fmt_bytes(used) if used is not None else '?':>8}")

        sys_text, sys_col = sys_rows[i]
        p(r, c_sys, sys_text, sys_col)

        bc_text = (bc_rows_online if bc.get("online") else bc_rows_offline)[i]
        p(r, c_bc, bc_text, P_GREEN if bc.get("online") else P_DIM)

        side(r); r += 1

    # ── Alerts ────────────────────────────────────────────────────────────────
    sep(r); r += 1
    p(r, 1, "ALERTS", P_TITLE, bold=True)
    if alerts:
        p(r, W - 16, f"{len(alerts)} active", P_WARN if len(alerts) < 3 else P_RED, bold=True)
    else:
        p(r, W - 12, "all clear", P_GREEN, bold=True)
    side(r); r += 1

    if alerts:
        for text, color in alerts:
            p(r, 1, "!", color, bold=True)
            p(r, 4, text, color)
            side(r); r += 1
    else:
        p(r, 1, "All monitored host, chain, and service checks are green.", P_GREEN)
        side(r); r += 1

    # ── Drives ────────────────────────────────────────────────────────────────
    sep(r); r += 1
    p(r, 1, "DRIVES", P_TITLE, bold=True)
    p(r, W - 34, f"tank I/O  ↑{_fmt_rate(zfs.get('write_bps', 0)):>9}  ↓{_fmt_rate(zfs.get('read_bps', 0)):>9}", P_DIM)
    side(r); r += 1

    def _temp_col(t, is_nvme=False):
        if t is None or t == "?":
            return P_DIM
        try:
            t = float(t)
        except ValueError:
            return P_DIM
        if is_nvme:
            return P_GREEN if t < 50 else (P_WARN if t < 65 else P_RED)
        return P_GREEN if t < 40 else (P_WARN if t < 50 else P_RED)

    def _bad_col(reallocated, pending):
        try:
            bad = int(reallocated or 0) + int(pending or 0)
            return P_RED if bad > 0 else P_GREEN
        except Exception:
            return P_DIM

    def _fmt_hours(h):
        try:
            h = int(h)
            if h < 24:   return f"{h}h"
            if h < 8760: return f"{h//24}d"
            return f"{h//8760}y{(h%8760)//24}d"
        except Exception:
            return "?"

    # NVMe drives first
    nvmes = [(dev, info) for dev, info in drives.items() if info.get("type") == "nvme"]
    if nvmes:
        p(r, 1, f"  M.2 NVMe  ({'1 drive' if len(nvmes)==1 else f'{len(nvmes)} drives'})", P_DIM)
        side(r); r += 1
        for dev, info in nvmes:
            temp     = info.get("temp", "?")
            pct_used = info.get("pct_used", "?")
            rd, wr   = disk_rates.get(dev, (0.0, 0.0))
            tc       = _temp_col(temp, is_nvme=True)
            pc       = P_GREEN if pct_used in ("0", "?") else (P_WARN if int(pct_used or 99) < 80 else P_RED)
            p(r, 1,  "  ●", P_GREEN)
            p(r, 4,  f"{dev:<10}", P_DIM, bold=True)
            p(r, 15, f"WD Black SN850X 4000GB", P_DIM)
            p(r, 38, f"3.6T", P_DIM)
            p(r, 44, f"{temp}°C", tc)
            p(r, 51, f"{pct_used}% worn", pc)
            p(r, 62, f"↑{_fmt_rate(wr):>9}", P_DIM)
            p(r, 73, f"↓{_fmt_rate(rd):>9}", P_DIM)
            side(r); r += 1

    # SATA HDDs
    hdds = [(dev, info) for dev, info in drives.items() if info.get("type") == "hdd"]
    if hdds:
        p(r, 1, f"  SATA HDD  ({len(hdds)} × 9.1T Toshiba N300 — ZFS RAIDZ1 · tank)", P_DIM)
        side(r); r += 1
        for dev, info in hdds:
            temp  = info.get("temp", "?")
            hours = _fmt_hours(info.get("hours", "?"))
            bad_r = info.get("reallocated", "0")
            bad_p = info.get("pending",     "0")
            bad_total = 0
            try: bad_total = int(bad_r or 0) + int(bad_p or 0)
            except Exception: pass
            rd, wr = disk_rates.get(dev, (0.0, 0.0))
            tc  = _temp_col(temp)
            bc2 = _bad_col(bad_r, bad_p)
            p(r, 1,  "  ●", P_GREEN)
            p(r, 4,  f"{dev:<8}", P_DIM, bold=True)
            p(r, 13, f"{temp}°C", tc)
            p(r, 20, f"{hours:>5} on", P_DIM)
            bad_str = f"{bad_total} bad sect" if bad_total > 0 else "0 bad sect"
            p(r, 30, bad_str, bc2)
            p(r, 42, f"↑{_fmt_rate(wr):>9}", P_DIM)
            p(r, 53, f"↓{_fmt_rate(rd):>9}", P_DIM)
            side(r); r += 1

    if not drives:
        p(r, 1, "  collecting drive data…", P_DIM); side(r); r += 1

    # ── Weather stations ────────────────────────────────────────────────────
    stations = bc.get("weather_stations", [])
    weather_latest = bc.get("weather_latest") or {}
    weather_acc = bc.get("weather_accuracy") or {}
    if "weather_stations" in bc:
        fresh_n = sum(1 for s in stations if s.get("fresh"))
        sep(r); r += 1
        p(r, 1, "WEATHER STATIONS", P_TITLE, bold=True)
        if stations:
            p(r, W - 24, f"{fresh_n}/{len(stations)} reporting",
              P_GREEN if fresh_n == len(stations) else (P_WARN if fresh_n else P_RED), bold=True)
        side(r); r += 1

        for stn in stations:
            reporting = stn.get("fresh", False)
            p(r, 1,  f"  {'●' if reporting else '○'} {stn.get('name', '?')}",
              P_GREEN if reporting else P_RED, bold=True)
            p(r, 22, f"{stn.get('device', '?')}", P_DIM)
            p(r, 34, f"{stn.get('location', '?')}", P_DIM)
            if stn.get("lat") and stn.get("lon"):
                p(r, 52, f"({stn['lat']:.2f}, {stn['lon']:.2f})", P_DIM)
            if stn.get("elevation_m"):
                p(r, 72, f"{stn['elevation_m']}m elev", P_DIM)
            side(r); r += 1

        fetched_by_station = bc.get("weather_fetched_at") or {}
        if not stations:
            p(r, 1, "  No station files discovered", P_WARN)
            side(r); r += 1

        for stn in stations:
            station_key = stn.get("key")
            latest = weather_latest.get(station_key) or {}
            if not stn.get("fresh"):
                p(r, 1, "    No fresh readings", P_WARN, bold=True)
                p(r, 26, "station not reporting to Ambient Weather", P_WARN)
                fetched = fetched_by_station.get(station_key)
                if fetched:
                    p(r, W - 30, f"last fetch {_fmt_age(fetched)} ago", P_DIM)
                side(r); r += 1

            if latest:
                temp_c = latest.get("temperature_c")
                temp_f = temp_c * 9 / 5 + 32 if temp_c is not None else None
                hum = latest.get("humidity_pct")
                pres = latest.get("pressure_hpa")
                wind = latest.get("wind_speed_ms")
                w_dir = latest.get("wind_dir_deg")
                gust = latest.get("wind_gust_ms")
                solar = latest.get("solar_wm2")
                dew = latest.get("dew_point_c")
                uv = latest.get("uv_index")
                temp_str = f"{temp_c:.1f}°C / {temp_f:.1f}°F" if temp_c is not None else "—"
                p(r, 1, f"  Temp  {temp_str}", P_DIM, bold=True)
                p(r, 30, f"Humidity  {hum:.0f}%" if hum is not None else "Humidity  —", P_DIM)
                p(r, 47, f"Dew  {dew:.1f}°C" if dew is not None else "Dew  —", P_DIM)
                p(r, 60, f"Pressure  {pres:.1f} hPa" if pres is not None else "Pressure  —", P_DIM)
                p(r, 1, f"  Wind  {wind:.1f} m/s" if wind is not None else "  Wind  —", P_DIM)
                p(r, 35, f"gust {gust:.1f} m/s" if gust is not None else "", P_DIM)
                p(r, 52, f"Solar  {solar:.1f} W/m²" if solar is not None else "Solar  —", P_DIM)
                p(r, 72, f"UV {uv}" if uv is not None else "", P_DIM)
                side(r); r += 1
                ts = latest.get("recorded_at")
                if ts:
                    try:
                        age_str = _fmt_duration(max(0, int(time.time() - ts / 1000)))
                    except Exception:
                        age_str = "?"
                    p(r, 1, f"  Last reading  {age_str} ago", P_DIM)
                fetched = fetched_by_station.get(station_key)
                if fetched:
                    p(r, 30, f"Fetched  {fetched[:19]}Z", P_DIM)
                side(r); r += 1

            acc = weather_acc.get(station_key) or {}
            scores = []
            for key, label in [("temp", "Temp"), ("pressure", "Pres"), ("humidity", "Hum"), ("wind", "Wind")]:
                score = acc.get(f"{key}_score")
                if score is not None:
                    sc = P_GREEN if score >= 0.9 else (P_WARN if score >= 0.75 else P_RED)
                    scores.append((f"{label} {score:.3f}", sc))
            if scores:
                p(r, 1, f"  NWS accuracy (vs {acc.get('nws_station', '?')}):", P_DIM)
                col = 38
                for text, sc in scores:
                    p(r, col, text, sc)
                    col += len(text) + 3
                side(r); r += 1

    # ── Docker services ───────────────────────────────────────────────────────
    sep(r); r += 1

    ct_up    = ct.get("running", False)
    ct_name = ct.get("hostname", "docker-host")
    ct_ip = ct.get("ip", "?")
    ct_label = f"CT {ct.get('id', CT_ID)} RUNNING" if ct_up else f"CT {ct.get('configured_id', CT_ID)} STOPPED"
    p(r, 1, f"DOCKER SERVICES  ({ct_name} · {ct_ip})", P_TITLE, bold=True)
    p(r, W - len(ct_label) - 2, ct_label, P_GREEN if ct_up else P_RED, bold=True)
    side(r); r += 1

    summary = (
        f"up {svc_counts['up']}  ·  starting {svc_counts['starting']}  ·  "
        f"problems {svc_counts['problem']}  ·  missing {svc_counts['missing']}  ·  "
        f"optional off {svc_counts['optional_off']}  ·  init done {svc_counts['init_done']}"
    )
    p(r, 1, summary, P_DIM)
    side(r); r += 1

    col_w = (W - 3) // 2
    left_col = 1
    right_col = 1 + col_w
    for i in range(0, len(SERVICE_DEFS), 2):
        left = SERVICE_DEFS[i]
        render_service(r, left_col, left, col_w)
        if i + 1 < len(SERVICE_DEFS):
            right = SERVICE_DEFS[i + 1]
            render_service(r, right_col, right, col_w)
        side(r); r += 1

    # ── CI runners (CT 102) + the queue they are working through ─────────────
    sep(r); r += 1
    host = runners.get("host") or {}
    header = f"CI RUNNERS  (CT {RUNNER_CT_ID}"
    if host.get("nproc"):
        header += (f" · {host['nproc']} cores · load {host.get('load1', '?')}"
                   f" · RAM free {_fmt_bytes(host.get('mem_avail', 0), 0)}")
    header += ")"
    p(r, 1, header, P_TITLE, bold=True)
    q_err = ci_queue.get("error")
    if q_err:
        right = f"queue: {q_err}" if q_err != "no token" else "queue: no WRFCOIN_GH_TOKEN"
        p(r, max(1, W - len(right) - 2), right, P_WARN)
    else:
        n_runs = len(ci_queue.get("queued") or [])
        n_jobs = len(ci_queue.get("queued_jobs") or [])
        more = "+" if n_runs > (ci_queue.get("probed") or 0) else ""
        right = f"{n_jobs}{more} self-hosted jobs queued · {n_runs} runs queued · {len(ci_queue.get('running') or [])} running"
        p(r, max(1, W - len(right) - 2), right, P_GREEN if n_runs == 0 else P_WARN, bold=True)
    side(r); r += 1

    runner_rows = runners.get("runners") or []
    if not runner_rows:
        p(r, 1, f"  {runners.get('error') or 'no runner data'}", P_WARN)
        side(r); r += 1
    nproc = max(1, int(host.get("nproc") or 1))
    for rr in runner_rows:
        down = rr.get("service") != "active"
        if down:
            dot, color, state_text = "✗", P_RED, "DOWN"
        elif rr.get("busy"):
            dot, color, state_text = "●", P_GREEN, "busy"
        else:
            dot, color, state_text = "○", P_DIM, "idle"
        cores = rr.get("cpu_pct", 0.0) / 100.0
        share = min(100.0, 100.0 * cores / nproc)
        p(r, 1, dot, color, bold=True)
        p(r, 3, f"{rr.get('name', '?')[:19]:<19}", P_DIM, bold=True)
        p(r, 23, f"{state_text:<5}", color, bold=True)
        if rr.get("busy"):
            p(r, 29, f"{_bar(share, 10)} {cores:4.1f} cores", P_GREEN if share < 60 else P_WARN)
            p(r, 52, f"{_fmt_duration(rr.get('elapsed', 0)):>7}", P_DIM)
            p(r, 61, rr.get("job", "")[:max(0, W - 63)], P_DIM)
        elif down:
            p(r, 29, f"service {rr.get('service', '?')}", P_RED)
        else:
            p(r, 29, f"{rr.get('repo', '')}", P_DIM)
        side(r); r += 1

    queued_jobs = ci_queue.get("queued_jobs") or []
    if q_err == "no token":
        p(r, 1, f"  next up: put WRFCOIN_GH_TOKEN=<actions:read token> in {RUNNER_TOKEN_ENV_FILE}", P_DIM)
        side(r); r += 1
    elif not queued_jobs:
        note = "queue empty" if not (ci_queue.get("queued") or []) else "no self-hosted jobs in the oldest queued runs"
        p(r, 1, f"  next up: {note}", P_GREEN if not q_err else P_DIM)
        side(r); r += 1
    else:
        for i, job in enumerate(queued_jobs[:RUNNER_QUEUE_SHOW], 1):
            waited = _fmt_age(job.get("created_at")) if job.get("created_at") else "?"
            label = f"  {i}. {job.get('repo', '?')} · {job.get('workflow', '?')} › {job.get('job', '?')}"
            branch = job.get("branch") or ""
            if branch:
                label += f" · {branch}"
            p(r, 1, label[:max(0, W - 20)], P_DIM)
            p(r, max(1, W - 18), f"waiting {waited:>7}", P_WARN)
            side(r); r += 1
        if len(queued_jobs) > RUNNER_QUEUE_SHOW:
            p(r, 1, f"  … and {len(queued_jobs) - RUNNER_QUEUE_SHOW} more self-hosted jobs in the oldest {ci_queue.get('probed', 0)} runs", P_DIM)
            side(r); r += 1

    # ── WRFCoin CLI / blockchain detail ───────────────────────────────────────
    sep(r); r += 1
    p(r, 1, "WRFCOIN", P_TITLE, bold=True)
    source = bc.get("source", "")
    if source:
        p(r, 10, f"({source})", P_DIM)
    side(r); r += 1

    if bc.get("online"):
        ready_color = P_GREEN if bc.get("status") == "ready" else P_WARN
        p(r, 1,  f"  API: {bc.get('status', 'online'):<12}", ready_color)
        p(r, 24, f"Sync: {str(bc.get('sync_status', '?')):<12}", ready_color)
        p(r, 47, f"Uptime: {_fmt_duration(bc.get('uptime_seconds'))}", P_DIM)
        side(r); r += 1
        p(r, 1,  f"  Blocks mem: {bc.get('blocks_in_memory', '?'):<8}", P_GREEN)
        p(r, 24, f"Accounts: {bc.get('accounts', '?'):<10}", P_GREEN)
        p(r, 47, f"NFTs: {bc.get('nfts', '?')}", P_GREEN)
        side(r); r += 1
        p(r, 1,  f"  P2P blocks  rx {bc.get('blocks_received', 0):<8}  tx {bc.get('blocks_published', 0):<8}", P_DIM)
        p(r, 47, f"TX msgs  rx {bc.get('txs_received', 0):<6}  tx {bc.get('txs_published', 0):<6}", P_DIM)
        side(r); r += 1
        p(r, 1,  f"  Weather msgs rx {bc.get('weather_msgs_received', 0):<6}  tx {bc.get('weather_msgs_published', 0):<6}", P_DIM)
        p(r, 47, f"Net I/O  ↑{_fmt_bytes(bc.get('bytes_outbound', 0)):>8}  ↓{_fmt_bytes(bc.get('bytes_inbound', 0)):>8}", P_DIM)
        side(r); r += 1
        tip = str(bc.get("tip", "—"))
        if len(tip) > 18:
            tip = f"{tip[:8]}…{tip[-8:]}"
        p(r, 1,  f"  Tip: {tip:<22}", P_DIM)
        p(r, 36, f"Network: {bc.get('network_id', '?')}  chain {bc.get('chain_id', '?')}", P_DIM)
        p(r, 70, f"v{bc.get('node_version', '?')}", P_DIM)
        side(r); r += 1
        active_ct_label = f"CT {ct.get('id', CT_ID)}"
        p(r, 1, f"  Deep-dive: run  wrfcoin tui  or  wrfcoin live  in {active_ct_label}", P_DIM)
        side(r); r += 1
    else:
        p(r, 1, "  native-chain offline  —  deploy infra#77 to launch the full testnet stack",
          P_WARN)
        side(r); r += 1
        p(r, 1, "  once online, this panel shows sync, block age, oracle quorum, and P2P traffic.",
          P_DIM)
        side(r); r += 1
        p(r, 1, "  interactive view: wrfcoin tui   multi-pane: wrfcoin live --layout=quad",
          P_DIM)
        side(r); r += 1

    # ── Footer ────────────────────────────────────────────────────────────────
    sep(r); r += 1
    footer = (
        f"[q] quit   [r] force refresh"
        f"   ·   last update {updated or '—'}"
        f"   ·   auto-refresh every {REFRESH}s"
    )
    p(r, max(1, (W - len(footer)) // 2), footer, P_DIM)
    side(r); r += 1

    if r < H - 1:
        p(r, 0, "└" + "─" * (W - 2) + "┘", P_TITLE)

    scr.noutrefresh()
    curses.doupdate()


# ── Main event loop ───────────────────────────────────────────────────────────
def _main(scr):
    curses.curs_set(0)
    scr.nodelay(True)
    scr.timeout(300)
    _init_colors()

    state = NodeState()

    # Splash screen while first collection runs
    H, W = scr.getmaxyx()
    splash = "Collecting metrics…  (this takes ~10s)"
    try:
        scr.addstr(H // 2, max(0, (W - len(splash)) // 2), splash,
                   curses.color_pair(P_WARN))
        scr.refresh()
    except curses.error:
        pass

    state.collect()          # blocking first run
    _draw(scr, state)

    last_refresh = time.time()
    collector = [None]       # the single in-flight collector thread, if any

    def _spawn_collect():
        # Collection runs in a background thread, but that thread MUST NOT touch
        # curses — all drawing happens on the main thread below. Never overlap
        # collections: a slow collect (many pct-exec round-trips) otherwise piles
        # up threads whose draws would interleave and corrupt the display.
        if collector[0] is not None and collector[0].is_alive():
            return
        t = threading.Thread(target=state.collect, daemon=True)
        collector[0] = t
        t.start()

    while True:
        key = scr.getch()
        if key in (ord("q"), ord("Q"), 27):          # q / Q / ESC
            break
        elif key in (ord("r"), ord("R")):
            _spawn_collect()
            last_refresh = time.time()
        # KEY_RESIZE and every other key fall through to the redraw below.

        if time.time() - last_refresh >= REFRESH:
            last_refresh = time.time()
            _spawn_collect()

        # All curses drawing happens here, on the main thread ONLY. Redrawing
        # every loop iteration (~3x/sec via the 300ms getch timeout) keeps the
        # panel in sync with the latest snapshot and handles resize, without ever
        # letting a background thread write to the screen concurrently (curses is
        # not thread-safe — concurrent draws corrupt the display and can crash).
        _draw(scr, state)


if __name__ == "__main__":
    try:
        curses.wrapper(_main)
    except KeyboardInterrupt:
        pass
