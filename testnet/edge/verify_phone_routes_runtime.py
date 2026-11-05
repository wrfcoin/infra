#!/usr/bin/env python3
"""Phone station registration and reading upload at the edge: real Caddy, loopback-only fake backend,
synthetic bodies; no live nodes.

Usage: python3 testnet/edge/verify_phone_routes_runtime.py /path/to/caddy
The executable must include the edge's rate_limit module (the local edge image), like
verify_bond_grant_runtime.py. A backend that reads the body is required: without one the proxy
fails to dial before it reads anything, so a body cap can never be observed. The site is built the
way both public edges build it (sane_limits at site level, the allowlist inside a route), so the
site-wide 2MB cap and its one multipart-upload exemption are exercised together with the routes.
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
CHALLENGE = '/api/weather/stations/mobile/challenge'
REGISTER = '/api/weather/stations/mobile'
PREPARE = '/api/oracle/submit-data/prepare'
SUBMIT = '/api/oracle/submit-data'
PHONE_POSTS = (CHALLENGE, REGISTER, PREPARE, SUBMIT)
SITE_CAP = 2 * 1000 * 1000       # sane_limits `max_size 2MB` (Caddy parses MB as 10^6 bytes)
UPLOAD_CAP = 10 * 1000 * 1000    # the multipart upload's own `max_size 10MB`

BEARER = {'Authorization': 'Bearer synthetic-session'}
JSON = {'Content-Type': 'application/json'}
MULTIPART = {'Content-Type': 'multipart/form-data; boundary=synthetic'}


class Stub(http.server.BaseHTTPRequestHandler):
    calls = []

    def _answer(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        self.calls.append((self.command, self.path, len(body)))
        try:
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"synthetic"}')
        except BrokenPipeError:
            pass  # Caddy has already rejected an over-cap body with 413.

    do_GET = do_POST = do_PUT = do_DELETE = _answer

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

    # One fresh Caddy per batch, so the 30/minute onboarding zone never decides an answer here.
    def prove(cases):
        nonlocal checks
        listen = port()
        with tempfile.TemporaryDirectory(prefix='phone-routes-edge-') as folder:
            p = Path(folder)
            (p / 'snippets').write_text(snippet)
            (p / 'Caddyfile').write_text(
                '{\n admin off\n auto_https off\n}\nimport snippets\n'
                f'http://127.0.0.1:{listen} {{\n bind 127.0.0.1\n import sane_limits\n import public_onboarding_limits\n'
                ' route {\n  import public_onboarding_api\n }\n}\n')
            with (p / 'log').open('w') as log:
                process = subprocess.Popen([binary, 'run', '--config', str(p / 'Caddyfile'), '--adapter', 'caddyfile'],
                                           env={**os.environ}, stdout=log, stderr=log)
                try:
                    for _ in range(100):
                        if process.poll() is not None: raise AssertionError((p / 'log').read_text())
                        try:
                            with socket.create_connection(('127.0.0.1', listen), timeout=.1): break
                        except OSError: time.sleep(.05)
                    for method, path, headers, size, want in cases:
                        before = len(Stub.calls)
                        body = b'a' * size if size else None
                        conn = http.client.HTTPConnection('127.0.0.1', listen, timeout=30)
                        conn.request(method, path, body=body, headers=headers)
                        response = conn.getresponse(); got = response.status; response.read(); conn.close()
                        label = (method, path, sorted(headers.items()), size)
                        assert got == want, (label, 'want', want, 'got', got)
                        if want == 200:
                            # 200 must come from the stub with the whole body.
                            assert Stub.calls[before:] == [(method, path, size)], (label, Stub.calls[before:])
                        elif want in (400, 404):
                            # A refusal at the edge never reaches the backend at all.
                            assert Stub.calls[before:] == [], (label, Stub.calls[before:])
                        checks += 1
                finally:
                    process.terminate(); process.wait(timeout=5)

    try:
        # Each of the four POSTs reaches the backend with a Bearer header and no query string.
        prove([('POST', path, {**BEARER, **JSON}, 200, 200) for path in PHONE_POSTS])
        prove([('POST', SUBMIT, {**BEARER, **MULTIPART}, 200, 200)])
        # Without a Bearer credential, with another scheme, or with any query string: the edge's 404.
        prove([('POST', path, JSON, 10, 404) for path in PHONE_POSTS]
              + [('POST', path, {'Authorization': 'Basic c3ludGhldGlj', **JSON}, 10, 404) for path in PHONE_POSTS]
              + [('POST', path + '?x=1', {**BEARER, **JSON}, 10, 404) for path in PHONE_POSTS]
              + [('POST', SUBMIT + '?x=1', {**BEARER, **MULTIPART}, 10, 404),
                 ('POST', SUBMIT, MULTIPART, 10, 404)])
        # Other methods, subpaths and suffixes stay off. GET on the registration path is the
        # separate own-status read, so it is the one non-POST that still reaches the backend.
        prove([(m, path, {**BEARER, **JSON}, 10 if m == 'PUT' else 0, 404)
               for path in (CHALLENGE, PREPARE, SUBMIT) for m in ('GET', 'PUT', 'DELETE')]
              + [('PUT', REGISTER, {**BEARER, **JSON}, 10, 404), ('DELETE', REGISTER, BEARER, 0, 404),
                 ('GET', REGISTER, BEARER, 0, 200)]
              + [('POST', path, {**BEARER, **JSON}, 10, 404) for path in (
                  REGISTER + '/x', REGISTER + '/', REGISTER + 'x', CHALLENGE + '/x', PREPARE + '/x',
                  SUBMIT + '/', SUBMIT + 'x', SUBMIT + '/other', '/api/oracle/submit')])
        # Non-canonical spellings are refused before routing.
        prove([('POST', path, {**BEARER, **JSON}, 10, 400) for path in (
            '/api/weather/stations//mobile', '/api/weather/stations/./mobile', '/api/weather/stations/mobile%2Fchallenge',
            '/api/oracle//submit-data', '/api/oracle/submit-data/prepare/..', '/api/oracle%2Fsubmit-data')])
        # Body caps. The site-wide 2MB holds on every phone POST, including a JSON body on the upload path.
        prove([('POST', path, {**BEARER, **JSON}, SITE_CAP, 200) for path in PHONE_POSTS])
        for path in PHONE_POSTS:
            prove([('POST', path, {**BEARER, **JSON}, SITE_CAP + 1, 413)])
        # The authenticated multipart upload is exempt from the 2MB and capped at 10MB by its own handler.
        prove([('POST', SUBMIT, {**BEARER, **MULTIPART}, 3 * 1000 * 1000, 200),
               ('POST', SUBMIT, {**BEARER, **MULTIPART}, UPLOAD_CAP, 200)])
        prove([('POST', SUBMIT, {**BEARER, **MULTIPART}, UPLOAD_CAP + 1, 413)])
        # Claiming multipart elsewhere earns nothing: the other phone POSTs keep the 2MB.
        prove([('POST', PREPARE, {**BEARER, **MULTIPART}, SITE_CAP + 1, 413)])
        print(f'PASS phone routes real Caddy: {checks} assertions (four POSTs reach the backend only with a '
              f'Bearer header and no query; methods, subpaths and other schemes 404; 2MB site cap on all four; '
              f'authenticated multipart upload exempt and capped at 10MB)')
    finally:
        server.shutdown(); server.server_close()


if __name__ == '__main__':
    main(sys.argv[1])
