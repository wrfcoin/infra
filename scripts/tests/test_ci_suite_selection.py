"""Suite-policy refusal controls; subprocesses are explicit test doubles."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('ci_suites', ROOT / 'scripts/ci-suites.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


class SuiteSelection(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.manifest = json.loads((ROOT / '.github/ci/scripts-test-suites.json').read_text())
        for profile in ('hosted', 'private'):
            for rows in self.manifest[profile].values():
                for row in rows:
                    path = self.root / row['path']
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('# synthetic fixture; never executed\n')
        self.env = patch.dict(os.environ, {'GITHUB_STEP_SUMMARY': str(self.root / 'summary')})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_actual_inventory_and_private_input_routes(self):
        gate.inventory(ROOT, self.manifest)
        hosted = {x['path'] for rows in self.manifest['hosted'].values() for x in rows}
        private = {x['path'] for rows in self.manifest['private'].values() for x in rows}
        self.assertFalse(hosted & private)
        for path in ('test_testnet_ipfs_profile.py', 'test_weather_archive_profile.py',
                     'test-block-heartbeat-compose.sh', 'test-upgrade-notice-overlays.sh'):
            self.assertIn('scripts/tests/' + path, hosted)
        for path in ('test_node_dashboard.py', 'test-real-cli-smoke.sh', 'test-real-cli-activation.sh'):
            self.assertIn('scripts/tests/' + path, private)

    def test_new_unclassified_suite_refuses_before_execution(self):
        (self.root / 'scripts/tests/test-unreviewed.sh').write_text('exit 0\n')
        with self.assertRaisesRegex(ValueError, 'unclassified'):
            gate.selected(self.root, self.manifest, 'hosted', 'shell')

    def test_unsafe_path_refuses(self):
        self.manifest['hosted']['python'][0]['path'] = 'scripts/tests/../../outside.py'
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            gate.inventory(self.root, self.manifest)

    def test_live_default_helper_cannot_be_promoted_to_suite(self):
        self.manifest['hosted']['shell'][0]['path'] = 'scripts/tests/verify-dev-runtime.sh'
        with self.assertRaisesRegex(ValueError, 'unsafe'):
            gate.inventory(self.root, self.manifest)

    def test_missing_selected_module_refuses(self):
        (self.root / self.manifest['hosted']['python'][0]['path']).unlink()
        with self.assertRaisesRegex(ValueError, 'missing hosted'):
            gate.selected(self.root, self.manifest, 'hosted', 'python')

    def test_duplicate_routes_refuse(self):
        self.manifest['private']['shell'].append(copy.deepcopy(self.manifest['hosted']['shell'][0]))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            gate.inventory(self.root, self.manifest)

    def test_empty_selected_group_refuses(self):
        self.manifest['hosted']['python'] = []
        with self.assertRaisesRegex(ValueError, 'empty'):
            gate.selected(self.root, self.manifest, 'hosted', 'python')

    def test_symlink_suite_refuses(self):
        path = self.root / self.manifest['hosted']['python'][0]['path']
        path.unlink()
        path.symlink_to('/dev/null')
        with self.assertRaisesRegex(ValueError, 'regular file'):
            gate.inventory(self.root, self.manifest)

    def test_public_snapshot_can_omit_private_sources_but_private_run_cannot(self):
        for rows in self.manifest['private'].values():
            for row in rows:
                (self.root / row['path']).unlink()
        gate.selected(self.root, self.manifest, 'hosted', 'python')
        with self.assertRaisesRegex(ValueError, 'unavailable'):
            gate.selected(self.root, self.manifest, 'private', 'shell')

    def test_pytest_receives_whole_explicit_hosted_modules(self):
        with patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as execute:
            self.assertEqual(gate.run(self.root, self.manifest, 'hosted', 'python'), 0)
        selected = [x['path'] for x in self.manifest['hosted']['python']]
        self.assertEqual(len(execute.call_args_list), 2)
        self.assertEqual(execute.call_args_list[0].args[0][5:], selected)
        self.assertEqual(execute.call_args_list[1].args[0][4:], selected)
        self.assertTrue(all('*' not in path and '::' not in path for path in selected))

    def test_pytest_empty_collection_blocks_execution(self):
        with patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 5)) as execute:
            self.assertEqual(gate.run(self.root, self.manifest, 'hosted', 'python'), 5)
            self.assertEqual(execute.call_count, 1)

    def test_pytest_failure_is_returned(self):
        results = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1)]
        with patch.object(gate.subprocess, 'run', side_effect=results):
            self.assertEqual(gate.run(self.root, self.manifest, 'hosted', 'python'), 1)

    def test_shell_failure_does_not_hide_remaining_suites_or_pass(self):
        count = len(self.manifest['hosted']['shell'])
        results = [subprocess.CompletedProcess([], 1)] + [subprocess.CompletedProcess([], 0)] * (count - 1)
        with patch.object(gate.subprocess, 'run', side_effect=results) as execute:
            self.assertEqual(gate.run(self.root, self.manifest, 'hosted', 'shell'), 1)
            self.assertEqual(execute.call_count, len(self.manifest['hosted']['shell']))

    def test_private_missing_cli_exit77_is_not_success(self):
        with patch.object(gate.subprocess, 'run', return_value=subprocess.CompletedProcess([], 77)):
            self.assertEqual(gate.run(self.root, self.manifest, 'private', 'shell'), 1)

    def test_new_unverified_exemption_refuses(self):
        self.manifest['hosted']['shell'][0]['allow_unverified'] = True
        with self.assertRaisesRegex(ValueError, 'only the existing external'):
            gate.inventory(self.root, self.manifest)

    def test_timeout_is_fatal(self):
        with patch.object(gate.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 600)):
            self.assertEqual(gate.run(self.root, self.manifest, 'hosted', 'shell'), 1)


if __name__ == '__main__':
    unittest.main()
