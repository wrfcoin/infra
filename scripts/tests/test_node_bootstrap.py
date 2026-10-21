"""Fresh-node public bootstrap inputs: synthetic pins and Compose renders only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import shutil

import pytest
from test_chain_configuration import render

ROOT = Path(__file__).resolve().parents[2]
HASH = 'a' * 64
SCHEDULE = '0:v1,2:schedule_extension,2:node_share_settlement'
PRODUCERS = json.dumps({'version': 1, 'members': [{'producer_id': 'synthetic',
    'payout_address': '0x' + '1' * 40, 'public_key': '2' * 64}]}, separators=(',', ':'))
INPUTS = {'WRFCOIN_GENESIS_HASH': HASH, 'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE': SCHEDULE,
          'WRFCOIN_GENESIS_PRODUCER_SET': PRODUCERS}


def pins(tmp_path, missing=None, chain='888'):
    path = tmp_path / 'cut-pins.env'
    values = {'WRFCOIN_CUT_CHAIN_ID': chain,
              'WRFCOIN_CUT_GENESIS_HASH': HASH,
              'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE': SCHEDULE,
              'WRFCOIN_GENESIS_PRODUCER_SET': PRODUCERS}
    values.pop(missing, None)
    path.write_text(''.join(f"{key}='{value}'\n" for key, value in values.items()))
    return path


def configure(tmp_path, pinfile):
    env_file = tmp_path / '.env'
    if not env_file.exists():
        env_file.write_text('UNRELATED=keep\n')
    return subprocess.run([sys.executable, str(ROOT / 'testnet/scripts/chain-identity.py'),
        '--pins', str(pinfile), '--bootstrap-env', str(env_file)], capture_output=True, text=True,
        env={**os.environ, **{key: 'stale' for key in INPUTS}})


def test_both_888_services_receive_reviewed_bootstrap():
    result = render('888', extra=INPUTS)
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    for service in ['wrfcoin-node', 'wrfcoin-seed']:
        for key, value in INPUTS.items():
            assert services[service]['environment'].get(key) == value, (service, key)


@pytest.mark.parametrize('missing', list(INPUTS))
@pytest.mark.parametrize('empty', [False, True])
def test_fresh_888_compose_refuses_each_missing_or_empty_input(missing, empty):
    inputs = dict(INPUTS)
    if empty:
        inputs[missing] = ''
    else:
        inputs.pop(missing)
    result = render('888', extra=inputs)
    assert result.returncode != 0, f'fresh 888 render accepted absent {missing}'
    assert missing in result.stderr


def test_cut_pins_overwrite_stale_runtime_inputs(tmp_path):
    result = configure(tmp_path, pins(tmp_path))
    assert result.returncode == 0, result.stderr
    exported = dict(row.split('=', 1) for row in result.stdout.splitlines())
    assert exported == {'WRFCOIN_CHAIN_ID': '888', **INPUTS}
    assert 'UNRELATED=keep' in (tmp_path / '.env').read_text()
    # The real Compose env-file parser must recover the exact inline JSON.
    paths = [ROOT / 'testnet/docker-compose.testnet.yml']
    result = render('888', paths, env_file=tmp_path / '.env')
    assert result.returncode == 0, result.stderr
    actual = json.loads(result.stdout)['services']['wrfcoin-node']['environment']
    assert {key: actual[key] for key in INPUTS} == INPUTS


@pytest.mark.parametrize('key,malformed', [('WRFCOIN_CUT_GENESIS_HASH', '<AFTER_CUT>'),
    ('WRFCOIN_GENESIS_ACTIVATION_SCHEDULE', 'not-a-schedule'),
    ('WRFCOIN_GENESIS_PRODUCER_SET', '<REVIEWED_PRODUCERS>')])
def test_unfilled_or_malformed_pins_refuse_before_env_change(tmp_path, key, malformed):
    path = pins(tmp_path)
    rows = path.read_text().splitlines()
    path.write_text('\n'.join(key + "='" + malformed + "'" if row.startswith(key + '=') else row
                              for row in rows) + '\n')
    result = configure(tmp_path, path)
    assert result.returncode == 1 and key in result.stderr
    assert (tmp_path / '.env').read_text() == 'UNRELATED=keep\n'


@pytest.mark.parametrize('missing', ['WRFCOIN_CUT_GENESIS_HASH',
    'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE', 'WRFCOIN_GENESIS_PRODUCER_SET'])
def test_missing_pin_cannot_be_masked_by_inherited_runtime_value(tmp_path, missing):
    result = configure(tmp_path, pins(tmp_path, missing))
    assert result.returncode == 1
    assert missing in result.stderr
    assert (tmp_path / '.env').read_text() == 'UNRELATED=keep\n'


def test_777_bootstrap_configuration_changes_nothing(tmp_path):
    result = configure(tmp_path, pins(tmp_path, chain='777'))
    assert result.returncode == 0, result.stderr
    assert result.stdout == ''
    assert (tmp_path / '.env').read_text() == 'UNRELATED=keep\n'


@pytest.mark.parametrize('missing', [None, 'WRFCOIN_CUT_GENESIS_HASH',
    'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE', 'WRFCOIN_GENESIS_PRODUCER_SET'])
def test_installer_main_requires_cut_inputs_before_build_and_start(tmp_path, missing):
    testnet = tmp_path / 'infra/testnet'
    (testnet / 'scripts').mkdir(parents=True)
    for name in ['chain-identity.py']:
        shutil.copyfile(ROOT / 'testnet/scripts' / name, testnet / 'scripts' / name)
    pins_file = pins(tmp_path, missing)
    shutil.copyfile(pins_file, testnet / 'cut-pins.env')
    (testnet / '.env').write_text('UNRELATED=keep\n')
    installer = (ROOT / 'scripts/operator-install.sh').read_text().rsplit('\nmain "$@"', 1)[0]
    script = installer + '''
check_os() { :; }
install_deps() { :; }
install_docker() { :; }
clone_repos() { :; }
detect_hardware() { :; }
generate_secrets() { :; }
verify_health() { :; }
build_images() { python3 -c 'import os,json; print(json.dumps({k:v for k,v in os.environ.items() if k.startswith("WRFCOIN_GENESIS_")}))' > "$INSTALL_DIR/build-env.json"; }
start_testnet() { touch "$INSTALL_DIR/started"; }
main --install-dir "$1"
'''
    result = subprocess.run(['bash', '-eu', '-c', script, 'test', str(tmp_path)],
        env={**os.environ, **{key: 'stale' for key in INPUTS}}, capture_output=True, text=True)
    if missing:
        assert result.returncode == 1 and missing in result.stderr
        assert not (tmp_path / 'started').exists()
        assert not (tmp_path / 'build-env.json').exists()
    else:
        assert result.returncode == 0, result.stderr
        assert (tmp_path / 'started').exists()
        actual = json.loads((tmp_path / 'build-env.json').read_text())
        assert {key: actual[key] for key in INPUTS} == INPUTS
