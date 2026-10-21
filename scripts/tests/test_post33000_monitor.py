"""Configuration admission for the optional observer; real evaluator is the shell gate."""
import json
from pathlib import Path
import subprocess

import yaml

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = ROOT / 'infra/monitoring/post33000'


def test_jobs_are_distinct_bounded_existing_metrics():
    config = yaml.safe_load((BUNDLE / 'prometheus.yml').read_text())
    assert config['global']['scrape_interval'] == '90s'
    jobs = config['scrape_configs']
    assert {j['job_name'] for j in jobs} == {'post33000-' + n for n in ('ws', 'mango', 'n5', 'faucet')}
    assert len({j['static_configs'][0]['targets'][0] for j in jobs}) == 4
    assert all(j['bearer_token_file'] == '/run/secrets/reader-token' for j in jobs)
    assert config['rule_files'] == ['/etc/prometheus/alerts.yml']


def test_actual_compose_default_is_off_and_explicit_profile_admits(tmp_path):
    overlay = ROOT / 'testnet/docker-compose.post33000-monitor.yml'
    for profiles, included in [([], False), (['--profile', 'post33000-monitor'], True)]:
        # config only; intentionally dead daemon and no credential/env file read.
        result = subprocess.run(['docker', '--host', 'unix:///nonexistent/post33000-test.sock',
            'compose', '--env-file', '/dev/null', '-f', str(overlay), *profiles, 'config', '--format', 'json'],
            capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stderr
        service = json.loads(result.stdout)['services'].get('post33000-prometheus')
        if not included:
            assert service is None
        else:
            assert service['profiles'] == ['post33000-monitor']
            assert service['pull_policy'] == 'never' and service['network_mode'] == 'host'
            assert '--web.listen-address=127.0.0.1:9097' in service['command']
            assert not service.get('depends_on') and service['read_only'] is True
            assert not any('docker.sock' in v.get('source', '') for v in service['volumes'])


def test_rules_have_real_boundary_fixture_inventory():
    rules = yaml.safe_load((BUNDLE / 'alerts.yml').read_text())['groups'][0]['rules']
    assert {r['alert'] for r in rules} == {
        'FaucetNetFundingStalled', 'ThreeNodeTipsDiverged', 'Post33000ObservationUnavailable'}
    cases = yaml.safe_load((BUNDLE / 'alerts.test.yml').read_text())['tests']
    assert len(cases) >= 12
    assert {'N exactly20', 'N only19', 'spread20allowed', 'spread21critical', 'beforeE0f', 'missing node',
        'total outage allfour upzero', 'total outage allfour absent after15m'} <= {
        t['name'] for t in cases}
