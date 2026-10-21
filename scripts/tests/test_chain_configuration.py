"""Render-only chain propagation and hermetic fresh-chain join controls."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ['docker-compose.testnet.yml', 'docker-compose.override.yml',
         'docker-compose.block-heartbeat.yml', 'docker-compose.oracle-attester.yml']
BOOTSTRAP_888 = {'WRFCOIN_GENESIS_HASH': 'a' * 64,
                 'WRFCOIN_GENESIS_ACTIVATION_SCHEDULE': '0:v1,2:schedule_extension',
                 'WRFCOIN_GENESIS_PRODUCER_SET': '{"version":1,"members":[{"producer_id":"synthetic","payout_address":"0x' + '1' * 40 + '","public_key":"' + '2' * 64 + '"}]}'}


def render(chain, files=None, extra=None, env_file='/dev/null'):
    paths = files or [ROOT / 'testnet' / name for name in FILES]
    env = {'PATH': os.environ['PATH'], 'HOME': os.environ['HOME'], 'WRFCOIN_CHAIN_ID': chain}
    for path in paths:
        for key in re.findall(r'\$\{([A-Z0-9_]+):\?', path.read_text()):
            env[key] = 'synthetic-render-only'
    env.update(WRFCOIN_P2P_EXTERNAL_ADDR='/ip4/192.0.2.1/tcp/9000',
               WRFCOIN_SEED_P2P_EXTERNAL_ADDR='/ip4/192.0.2.2/tcp/9000')
    env.update(extra or {})
    args = ['docker', 'compose', '--env-file', str(env_file), '--project-name', 'chain-test',
            '--project-directory', str(ROOT / 'testnet'), '--profile', '*']
    for path in paths:
        args += ['-f', str(path)]
    return subprocess.run(args + ['config', '--format', 'json'], env=env,
                          capture_output=True, text=True)


class ChainConfiguration(unittest.TestCase):
    def test_testnet_validation_floor_is_explicit_on_both_nodes(self):
        for chain in ['777', '888']:
            for extra in [{}, {'WRFCOIN_MIN_WORK_FACTOR': '0'}]:
                if chain == '888':
                    extra = {**BOOTSTRAP_888, **extra}
                result = render(chain, extra=extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                services = json.loads(result.stdout)['services']
                for name in ['wrfcoin-node', 'wrfcoin-seed']:
                    self.assertEqual(services[name]['environment']['WRFCOIN_MIN_WORK_FACTOR'], '0')

    def test_all_consumers_receive_same_chain(self):
        for chain in ['777', '888']:
            result = render(chain, extra=BOOTSTRAP_888 if chain == '888' else {})
            self.assertEqual(result.returncode, 0, result.stderr)
            services = json.loads(result.stdout)['services']
            counts = {'WRFCOIN_CHAIN_ID': 0, 'PAYMASTER_CHAIN_ID': 0}
            for service in services.values():
                for key in counts:
                    if key in service.get('environment', {}):
                        self.assertEqual(service['environment'][key], chain)
                        counts[key] += 1
                args = service.get('build', {}).get('args', {})
                if 'VITE_WRFCOIN_CHAIN_ID' in args:
                    self.assertEqual(args['VITE_WRFCOIN_CHAIN_ID'], chain)
            self.assertEqual(counts['PAYMASTER_CHAIN_ID'], 8)
            self.assertGreaterEqual(counts['WRFCOIN_CHAIN_ID'], 10)

    def test_genesis_overlay_forwards_and_requires_declarations(self):
        paths = [ROOT / 'testnet' / FILES[0], ROOT / 'testnet/docker-compose.genesis.yml']
        inputs = dict(WRFCOIN_CHAIN_ID='888', WRFCOIN_SIGNING_PROTOCOL_VERSION='1',
                      WRFCOIN_GENESIS_HASH='a' * 64,
                      WRFCOIN_GENESIS_ACTIVATION_SCHEDULE='0:v1,2:schedule_extension,2:reward_gross_outlier_guard,2:weather_skew_block_time_allowance,2:station_active_reward_gate,2:station_owner_actions,2:station_owner_consent,2:station_registration_nonce,2:node_share_settlement',
                      WRFCOIN_GENESIS_PRODUCER_SET='synthetic-producer',
                      WRFCOIN_GENESIS_ORACLE_SET='synthetic-oracle',
                      WRFCOIN_GENESIS_FAUCET_ADDRESS='0x' + '1' * 40,
                      WRFCOIN_GENESIS_FLAT_REWARD_SECONDS='600',
                      WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS='123',
                      WRFCOIN_GENESIS_FAUCET_ALLOCATION_BASE_UNITS='123',
                      WRFCOIN_GENESIS_SCHEDULE_GOVERNANCE_KEYS='2' * 64,
                      WRFCOIN_GENESIS_NODE_SHARE_EPOCH_BLOCKS='512',
                      WRFCOIN_GENESIS_NODE_SHARE_CHALLENGE_BLOCKS='512')
        result = render('888', paths, inputs)
        self.assertEqual(result.returncode, 0, result.stderr)
        for service in ['wrfcoin-node', 'wrfcoin-seed']:
            env = json.loads(result.stdout)['services'][service]['environment']
            for key, value in inputs.items():
                self.assertEqual(env[key], value)
        for key in inputs:
            result = render('888', paths, {**inputs, key: ''})
            self.assertNotEqual(result.returncode, 0, key)

    def test_fresh_join_policy_runs_actual_branch_without_hosts(self):
        source = (ROOT / 'testnet/join-testnet-sync-node.sh').read_text()
        start = source.index('if ! "${DOCKER_BIN}" volume inspect')
        end = source.index('\nelse\n  if ! jsr_volume_has_durable_state', start)
        branch = source[start:end] + '\nfi\n'
        for chain, allow, expected in [('777', '0', 1), ('777', '1', 0), ('888', '0', 0)]:
            script = ('set -eu\nDOCKER_BIN=false\nnode_data_volume=synthetic\n'
                      'SNAPSHOT_SOURCE=\n' + f'WRFCOIN_CUT_CHAIN_ID={chain}\nALLOW_FULL_SYNC={allow}\n' + branch)
            result = subprocess.run(['bash', '-c', script], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stderr)
            if chain == '888':
                self.assertIn('syncing from genesis', result.stdout)

    def test_inactive_template_matches_owner_parameters(self):
        text = (ROOT / 'testnet/cut-pins.888.env.example').read_text()
        values = dict(line.split('=', 1) for line in text.splitlines() if line and not line.startswith('#'))
        for key, value in {'WRFCOIN_CHAIN_ID': '888', 'WRFCOIN_SIGNING_PROTOCOL_VERSION': '1',
                           'WRFCOIN_GENESIS_FLAT_REWARD_SECONDS': '600',
                           'WRFCOIN_GENESIS_FAUCET_ALLOCATION_BASE_UNITS': '10000000000000',
                           'WRFCOIN_GENESIS_NODE_SHARE_EPOCH_BLOCKS': '512',
                           'WRFCOIN_GENESIS_NODE_SHARE_CHALLENGE_BLOCKS': '512'}.items():
            self.assertEqual(values[key], value)
        entries = values['WRFCOIN_GENESIS_ACTIVATION_SCHEDULE'].split(',')
        self.assertEqual(entries.pop(0), '0:v1')
        self.assertEqual({entry.split(':')[1] for entry in entries}, {
            'schedule_extension', 'reward_gross_outlier_guard', 'weather_skew_block_time_allowance',
            'station_active_reward_gate', 'station_owner_actions', 'station_owner_consent',
            'station_registration_nonce', 'node_share_settlement'})
        self.assertTrue(all(2 <= int(entry.split(':')[0]) <= 100 for entry in entries))
        self.assertEqual(values['WRFCOIN_GENESIS_FLAT_REWARD_BASE_UNITS'], '2222222222')
        self.assertIn('<GENESIS_HASH_AFTER_CUT>', values['WRFCOIN_CUT_GENESIS_HASH'])

    def test_mobile_artifact_binds_configured_chain(self):
        # Import only: no CLI, Docker, private files, or submissions.
        script = '''import importlib.util
s = importlib.util.spec_from_file_location('activation', %r)
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
assert m.CHAIN_ID == '888'
''' % str(ROOT / 'testnet/scripts/activate-mobile-stations.py')
        result = subprocess.run(['python3', '-c', script], env={**os.environ, 'WRFCOIN_CHAIN_ID': '888'}, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
