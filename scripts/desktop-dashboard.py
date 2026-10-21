#!/usr/bin/env python3
"""
WRFCoin Desktop Node Dashboard (v3)
===================================

Layout:
  HERO BANNER       — 4 huge headline metrics (HEIGHT · PEERS · SYNC · BLOCK AGE)
  4-COLUMN ROW      — SYSTEM | DRIVES | WEATHER STATIONS | DOCKER SERVICES
  CHAIN PANEL       — Peer ID, tip details, node version
  WRFCOIN (http)    — API state + tx counters + tip hash + version
  ACTIVITY FEED     — last N events from docker logs

Designed for wide terminal (160+ cols ideal). Adapts to narrower widths by
stacking columns. Multi-station weather rotates every ~8 refresh ticks.

Run:
  python3 <repo-root>/scripts/desktop-dashboard.py

Controls:
  q / Q / ESC — quit
  r / R       — force refresh
"""

import curses
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone

# ── Configuration ─────────────────────────────────────────────────────────────
REFRESH_SEC = 3
NODE_API = "http://localhost:8556"
ACTIVITY_KEEP = 6
WEATHER_ROTATE_TICKS = 8

# Set DASHBOARD_STATION_* for an operator-owned station; defaults are synthetic.
KNOWN_STATIONS = [
    {
        "id": os.environ.get("DASHBOARD_STATION_ID", "PWS-EXAMPLE-WS5000"),
        "label": os.environ.get("DASHBOARD_STATION_NAME", "Example Station"),
        "device": "WS-5000",
        "location": os.environ.get("DASHBOARD_STATION_LOCATION", "Example location"),
        "lat": float(os.environ.get("DASHBOARD_STATION_LAT", "10.0")),
        "lon": float(os.environ.get("DASHBOARD_STATION_LON", "20.0")),
        "elevation_m": 220,
    },
]

# Service name candidates (auto-resolve compose project naming variants).
SERVICE_CANDIDATES = [
    ("Node",     8556, ["wrfcoin-testnet-node",     "testnet-wrfcoin-node",     "wrfcoin-node"]),
    ("Postgres", 5432, ["wrfcoin-testnet-postgres", "testnet-postgres",         "wrfcoin-postgres",         "postgres"]),
    ("Redis",    6379, ["wrfcoin-testnet-redis",    "testnet-redis",            "wrfcoin-redis",            "redis"]),
]

# ── Color pairs ───────────────────────────────────────────────────────────────
PAIR_OK = 1
PAIR_WARN = 2
PAIR_BAD = 3
PAIR_DIM = 4
PAIR_HERO = 5
PAIR_HERO_OK = 6
PAIR_HERO_BAD = 7
PAIR_LABEL = 8
PAIR_HIGHLIGHT = 9


def init_colors():
    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(PAIR_OK, curses.COLOR_GREEN, -1)
    curses.init_pair(PAIR_WARN, curses.COLOR_YELLOW, -1)
    curses.init_pair(PAIR_BAD, curses.COLOR_RED, -1)
    curses.init_pair(PAIR_DIM, 8 if curses.COLORS >= 16 else curses.COLOR_BLUE, -1)
    curses.init_pair(PAIR_HERO, curses.COLOR_CYAN, -1)
    curses.init_pair(PAIR_HERO_OK, curses.COLOR_GREEN, -1)
    curses.init_pair(PAIR_HERO_BAD, curses.COLOR_RED, -1)
    curses.init_pair(PAIR_LABEL, curses.COLOR_CYAN, -1)
    curses.init_pair(PAIR_HIGHLIGHT, curses.COLOR_MAGENTA, -1)


# ── Shell helpers ─────────────────────────────────────────────────────────────
def run(cmd, timeout=4):
    try:
        out = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return out.stdout.strip()
    except Exception:
        return ""


def fetch_json(url, timeout=2):
    raw = run(f"curl -s --max-time {timeout} '{url}'")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        return None


def _resolve_container(candidates):
    for name in candidates:
        check = run(f"docker inspect --format '{{{{.Name}}}}' {name} 2>/dev/null")
        if check:
            return name
    return candidates[0]


# ── Data collectors ───────────────────────────────────────────────────────────
def collect_chain_info():
    net = fetch_json(f"{NODE_API}/network/info") or {}
    blocks_resp = fetch_json(f"{NODE_API}/chain/blocks?limit=1") or {}

    last_block = None
    if blocks_resp.get("ok") and blocks_resp.get("data", {}).get("blocks"):
        last_block = blocks_resp["data"]["blocks"][0]

    age_sec = None
    if last_block and "timestamp" in last_block:
        try:
            ts = datetime.fromisoformat(last_block["timestamp"].replace("Z", "+00:00"))
            age_sec = int((datetime.now(timezone.utc) - ts).total_seconds())
        except Exception:
            pass

    return {
        "height": net.get("chain_height", 0),
        "peer_count": net.get("peer_count", 0),
        "sync_status": net.get("sync_status", "unknown"),
        "peer_id": net.get("local_peer_id", ""),
        "node_version": net.get("node_version", ""),
        "chain_id": net.get("chain_id", ""),
        "network_id": net.get("network_id", ""),
        "last_block_hash": (last_block or {}).get("hash", ""),
        "last_block_time": (last_block or {}).get("timestamp", ""),
        "last_block_age_sec": age_sec,
        "last_block_tx_count": (last_block or {}).get("tx_count"),
    }


def collect_service_health():
    out = []
    for label, port, candidates in SERVICE_CANDIDATES:
        ctr = _resolve_container(candidates)
        info = run(
            f"docker inspect --format '{{{{.State.Status}}}}|"
            f"{{{{if .State.Health}}}}{{{{.State.Health.Status}}}}{{{{else}}}}none{{{{end}}}}|"
            f"{{{{.State.StartedAt}}}}|"
            f"{{{{.RestartCount}}}}|"
            f"{{{{.Config.Image}}}}' {ctr}"
        )
        parts = info.split("|") if info else []
        status = parts[0] if len(parts) > 0 else "missing"
        health = parts[1] if len(parts) > 1 else "none"
        started = parts[2] if len(parts) > 2 else ""
        restarts = parts[3] if len(parts) > 3 else "0"
        image = parts[4] if len(parts) > 4 else ""

        uptime = "—"
        if started:
            try:
                ts = datetime.fromisoformat(started.replace("Z", "+00:00"))
                delta = datetime.now(timezone.utc) - ts
                hrs = int(delta.total_seconds() // 3600)
                mins = int((delta.total_seconds() % 3600) // 60)
                if hrs > 24:
                    uptime = f"{hrs // 24}d{hrs % 24:02d}h"
                elif hrs > 0:
                    uptime = f"{hrs}h{mins:02d}m"
                else:
                    uptime = f"{mins}m"
            except Exception:
                pass

        # Last log line for context (one line, truncated)
        last_log = run(
            f"docker logs --tail 1 {ctr} 2>&1 | sed 's/\\x1b\\[[0-9;]*m//g'"
        )
        last_log = re.sub(r"^\S+T\S+Z\s+", "", last_log)[:60] if last_log else ""

        out.append({
            "label": label,
            "container": ctr,
            "port": port,
            "status": status,
            "health": health,
            "uptime": uptime,
            "restarts": int(restarts) if restarts.isdigit() else 0,
            "image_short": image.split(":")[-1][:14] if image else "",
            "last_log": last_log,
        })
    return out


def collect_system():
    cpu_pct = 0.0
    try:
        a = open("/proc/stat").readline().split()[1:5]
        time.sleep(0.1)
        b = open("/proc/stat").readline().split()[1:5]
        a = list(map(int, a))
        b = list(map(int, b))
        idle_diff = b[3] - a[3]
        total_diff = sum(b) - sum(a)
        if total_diff > 0:
            cpu_pct = round(100 * (1 - idle_diff / total_diff), 1)
    except Exception:
        pass

    ram_used_gb = 0.0
    ram_pct = 0.0
    try:
        info = {
            line.split(":")[0]: int(line.split()[1])
            for line in open("/proc/meminfo").readlines()
            if ":" in line
        }
        total_kb = info.get("MemTotal", 1)
        avail_kb = info.get("MemAvailable", total_kb)
        used_kb = total_kb - avail_kb
        ram_used_gb = round(used_kb / 1024 / 1024, 1)
        ram_pct = round(100 * used_kb / total_kb, 1)
    except Exception:
        pass

    load_1 = load_5 = load_15 = 0.0
    try:
        with open("/proc/loadavg") as f:
            parts = f.read().split()
            load_1, load_5, load_15 = float(parts[0]), float(parts[1]), float(parts[2])
    except Exception:
        pass

    temp_c = "?"
    try:
        for path in (
            "/sys/class/thermal/thermal_zone0/temp",
            "/sys/class/hwmon/hwmon0/temp1_input",
        ):
            try:
                with open(path) as f:
                    raw_temp = int(f.read().strip())
                    temp_c = f"{raw_temp // 1000}°C"
                    break
            except Exception:
                continue
    except Exception:
        pass

    uptime_str = "?"
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
            d, rem = divmod(secs, 86400)
            h, rem = divmod(rem, 3600)
            m, _ = divmod(rem, 60)
            uptime_str = f"{d}d {h}h {m}m"
    except Exception:
        pass

    net_rx_bps = net_tx_bps = 0
    try:
        def _read_net():
            rx = tx = 0
            for line in open("/proc/net/dev").readlines():
                if ":" in line and not line.strip().startswith("lo:"):
                    parts = line.split()
                    rx += int(parts[1])
                    tx += int(parts[9])
            return rx, tx

        a_rx, a_tx = _read_net()
        time.sleep(1.0)
        b_rx, b_tx = _read_net()
        net_rx_bps = b_rx - a_rx
        net_tx_bps = b_tx - a_tx
    except Exception:
        pass

    def _fmt_bps(b):
        if b < 1024:
            return f"{b}B/s"
        if b < 1024 * 1024:
            return f"{b // 1024}KB/s"
        return f"{b / 1024 / 1024:.1f}MB/s"

    return {
        "cpu_pct": cpu_pct,
        "ram_used_gb": ram_used_gb,
        "ram_pct": ram_pct,
        "load_1": load_1,
        "load_5": load_5,
        "load_15": load_15,
        "temp_c": temp_c,
        "uptime_str": uptime_str,
        "net_rx": _fmt_bps(net_rx_bps),
        "net_tx": _fmt_bps(net_tx_bps),
    }


def collect_drives():
    """Returns list of drive info dicts. Works for any Linux box, not just N5."""
    drives = []
    raw = run("lsblk -bn -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT 2>/dev/null")
    seen = set()
    for line in raw.split("\n"):
        if not line.strip():
            continue
        parts = line.split(None, 4)
        if len(parts) < 3:
            continue
        name, size_b, dtype = parts[0], parts[1], parts[2]
        if dtype != "disk" or name in seen:
            continue
        seen.add(name)
        model = parts[3] if len(parts) > 3 else ""

        try:
            size_gb = int(size_b) / 1024 ** 3
            if size_gb < 1:  # skip empty placeholders (0G WSL2 virtual disks)
                continue
            if size_gb >= 1000:
                size_str = f"{size_gb / 1024:.1f}T"
            else:
                size_str = f"{size_gb:.0f}G"
        except Exception:
            size_str = "?"

        # Disk usage from df for any mountpoint backed by this device
        used_pct = "?"
        df_raw = run(f"df -h | grep '^/dev/{name}' | head -1")
        if df_raw:
            df_parts = df_raw.split()
            if len(df_parts) >= 5:
                used_pct = df_parts[4]

        # Try to read SMART temp (requires smartctl + permissions; common to fail in WSL/containers)
        temp = "?"
        smart = run(f"smartctl -A /dev/{name} 2>/dev/null")
        if smart:
            for line_s in smart.split("\n"):
                if "Temperature_Celsius" in line_s or line_s.startswith("Temperature:"):
                    bits = line_s.split()
                    for b in bits:
                        if b.isdigit() and 10 <= int(b) <= 99:
                            temp = f"{b}°C"
                            break

        drives.append({
            "name": name,
            "size": size_str,
            "model": (model or "").strip()[:18],
            "used_pct": used_pct,
            "temp": temp,
        })
    return drives


def collect_weather_stations(chain):
    """
    Build per-station info from the latest chain block(s) + KNOWN_STATIONS.
    For now (chain still at low height), shows the known station with chain
    activity counters once data starts flowing.
    """
    # Future: parse contribution txs from chain/blocks?limit=N to extract
    # latest readings per station_id. For now return known station scaffold.
    return KNOWN_STATIONS


def collect_wrfcoin_http():
    """The (http) summary panel — chain + sync + tx counters at a glance."""
    net = fetch_json(f"{NODE_API}/network/info") or {}
    blocks_resp = fetch_json(f"{NODE_API}/chain/blocks?limit=1") or {}
    chain_height = blocks_resp.get("data", {}).get("chain_height", 0)

    return {
        "api_state": "ready" if net else "down",
        "sync": net.get("sync_status", "?"),
        "chain_height": chain_height,
        "peer_count": net.get("peer_count", 0),
        "node_version": net.get("node_version", "?"),
        "network_id": net.get("network_id", "?"),
        "chain_id": net.get("chain_id", "?"),
        "tip_hash": (blocks_resp.get("data", {}).get("blocks", [{}]) or [{}])[0].get("hash", ""),
    }


def collect_activity_feed():
    node_ctr = _resolve_container(SERVICE_CANDIDATES[0][2])
    raw = run(
        f"docker logs --tail 80 {node_ctr} 2>&1 | "
        f"grep -E 'peer|block|orphan|sync|height|Mined|consensus|HSM|FORK' | "
        f"grep -v 'P2P bandwidth' | tail -{ACTIVITY_KEEP}"
    )
    lines = []
    for line in raw.split("\n"):
        if not line.strip():
            continue
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)
        m = re.match(r"(\S+T\S+Z)\s+(\w+)\s+(.+)", line)
        if m:
            ts, level, msg = m.groups()
            try:
                t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                ts_short = t.strftime("%H:%M:%S")
            except Exception:
                ts_short = ts[:8]
            msg = re.sub(r"^[\w:]+: ", "", msg).strip()
            lines.append((ts_short, level, msg))
    return lines


# ── Drawing helpers ───────────────────────────────────────────────────────────
def draw_box(stdscr, y, x, h, w, title=""):
    try:
        for i in range(w):
            stdscr.addch(y, x + i, curses.ACS_HLINE)
            stdscr.addch(y + h - 1, x + i, curses.ACS_HLINE)
        for i in range(h):
            stdscr.addch(y + i, x, curses.ACS_VLINE)
            stdscr.addch(y + i, x + w - 1, curses.ACS_VLINE)
        stdscr.addch(y, x, curses.ACS_ULCORNER)
        stdscr.addch(y, x + w - 1, curses.ACS_URCORNER)
        stdscr.addch(y + h - 1, x, curses.ACS_LLCORNER)
        stdscr.addch(y + h - 1, x + w - 1, curses.ACS_LRCORNER)
        if title:
            stdscr.addstr(y, x + 2, f" {title} ", curses.color_pair(PAIR_LABEL) | curses.A_BOLD)
    except curses.error:
        pass


def draw_text(stdscr, y, x, text, attr=0, max_w=None):
    if max_w is not None:
        text = text[:max_w]
    try:
        stdscr.addstr(y, x, text, attr)
    except curses.error:
        pass


def color_for_health(status, health):
    if status != "running":
        return PAIR_BAD
    if health == "unhealthy":
        return PAIR_BAD
    if health in ("starting", "none"):
        return PAIR_WARN
    return PAIR_OK


def fmt_age(sec):
    if sec is None:
        return "?"
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m{sec % 60:02d}s"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def hex_short(s, n=10):
    if not s:
        return "—"
    return s[:n] + ("…" if len(s) > n else "")


# ── Layout ────────────────────────────────────────────────────────────────────
def render(stdscr, chain, services, system, drives, stations, http_info, activity, tick):
    stdscr.erase()
    h, w = stdscr.getmaxyx()

    # ─── HERO BANNER (top 6 lines) ────────────────────────────────────────────
    role = "DESKTOP PEER · OBSERVER" if chain.get("peer_id") else "OFFLINE"

    title = "WRFCOIN  DESKTOP NODE  v3"
    draw_text(stdscr, 0, max(0, (w - len(title)) // 2), title,
              curses.color_pair(PAIR_HERO) | curses.A_BOLD)
    subtitle = f"{role}  ·  {chain.get('network_id', '?')}  ·  chain_id={chain.get('chain_id', '?')}"
    draw_text(stdscr, 1, max(0, (w - len(subtitle)) // 2), subtitle,
              curses.color_pair(PAIR_DIM))

    metrics = [
        ("HEIGHT", f"{chain.get('height', 0)}",
            PAIR_HERO_OK if chain.get("height", 0) > 0 else PAIR_HERO_BAD),
        ("PEERS", f"{chain.get('peer_count', 0)}",
            PAIR_HERO_OK if chain.get("peer_count", 0) > 0 else PAIR_HERO_BAD),
        ("SYNC", f"{chain.get('sync_status', '?')}",
            PAIR_HERO_OK if chain.get("sync_status") == "synced" else PAIR_HERO_BAD),
        ("BLOCK AGE", f"{fmt_age(chain.get('last_block_age_sec'))}",
            PAIR_HERO_OK if (chain.get("last_block_age_sec") or 999) < 600 else PAIR_HERO_BAD),
    ]
    cell_w = max(20, w // 4)
    for i, (label, value, color) in enumerate(metrics):
        x = i * cell_w + (cell_w - 18) // 2
        if x + 18 > w:
            continue
        draw_text(stdscr, 3, x, f"{label:^18}", curses.color_pair(PAIR_DIM))
        draw_text(stdscr, 4, x, f"{value:^18}", curses.color_pair(color) | curses.A_BOLD)

    try:
        for col in range(w):
            stdscr.addch(5, col, curses.ACS_HLINE, curses.color_pair(PAIR_DIM))
    except curses.error:
        pass

    # ─── 4-COLUMN ROW: SYSTEM | DRIVES | WEATHER STATIONS | DOCKER SERVICES ──
    row_y = 6
    row_h = 9
    col_w = w // 4

    # ── COL 1: SYSTEM (2-column compact: left=resource, right=value pair) ──
    sx = 0
    draw_box(stdscr, row_y, sx, row_h, col_w, "SYSTEM")
    cpu_color = PAIR_OK if system["cpu_pct"] < 60 else PAIR_WARN if system["cpu_pct"] < 85 else PAIR_BAD
    ram_color = PAIR_OK if system["ram_pct"] < 70 else PAIR_WARN if system["ram_pct"] < 90 else PAIR_BAD

    half_x = sx + col_w // 2
    rows = [
        # (left_label, left_value, left_color, right_label, right_value, right_color)
        ("CPU",  f"{system['cpu_pct']:.1f}%",                                cpu_color,
         "RAM",  f"{system['ram_used_gb']:.1f}G",                            ram_color),
        ("Load", f"{system['load_1']:.2f} {system['load_5']:.2f}",           PAIR_OK,
         "Temp", f"{system['temp_c']}",                                       PAIR_OK),
        ("↑",    system['net_tx'],                                            PAIR_OK,
         "↓",    system['net_rx'],                                            PAIR_OK),
        ("Up",   system['uptime_str'],                                        PAIR_OK,
         "",     "",                                                          PAIR_OK),
    ]
    for i, (lk, lv, lc, rk, rv, rc) in enumerate(rows):
        line_y = row_y + 1 + i
        if line_y >= row_y + row_h - 1:
            break
        draw_text(stdscr, line_y, sx + 2, f"{lk:<5}", curses.color_pair(PAIR_DIM))
        draw_text(stdscr, line_y, sx + 7, lv, curses.color_pair(lc), max_w=half_x - sx - 8)
        if rk:
            draw_text(stdscr, line_y, half_x, f"{rk:<5}", curses.color_pair(PAIR_DIM))
            draw_text(stdscr, line_y, half_x + 5, rv, curses.color_pair(rc), max_w=col_w - (half_x - sx) - 6)

    # ── COL 2: DRIVES ──
    sx = col_w
    draw_box(stdscr, row_y, sx, row_h, col_w, "DRIVES")
    for i, drv in enumerate(drives[: row_h - 2]):
        line_y = row_y + 1 + i
        # Compact: name (size, %used) | model | temp
        n_part = f"● {drv['name']:<8}"
        info_part = f"{drv['size']:<6} {drv['used_pct']:<4}  {drv['temp']:<6}"
        model_part = drv['model'][:col_w - 30] if drv['model'] else ""

        draw_text(stdscr, line_y, sx + 2, n_part, curses.color_pair(PAIR_OK))
        draw_text(stdscr, line_y, sx + 12, info_part, curses.color_pair(PAIR_DIM), max_w=col_w - 14)
        if model_part and (sx + 30) < (sx + col_w - 1):
            draw_text(stdscr, line_y, sx + 30, model_part, curses.color_pair(PAIR_DIM), max_w=col_w - 32)
    if not drives:
        draw_text(stdscr, row_y + 2, sx + 2, "(no drives detected)", curses.color_pair(PAIR_WARN))

    # ── COL 3: WEATHER STATIONS (rotate if multiple) ──
    sx = col_w * 2
    draw_box(stdscr, row_y, sx, row_h, col_w, "WEATHER STATIONS")
    if stations:
        idx = (tick // WEATHER_ROTATE_TICKS) % len(stations)
        st = stations[idx]
        draw_text(stdscr, row_y + 1, sx + 2, f"● {st['label']}",
                  curses.color_pair(PAIR_HIGHLIGHT) | curses.A_BOLD,
                  max_w=col_w - 4)
        draw_text(stdscr, row_y + 2, sx + 2, f"{st['device']:<8} {st['location']}",
                  curses.color_pair(PAIR_DIM), max_w=col_w - 4)
        draw_text(stdscr, row_y + 3, sx + 2, f"({st['lat']:.4f}, {st['lon']:.4f})",
                  curses.color_pair(PAIR_DIM), max_w=col_w - 4)
        draw_text(stdscr, row_y + 4, sx + 2, f"Elev {st['elevation_m']}m",
                  curses.color_pair(PAIR_DIM), max_w=col_w - 4)
        draw_text(stdscr, row_y + 5, sx + 2, "—",
                  curses.color_pair(PAIR_DIM), max_w=col_w - 4)
        draw_text(stdscr, row_y + 6, sx + 2,
                  f"({len(stations)} known · rotates {WEATHER_ROTATE_TICKS * REFRESH_SEC}s)",
                  curses.color_pair(PAIR_DIM), max_w=col_w - 4)
    else:
        draw_text(stdscr, row_y + 2, sx + 2, "(no stations registered)", curses.color_pair(PAIR_WARN))

    # ── COL 4: DOCKER SERVICES (concise tabular with restart count + image tag) ──
    sx = col_w * 3
    draw_box(stdscr, row_y, sx, row_h, w - sx, "DOCKER SERVICES")
    draw_text(stdscr, row_y + 1, sx + 2,
              "SVC     PORT  STATUS  HEALTH   UP      RST  IMG",
              curses.color_pair(PAIR_DIM) | curses.A_BOLD, max_w=w - sx - 3)
    for i, svc in enumerate(services):
        if row_y + 2 + i >= row_y + row_h - 1:
            break
        line_y = row_y + 2 + i
        c = curses.color_pair(color_for_health(svc["status"], svc["health"])) | curses.A_BOLD
        rst_color = PAIR_OK if svc["restarts"] == 0 else PAIR_WARN if svc["restarts"] < 3 else PAIR_BAD
        line = f"● {svc['label'][:6]:<6} :{svc['port']:<4} {svc['status'][:7]:<7} {svc['health'][:8]:<8} {svc['uptime']:<6}"
        draw_text(stdscr, line_y, sx + 2, line, c, max_w=w - sx - 3)
        # Restart count + image tag, separately colored
        rst_x = sx + 2 + len(line) + 1
        if rst_x < sx + w - sx - 3:
            draw_text(stdscr, line_y, rst_x, f"{svc['restarts']:>2}",
                      curses.color_pair(rst_color), max_w=4)
            draw_text(stdscr, line_y, rst_x + 4, svc["image_short"],
                      curses.color_pair(PAIR_DIM), max_w=w - rst_x - 6)

    # ─── CHAIN PANEL (single row, peer ID + tip details) ─────────────────────
    chain_y = row_y + row_h
    chain_h = 4
    draw_box(stdscr, chain_y, 0, chain_h, w, "CHAIN")
    half = w // 2
    draw_text(stdscr, chain_y + 1, 2, f"Peer ID    {chain.get('peer_id', '?')[:48]}",
              curses.color_pair(PAIR_DIM), max_w=half - 4)
    draw_text(stdscr, chain_y + 2, 2, f"Tip hash   {hex_short(chain.get('last_block_hash', ''), 24)}",
              curses.color_pair(PAIR_DIM), max_w=half - 4)
    draw_text(stdscr, chain_y + 1, half, f"Tip time   {chain.get('last_block_time', '?')[:25]}",
              curses.color_pair(PAIR_DIM), max_w=w - half - 2)
    draw_text(stdscr, chain_y + 2, half, f"Tip txs    {chain.get('last_block_tx_count', '?')}      Node ver {chain.get('node_version', '?')}",
              curses.color_pair(PAIR_DIM), max_w=w - half - 2)

    # ─── WRFCOIN (http) ──────────────────────────────────────────────────────
    http_y = chain_y + chain_h
    http_h = 4
    draw_box(stdscr, http_y, 0, http_h, w, "WRFCOIN  (http)")
    api_color = PAIR_OK if http_info["api_state"] == "ready" else PAIR_BAD
    sync_color = PAIR_OK if http_info["sync"] == "synced" else PAIR_WARN

    quarter = w // 4
    # Row 1: API state · Sync · Height · Peers
    draw_text(stdscr, http_y + 1, 2, "API   ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 1, 9, f"{http_info['api_state']:<8}", curses.color_pair(api_color) | curses.A_BOLD)
    draw_text(stdscr, http_y + 1, quarter, "Sync  ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 1, quarter + 7, f"{http_info['sync']:<10}", curses.color_pair(sync_color))
    draw_text(stdscr, http_y + 1, quarter * 2, "Height ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 1, quarter * 2 + 8, f"{http_info['chain_height']:<6}", curses.color_pair(PAIR_OK))
    draw_text(stdscr, http_y + 1, quarter * 3, "Peers  ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 1, quarter * 3 + 8, f"{http_info['peer_count']}", curses.color_pair(PAIR_OK))

    # Row 2: Network · Chain ID · Version · Tip hash
    draw_text(stdscr, http_y + 2, 2, "Net   ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 2, 9, http_info["network_id"], curses.color_pair(PAIR_OK))
    draw_text(stdscr, http_y + 2, quarter, "Chain ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 2, quarter + 7, http_info["chain_id"], curses.color_pair(PAIR_OK))
    draw_text(stdscr, http_y + 2, quarter * 2, "Ver    ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 2, quarter * 2 + 8, http_info["node_version"], curses.color_pair(PAIR_OK))
    draw_text(stdscr, http_y + 2, quarter * 3, "Tip    ", curses.color_pair(PAIR_DIM))
    draw_text(stdscr, http_y + 2, quarter * 3 + 8, hex_short(http_info["tip_hash"], 12), curses.color_pair(PAIR_OK), max_w=w - quarter * 3 - 10)

    # ─── ACTIVITY FEED ────────────────────────────────────────────────────────
    feed_y = http_y + http_h
    feed_h = max(4, h - feed_y - 2)
    draw_box(stdscr, feed_y, 0, feed_h, w, "ACTIVITY")
    for i, (ts, level, msg) in enumerate(activity[-(feed_h - 2) :]):
        if i >= feed_h - 2:
            break
        color = PAIR_OK if level == "INFO" else PAIR_WARN if level == "WARN" else PAIR_BAD
        line = f"{ts}  {level[:4]:<4}  {msg}"
        draw_text(stdscr, feed_y + 1 + i, 2, line, curses.color_pair(color), max_w=w - 4)

    # ─── FOOTER ───────────────────────────────────────────────────────────────
    footer = f"[q] quit  ·  [r] refresh  ·  auto every {REFRESH_SEC}s  ·  {datetime.now().strftime('%H:%M:%S')}"
    draw_text(stdscr, h - 1, max(0, (w - len(footer)) // 2), footer, curses.color_pair(PAIR_DIM))
    stdscr.refresh()


# ── Main loop ─────────────────────────────────────────────────────────────────
def main(stdscr):
    curses.curs_set(0)
    init_colors()
    stdscr.nodelay(True)
    stdscr.timeout(100)

    last_refresh = 0
    chain = {}
    services = []
    system = {}
    drives = []
    stations = KNOWN_STATIONS
    http_info = {}
    activity = []
    tick = 0

    while True:
        now = time.time()
        if now - last_refresh >= REFRESH_SEC:
            chain = collect_chain_info()
            services = collect_service_health()
            system = collect_system()
            drives = collect_drives()
            stations = collect_weather_stations(chain)
            http_info = collect_wrfcoin_http()
            activity = collect_activity_feed()
            last_refresh = now
            tick += 1

        render(stdscr, chain, services, system, drives, stations, http_info, activity, tick)

        ch = stdscr.getch()
        if ch in (ord("q"), ord("Q"), 27):
            break
        if ch in (ord("r"), ord("R")):
            last_refresh = 0


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        pass
