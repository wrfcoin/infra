"""Exercise the real CLI against a temporary git repo; no network or node required."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-node-release-compatibility.py'


class GateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / 'core4'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        self.source = self.repo / 'shared-protocol/src/crypto/protocol_support.rs'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('pub const KNOWN_FEATURES: &[&str] = &["active"]; // "upcoming"\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'old')
        self.old = self.git('rev-parse', 'HEAD')
        self.source.write_text('pub const KNOWN_FEATURES: &[&str] = &["active", "upcoming"];\n')
        self.git('commit', '-qam', 'compatible')
        self.new = self.git('rev-parse', 'HEAD')
        self.schedule = self.root / 'schedule.json'
        self.document = {
            'captured_at': datetime.now(timezone.utc).isoformat(), 'chain_id': '888', 'network_id': 'testnet',
            'upgrade': {'tip_height': 100, 'scheduled': {'truncated': False, 'base_provisional': False,
                'total_entries': 2, 'entries': [{'feature': 'active', 'activation_height': 2},
                                               {'feature': 'upcoming', 'activation_height': 200}]}}}
        self.pins = self.root / 'pins.env'
        self.pins.write_text('WRFCOIN_CUT_CORE4_COMMIT=' + self.new + '\n')

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.repo), *args], text=True, stderr=subprocess.DEVNULL).strip()

    def run_gate(self, *args):
        self.schedule.write_text(json.dumps(self.document))
        r = subprocess.run(['python3', str(SCRIPT), '--core4-repo', str(self.repo), '--schedule', str(self.schedule),
                            '--pins', str(self.pins), *args], capture_output=True, text=True)
        return r.returncode, json.loads(r.stdout or r.stderr)

    def test_default_pin_and_explicit_hardening_ancestry(self):
        code, data = self.run_gate('--required-commit', self.old)
        self.assertEqual(code, 0)
        self.assertEqual(data['requiredCommitsChecked'], 1)
        self.assertEqual(data['runtimeReplay'], 'not-run')
        self.assertEqual(data['evidence'], 'source-preflight-only')

    def test_unsupported_scheduled_feature_is_real_red_even_if_in_comment(self):
        code, data = self.run_gate('--candidate', self.old)
        self.assertEqual(code, 1)
        self.assertIn('upcoming', data['reason'])

    def test_required_fix_missing_is_red(self):
        self.document['upgrade']['scheduled']['entries'].pop()
        self.document['upgrade']['scheduled']['total_entries'] = 1
        self.assertEqual(self.run_gate('--candidate', self.old, '--required-commit', self.new)[0], 1)

    def test_stale_future_and_missing_timezone(self):
        for stamp in [(datetime.now(timezone.utc) - timedelta(days=2)).isoformat(),
                      (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat(), '2026-11-16T00:00:00']:
            self.document['captured_at'] = stamp
            self.assertEqual(self.run_gate()[0], 1)

    def test_incomplete_wrong_identity_and_malformed_schedules(self):
        original = json.loads(json.dumps(self.document))
        mutations = [lambda d: d.update(chain_id='777'), lambda d: d.update(network_id='mainnet'),
                     lambda d: d['upgrade']['scheduled'].update(truncated=True),
                     lambda d: d['upgrade']['scheduled'].update(base_provisional=True),
                     lambda d: d['upgrade']['scheduled'].update(total_entries=3),
                     lambda d: d['upgrade']['scheduled'].update(entries=[]),
                     lambda d: d['upgrade']['scheduled']['entries'][0].update(activation_height=True),
                     lambda d: d['upgrade']['scheduled']['entries'][0].update(feature='upcoming')]
        for mutate in mutations:
            self.document = json.loads(json.dumps(original))
            mutate(self.document)
            self.assertEqual(self.run_gate()[0], 1)

    def test_downloads_drift_is_red_and_matching_entries_pass(self):
        manifest = self.root / 'manifest.json'
        artifacts = [{'id': name, 'commit': self.new, 'repo': 'wrfcoin/core4', 'published': True}
                     for name in ['node-source', 'cli-source']]
        manifest.write_text(json.dumps({'artifacts': artifacts}))
        self.assertEqual(self.run_gate('--downloads-manifest', str(manifest))[0], 0)
        artifacts[1]['commit'] = self.old
        manifest.write_text(json.dumps({'artifacts': artifacts}))
        self.assertEqual(self.run_gate('--downloads-manifest', str(manifest))[0], 1)

    def test_branch_names_and_unreviewed_registry_expressions_fail_closed(self):
        self.assertEqual(self.run_gate('--candidate', 'HEAD')[0], 1)
        self.source.write_text('pub const KNOWN_FEATURES: &[&str] = GENERATED;\n')
        self.git('commit', '-qam', 'unsupported registry format')
        self.assertEqual(self.run_gate('--candidate', self.git('rev-parse', 'HEAD'))[0], 1)


if __name__ == '__main__':
    unittest.main()
