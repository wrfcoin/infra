#!/usr/bin/env python3
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--mode", choices=("fresh", "stale", "edge404", "backendstale"), required=True)
parser.add_argument("--port-file", required=True)
args = parser.parse_args()

last_modified = "Tue, 18 Aug 2026 12:00:00 GMT" if args.mode == "stale" else "Fri, 18 Sep 2026 12:00:00 GMT"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_payload(self, code, body, content_type, *, dated=False):
        encoded = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        if dated:
            self.send_header("Last-Modified", last_modified)
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            self.send_payload(200, '<script src="/assets/index-fixture.js"></script>', "text/html", dated=True)
        elif path == "/assets/index-fixture.js":
            self.send_payload(200, "console.log('fixture');", "application/javascript", dated=True)
        elif path == "/join/manifest.json":
            self.send_payload(200, json.dumps({"fixture": True}), "application/json")
        elif path == "/api/capabilities":
            self.send_payload(200, json.dumps({"features": {}}), "application/json")
        elif path == "/api/build":
            revision = "0" * 40 if args.mode == "backendstale" else "2" * 40
            self.send_payload(200, json.dumps({
                "available": True,
                "revision": revision,
                "created": "2026-09-19T12:00:00.000Z",
                "source": "oci-build-args",
            }), "application/json")
        elif path in {
            "/api/blockchain/status",
            "/api/blockchain/blocks",
            "/api/weather/coverage-zones",
        }:
            if args.mode == "edge404" and path == "/api/blockchain/status":
                self.send_payload(404, "Not found", "text/plain")
            else:
                self.send_payload(200, json.dumps({"path": path}), "application/json")
        else:
            self.send_payload(404, "Not found", "text/plain")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(args.port_file).write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
