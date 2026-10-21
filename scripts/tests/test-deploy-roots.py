#!/usr/bin/env python3
"""Portable root and systemd rendering controls, with synthetic paths only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeployRoots(unittest.TestCase):
    def test_compose_precedence(self):
        # Exercise the exact compose expressions, without pulling images or
        # opening a Docker socket. The minimal model needs no service secrets.
        import yaml
        class Loader(yaml.SafeLoader):
            pass
        Loader.add_constructor('!reset', lambda loader, node: loader.construct_sequence(node))
        models = [yaml.load((ROOT / 'testnet' / f'docker-compose.{name}.yml').read_text(), Loader=Loader)
                  for name in ('testnet', 'override', 'block-heartbeat', 'oracle-attester')]
        expressions = []
        for model in models:
            for service in model['services'].values():
                context = service.get('build', {}).get('context') if isinstance(service.get('build'), dict) else None
                if context and 'WRFCOIN_DEPLOY_ROOT' in context:
                    expressions.append(context)
                expressions += [v.split(':/')[0] for v in service.get('volumes', [])
                                if isinstance(v, str) and 'WRFCOIN_DEPLOY_ROOT' in v]
        # Require every extracted nested expression to remain complete.
        self.assertTrue(all(x.count('${') == x.count('}') for x in expressions))
        self.assertTrue(expressions)
        for expr in set(expressions):
            with tempfile.TemporaryDirectory() as td:
                p = Path(td) / 'compose.yml'
                p.write_text('services:\n  test:\n    image: scratch\n    build:\n      context: ' + expr + '\n')
                env = dict(os.environ, WRFCOIN_DEPLOY_ROOT='/srv/render/deploy')
                env.pop('WRFCOIN_ROOT', None)
                cmd = ['docker', 'compose', '--env-file', '/dev/null', '-f', str(p), 'config', '--format', 'json']
                import json
                data = json.loads(subprocess.check_output(cmd, env=env))
                self.assertTrue(data['services']['test']['build']['context'].startswith('/srv/render/deploy'))
                env['WRFCOIN_ROOT'] = '/srv/render/legacy'
                if 'WRFCOIN_ROOT' in expr:
                    data = json.loads(subprocess.check_output(cmd, env=env))
                    self.assertTrue(data['services']['test']['build']['context'].startswith('/srv/render/legacy'))

    def test_systemd_render_and_reject(self):
        script = ROOT / 'testnet/scripts/render-systemd-units.py'
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / 'units'
            env = dict(os.environ, WRFCOIN_DEPLOY_ROOT='/srv/render/deploy')
            subprocess.run(['python3', str(script), '--output-dir', str(out)], env=env, check=True)
            for file in out.iterdir():
                expected = (ROOT / 'testnet/systemd' / file.name).read_text().replace('@WRFCOIN_DEPLOY_ROOT@', '/srv/render/deploy')
                self.assertEqual(file.read_text(), expected)
            for root in ('', 'relative', '/srv/%h', '/srv/a b', '/path/to/wrfcoin-deploy', '/'):
                env['WRFCOIN_DEPLOY_ROOT'] = root
                result = subprocess.run(['python3', str(script), '--output-dir', str(Path(td) / 'bad')], env=env, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((Path(td) / 'bad').exists())

    def test_bootstrap_env_roots(self):
        text = (ROOT / 'testnet/bootstrap.sh').read_text()
        function = text.split('ensure_workspace_dockerignore() {', 1)[1].split('\n}\n', 1)[0]
        with tempfile.TemporaryDirectory() as td:
            d = Path(td); testnet = d / 'testnet'; testnet.mkdir()
            (testnet / 'workspace.dockerignore').write_text('fixture\n')
            src = d / 'source'; src.mkdir()
            (testnet / '.env').write_text(f'WRFCOIN_SRC_ROOT="{src}"\n')
            env = {k: v for k, v in os.environ.items() if k not in ('WRFCOIN_ROOT', 'WRFCOIN_SRC_ROOT', 'WRFCOIN_DEPLOY_ROOT')}
            code = 'log() { :; }; err() { echo "$*" >&2; }; run() { "$@"; }; SCRIPT_DIR="$1"; DRY_RUN=false; ensure_workspace_dockerignore() {' + function + '\n}; ensure_workspace_dockerignore'
            subprocess.run(['bash', '-eu', '-c', code, '_', str(testnet)], env=env, check=True)
            self.assertEqual((src / '.dockerignore').read_text(), 'fixture\n')
            deploy = d / 'deploy'; deploy.mkdir()
            (testnet / '.env').write_text(f'WRFCOIN_DEPLOY_ROOT="{deploy}"\nWRFCOIN_ROOT=${{WRFCOIN_DEPLOY_ROOT}}\n')
            subprocess.run(['bash', '-eu', '-c', code, '_', str(testnet)], env=env, check=True)
            self.assertEqual((deploy / '.dockerignore').read_text(), 'fixture\n')
            legacy = d / 'legacy'; legacy.mkdir()
            env['WRFCOIN_ROOT'] = str(legacy)
            subprocess.run(['bash', '-eu', '-c', code, '_', str(testnet)], env=env, check=True)
            self.assertEqual((legacy / '.dockerignore').read_text(), 'fixture\n')


if __name__ == '__main__':
    unittest.main()
