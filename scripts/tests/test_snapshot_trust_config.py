"""Synthetic cut/daemonless Compose checks: explicit empty or already pinned native trust."""
import json
import os
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
WRITER = ROOT / 'testnet/scripts/render-cut-overlay.sh'
KEY = 'WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS'
PIN = '12' * 32


def render(tmp_path, trust, seed=None):
    pins = tmp_path / 'pins.env'
    pins.write_text('WRFCOIN_CUT_GENESIS_HASH=' + '34' * 32 + '\n' +
        ('' if trust is None else 'WRFCOIN_CUT_SNAPSHOT_TRUSTED_SIGNERS=' + trust + '\n') +
        ('' if seed is None else 'WRFCOIN_CUT_INCLUDE_SEED=' + seed + '\n'))
    overlay = tmp_path / 'cut.yml'
    result = subprocess.run(['bash', str(WRITER), '--pins', str(pins), '--out', str(overlay)],
        capture_output=True, text=True, timeout=10)
    return pins, overlay, result


@pytest.mark.parametrize('trust', [None, '', PIN, PIN + ',' + '56' * 32])
@pytest.mark.parametrize('seed', [None, '0', '1'])
def test_renderer_states_trust_for_selected_services(tmp_path, trust, seed):
    pins, overlay, result = render(tmp_path, trust, seed)
    if seed == '1' and not trust:
        assert result.returncode != 0
        assert not overlay.exists() and not Path(str(overlay) + '.custody.json').exists()
        return
    assert result.returncode == 0, result.stderr
    data = yaml.safe_load(overlay.read_text())['services']
    names = ('wrfcoin-node', 'wrfcoin-seed') if seed == '1' else ('wrfcoin-node',)
    assert set(data) == set(names)
    for name in names:
        assert KEY in data[name]['environment']
        assert data[name]['environment'][KEY] == (trust or '')
    assert 'empty trust set' in overlay.read_text()
    assert trust is None or not trust or trust not in result.stdout
    checked = subprocess.run(['bash', str(WRITER), '--pins', str(pins), '--out', str(overlay), '--check'],
        capture_output=True, text=True, timeout=10)
    assert checked.returncode == 0, checked.stderr


@pytest.mark.parametrize('trust', ['not-a-key', PIN + ',', ',' + PIN, PIN + ',,', PIN[:63], PIN + ' ' + PIN])
def test_malformed_trust_refuses_before_output(tmp_path, trust):
    _, overlay, result = render(tmp_path, trust)
    assert result.returncode != 0
    assert not overlay.exists() and not Path(str(overlay) + '.custody.json').exists()


@pytest.mark.parametrize(('trust', 'seed'), [
    (trust, seed) for trust in (None, '', PIN) for seed in (None, '0', '1')
    if seed != '1' or trust
])
def test_actual_compose_merge_cannot_inherit_an_unrelated_shell_signer(tmp_path, trust, seed):
    _, overlay, result = render(tmp_path, trust, seed)
    assert result.returncode == 0
    original = yaml.safe_load((ROOT / 'testnet/docker-compose.testnet.yml').read_text())['services']
    # Reuse the exact production env interpolation, stripping unrelated runtime/services/credentials.
    base = tmp_path / 'base.yml'
    base.write_text(yaml.safe_dump({'services':{n:{'image':'synthetic:fixture', 'environment':{
        KEY:original[n]['environment'][KEY]}} for n in (('wrfcoin-node','wrfcoin-seed') if seed == '1' else ('wrfcoin-node',))}}))
    plugin_dir = Path.home() / '.docker/cli-plugins'
    cfgdir = tmp_path / 'docker-config'; cfgdir.mkdir()
    (cfgdir / 'config.json').write_text(json.dumps({'cliPluginsExtraDirs':[str(plugin_dir)]}))
    env = dict(PATH=os.environ['PATH'], HOME=str(tmp_path), DOCKER_CONFIG=str(cfgdir),
        WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS='78' * 32)
    merged = subprocess.run(['docker','--host','unix:///nonexistent/trust.sock','compose','--env-file','/dev/null',
        '-f',str(base),'-f',str(overlay),'config','--format','json'],env=env,capture_output=True,text=True,timeout=10)
    assert merged.returncode == 0, merged.stderr
    services = json.loads(merged.stdout)['services']
    assert set(services) == ({'wrfcoin-node','wrfcoin-seed'} if seed == '1' else {'wrfcoin-node'})
    assert all(services[n]['environment'][KEY] == (trust or '') for n in services)


def test_base_explicit_empty_fallback_documents_boot_and_ingest():
    text = (ROOT / 'testnet/docker-compose.testnet.yml').read_text()
    data = yaml.safe_load(text)['services']
    assert all(data[n]['environment'][KEY] == '${WRFCOIN_SNAPSHOT_TRUSTED_SIGNERS:-}'
        for n in ('wrfcoin-node', 'wrfcoin-seed'))
    assert text.count('Unset/empty boots with an empty trust set') == 2


@pytest.mark.parametrize('seed', ['yes', '2', '1\nWRFCOIN_CUT_INCLUDE_SEED=0'])
def test_invalid_or_duplicate_seed_selector_refuses(tmp_path, seed):
    _, overlay, result = render(tmp_path, PIN, seed)
    assert result.returncode != 0
    assert not overlay.exists() and not Path(str(overlay) + '.custody.json').exists()


@pytest.mark.parametrize('trust', [None, ''])
def test_optional_seed_without_trust_pin_refuses_before_publication(tmp_path, trust):
    overlay = tmp_path / 'cut.yml'
    custody = Path(str(overlay) + '.custody.json')
    overlay.write_text('retained synthetic overlay\n')
    custody.write_text('retained synthetic custody\n')
    _, _, result = render(tmp_path, trust, '1')
    assert result.returncode != 0
    assert 'seed inclusion requires a nonempty snapshot trust pin' in result.stderr
    assert overlay.read_text() == 'retained synthetic overlay\n'
    assert custody.read_text() == 'retained synthetic custody\n'
