"""Execute the shipped health command across Linux's 15-byte process comm boundary."""
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).parents[2]


def health_command(name, comm_path):
    compose = yaml.safe_load((ROOT / 'testnet/docker-compose.oracle-attester.yml').read_text())
    service = compose['services']['oracle-attester']
    declared = Path(service['command'][0]).name
    # Model a rename in both command and declared health name. Compose turns $$ into $.
    return service['healthcheck']['test'][1].replace(declared, name).replace('$$', '$').replace(
        '/proc/1/comm', str(comm_path))


@pytest.mark.parametrize('name', ['oracle_atteste', 'oracle_attester',
                                 'oracle_attester2', 'oracle_attester_renamed'])
def test_declared_binary_matches_its_kernel_comm_prefix(tmp_path, name):
    comm = tmp_path / 'comm'
    comm.write_bytes(name.encode()[:15] + b'\n')
    result = subprocess.run(['sh', '-c', health_command(name, comm)], capture_output=True)
    assert result.returncode == 0, (name, result.stderr)


def test_unrelated_process_is_unhealthy(tmp_path):
    comm = tmp_path / 'comm'; comm.write_text('other_process\n')
    assert subprocess.run(['sh', '-c', health_command('oracle_attester_renamed', comm)],
                          capture_output=True).returncode != 0


def test_missing_proc_comm_is_unhealthy(tmp_path):
    assert subprocess.run(['sh', '-c', health_command('oracle_attester', tmp_path / 'missing')],
                          capture_output=True).returncode != 0
