"""Outside observer tests replace every subprocess and HTTP boundary."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).parents[2]
SCRIPT = ROOT / 'scripts/check-standby-external.py'


@pytest.fixture
def observer():
    spec = importlib.util.spec_from_file_location('standby_external', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def config():
    return dict(node_ready_url='http://node.example.invalid:8556/readyz',
                remote_target='watch@workstation.example.invalid',
                node_usb_device='/dev/bus/usb/001/002',
                attester_usb_device='/dev/bus/usb/001/003',
                receiver_url='https://receiver.example.invalid/private-topic',
                receiver_type='ntfy')


def wire(monkeypatch, observer, ready='ready', remote=0, body=None, broken_delivery=False):
    calls = []
    def exchange(url, data=None):
        calls.append((url, data))
        if data is None:
            return json.dumps({'status': ready}).encode() if body is None else body
        if broken_delivery:
            raise OSError('PRIVATE_TOPIC must not reach logs')
        return b'OK' if 'hc-ping' in url or 'heartbeat' in url else b'{"event":"message","id":"synthetic"}'
    def run(argv, **kwargs):
        assert argv[:2] == ['ssh', '-o']
        assert 'BatchMode=yes' in argv and 'StrictHostKeyChecking=yes' in argv
        assert kwargs['timeout'] <= 25
        return subprocess.CompletedProcess(argv, remote, '{"check":"standby-local","status":"PASS"}\n', 'PRIVATE_REMOTE')
    monkeypatch.setattr(observer, 'exchange', exchange)
    monkeypatch.setattr(observer.subprocess, 'run', run)
    return calls


def test_healthy_first_run_does_not_send_alarm(observer, config, monkeypatch, tmp_path):
    calls = wire(monkeypatch, observer)
    assert observer.observe(config, tmp_path/'state', now=1000) == 0
    assert calls == [(config['node_ready_url'], None)]


@pytest.mark.parametrize('ready,remote', [('not_ready', 0), ('ready', 1), ('not_ready', 255)])
def test_failure_alarm_repeat_and_recovery(observer, config, monkeypatch, tmp_path, ready, remote):
    calls = wire(monkeypatch, observer, ready=ready, remote=remote)
    state = tmp_path/'state'
    assert observer.observe(config, state, now=1000) == 1
    assert b'FAIL' in calls[-1][1]
    assert observer.observe(config, state, now=1060) == 1
    assert len([x for x in calls if x[1] is not None]) == 1
    assert observer.observe(config, state, now=1900) == 1
    assert len([x for x in calls if x[1] is not None]) == 2
    calls = wire(monkeypatch, observer)
    assert observer.observe(config, state, now=1960) == 0
    assert b'RECOVERED' in calls[-1][1]


@pytest.mark.parametrize('body', [b'{}', b'{"status":true}', b'not json', b'x'*16385])
def test_bad_ready_payload_alarms(observer, config, monkeypatch, tmp_path, body):
    wire(monkeypatch, observer, body=body)
    assert observer.observe(config, tmp_path/'state', now=1000) == 1


def test_timeouts_and_remote_false_success_cannot_pass(observer, config, monkeypatch, tmp_path):
    wire(monkeypatch, observer)
    monkeypatch.setattr(observer.subprocess, 'run', lambda *a, **k: subprocess.CompletedProcess(a, 0, 'not the checker', ''))
    assert observer.observe(config, tmp_path/'state', now=1000) == 1
    def timeout(*a, **k):
        raise subprocess.TimeoutExpired('ssh', 22)
    monkeypatch.setattr(observer.subprocess, 'run', timeout)
    assert observer.observe(config, tmp_path/'state2', now=1000) == 1


def test_receiver_failure_is_nonzero_and_private(observer, config, monkeypatch, tmp_path, capsys):
    wire(monkeypatch, observer, remote=255, broken_delivery=True)
    assert observer.observe(config, tmp_path/'state', now=1000) == 1
    output = capsys.readouterr()
    assert 'DELIVERY_UNAVAILABLE' in output.err
    assert 'PRIVATE' not in output.err + output.out
    assert config['receiver_url'] not in output.err + output.out


def test_healthchecks_receiver_reports_every_poll_for_missing_job_detection(observer, config, monkeypatch, tmp_path):
    config['receiver_type'] = 'healthchecks'
    config['receiver_url'] = 'https://hc-ping.example.invalid/private-id'
    calls = wire(monkeypatch, observer, remote=1)
    assert observer.observe(config, tmp_path/'state', now=1000) == 1
    assert calls[-1][0] == config['receiver_url']+'/fail'
    calls = wire(monkeypatch, observer)
    assert observer.observe(config, tmp_path/'state', now=1060) == 0
    assert calls[-1][0] == config['receiver_url']


def test_failed_recovery_delivery_retries_next_poll(observer, config, monkeypatch, tmp_path):
    state = tmp_path/'state'
    wire(monkeypatch, observer, remote=1)
    assert observer.observe(config, state, now=1000) == 1
    wire(monkeypatch, observer, broken_delivery=True)
    assert observer.observe(config, state, now=1060) == 1
    calls = wire(monkeypatch, observer)
    assert observer.observe(config, state, now=1120) == 0
    assert b'RECOVERED' in calls[-1][1]


@pytest.mark.parametrize('sent', [float('nan'), -1, 9999])
def test_corrupt_or_future_state_cannot_suppress_alarm(observer, config, monkeypatch, tmp_path, sent):
    state = tmp_path/'state'
    state.write_text(json.dumps({'failed': True, 'sent': sent}))
    calls = wire(monkeypatch, observer, remote=1)
    assert observer.observe(config, state, now=1000) == 1
    assert any(data is not None for url, data in calls)


def test_optional_deadman_heartbeat_and_failure(observer, config, monkeypatch, tmp_path):
    config['heartbeat_url'] = 'https://heartbeat.example.invalid/private-id'
    calls = wire(monkeypatch, observer)
    assert observer.observe(config, tmp_path/'state', now=1000) == 0
    assert calls[-1][0] == config['heartbeat_url']
    calls = wire(monkeypatch, observer, remote=1)
    assert observer.observe(config, tmp_path/'state', now=1060) == 1
    assert calls[-1][0] == config['heartbeat_url']+'/fail'


@pytest.mark.parametrize('kind,receipt', [('ntfy', b'OK'), ('ntfy', b'{}'), ('healthchecks', b'OK (not found)'), ('healthchecks', b'OK (rate limited)')])
def test_http_200_without_receiver_acknowledgment_is_not_success(observer, monkeypatch, kind, receipt):
    monkeypatch.setattr(observer, 'exchange', lambda *a: receipt)
    with pytest.raises(ValueError):
        observer.deliver('https://receiver.example.invalid/topic', b'alarm', kind)


@pytest.mark.parametrize('value', ['http://receiver.invalid/topic', 'https://u:p@receiver.invalid/topic', 'https://receiver.invalid/topic?q=secret'])
def test_invalid_private_config_is_sanitized(observer, config, tmp_path, capsys, value):
    config['receiver_url'] = value
    path = tmp_path/'config'
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    assert observer.main(['--config', str(path), '--validate-config']) == 1
    assert value not in capsys.readouterr().err


def test_config_validation_has_no_io_and_requires_private_permissions(observer, config, tmp_path, capsys):
    path = tmp_path/'config'
    path.write_text(json.dumps(config))
    path.chmod(0o644)
    assert observer.main(['--config', str(path), '--validate-config']) == 1
    path.chmod(0o600)
    assert observer.main(['--config', str(path), '--validate-config']) == 0
    assert 'PASS' in capsys.readouterr().out


def test_owner_test_notification_requires_receipt_without_node_or_ssh(observer, config, monkeypatch, tmp_path):
    path = tmp_path/'config'
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    calls = wire(monkeypatch, observer)
    assert observer.main(['--config', str(path), '--test-notification']) == 0
    assert calls == [(config['receiver_url'], b'Standby observer TEST notification')]
    wire(monkeypatch, observer, broken_delivery=True)
    assert observer.main(['--config', str(path), '--test-notification']) == 1


@pytest.mark.parametrize('health', ['healthy', 'unhealthy', 'starting', 'unknown'])
def test_local_calls_existing_usb_checker_and_attester_process_health(observer, monkeypatch, health):
    calls = []
    def run(argv, **kwargs):
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 0, json.dumps(health), '')
    monkeypatch.setattr(observer.subprocess, 'run', run)
    assert observer.local_probe(['/dev/bus/usb/001/002', '/dev/bus/usb/001/003']) == (0 if health == 'healthy' else 1)
    assert 'check-standby-usb.py' in calls[0][1]
    assert calls[1][-1] == 'wrfcoin-testnet-oracle-attester'


def test_local_usb_failure_is_not_hidden(observer, monkeypatch):
    monkeypatch.setattr(observer.subprocess, 'run', lambda argv, **k: subprocess.CompletedProcess(argv, 1, '', 'private'))
    assert observer.local_probe(['/dev/bus/usb/001/002', '/dev/bus/usb/001/003']) == 1


@pytest.fixture
def cli_doubles(tmp_path):
    bootstrap = tmp_path/'sitecustomize.py'
    bootstrap.write_text('''
import io, json, os, stat, types, urllib.request
original_stat = os.stat
def fake_stat(path, *args, **kwargs):
    if str(path).startswith('/dev/bus/usb/'):
        if os.environ.get('FAKE_USB_MISSING') == '1':
            raise OSError('private hardware error')
        return types.SimpleNamespace(st_mode=stat.S_IFCHR)
    return original_stat(path, *args, **kwargs)
os.stat = fake_stat
class Reply(io.BytesIO):
    status = 200
class Opener:
    def open(self, request, timeout):
        assert timeout == 5
        with open(os.environ['FAKE_HTTP_LOG'], 'a') as log:
            log.write(json.dumps({'method': request.get_method(), 'url': request.full_url})+'\\n')
        if request.data is None:
            return Reply(json.dumps({'status': os.environ.get('FAKE_READY', 'ready')}).encode())
        return Reply(b'{}' if os.environ.get('FAKE_RECEIVER_BAD') else b'{"event":"message","id":"synthetic"}')
urllib.request.build_opener = lambda *a: Opener()
''')
    (tmp_path/'ssh').write_text('''#!/bin/sh
printf '%s\\n' "$@" >> "$FAKE_SSH_LOG"
printf '%s\\n' '{"check":"standby-local","status":"PASS"}'
printf '%s\\n' 'PRIVATE_REMOTE' >&2
exit "${FAKE_REMOTE_EXIT:-0}"
''')
    (tmp_path/'docker').write_text('''#!/usr/bin/python3
import json, sys
if 'Health.Status' in sys.argv[sys.argv.index('--format')+1]:
    print('"healthy"')
else:
    print(json.dumps({'name':'/'+sys.argv[-1], 'running':True, 'status':'running', 'exit_code':0,
                      'devices':[{'PathOnHost':'/dev/bus/usb'}]}))
''')
    for executable in ['ssh', 'docker']:
        (tmp_path/executable).chmod(0o755)
    return {**os.environ, 'PATH': str(tmp_path)+':'+os.environ['PATH'], 'PYTHONPATH': str(tmp_path),
            'FAKE_HTTP_LOG': str(tmp_path/'http.log'), 'FAKE_SSH_LOG': str(tmp_path/'ssh.log')}


@pytest.mark.parametrize('ready,remote,bad_receiver,expected', [('ready', '0', '', 0), ('not_ready', '0', '', 1), ('ready', '255', '', 1), ('not_ready', '255', '1', 1)])
def test_actual_external_cli_with_transport_and_ssh_doubles(config, tmp_path, cli_doubles, ready, remote, bad_receiver, expected):
    path = tmp_path/'config'
    path.write_text(json.dumps(config))
    path.chmod(0o600)
    result = subprocess.run([sys.executable, str(SCRIPT), '--config', str(path), '--state', str(tmp_path/'state')],
                            env={**cli_doubles, 'FAKE_READY': ready, 'FAKE_REMOTE_EXIT': remote, 'FAKE_RECEIVER_BAD': bad_receiver},
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == expected, result.stderr
    assert ('STOP' if expected else 'PASS') in result.stderr + result.stdout
    assert 'PRIVATE' not in result.stderr + result.stdout
    assert config['receiver_url'] not in result.stderr + result.stdout
    requests = [json.loads(line) for line in (tmp_path/'http.log').read_text().splitlines()]
    assert requests[0] == {'method': 'GET', 'url': config['node_ready_url']}
    assert len(requests) == (1 if expected == 0 else 2)
    assert 'StrictHostKeyChecking=yes' in (tmp_path/'ssh.log').read_text()


@pytest.mark.parametrize('missing,expected', [('0', 0), ('1', 1)])
def test_actual_local_cli_calls_actual_usb_checker_with_docker_stat_doubles(tmp_path, cli_doubles, missing, expected):
    result = subprocess.run([sys.executable, str(SCRIPT), '--local', '--node-usb-device', '/dev/bus/usb/001/002',
                             '--attester-usb-device', '/dev/bus/usb/001/003'],
                            env={**cli_doubles, 'FAKE_USB_MISSING': missing}, capture_output=True, text=True, timeout=5)
    assert result.returncode == expected, result.stderr
    assert json.loads(result.stdout)['status'] == ('PASS' if expected == 0 else 'STOP')
    assert not (tmp_path/'http.log').exists()


def test_workstation_owner_install_uses_only_install_doubles(tmp_path, cli_doubles):
    (tmp_path/'id').write_text('#!/bin/sh\necho 0\n')
    (tmp_path/'install').write_text('#!/bin/sh\nprintf "%s\\n" "$@" >> "$FAKE_INSTALL_LOG"\n')
    for file in ['id', 'install']:
        (tmp_path/file).chmod(0o755)
    result = subprocess.run(['bash', str(ROOT/'testnet/owner-steps/standby-alert/01-install.sh'), 'workstation'],
                            env={**cli_doubles, 'FAKE_INSTALL_LOG': str(tmp_path/'install.log')},
                            capture_output=True, text=True, timeout=5)
    assert result.returncode == 0, result.stderr
    assert 'PASS' in result.stdout
    assert 'check-standby-usb.py' in (tmp_path/'install.log').read_text()
    assert not (tmp_path/'http.log').exists()


@pytest.mark.parametrize('step', ['02-proxmox-preflight.sh', '03-proxmox-enable.sh', '04-proxmox-verify.sh'])
def test_proxmox_steps_refuse_workstation_before_any_action(step, cli_doubles):
    if Path('/etc/pve').exists():
        pytest.skip('this control requires a non-Proxmox test host')
    result = subprocess.run(['bash', str(ROOT/'testnet/owner-steps/standby-alert'/step)],
                            env=cli_doubles, capture_output=True, text=True, timeout=5)
    assert result.returncode == 1
    assert 'STOP' in result.stderr
