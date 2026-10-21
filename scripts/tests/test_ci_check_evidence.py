"""Real API snapshots and production CLI controls; GitHub transport is synthetic."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / 'ci-check-evidence.py'
SPEC = importlib.util.spec_from_file_location('ci_check_evidence', SCRIPT)
ci = importlib.util.module_from_spec(SPEC)
if SCRIPT.exists():
    SPEC.loader.exec_module(ci)
FIXTURES = Path(__file__).parent / 'fixtures' / 'ci-evidence'


def fixture(name='infra1239-pass'):
    return json.loads((FIXTURES / (name + '.json')).read_text())


class SyntheticGitHub:
    def __init__(self, data):
        self.data = data
        self.calls = []
        self.refresh = None
        self.pull_reads = 0

    def api(self, endpoint):
        self.calls.append(endpoint)
        d = self.data
        if '/pulls/' in endpoint:
            self.pull_reads += 1
            return copy.deepcopy(self.refresh if self.pull_reads > 1 and self.refresh else d['pr'])
        if '/check-runs?' in endpoint:
            return {'total_count': 1, 'check_runs': [copy.deepcopy(d['check'])]}
        if '/actions/jobs/' in endpoint:
            return copy.deepcopy(d['job'])
        if '/git/commits/' in endpoint:
            return {'sha': d['checkout_sha'], 'parents': [{'sha': s} for s in d['parents']]}
        raise AssertionError(endpoint)

    def checkout(self, repo, job):
        return self.data['checkout_sha']


@unittest.skipUnless(SCRIPT.exists(), 'baseline lacks the required CLI')
class CheckEvidence(unittest.TestCase):
    def classify(self, d, relevant=True):
        return ci.classify(d['check'], d['job'], d['pr'], relevant,
                           d['checkout_sha'], d['parents'])

    def test_real_snapshots(self):
        for name, want, steps in [('sp-runnerless', 'VOID', 0),
                                 ('core3450-stale', 'VOID', 10),
                                 ('infra1239-pass', 'REAL-GREEN', 18)]:
            with self.subTest(name=name):
                d = fixture(name); row = self.classify(d)
                self.assertEqual(row['class'], want)
                self.assertEqual(row['executed_steps'], steps)
        self.assertEqual(self.classify(fixture('sp-runnerless'))['reason'], 'missing runner identity')
        self.assertEqual(self.classify(fixture('core3450-stale'))['reason'], 'stale head')

    def test_null_empty_whitespace_numeric_runner(self):
        for runner in [None, '', ' ', 123]:
            with self.subTest(runner=runner):
                d = fixture(); d['job']['runner_name'] = runner
                self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_relevance_requires_reviewer(self):
        self.assertEqual(self.classify(fixture(), False)['class'], 'VOID')

    def test_same_head_stale_merge_base(self):
        d = fixture(); d['parents'][0] = 'b' * 40
        self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_actual_stale_merge_ref_with_historical_head(self):
        d = fixture('core3450-stale')
        # Pin the historical head: the real materialized merge still has the OLD base.
        d['pr']['head']['sha'] = d['check']['head_sha']
        self.assertEqual(self.classify(d)['class'], 'VOID')
        self.assertEqual(self.classify(d)['reason'], 'missing/stale materialized checkout identity')

    def test_missing_checkout(self):
        d = fixture(); d['checkout_sha'] = None
        self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_explicit_head_checkout(self):
        d = fixture(); d['checkout_sha'] = d['pr']['head']['sha']; d['parents'] = []
        self.assertEqual(self.classify(d)['class'], 'REAL-GREEN')

    def test_zero_unexecuted_or_provider_only_steps(self):
        for steps in [[], None, [{'name': 'Test', 'status': 'completed', 'conclusion': 'success'}],
                      [fixture()['job']['steps'][0]]]:
            with self.subTest(steps=steps):
                d = fixture(); d['job']['steps'] = steps
                self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_incomplete_cancelled_skipped(self):
        for status, conclusion in [('queued', None), ('in_progress', None),
                                   ('completed', 'cancelled'), ('completed', 'skipped')]:
            with self.subTest(status=status, conclusion=conclusion):
                d = fixture()
                for obj in (d['check'], d['job']): obj.update(status=status, conclusion=conclusion)
                self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_failure_and_masked_step_failure_are_red(self):
        d = fixture()
        d['job']['steps'][3]['conclusion'] = 'failure'
        self.assertEqual(self.classify(d)['class'], 'REAL-RED')
        d['check']['conclusion'] = d['job']['conclusion'] = 'failure'
        self.assertEqual(self.classify(d)['class'], 'REAL-RED')

    def test_wrapper_only_success(self):
        d = fixture(); d['check']['name'] = 'Secret Scanning summary'
        self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_check_job_disagreement(self):
        d = fixture(); d['job']['conclusion'] = 'failure'
        self.assertEqual(self.classify(d)['class'], 'VOID')

    def test_101_checks_are_exhaustive(self):
        def api(endpoint):
            self.assertIn('per_page=100', endpoint)
            start = 0 if endpoint.endswith('page=1') else 100
            return {'total_count': 101, 'check_runs': [{'id': i} for i in range(start, min(101, start + 100))]}
        self.assertEqual(len(ci.all_checks(api, 'wrfcoin/infra', 'a' * 40)), 101)

    def test_truncation_duplicate_counts_and_missing_pages(self):
        for response in [{'total_count': 101, 'check_runs': [{'id': 1}]},
                         {'total_count': 2, 'check_runs': [{'id': 1}, {'id': 1}]},
                         {'total_count': True, 'check_runs': []},
                         {'check_runs': []}, {'total_count': 0, 'check_runs': [{'id': 1}]}]:
            with self.subTest(response=response), self.assertRaises(ci.Unavailable):
                ci.all_checks(lambda _: response, 'wrfcoin/infra', 'a' * 40)
        def changed(endpoint):
            return {'total_count': 101 if endpoint.endswith('page=1') else 102,
                    'check_runs': [{'id': i} for i in range(100)]}
        with self.assertRaises(ci.Unavailable): ci.all_checks(changed, 'wrfcoin/infra', 'a' * 40)

    def test_inspect_complete_and_head_base_races(self):
        d = fixture(); name = d['check']['name']
        result = ci.inspect(SyntheticGitHub(d), 'wrfcoin/infra', 1239, {name})
        self.assertTrue(result['admissible_checks']); self.assertEqual(len(result['checks']), 1)
        for key in ['head', 'base']:
            with self.subTest(key=key), self.assertRaises(ci.Unavailable):
                g = SyntheticGitHub(d); g.refresh = copy.deepcopy(d['pr']); g.refresh[key]['sha'] = 'b' * 40
                ci.inspect(g, 'wrfcoin/infra', 1239, {name})

    def test_job_binding_refuses(self):
        d = fixture(); d['job']['check_run_url'] = 'https://api.github.com/repos/wrfcoin/infra/check-runs/1'
        with self.assertRaises(ci.Unavailable): ci.inspect(SyntheticGitHub(d), 'wrfcoin/infra', 1239, set())

    def test_absent_relevant_context_no_admission(self):
        self.assertFalse(ci.inspect(SyntheticGitHub(fixture()), 'wrfcoin/infra', 1239, {'missing'})['admissible_checks'])

    def test_api_two_failures_unknown(self):
        with patch.object(ci.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'gh')) as run:
            with self.assertRaises(ci.Unavailable): ci.GitHub().api('repos/wrfcoin/infra')
        self.assertEqual(run.call_count, 2)

    def test_actual_cli_and_checkout_prefix(self):
        d = fixture(); name = d['check']['name']
        with tempfile.TemporaryDirectory(prefix='soln-ci-cli-') as tmp:
            path = Path(tmp); data = path/'data.json'; data.write_text(json.dumps(d))
            gh = path/'gh'; gh.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
x=json.load(open(os.environ['SYNTHETIC_CI_DATA'])); e=sys.argv[2]
if e.endswith('/logs'):
 if os.environ.get('LATE_CHECKOUT'): print('x'*270000)
 print("2026-10-03T00:00:00Z [command]/usr/bin/git log -1 --format=%H\\n2026-10-03T00:00:00Z "+x['checkout_sha'])
elif '/pulls/' in e: print(json.dumps(x['pr']))
elif '/check-runs?' in e: print(json.dumps({'total_count':1,'check_runs':[x['check']]}))
elif '/actions/jobs/' in e: print(json.dumps(x['job']))
elif '/git/commits/' in e: print(json.dumps({'sha':x['checkout_sha'],'parents':[{'sha':s}for s in x['parents']]}))
else: sys.exit(99)
'''); gh.chmod(0o700)
            env = {**os.environ, 'PATH': str(path)+':'+os.environ['PATH'], 'SYNTHETIC_CI_DATA':str(data)}
            args = [sys.executable, str(SCRIPT), 'infra', '1239', '--json']
            r = subprocess.run(args, env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, r.stderr); self.assertEqual(json.loads(r.stdout)['checks'][0]['class'], 'VOID')
            r = subprocess.run(args+['--relevant-check', name], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr); self.assertEqual(json.loads(r.stdout)['checks'][0]['executed_steps'], 18)
            env['LATE_CHECKOUT'] = '1'
            r = subprocess.run(args+['--relevant-check', name], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2); self.assertEqual(json.loads(r.stdout)['checks'][0]['class'], 'VOID')


class BaselinePresence(unittest.TestCase):
    def test_detector_exists(self):
        self.assertTrue(SCRIPT.exists(), 'main has no PR-head runner/step detector')
