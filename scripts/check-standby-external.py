#!/usr/bin/env python3
"""Independent Proxmox observer; owner-installed, never self-installs."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

PIN = re.compile(r'/dev/bus/usb/[0-9]{3}/[0-9]{3}\Z')
TARGET = re.compile(r'(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9][a-zA-Z0-9.-]*\Z')


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def exchange(url, data=None):
    request = Request(url, data=data, headers={'Content-Type': 'text/plain; charset=utf-8'})
    with build_opener(NoRedirect).open(request, timeout=5) as response:
        if response.status != 200:
            raise ValueError('response status')
        body = response.read(16385)
        if len(body) > 16384:
            raise ValueError('response size')
        return body


def valid_url(value, https=False):
    url = urlsplit(value)
    if (url.scheme not in ({'https'} if https else {'http', 'https'}) or not url.hostname
            or url.username is not None or url.password is not None or url.query or url.fragment
            or not url.path or any(c.isspace() for c in value)):
        raise ValueError('configuration URL')
    return url


def deliver(url, message, kind):
    receipt = exchange(url, message)
    if kind == 'healthchecks':
        if receipt.strip() != b'OK':
            raise ValueError('receiver did not record ping')
    else:
        receipt = json.loads(receipt)
        if (not isinstance(receipt, dict) or receipt.get('event') != 'message'
                or not isinstance(receipt.get('id'), str) or not receipt['id']):
            raise ValueError('receiver did not acknowledge message')


def load_config(path):
    if path.stat().st_mode & 0o077 or path.stat().st_size > 4096:
        raise ValueError('private configuration required')
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ValueError('configuration object')
    if valid_url(config['node_ready_url']).path != '/readyz':
        raise ValueError('readyz required')
    valid_url(config['receiver_url'], https=True)
    if config.get('heartbeat_url'):
        valid_url(config['heartbeat_url'], https=True)
    if config['receiver_type'] not in {'ntfy', 'healthchecks'}:
        raise ValueError('receiver type')
    if not TARGET.fullmatch(config['remote_target']):
        raise ValueError('remote target')
    for key in ('node_usb_device', 'attester_usb_device'):
        if not PIN.fullmatch(config[key]):
            raise ValueError('USB pin')
    return config


def local_probe(pins):
    """Run on the workstation through SSH: USB/state plus existing PID health."""
    try:
        usb = subprocess.run([
            sys.executable, str(Path(__file__).with_name('check-standby-usb.py')),
            '--node-usb-device', pins[0], '--attester-usb-device', pins[1],
        ], capture_output=True, text=True, timeout=12, check=False)
        health = subprocess.run([
            'docker', '--host', 'unix:///var/run/docker.sock', 'container', 'inspect',
            '--format', '{{if .State.Health}}{{json .State.Health.Status}}{{else}}"unknown"{{end}}',
            '--', 'wrfcoin-testnet-oracle-attester',
        ], capture_output=True, text=True, timeout=5, check=False)
        passed = (usb.returncode == 0 and health.returncode == 0
                  and len(health.stdout) < 100 and json.loads(health.stdout) == 'healthy')
    except (OSError, ValueError, subprocess.TimeoutExpired):
        passed = False
    print(json.dumps({'check': 'standby-local', 'status': 'PASS' if passed else 'STOP'}))
    return int(not passed)


def observe(config, state_path, now=None):
    now = time.time() if now is None else now
    failures = []
    try:
        body = exchange(config['node_ready_url'])
        if len(body) > 16384 or json.loads(body).get('status') != 'ready':
            raise ValueError('node not ready')
    except (OSError, ValueError, AttributeError, TypeError):
        failures.append('NODE_NOT_READY')
    try:
        remote = shlex.join([
            'python3', '/opt/wrfcoin-standby/check-standby-external.py', '--local',
            '--node-usb-device', config['node_usb_device'],
            '--attester-usb-device', config['attester_usb_device'],
        ])
        result = subprocess.run([
            'ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ConnectTimeout=5', '--', config['remote_target'], remote,
        ], capture_output=True, text=True, timeout=22, check=False)
        if (result.returncode != 0 or len(result.stdout) > 32768
                or json.loads(result.stdout.strip()) != {'check': 'standby-local', 'status': 'PASS'}):
            raise ValueError('remote unavailable')
    except (OSError, ValueError, subprocess.TimeoutExpired):
        failures.append('ATTESTER_OR_USB_UNAVAILABLE')
    previous = {'failed': False, 'sent': 0}
    try:
        if state_path.exists():
            if state_path.stat().st_size > 1024:
                raise ValueError('state size')
            previous = json.loads(state_path.read_text())
            if (type(previous['failed']) is not bool or type(previous['sent']) not in (int, float)
                    or not math.isfinite(previous['sent']) or previous['sent'] < 0):
                raise ValueError('state fields')
    except (OSError, ValueError, KeyError, TypeError):
        previous = {'failed': True, 'sent': 0}
        failures.append('STATE_UNAVAILABLE')
    failed = bool(failures)
    due = (config['receiver_type'] == 'healthchecks' or failed != previous['failed']
           or (failed and (now < previous['sent'] or now - previous['sent'] >= 900)))
    message = ('Standby FAIL: ' + ','.join(failures) if failed else 'Standby RECOVERED').encode()
    sent = previous['sent']
    if due:
        sink = config['receiver_url'].rstrip('/')
        if config['receiver_type'] == 'healthchecks' and failed:
            sink += '/fail'
        try:
            deliver(sink, message, config['receiver_type'])
            sent = now
        except (OSError, ValueError):
            failures.append('DELIVERY_UNAVAILABLE')
    if config.get('heartbeat_url'):
        try:
            deliver(config['heartbeat_url'].rstrip('/') + ('/fail' if failures else ''), b'Standby observer', 'healthchecks')
        except (OSError, ValueError):
            failures.append('HEARTBEAT_DELIVERY_UNAVAILABLE')
    try:
        temporary = state_path.with_suffix('.tmp')
        acknowledged = previous['failed'] if 'DELIVERY_UNAVAILABLE' in failures else failed
        temporary.write_text(json.dumps({'failed': acknowledged, 'sent': sent}))
        temporary.chmod(0o600)
        os.replace(temporary, state_path)
    except OSError:
        failures.append('STATE_WRITE_UNAVAILABLE')
    status = 'STOP' if failures else 'PASS'
    print(json.dumps({'check': 'standby-external', 'status': status, 'codes': failures}),
          file=sys.stderr if failures else sys.stdout, flush=True)
    return int(bool(failures))


def main(argv=()):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local', action='store_true')
    parser.add_argument('--node-usb-device')
    parser.add_argument('--attester-usb-device')
    parser.add_argument('--config', type=Path)
    parser.add_argument('--state', type=Path, default=Path('/var/lib/wrfcoin-standby/state.json'))
    parser.add_argument('--validate-config', action='store_true')
    parser.add_argument('--test-notification', action='store_true')
    args = parser.parse_args(argv)
    if args.local:
        pins = [args.node_usb_device, args.attester_usb_device]
        if any(not isinstance(pin, str) or not PIN.fullmatch(pin) for pin in pins):
            print('STOP: expected USB source pins required', file=sys.stderr)
            return 1
        return local_probe(pins)
    try:
        config = load_config(args.config)
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        print('STOP: private owner configuration unavailable or invalid', file=sys.stderr)
        return 1
    if args.validate_config:
        print('PASS: owner configuration valid; no probes or delivery attempted')
        return 0
    if args.test_notification:
        try:
            deliver(config['receiver_url'].rstrip('/'), b'Standby observer TEST notification', config['receiver_type'])
        except (OSError, ValueError):
            print('STOP: test notification not acknowledged', file=sys.stderr)
            return 1
        print('PASS: test notification acknowledged; owner must confirm receipt independently')
        return 0
    return observe(config, args.state)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
