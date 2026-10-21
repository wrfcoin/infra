"""Run newcomer configuration with synthetic files; never install or start nodes."""
import os
from pathlib import Path
import subprocess
import shutil

import pytest

ROOT = Path(__file__).resolve().parents[2]


def shell(script, tmp_path, inherited='71'):
    return subprocess.run(['bash', '-eu', '-c', script, 'test', str(tmp_path)],
                          cwd=tmp_path, capture_output=True, text=True,
                          env={**os.environ, 'WRFCOIN_MIN_WORK_FACTOR': inherited})


@pytest.mark.parametrize('persisted', ['', 'WRFCOIN_MIN_WORK_FACTOR=\n',
                                      'WRFCOIN_MIN_WORK_FACTOR=93\n',
                                      'WRFCOIN_MIN_WORK_FACTOR=0\n'])
@pytest.mark.parametrize('inherited', ['', '71'])
def test_direct_sync_join_persists_and_exports_zero(tmp_path, persisted, inherited):
    env_file = tmp_path / '.env'
    env_file.write_text('UNRELATED=keep\n' + persisted)
    source = (ROOT / 'testnet/join-testnet-sync-node.sh').read_text()
    # Execute the real persistence helper and configuration, before any P2P or
    # snapshot operation. This also covers invoking the sync script directly.
    config = source[source.index('set_env() {'):source.index('operator_external_addr=')]
    script = ('BOOTSTRAP_PEERS=synthetic\nWRFCOIN_CUT_NETWORK_ID=testnet\n'
              'WRFCOIN_CUT_CHAIN_ID=888\nTESTNET_GENESIS_HASH=synthetic\n' + config +
              '\nbash -c \'test "$WRFCOIN_MIN_WORK_FACTOR" = 0\'\n')
    result = shell(script, tmp_path, inherited)
    assert result.returncode == 0, result.stdout + result.stderr
    assert env_file.read_text().splitlines().count('WRFCOIN_MIN_WORK_FACTOR=0') == 1
    assert 'UNRELATED=keep' in env_file.read_text()


def installer_functions():
    source = (ROOT / 'scripts/operator-install.sh').read_text()
    definitions, entrypoint = source.rsplit('\nmain "$@"', 1)
    assert not entrypoint.strip()
    return definitions + '\nTESTNET_DIR="$1"\n'


@pytest.mark.parametrize('persisted', ['', 'WRFCOIN_MIN_WORK_FACTOR=\n',
                                      'WRFCOIN_MIN_WORK_FACTOR=93\n',
                                      'WRFCOIN_MIN_WORK_FACTOR=0\n'])
@pytest.mark.parametrize('inherited', ['', '71'])
def test_operator_install_pins_existing_env_and_compose(tmp_path, persisted, inherited):
    env_file = tmp_path / '.env'
    env_file.write_text('UNRELATED=keep\n' + persisted)
    # Only call configuration/build/start functions; Docker is a fail-closed
    # PATH stub that checks its inherited environment and records both calls.
    docker = tmp_path / 'docker'
    docker.write_text('#!/bin/bash\nset -eu\ntest "$WRFCOIN_MIN_WORK_FACTOR" = 0\n'
                      'test "$1" = compose\nprintf "%s\\n" "$*" >> "$TESTNET_LOG"\n')
    docker.chmod(0o755)
    script = (installer_functions() + '\nexport PATH="$1:$PATH" TESTNET_LOG="$1/docker.log"\n'
              'configure_node_validation\nconfigure_node_validation\n'
              'build_images\nstart_testnet\n')
    result = shell(script, tmp_path, inherited)
    assert result.returncode == 0, result.stdout + result.stderr
    lines = env_file.read_text().splitlines()
    assert lines.count('WRFCOIN_MIN_WORK_FACTOR=0') == 1
    assert 'UNRELATED=keep' in lines
    calls = (tmp_path / 'docker.log').read_text().splitlines()
    assert len(calls) == 2
    assert calls[0].endswith('build --parallel') and calls[1].endswith('up -d')


def test_operator_configuration_dry_run_is_read_only(tmp_path):
    env_file = tmp_path / '.env'
    env_file.write_text('UNRELATED=keep\nWRFCOIN_MIN_WORK_FACTOR=93\n')
    before = env_file.read_bytes()
    result = shell(installer_functions() + '\nDRY_RUN=true\nconfigure_node_validation\n', tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert env_file.read_bytes() == before
    assert 'WRFCOIN_MIN_WORK_FACTOR=0' in result.stdout


def test_installer_entrypoint_configures_before_start(tmp_path):
    script = installer_functions() + '''
check_os() { :; }
install_deps() { :; }
install_docker() { :; }
clone_repos() { :; }
detect_hardware() { :; }
generate_secrets() { :; }
verify_health() { :; }
build_images() { bash -c 'test "$WRFCOIN_MIN_WORK_FACTOR" = 0'; }
start_testnet() { grep -qx WRFCOIN_MIN_WORK_FACTOR=0 "$TESTNET_DIR/.env"; }
main --install-dir "$1"
'''
    # parse_args derives <install-dir>/infra/testnet, so provide that layout.
    testnet = tmp_path / 'infra/testnet'
    testnet.mkdir(parents=True)
    (testnet / 'scripts').mkdir()
    shutil.copyfile(ROOT / 'testnet/scripts/chain-identity.py', testnet / 'scripts/chain-identity.py')
    (testnet / 'cut-pins.env').write_text('WRFCOIN_CUT_CHAIN_ID=777\n')
    (testnet / '.env').write_text('WRFCOIN_MIN_WORK_FACTOR=93\n')
    result = shell(script, tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
