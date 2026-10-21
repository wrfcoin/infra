"""Actual boot service selection with daemonless Compose rendering only."""
import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).parents[2]
DOCKER = shutil.which('docker')


@pytest.fixture
def stack(tmp_path):
    testnet = tmp_path / 'testnet'
    (testnet / 'lib').mkdir(parents=True)
    for name in ('boot-heal.sh', 'docker-compose.container-health-watch.yml', 'lib/compose-inputs.sh'):
        shutil.copyfile(ROOT / 'testnet' / name, testnet / name)
    (testnet / 'docker-compose.testnet.yml').write_text('''services:
  alert-receiver:
    image: fixture/receiver
    healthcheck: {test: [CMD, "true"]}
    networks: [wrfcoin-testnet]
  wrfcoin-node:
    image: fixture/node
    networks: [wrfcoin-testnet]
networks:
  wrfcoin-testnet: {}
''')
    binpath = tmp_path / 'bin'; binpath.mkdir()
    docker = binpath / 'docker'
    # No daemon operation reaches the real Docker executable, including mutation runs.
    docker.write_text('''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
if a[:1] != ['compose'] or 'config' not in a or a[-1:] != ['--services']:
    open(os.environ['SOL_N_DENIED_LOG'],'a').write('docker-denied\\n')
    sys.exit(99)
os.execv(%r, [%r, *a, '--no-interpolate'])
''' % (DOCKER, DOCKER))
    docker.chmod(0o755)
    custody = testnet / 'synthetic-custody.conf'
    rows = ['HSM_INIT_IMAGE_IDS=sha256:' + 'a'*64]
    for owner in ('NODE', 'SEED'):
        rows.append('HSM_INIT_' + owner + '_VOLUME_MOUNTPOINT=/fixture/' + owner.lower())
        for field in ('CMD', 'ENTRYPOINT', 'HEALTHCHECK', 'PUBLIC_KEY'):
            rows.append('HSM_INIT_' + owner + '_' + field + '_SHA256=' + 'a'*64)
    custody.write_text('\n'.join(rows) + '\n')
    return testnet, binpath


def boot_services(stack, profiles):
    testnet, binpath = stack
    env = {k:v for k,v in os.environ.items() if not k.startswith('WRFCOIN_')}
    env.update(COMPOSE_PROFILES=profiles, PATH=str(binpath)+os.pathsep+os.environ['PATH'])
    env['WRFCOIN_BOOT_HEAL_HSM_CUSTODY_CONFIG'] = str(testnet/'synthetic-custody.conf')
    result = subprocess.run(['bash', str(testnet/'boot-heal.sh'), '--print-reconcile-services'],
                            env=env, capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    return set(result.stdout.splitlines())


@pytest.mark.parametrize('profiles', ['', 'full', 'seed', 'oracle-reference'])
def test_watcher_default_off_in_actual_boot_selection(stack, profiles):
    selected = boot_services(stack, profiles)
    assert 'wrfcoin-node' in selected and 'alert-receiver' in selected
    assert 'container-health-watch' not in selected


@pytest.mark.parametrize('profiles', ['container-health-watch', 'full,container-health-watch'])
def test_watcher_explicit_profile_in_actual_boot_selection(stack, profiles):
    selected = boot_services(stack, profiles)
    assert {'wrfcoin-node', 'alert-receiver', 'container-health-watch'} <= selected


def test_overlay_preserves_health_delivery_and_restrictions():
    import yaml
    service = yaml.safe_load((ROOT/'testnet/docker-compose.container-health-watch.yml').read_text())[
        'services']['container-health-watch']
    assert service['profiles'] == ['container-health-watch']
    assert service['depends_on']['alert-receiver']['condition'] == 'service_healthy'
    assert service['volumes'] == ['/var/run/docker.sock:/var/run/docker.sock:ro']
    assert service['read_only'] is True and service['cap_drop'] == ['ALL']
    assert service['environment']['ALERT_RECEIVER_URL'].endswith('http://wrfcoin-alert-receiver:19093/alerts}')
