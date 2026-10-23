#!/usr/bin/env python3
"""Bond-grant POST edge body cap: real Caddy, loopback-only fake backend, synthetic bodies; no live nodes.

Usage: python3 testnet/edge/verify_bond_grant_runtime.py /path/to/caddy
The executable must include the edge's rate_limit module (the local edge image), like
verify_wallet_send_runtime.py. A backend that reads the body is required: without one the proxy
fails to dial before it reads anything, so a body cap can never be observed.
"""
import http.client
import http.server
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

SNIPPET = Path(__file__).with_name('public_onboarding.caddy')
HEADERS = {'Content-Type': 'application/json'}
GRANT = '/api/faucet/bond-grant'
CAP = 8 * 1024


class Stub(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.calls.append((self.command, self.path, len(body)))
        try:
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"synthetic"}')
        except BrokenPipeError:
            pass  # Caddy has already rejected an over-cap body with 413.

    def log_message(self, *_):
        pass


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); return s.getsockname()[1]


def main(binary):
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    checks = 0
    snippet = SNIPPET.read_text().replace('wrfcoin-testnet-backend:4001', f'127.0.0.1:{server.server_port}')

    # One fresh Caddy per batch, so the 5/minute faucet_claim zone never decides an answer here.
    def prove(cases):
        nonlocal checks
        listen = port()
        with tempfile.TemporaryDirectory(prefix='bond-grant-edge-') as folder:
            p = Path(folder)
            (p / 'snippets').write_text(snippet)
            (p / 'Caddyfile').write_text(
                '{\n admin off\n auto_https off\n}\nimport snippets\n'
                f'http://127.0.0.1:{listen} {{\n bind 127.0.0.1\n import public_onboarding_limits\n route {{\n import public_onboarding_api\n }}\n}}\n')
            with (p / 'log').open('w') as log:
                process = subprocess.Popen([binary, 'run', '--config', str(p / 'Caddyfile'), '--adapter', 'caddyfile'],
                                           env={**os.environ}, stdout=log, stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None: raise AssertionError((p / 'log').read_text())
                        try:
                            with socket.create_connection(('127.0.0.1', listen), timeout=.1): break
                        except OSError: time.sleep(.05)
                    for method, path, body, want in cases:
                        before = len(Stub.calls)
                        conn = http.client.HTTPConnection('127.0.0.1', listen, timeout=5)
                        conn.request(method, path, body=body, headers=HEADERS)
                        response = conn.getresponse(); got = response.status; response.read(); conn.close()
                        assert got == want, (method, path, len(body), want, got)
                        # 200 must come from the stub with the whole body; a refusal must not reach it intact.
                        if want == 200:
                            assert Stub.calls[before:] == [(method, path, len(body))], (Stub.calls[before:], len(body))
                        checks += 1
                finally:
                    process.terminate(); process.wait(timeout=5)

    try:
        prove([('POST', GRANT, '{"x":"' + 'a' * 1000 + '"}', 200),   # a realistic ~1 KiB signed request
               ('POST', GRANT, 'a' * CAP, 200)])                    # exactly at the cap
        prove([('POST', GRANT, 'a' * (CAP + 1), 413)])               # one byte over
        prove([('POST', GRANT, 'a' * (16 * 1024), 413)])             # the backend's own cap is never the first line
        # The cap is per route: the audit list stays a GET-only read and the sibling paths stay off.
        prove([('GET', GRANT, '', 404), ('PUT', GRANT, 'a', 404), ('POST', GRANT + '/', 'a', 404)])
        print(f'PASS bond-grant real Caddy: {checks} assertions (8 KiB edge body cap: 1 KiB and 8 KiB pass, '
              f'8 KiB + 1 and 16 KiB refused 413; method/path stay exact)')
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main(sys.argv[1])
