#!/usr/bin/env python3
"""Hermetic loopback fixture for verify-two-node-convergence.sh."""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--omit-state-root", action="store_true")
    parser.add_argument("--omit-genesis", action="store_true")
    parser.add_argument("--omit-entry-count", action="store_true")
    parser.add_argument("--empty-entries", action="store_true")
    parser.add_argument("--null-entry-total", action="store_true")
    parser.add_argument("--null-entry-height", action="store_true")
    parser.add_argument("--reader-token", default="test-reader-token")
    parser.add_argument("--state-root", default="c" * 64)
    parser.add_argument("--height", type=int, default=10)
    return parser.parse_args()


ARGS = parse_args()
GENESIS_HASH = "0x" + ("a" * 64)
BLOCK_HASH = "0x" + ("b" * 64)
SNAPSHOT_ROOT = "d" * 64


class Handler(BaseHTTPRequestHandler):
    def _json(self, payload: dict) -> None:
        encoded = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        if self.headers.get("Authorization") != f"Bearer {ARGS.reader_token}":
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {
                        "ok": False,
                        "data": None,
                        "error": {
                            "code": "UNAUTHORIZED",
                            "message": "Missing or malformed Authorization header",
                        },
                    }
                ).encode()
            )
            return

        path = urlparse(self.path).path
        if path == "/network/info":
            payload = {
                "chain_height": ARGS.height,
                "peer_count": 1,
                "sync_status": "synced",
            }
            if not ARGS.omit_genesis:
                payload["genesis_hash"] = GENESIS_HASH
            self._json(payload)
        elif path.startswith("/chain/block/"):
            self._json({"data": {"hash": BLOCK_HASH}})
        elif path == "/state/snapshot":
            payload = {
                "height": ARGS.height,
                "snapshot_root_hex": SNAPSHOT_ROOT,
            }
            if not ARGS.omit_state_root:
                payload["state_root_hex"] = ARGS.state_root
            if not ARGS.omit_entry_count:
                payload["entry_count"] = 1
            self._json(payload)
        elif path == "/state/snapshot/entries":
            entries = []
            if not ARGS.empty_entries:
                entries = [{"key_hex": "account/mock".encode().hex()}]
            payload = {
                "height": None if ARGS.null_entry_height else ARGS.height,
                "total": None if ARGS.null_entry_total else len(entries),
                "entries": entries,
                "next_offset": None,
            }
            self._json(payload)
        elif path == "/metrics":
            encoded = b"wrfcoin_state_divergence_total 0\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)
        elif path == "/readyz":
            self._json({"status": "ready"})
        else:
            self.send_error(404)

    def log_message(self, _format: str, *_args: object) -> None:
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(ARGS.port_file).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
