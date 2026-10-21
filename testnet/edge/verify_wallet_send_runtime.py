#!/usr/bin/env python3
"""S9: real Caddy, loopback-only fake backend, synthetic credentials; no live nodes.

Usage: python3 testnet/edge/verify_wallet_send_runtime.py /path/to/caddy
The executable must include the edge's rate_limit module (the local edge image).
"""
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

SNIPPET = Path(__file__).with_name('public_onboarding.caddy')
ADDRESS = '0x' + 'a1' * 20
HEADERS = {'Authorization': 'Bearer synthetic-test-session', 'Content-Type': 'application/json'}


class Stub(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        self.calls.append((self.command, self.path))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"nonce":"7"}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.calls.append((self.command, self.path))
        try:
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"hash":"synthetic-id"}')
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
    # Literal gate expansion is isolated to the scratch config, like Caddy env expansion.
    def prove(gate, cases):
        nonlocal checks
        listen = port()
        with tempfile.TemporaryDirectory(prefix='sol-s9-edge-') as folder:
            p = Path(folder)
            (p / 'snippets').write_text(snippet)
            (p / 'Caddyfile').write_text(
                '{\n admin off\n auto_https off\n}\nimport snippets\n'
                f'http://127.0.0.1:{listen} {{\n bind 127.0.0.1\n import public_onboarding_limits\n route {{\n import public_onboarding_api\n }}\n}}\n')
            with (p / 'log').open('w') as log:
                process = subprocess.Popen([binary, 'run', '--config', str(p / 'Caddyfile'), '--adapter', 'caddyfile'],
                                           env={**os.environ, 'PUBLIC_READONLY_API': gate}, stdout=log, stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None: raise AssertionError((p / 'log').read_text())
                        try:
                            with socket.create_connection(('127.0.0.1', listen), timeout=.1): break
                        except OSError: time.sleep(.05)
                    for method, path, headers, body, want in cases:
                        conn = http.client.HTTPConnection('127.0.0.1', listen, timeout=5)
                        conn.request(method, path, body=body, headers=headers)
                        response = conn.getresponse(); got = response.status; response.read(); conn.close()
                        assert got == want, (gate, method, path, len(body), want, got)
                        checks += 1
                finally:
                    process.terminate(); process.wait(timeout=5)

    submit = '/api/wallet/send'
    nonce = f'/api/wallet/{ADDRESS}/nonce'
    try:
        for gate in ('off', 'ON', 'true', 'unset'):
            prove(gate, [('POST', submit, HEADERS, '{}', 404), ('GET', nonce, HEADERS, '', 404)])
        prove('on', [('POST', submit, HEADERS, '{}', 200), ('GET', nonce, HEADERS, '', 200)])
        # Fresh buckets: rejected POSTs also count toward the submission budget.
        for headers in ({}, {'Content-Type': 'application/json'}, {'Authorization': HEADERS['Authorization']},
                        {**HEADERS, 'Content-Type': 'text/plain'}, {**HEADERS, 'Content-Type': 'application/json; charset=utf-8'}):
            prove('on', [('POST', submit, headers, '{}', 404)])
        for method, path in [('GET', submit), ('PUT', submit), ('POST', submit + '/'), ('POST', submit + '?x=1'),
                             ('POST', '/api/wallet/send-private'), ('POST', f'/api/wallet/{ADDRESS}/transactions'),
                             ('GET', nonce + '?x=1'), ('GET', nonce + '/'), ('GET', '/api/wallet/0xabc/nonce')]:
            prove('on', [(method, path, HEADERS, '', 404)])
        prove('on', [('POST', submit, HEADERS, 'x' * 4096, 200), ('POST', submit, HEADERS, 'x' * 4097, 413)])
        prove('on', [('POST', submit, HEADERS, '{}', 200)] * 5 + [('POST', submit, HEADERS, '{}', 429)])
        print(f'PASS S9 real Caddy: {checks} assertions (gate, exact method/path/query, Bearer, content-type, 4KiB cap, 5/minute)')
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main(sys.argv[1])
