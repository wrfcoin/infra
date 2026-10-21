"""Public-CI source policy and independent negative controls; no runner access."""
import copy
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
PR_EVENTS = {'pull_request', 'pull_request_target', 'issue_comment', 'workflow_run', 'workflow_call'}
GUARD = "github.event_name == 'push' || github.event_name == 'workflow_dispatch'"
PRIVATE_GUARD = "github.event.repository.private && (" + GUARD + ")"


def check(workflow):
    events = workflow.get('on', workflow.get(True, {}))
    assert isinstance(events, dict)
    assert workflow.get('permissions') == {'contents': 'read'}
    for job in workflow['jobs'].values():
        runner = job.get('runs-on')
        if PR_EVENTS.intersection(events):
            assert runner == 'ubuntu-latest'
        if runner != 'ubuntu-latest':
            assert isinstance(runner, list) and 'self-hosted' in runner
            assert set(events) <= {'push', 'workflow_dispatch'}
            assert events.get('push', {}).get('branches') == ['main']
            assert job.get('if') in (GUARD, PRIVATE_GUARD)


class PublicRunnerPolicy(unittest.TestCase):
    def test_all_workflows(self):
        for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
            with self.subTest(workflow=path.name):
                check(yaml.safe_load(path.read_text()))

    def test_required_contexts_are_substantive_hosted_jobs(self):
        scripts = yaml.safe_load((ROOT / '.github/workflows/scripts-tests.yml').read_text())
        self.assertEqual(scripts['jobs']['scripts-tests']['name'], 'scripts/tests suites')
        self.assertEqual(scripts['jobs']['scripts-tests']['if'], 'always()')
        self.assertIn('python3 scripts/ci-suites.py run --profile hosted --kind python', str(scripts['jobs']['scripts-tests-worker']['steps']))
        self.assertIn('python3 scripts/ci-suites.py run --profile hosted --kind shell', str(scripts['jobs']['scripts-tests-worker']['steps']))
        self.assertNotIn('find scripts/tests', str(scripts['jobs']['scripts-tests-worker']['steps']))
        dependabot = yaml.safe_load((ROOT / '.github/workflows/dependabot-coverage.yml').read_text())
        self.assertEqual(dependabot['jobs']['dependabot-coverage']['runs-on'], 'ubuntu-latest')

    def test_mutations_rejected(self):
        base = {'on': {'push': {'branches': ['main']}, 'workflow_dispatch': {}},
                'permissions': {'contents': 'read'},
                'jobs': {'build': {'runs-on': ['self-hosted', 'synthetic'], 'if': GUARD}}}
        check(base)
        private = copy.deepcopy(base)
        private['jobs']['build']['if'] = PRIVATE_GUARD
        check(private)
        for mutation in ['pr', 'comment', 'workflow_run', 'schedule', 'branch', 'guard', 'write']:
            altered = copy.deepcopy(base)
            if mutation in ['pr', 'comment', 'workflow_run', 'schedule']:
                key = {'pr': 'pull_request', 'comment': 'issue_comment'}.get(mutation, mutation)
                altered['on'][key] = {}
            elif mutation == 'branch': altered['on']['push']['branches'] = ['**']
            elif mutation == 'guard': altered['jobs']['build']['if'] = 'always()'
            else: altered['permissions']['contents'] = 'write'
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError): check(altered)
        for guard in ("github.event.repository.private", PRIVATE_GUARD + " || github.event_name == 'pull_request'"):
            private['jobs']['build']['if'] = guard
            with self.subTest(private_guard=guard), self.assertRaises(AssertionError): check(private)


if __name__ == '__main__':
    unittest.main(verbosity=2)
