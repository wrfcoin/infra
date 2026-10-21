"""Cutter-only zero expectation; no daemon, node binary, HSM or live file access."""
import json
import os
from pathlib import Path
import subprocess

import pytest
from test_chain_configuration import render, BOOTSTRAP_888
from test_node_bootstrap import configure, pins

ROOT = Path(__file__).resolve().parents[2]
ZERO = '0' * 64


def guard(tmp_path, **values):
    # Execute exactly the shipped bootstrap prefix, stopping before HSM setup.
    source = (ROOT / 'infra/docker/hsm-entrypoint.sh').read_text().split('\nHSM_DIR=', 1)[0]
    script = source + '\nprintf "%s\\n" "${WRFCOIN_GENESIS_HASH:-unset}"\n'
    env = {key: value for key, value in os.environ.items() if not key.startswith('WRFCOIN_')}
    env.update(WRFCOIN_CHAIN_ID='888', WRFCOIN_NETWORK_ID='testnet',
               WRFCOIN_DATA_DIR=str(tmp_path / 'data'))
    env.update(values)
    return subprocess.run(['sh', '-eu', '-c', script], cwd=tmp_path, env=env,
                          text=True, capture_output=True)


@pytest.mark.parametrize('hash_value', ['', ZERO, '0x' + ZERO])
@pytest.mark.parametrize('sync', ['0', '1'])
def test_normal_888_node_and_joiner_refuse_unbound_hash(tmp_path, hash_value, sync):
    result = guard(tmp_path, WRFCOIN_GENESIS_HASH=hash_value, WRFCOIN_SYNC_ONLY=sync)
    assert result.returncode == 1 and 'genesis' in result.stderr.lower()


@pytest.mark.parametrize('hash_value', ['', ZERO, '0x' + ZERO])
def test_only_explicit_empty_cutter_can_have_no_expectation(tmp_path, hash_value):
    result = guard(tmp_path, WRFCOIN_GENESIS_HASH=hash_value, WRFCOIN_CUTTER_PREGENESIS='1')
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == ZERO


@pytest.mark.parametrize('change', ['sync', 'existing-db', 'real-hash', 'wrong-chain', 'wrong-network'])
def test_cutter_mode_refuses_non_cutter_or_post_genesis_use(tmp_path, change):
    values = dict(WRFCOIN_GENESIS_HASH=ZERO, WRFCOIN_CUTTER_PREGENESIS='1')
    if change == 'sync':
        values['WRFCOIN_SYNC_ONLY'] = '1'
    elif change == 'existing-db':
        (tmp_path / 'data').mkdir()
        (tmp_path / 'data/wrfcoin.redb').touch()
    elif change == 'real-hash':
        values['WRFCOIN_GENESIS_HASH'] = 'a' * 64
    elif change == 'wrong-chain':
        values['WRFCOIN_CHAIN_ID'] = '777'
    else:
        values['WRFCOIN_NETWORK_ID'] = 'mainnet'
    assert guard(tmp_path, **values).returncode == 1


def test_pinned_888_and_legacy_777_startup_are_retained(tmp_path):
    assert guard(tmp_path, WRFCOIN_GENESIS_HASH='a' * 64).returncode == 0
    assert guard(tmp_path, WRFCOIN_CHAIN_ID='777').returncode == 0


def test_normal_compose_does_not_forward_an_inherited_cutter_flag(tmp_path):
    result = render('888', extra={**BOOTSTRAP_888, 'WRFCOIN_GENESIS_HASH': ZERO,
                                 'WRFCOIN_CUTTER_PREGENESIS': '1'})
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    for name in ['wrfcoin-node', 'wrfcoin-seed']:
        env = services[name]['environment']
        assert 'WRFCOIN_CUTTER_PREGENESIS' not in env
        assert guard(tmp_path, **env).returncode == 1


@pytest.mark.parametrize('hash_value', [ZERO, '0x' + ZERO])
def test_normal_pin_loader_refuses_zero_even_with_cutter_flag(tmp_path, hash_value, monkeypatch):
    path = pins(tmp_path)
    path.write_text(path.read_text().replace("WRFCOIN_CUT_GENESIS_HASH='" + 'a' * 64 + "'",
                                             "WRFCOIN_CUT_GENESIS_HASH='" + hash_value + "'"))
    monkeypatch.setenv('WRFCOIN_CUTTER_PREGENESIS', '1')
    result = configure(tmp_path, path)
    assert result.returncode == 1 and 'hash' in result.stderr.lower()
    assert (tmp_path / '.env').read_text() == 'UNRELATED=keep\n'


def cutter_render(hash_value=None):
    inputs = dict(BOOTSTRAP_888)
    inputs['WRFCOIN_CHAIN_ID'] = '888'
    if hash_value is None:
        inputs.pop('WRFCOIN_GENESIS_HASH')
    else:
        inputs['WRFCOIN_GENESIS_HASH'] = hash_value
    paths = [ROOT / 'testnet' / name for name in ['docker-compose.testnet.yml',
             'docker-compose.genesis.yml', 'docker-compose.cutter-pregenesis.yml']]
    return render('888', paths, inputs)


@pytest.mark.parametrize('hash_value', [None, '', ZERO])
def test_pre_cut_render_and_shipped_node_guard_without_hash(tmp_path, hash_value):
    result = cutter_render(hash_value)
    assert result.returncode == 0, result.stderr
    services = json.loads(result.stdout)['services']
    env = services['wrfcoin-node']['environment']
    assert env['WRFCOIN_GENESIS_HASH'] == ZERO
    assert env['WRFCOIN_CUTTER_PREGENESIS'] == '1'
    # The actual shipped prefix must accept exactly this rendered environment.
    assert guard(tmp_path, **env).returncode == 0
    seed = services['wrfcoin-seed']
    denied = subprocess.run(seed['entrypoint'], text=True, capture_output=True)
    assert denied.returncode == 1 and 'cutter' in denied.stderr.lower()
