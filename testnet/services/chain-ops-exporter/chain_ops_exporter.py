#!/usr/bin/env python3
"""Prometheus gauges for two chain-ops facts that broke silently in Oct 2026.

1. Node-pay receipts. Every 512-block epoch, each house bond needs a bonded
   service receipt included before the epoch closes, or that epoch pays it
   nothing. Epochs 4-18 on chain 888 went unpaid and nobody noticed. The ws
   cron (receipts.sh cycle) submits them and alerts on its own failures; this
   exporter is the independent check, read from CT101's own node:
     - current epoch: has a NodeServiceBatch tx from each house bond's owner
       account been included in a block of this epoch? (block scan)
     - last closed epoch: which house bonds are in the settlement's eligible
       set (`provisional` while PROVISIONAL, `payouts` once PAID)? This is the
       consensus answer, so it also catches a batch that landed but did not
       count.
2. Chain-rewards index freshness. The backend's earnings/forecast index sat in
   `db_error` for days. Its public reads (/api/earnings/leaderboard and
   /api/forecasters) answer 200 + asOf.height only while the index is `ok` and
   was checked in the last 10 minutes, so probing them measures exactly what
   users see, with no backend change.

Read-only: GETs only, with the node reader token (the same file Prometheus uses
as its bearer token). The token is never logged. Standard library only, so the
stock python image runs it with the script bind-mounted (no image build on a
host that runs a live node).

Environment:
  NODE_URL                 default http://wrfcoin-node:8556
  BACKEND_URL              default http://wrfcoin-backend:4001
  NODE_READER_TOKEN_FILE   default /run/secrets/node_reader_token
  NODE_PAY_HOUSE_BONDS     alias=<64-hex deployment id>,... (required for node-pay gauges)
  NODE_PAY_EPOCH_BLOCKS    default 512
  POLL_INTERVAL_SECS       default 60
  MAX_BLOCK_READS_PER_POLL default 40 (node limiter is 100/min per IP)
  EXPORTER_PORT            default 9202
"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NODE_URL = os.environ.get("NODE_URL", "http://wrfcoin-node:8556").rstrip("/")
BACKEND_URL = os.environ.get("BACKEND_URL", "http://wrfcoin-backend:4001").rstrip("/")
TOKEN_FILE = os.environ.get("NODE_READER_TOKEN_FILE", "/run/secrets/node_reader_token")
EPOCH_BLOCKS = int(os.environ.get("NODE_PAY_EPOCH_BLOCKS", "512"))
POLL_SECS = int(os.environ.get("POLL_INTERVAL_SECS", "60"))
MAX_BLOCK_READS = int(os.environ.get("MAX_BLOCK_READS_PER_POLL", "40"))
PORT = int(os.environ.get("EXPORTER_PORT", "9202"))

INDEX_SURFACES = (
    ("earnings", "/api/earnings/leaderboard?role=producer&period=all&limit=1"),
    ("forecasters", "/api/forecasters?period=all&limit=1"),
)
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


class CollectError(Exception):
    pass


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}", file=sys.stderr, flush=True)


def parse_house_bonds(spec: str) -> list[tuple[str, str]]:
    bonds = []
    for part in (spec or "").split(","):
        part = part.strip()
        if not part:
            continue
        alias, sep, bond_id = part.partition("=")
        bond_id = bond_id.strip().lower()
        if not sep or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", alias.strip()) or not _HEX64.match(bond_id):
            raise ValueError(f"invalid NODE_PAY_HOUSE_BONDS entry: {part[:40]!r}")
        bonds.append((alias.strip(), bond_id))
    return bonds


def http_get(url: str, token: str | None = None, timeout: float = 10.0) -> tuple[int, object]:
    """GET url -> (status, parsed JSON or None). Status 0 = transport failure."""
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    except Exception:  # noqa: BLE001 - any transport failure is "no answer"
        return 0, None
    try:
        return status, json.loads(raw)
    except ValueError:
        return status, None


def read_token() -> str:
    try:
        with open(TOKEN_FILE, encoding="utf-8") as fh:
            token = fh.read().strip()
    except OSError:
        raise CollectError("reader token file unreadable")
    if not token:
        raise CollectError("reader token file empty")
    return token


def account_hex(value: object) -> str:
    """Normalise a 20-byte account (byte list or hex string) to 0x-lowercase hex."""
    if isinstance(value, list) and all(isinstance(b, int) and 0 <= b < 256 for b in value):
        return "0x" + bytes(value).hex()
    if isinstance(value, str):
        v = value.lower()
        return v if v.startswith("0x") else "0x" + v
    return ""


def _esc(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metric(name: str, value: float, labels: dict[str, str] | None = None) -> str:
    if labels:
        inner = ",".join(f'{k}="{_esc(str(v))}"' for k, v in labels.items())
        return f"{name}{{{inner}}} {value}"
    return f"{name} {value}"


class Exporter:
    def __init__(self, bonds: list[tuple[str, str]], get=None, clock=time.time):
        self.bonds = bonds
        self.get = get or http_get
        self.clock = clock
        self.scan_epoch: int | None = None
        self.scanned_to: int | None = None
        self.batch_senders: set[str] = set()
        started = clock()
        # Start the staleness clock at process start, so an exporter that never
        # succeeds still trips ChainOpsExporterStale instead of staying silent.
        self.last_success = {"node_pay": started, "index": started}
        self.errors = {"node_pay": 0, "index": 0}
        self.sections: dict[str, list[str]] = {"node_pay": [], "index": []}
        self.lock = threading.Lock()

    # -- node pay --------------------------------------------------------------------------------
    def collect_node_pay(self, token: str) -> list[str]:
        if not self.bonds:
            raise CollectError("NODE_PAY_HOUSE_BONDS is empty")
        status, body = self.get(f"{NODE_URL}/blockchain", token)
        try:
            tip = int(body["data"]["height"])  # type: ignore[index]
        except (TypeError, KeyError, ValueError):
            raise CollectError(f"node /blockchain answered {status}")
        views = {}
        for alias, bond_id in self.bonds:
            status, view = self.get(f"{NODE_URL}/node/bonds/{bond_id}", token)
            if status != 200 or not isinstance(view, dict):
                raise CollectError(f"node /node/bonds/<{alias}> answered {status}")
            views[alias] = view
        first = views[self.bonds[0][0]]
        try:
            epoch = int(first["epoch"])
            activation = int(first["activation_height"])
        except (TypeError, KeyError, ValueError):
            raise CollectError("bond view has no epoch (node-pay not active?)")
        start = activation + EPOCH_BLOCKS * epoch
        close = start + EPOCH_BLOCKS - 1  # last height of the epoch (receipts.sh: 513 + 512*E on 888)

        if self.scan_epoch != epoch or self.scanned_to is None:
            self.scan_epoch, self.scanned_to, self.batch_senders = epoch, start - 1, set()
        reads = 0
        while self.scanned_to < min(tip, close) and reads < MAX_BLOCK_READS:
            height = self.scanned_to + 1
            status, block = self.get(f"{NODE_URL}/chain/block/{height}", token)
            reads += 1
            if status != 200 or not isinstance(block, dict):
                raise CollectError(f"node /chain/block/{height} answered {status}")
            data = block.get("data", block) if isinstance(block.get("data"), dict) else block
            for tx in data.get("transactions") or []:
                if isinstance(tx, dict) and tx.get("type") == "NodeServiceBatch":
                    self.batch_senders.add(str(tx.get("sender", "")).lower())
            self.scanned_to = height

        last_closed = epoch - 1
        eligible: set[str] | None = None
        settle_status = "NONE"
        if last_closed >= 0:
            status, settle = self.get(f"{NODE_URL}/node/settlement/{last_closed}", token)
            if status != 200 or not isinstance(settle, dict):
                raise CollectError(f"node /node/settlement/{last_closed} answered {status}")
            settle_status = str(settle.get("status", "UNKNOWN"))
            if settle_status == "PROVISIONAL":
                eligible = set((settle.get("provisional_base_units") or {}).keys())
            elif settle_status == "PAID":
                eligible = set((settle.get("payouts_base_units") or {}).keys())
            elif settle_status == "UNISSUED":
                eligible = set()
            # OPEN/UNKNOWN: no consensus answer to report (UNKNOWN = pruned after payout).

        out = [
            metric("wrfcoin_node_pay_tip_height", tip),
            metric("wrfcoin_node_pay_epoch", epoch),
            metric("wrfcoin_node_pay_epoch_close_height", close),
            metric("wrfcoin_node_pay_blocks_to_epoch_close", close - tip),
            metric("wrfcoin_node_pay_scan_lag_blocks", min(tip, close) - self.scanned_to),
            metric("wrfcoin_node_pay_house_bonds_configured", len(self.bonds)),
            metric("wrfcoin_node_pay_house_bonds_registered",
                   sum(1 for v in views.values() if v.get("status") == "REGISTERED")),
            metric("wrfcoin_node_pay_last_closed_epoch", last_closed),
            metric("wrfcoin_node_pay_last_closed_epoch_status", 1, {"status": settle_status}),
        ]
        house_eligible = 0
        for alias, bond_id in self.bonds:
            view = views[alias]
            labels = {"bond": alias, "deployment_id": bond_id[:16]}
            binding = ((view.get("registration") or {}).get("binding") or {})
            owner = account_hex(binding.get("owner_account"))
            out.append(metric("wrfcoin_node_pay_bond_registered", int(view.get("status") == "REGISTERED"), labels))
            out.append(metric("wrfcoin_node_pay_bond_jailed", int(view.get("jailed") is True), labels))
            out.append(metric("wrfcoin_node_pay_receipt_batch_included",
                              int(bool(owner) and owner in self.batch_senders), labels))
            if eligible is not None:
                ok = bond_id in eligible
                house_eligible += ok
                out.append(metric("wrfcoin_node_pay_last_closed_epoch_bond_eligible", int(ok), labels))
        if eligible is not None:
            out.append(metric("wrfcoin_node_pay_last_closed_epoch_eligible_house_bonds", house_eligible))
        return out

    # -- chain-rewards index ---------------------------------------------------------------------
    def collect_index(self, token: str) -> list[str]:
        status, body = self.get(f"{NODE_URL}/blockchain", token)
        try:
            tip = int(body["data"]["height"])  # type: ignore[index]
        except (TypeError, KeyError, ValueError):
            raise CollectError(f"node /blockchain answered {status}")
        out = []
        for surface, path in INDEX_SURFACES:
            status, body = self.get(f"{BACKEND_URL}{path}", None)
            labels = {"surface": surface}
            body = body if isinstance(body, dict) else {}
            code = str(((body.get("error") or {}) if isinstance(body.get("error"), dict) else {}).get("code", ""))
            enabled = not (status == 503 and code.endswith("_DISABLED"))
            available = status == 200 and body.get("status") == "available"
            out.append(metric("wrfcoin_chain_index_http_status", status, labels))
            out.append(metric("wrfcoin_chain_index_enabled", int(enabled), labels))
            out.append(metric("wrfcoin_chain_index_available", int(available), labels))
            if available:
                as_of = body.get("asOf") or {}
                try:
                    height = int(as_of.get("height"))
                    out.append(metric("wrfcoin_chain_index_as_of_height", height, labels))
                    out.append(metric("wrfcoin_chain_index_lag_blocks", tip - height, labels))
                except (TypeError, ValueError):
                    pass
                checked = as_of.get("checkedAt")
                if isinstance(checked, str):
                    try:
                        ts = datetime.fromisoformat(checked.replace("Z", "+00:00")).timestamp()
                        out.append(metric("wrfcoin_chain_index_checked_timestamp_seconds", ts, labels))
                    except ValueError:
                        pass
        return out

    # -- loop ------------------------------------------------------------------------------------
    def poll_once(self) -> None:
        try:
            token = read_token()
        except CollectError as e:
            for check in self.errors:
                self.errors[check] += 1
            with self.lock:
                self.sections = {"node_pay": [], "index": []}
            log(f"poll failed: {e}")
            return
        for check, fn in (("node_pay", self.collect_node_pay), ("index", self.collect_index)):
            try:
                lines = fn(token)
            except Exception as e:  # noqa: BLE001 - one failing check must not stop the other
                self.errors[check] += 1
                lines = []  # never serve stale gauges; staleness has its own alert
                log(f"{check} collection failed: {e}")
            else:
                self.last_success[check] = self.clock()
            with self.lock:
                self.sections[check] = lines

    def render(self) -> str:
        with self.lock:
            lines = [l for check in ("node_pay", "index") for l in self.sections[check]]
            for check in ("node_pay", "index"):
                lines.append(metric("wrfcoin_chain_ops_exporter_last_success_timestamp_seconds",
                                    self.last_success[check], {"check": check}))
                lines.append(metric("wrfcoin_chain_ops_exporter_errors_total", self.errors[check], {"check": check}))
        return "\n".join(lines) + "\n"


def serve(exporter: Exporter) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            if self.path == "/metrics":
                body, ctype = exporter.render().encode(), "text/plain; version=0.0.4"
            elif self.path == "/health":
                body, ctype = b'{"ok":true}', "application/json"
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):  # silence per-request logs
            pass

    return ThreadingHTTPServer(("0.0.0.0", PORT), Handler)


def main() -> int:
    try:
        bonds = parse_house_bonds(os.environ.get("NODE_PAY_HOUSE_BONDS", ""))
    except ValueError as e:
        log(str(e))
        return 2
    exporter = Exporter(bonds)
    server = serve(exporter)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"chain-ops exporter on :{PORT}, {len(bonds)} house bond(s), poll {POLL_SECS}s")
    while True:
        exporter.poll_once()
        time.sleep(POLL_SECS)


if __name__ == "__main__":
    sys.exit(main())
