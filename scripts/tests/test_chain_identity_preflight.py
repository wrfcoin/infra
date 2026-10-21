"""Exercise the real steady-state preflight with synthetic files; no host calls."""
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
CHECK = Path(os.environ.get('CHAIN_PREFLIGHT_SCRIPT', ROOT / 'testnet/check-env-completeness.sh'))
HELPER = ROOT / 'testnet/scripts/chain-identity.py'


def run_gate(tmp_path, pin, host='', exported=None):
    pins = tmp_path / 'pins.env'
    pins.write_text('WRFCOIN_CUT_CHAIN_ID=' + pin + '\n')
    env_file = tmp_path / 'host.env'
    env_file.write_text(host)
    compose = tmp_path / 'compose.yml'
    compose.write_text('services: {}\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('WRFCOIN_')}
    env.update(exported or {})
    return subprocess.run(['bash', str(CHECK), '-f', str(compose), '--env', str(env_file),
                           '--cut-pins', str(pins)], env=env, capture_output=True, text=True)


@pytest.mark.parametrize('host', ['', 'WRFCOIN_CHAIN_ID=\n', 'WRFCOIN_CHAIN_ID=777\n'])
def test_new_cut_refuses_stale_host_in_steady_state(tmp_path, host):
    result = run_gate(tmp_path, '888', host)
    assert result.returncode == 1
    assert 'persisted WRFCOIN_CHAIN_ID differs from cut pins' in result.stderr


@pytest.mark.parametrize('host', ['', 'WRFCOIN_CHAIN_ID=\n', 'WRFCOIN_CHAIN_ID=777\n'])
def test_legacy_defaults_are_unchanged(tmp_path, host):
    result = run_gate(tmp_path, '777', host)
    assert result.returncode == 0, result.stdout + result.stderr


def test_explicit_new_chain_passes_and_governance_cannot_lag(tmp_path):
    good = 'WRFCOIN_CHAIN_ID=888\nWRFCOIN_GOVERNANCE_CHAIN_ID=888\n'
    assert run_gate(tmp_path, '888', good).returncode == 0
    stale = good.replace('WRFCOIN_GOVERNANCE_CHAIN_ID=888', 'WRFCOIN_GOVERNANCE_CHAIN_ID=777')
    assert run_gate(tmp_path, '888', stale).returncode == 1
    assert run_gate(tmp_path, '888', good, {'WRFCOIN_GOVERNANCE_CHAIN_ID': '777'}).returncode == 1
    assert run_gate(tmp_path, '888', good, {'WRFCOIN_CHAIN_ID': '777'}).returncode == 1
    # Exporting the new value must not conceal a stale persisted file.
    assert run_gate(tmp_path, '888', '', {'WRFCOIN_CHAIN_ID': '888'}).returncode == 1


@pytest.mark.parametrize('pin', ['', '<pending>', '888\nWRFCOIN_CUT_CHAIN_ID=777'])
def test_missing_malformed_duplicate_pin_refused(tmp_path, pin):
    assert run_gate(tmp_path, pin).returncode == 1


def test_generator_identity_from_active_pins(tmp_path):
    pins = tmp_path / 'pins.env'
    pins.write_text('WRFCOIN_CUT_CHAIN_ID=888\n')
    env = {k: v for k, v in os.environ.items() if k != 'WRFCOIN_CHAIN_ID'}
    args = ['python3', str(HELPER), '--pins', str(pins), '--print-chain']
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    assert result.returncode == 0 and result.stdout == '888\n'
    result = subprocess.run(args, env={**env, 'WRFCOIN_CHAIN_ID': '777'}, capture_output=True, text=True)
    assert result.returncode == 1
