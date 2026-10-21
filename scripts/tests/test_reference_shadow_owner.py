"""Actual owner CLI with Docker doubles; no host/container/DB contacts."""
import importlib.util
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).parents[2]
SCRIPT = Path(os.environ.get('SHADOW_SCRIPT', ROOT / 'scripts/check-reference-shadow.py'))
DOUBLE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv[1:]; root=pathlib.Path(os.environ['DOUBLE_ROOT'])
scenario=json.loads((root/'scenario.json').read_text())
with (root/'calls.jsonl').open('a') as f: f.write(json.dumps(a)+'\\n')
mode=(root/'mode').read_text(); on='docker-compose.reference-shadow.yml' in ' '.join(a)
service=a[-1]; backend='b'*12; oracle='a'*12
if scenario.get('command_fail'): sys.exit(2)
if a[:2]==['compose','-f']:
 if 'config' in a:
  if '--services' in a: print('wrfcoin-backend' if scenario.get('absent_sidecar') else 'wrfcoin-backend\\noracle-reference')
  elif '--hash' in a: print(service+' '+('f' if scenario.get('hash_drift') else 'b' if on else 'c')*64)
  elif '--images' in a:
   # Real Compose (5.1.x, as on CT101) also lists the named service's DEPENDENCIES' images.
   print('example/'+service+':cached'+('\\npostgres:15-alpine\\nexample/oracle-reference:cached' if service=='wrfcoin-backend' else ''))
  elif a[-2:]==['--format','json']:
   assert '--no-interpolate' in a and '--no-env-resolution' in a  # never render secret values
   print(json.dumps({'services':{'wrfcoin-backend':{'image':'example/wrfcoin-backend:cached'},
    'oracle-reference':{'image':'example/oracle-reference:cached'},'postgres':{'image':'postgres:15-alpine'}}}))
  else: sys.exit(3)
 elif 'ps' in a: print('' if scenario.get('absent_container') else backend if service=='wrfcoin-backend' else oracle)
 elif 'up' in a:
  assert '--no-deps' in a and '--no-build' in a and a[a.index('--pull')+1]=='never'
  assert a[-2:]==['oracle-reference','wrfcoin-backend']
  (root/'mode').write_text('1')
 else: sys.exit(4)
elif a[:2]==['image','inspect']:
 print('sha256:'+('f' if scenario.get('wrong_cache') else '2' if 'wrfcoin-backend' in service else '1')*64)
elif a[0]=='inspect':
 template=a[2]
 if 'State.Status' in template: print('exited unhealthy' if scenario.get('unhealthy') else 'running healthy')
 elif template=='{{.Image}}': print('sha256:'+('f' if scenario.get('wrong_running') else '2' if service==backend else '1')*64)
 elif 'config-hash' in template: print(('f' if scenario.get('wrong_hash') else 'b' if mode=='1' else 'c')*64)
 else: sys.exit(5)
elif a[:2]==['exec','--workdir']:
 assert a[2:4]==['/app/backend','-i']
 code=sys.stdin.read()
 with (root/'node.jsonl').open('a') as f: f.write(json.dumps(code)+'\\n')
 if 'createRequire' not in code:
  print(json.dumps(scenario.get('runtime',{'shadow':scenario.get('flag',mode)})))
 else:
  assert 'BEGIN READ ONLY' in code and "statement_timeout='5s'" in code
  assert 'INSERT ' not in code and 'UPDATE ' not in code and 'DELETE ' not in code
  if 'max(id)' in code: print(json.dumps({'max_id':10,'count':7,'since':'2026-10-02 21:00:00+00:00'}))
  else:
   assert 's.id > $1' in code and "c.status='revealed'" in code
   assert 's.station_id=c.station_id' in code and 's.scored_at >= $2' in code
   assert 's.bands_version=$3' in code and 'jsonb_array_elements' in code
   print(json.dumps(scenario.get('result',{'total':'2','valid':'2','good':'1','degraded':'1','outlier':'0'})))
else: sys.exit(6)
'''

# Child-local clock only: realtime adjustments must not make a fresh fixture
# receipt appear to be from the future. Production still uses its real clock.
FIXTURE_NOW = '2026-10-02T21:00:00+00:00'
CLOCK_CLI = '''import datetime as dt, importlib.util, sys, types
script = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location('shadow_fixture_cli', script)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
class Clock(dt.datetime):
 @classmethod
 def now(cls, tz=None):
  value = cls.fromisoformat(%r)
  return value.astimezone(tz) if tz is not None else value.replace(tzinfo=None)
module.dt = types.SimpleNamespace(datetime=Clock, timezone=dt.timezone)
sys.exit(module.main())
''' % FIXTURE_NOW


@pytest.fixture
def owner(tmp_path):
    launcher = tmp_path / 'clock_cli.py'
    launcher.write_text(CLOCK_CLI)
    # The owner shell wrappers use python3; Docker's Python double delegates
    # unchanged to the real interpreter, avoiding any recursive launcher.
    python = tmp_path / 'python3'
    python.write_text('#!/bin/sh\nif [ "$1" = ' + repr(str(SCRIPT)) + ' ]; then\n'
                      'exec ' + repr(sys.executable) + ' ' + repr(str(launcher)) + ' "$@"\nfi\n'
                      'exec ' + repr(sys.executable) + ' "$@"\n')
    python.chmod(0o755)
    docker = tmp_path / 'docker'
    docker.write_text(DOUBLE)
    docker.chmod(0o755)
    (tmp_path / 'mode').write_text('0')
    (tmp_path / 'scenario.json').write_text('{}')
    base = tmp_path / 'base.yml'
    base.write_text('services: {}')
    overlay = ROOT / 'testnet/docker-compose.reference-shadow.yml'
    cfg = tmp_path / 'config.json'
    cfg.write_text(json.dumps({'compose_files': [str(base), str(overlay)], 'image_ids': {
        'oracle-reference': 'sha256:' + '1' * 64, 'wrfcoin-backend': 'sha256:' + '2' * 64}}))
    cfg.chmod(0o600)
    return tmp_path


def call(owner, phase, **scenario):
    (owner / 'scenario.json').write_text(json.dumps(scenario))
    env = {**os.environ, 'DOUBLE_ROOT': str(owner), 'PATH': str(owner) + ':' + os.environ['PATH']}
    return subprocess.run([sys.executable, str(owner / 'clock_cli.py'), str(SCRIPT), phase,
        '--config', str(owner / 'config.json'),
        '--receipt', str(owner / 'receipt.json'), '--evidence', str(owner / 'evidence.json')],
        text=True, capture_output=True, env=env, timeout=15)


def prepared(owner):
    result = call(owner, 'prepare')
    assert result.returncode == 0, result.stderr


def enabled(owner):
    prepared(owner)
    result = call(owner, 'enable')
    assert result.returncode == 0, result.stderr


def test_prepare_reads_table_and_keeps_flag_off(owner):
    prepared(owner)
    assert (owner / 'mode').read_text() == '0'
    receipt = json.loads((owner / 'receipt.json').read_text())
    assert receipt['baseline']['max_id'] == 10
    assert (owner / 'receipt.json').stat().st_mode & 0o777 == 0o600
    assert not (owner / 'evidence.json').exists()


def test_enable_only_two_services_no_build_or_pull(owner):
    enabled(owner)
    calls = [json.loads(x) for x in (owner / 'calls.jsonl').read_text().splitlines()]
    ups = [x for x in calls if 'up' in x]
    assert len(ups) == 1
    assert ups[0][-2:] == ['oracle-reference', 'wrfcoin-backend']
    assert '--wait' in ups[0] and '--no-deps' in ups[0] and '--no-build' in ups[0]
    assert not (owner / 'evidence.json').exists()


def test_record_new_durable_rows_with_private_aggregate_only(owner):
    enabled(owner)
    result = call(owner, 'record')
    assert result.returncode == 0, result.stderr
    data = (owner / 'evidence.json').read_text()
    assert json.loads(data)['counts']['total'] == 2
    assert 'station_id' not in data and 'latitude' not in data and 'residuals' not in data
    assert (owner / 'evidence.json').stat().st_mode & 0o777 == 0o600
    codes = [json.loads(x) for x in (owner / 'node.jsonl').read_text().splitlines()]
    assert any('s.id > $1' in x and '[10,' in x for x in codes)


@pytest.mark.parametrize('scenario', [
    {'absent_sidecar': True}, {'wrong_cache': True}, {'absent_container': True},
    {'unhealthy': True}, {'wrong_running': True}, {'wrong_hash': True},
    {'command_fail': True}, {'runtime': []}, {'runtime': {'shadow': True}}, {'flag': '1'},
])
def test_prepare_stops_on_unreviewed_or_unavailable_inputs(owner, scenario):
    result = call(owner, 'prepare', **scenario)
    assert result.returncode == 1 and 'STOP:' in result.stderr
    assert not (owner / 'receipt.json').exists()
    assert (owner / 'mode').read_text() == '0'


@pytest.mark.parametrize('change', ['mode', 'image', 'missing', 'overlay_order', 'overlay_bytes', 'symlink'])
def test_private_owner_config_required(owner, change):
    cfg = owner / 'config.json'
    data = json.loads(cfg.read_text())
    if change == 'mode': cfg.chmod(0o644)
    elif change == 'symlink':
        cfg.rename(owner / 'real.json')
        cfg.symlink_to(owner / 'real.json')
    else:
        if change == 'image': data['image_ids']['wrfcoin-backend'] = 'latest'
        elif change == 'missing': data['compose_files'][0] = '/missing/compose.yml'
        elif change == 'overlay_order': data['compose_files'].reverse()
        else:
            overlay = owner / 'docker-compose.reference-shadow.yml'
            overlay.write_text('services: {wrfcoin-backend: {environment: {REFERENCE_SHADOW: "1", ENFORCE: "1"}}}')
            data['compose_files'][-1] = str(overlay)
        cfg.write_text(json.dumps(data))
    assert call(owner, 'prepare').returncode == 1
    assert not (owner / 'receipt.json').exists()


def test_prepare_never_replaces_baseline(owner):
    prepared(owner)
    original = (owner / 'receipt.json').read_bytes()
    assert call(owner, 'prepare').returncode == 1
    assert (owner / 'receipt.json').read_bytes() == original


@pytest.mark.parametrize('change', ['missing_receipt', 'expired', 'config', 'render'])
def test_enable_requires_unchanged_fresh_prepare(owner, change):
    if change != 'missing_receipt': prepared(owner)
    if change == 'expired':
        path = owner / 'receipt.json'
        data = json.loads(path.read_text())
        data['prepared'] = '2000-01-01T00:00:00+00:00'
        path.write_text(json.dumps(data))
    elif change == 'config':
        with (owner / 'config.json').open('a') as out: out.write('\n')
    result = call(owner, 'enable', **({'hash_drift': True} if change == 'render' else {}))
    assert result.returncode == 1
    assert (owner / 'mode').read_text() == '0'


@pytest.mark.parametrize('age,allowed', [(0, True), (1800, True), (1801, False), (-1, False)])
def test_child_clock_keeps_exact_receipt_age_boundaries(owner, age, allowed):
    prepared(owner)
    path = owner / 'receipt.json'
    data = json.loads(path.read_text())
    assert data['prepared'] == FIXTURE_NOW
    data['prepared'] = (dt.datetime.fromisoformat(FIXTURE_NOW) - dt.timedelta(seconds=age)).isoformat()
    path.write_text(json.dumps(data))
    result = call(owner, 'enable')
    assert (result.returncode == 0) is allowed
    assert (owner / 'mode').read_text() == ('1' if allowed else '0')


@pytest.mark.parametrize('scenario', [
    {'flag': '0'}, {'runtime': []}, {'runtime': {'shadow': True}}, {'wrong_hash': True},
    {'wrong_running': True}, {'unhealthy': True}, {'absent_sidecar': True},
    {'result': {'total': '0', 'valid': '0', 'good': '0', 'degraded': '0', 'outlier': '0'}},
    {'result': {'total': '2', 'valid': '1', 'good': '1', 'degraded': '1', 'outlier': '0'}},
    {'result': {'total': '2', 'valid': '2', 'good': '0', 'degraded': '0', 'outlier': '0'}},
    {'result': {'total': 'NaN', 'valid': '2', 'good': '1', 'degraded': '1', 'outlier': '0'}},
])
def test_record_never_claims_success_without_valid_new_rows(owner, scenario):
    enabled(owner)
    result = call(owner, 'record', **scenario)
    assert result.returncode == 1
    assert 'PASS' not in result.stdout and not (owner / 'evidence.json').exists()


def test_evidence_is_append_only(owner):
    enabled(owner)
    assert call(owner, 'record').returncode == 0
    original = (owner / 'evidence.json').read_bytes()
    assert call(owner, 'record').returncode == 1
    assert (owner / 'evidence.json').read_bytes() == original


def image_layout(owner, image):
    dockerfile = ROOT / f'infra/docker/Dockerfile.{image}'
    runtime = dockerfile.read_text().split(' AS runtime\n', 1)[1]
    workdir = next(line.split()[1] for line in runtime.splitlines() if line.startswith('WORKDIR '))
    assert workdir == '/app/backend'
    backend = owner / 'image' / workdir.lstrip('/')
    backend.mkdir(parents=True)
    if image == 'backend':
        assert 'COPY --from=builder /app/backend/dist ./dist/' in runtime
        assert 'COPY --from=pruner /app/keep ./node_modules/' in runtime
        assert 'COPY --from=builder /app/backend/package.json ./' in runtime
        assert "printf '%s\\n' dotenv drizzle-kit drizzle-orm pg" in dockerfile.read_text()
        assert 'server/enhanced_unified_api_optimized.ts:dist/server.cjs' in (ROOT / 'infra/docker/esbuild-backend.sh').read_text()
        (backend / 'dist').mkdir()
        (backend / 'dist/server.cjs').write_text("throw Error('must not start the API during a probe');")
    else:
        assert 'COPY --from=deps /app/backend/node_modules ./node_modules/' in runtime
        assert 'COPY backend/ ./' in runtime
        (backend / 'server').mkdir()
        (backend / 'server/enhanced_unified_api_optimized.ts').write_text("throw Error('must not start the API during a probe');")
    (backend / 'package.json').write_text('{}')
    return backend, workdir


def probe_module():
    spec = importlib.util.spec_from_file_location('shadow_owner', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize('image', ['backend', 'backend-api'])
def test_node_database_transport_enforces_read_only(owner, image):
    module = probe_module()
    backend, _ = image_layout(owner, image)
    pg = backend / 'node_modules/pg'
    pg.mkdir(parents=True)
    (pg / 'index.js').write_text('''
exports.Client=class {
 constructor(options){if(options.query_timeout!==5000||options.connectionTimeoutMillis!==3000)throw Error();this.calls=[];}
 async connect(){}
 async query(sql,params){this.calls.push(sql);
  if(this.calls.length===1 && sql!=='BEGIN READ ONLY')throw Error('write transaction');
  if(this.calls.length===2 && !sql.includes('statement_timeout'))throw Error('unbounded query');
  if(this.calls.length===3){if(!sql.startsWith('SELECT ')||params[0]!==10||params[2]!==3||!sql.includes('s.bands_version=$3'))throw Error('bad SQL');
   return {rows:[{total:'1',valid:'1',good:'1',degraded:'0',outlier:'0'}]};}
 }
 async end(){if(this.calls.length!==3)throw Error();}
};
''')
    code = module.database_code(module.SQL_RECORD, [10, '2026-10-02T21:00:00Z', 3])
    result = subprocess.run(['node', '--input-type=module'], input=code, cwd=backend,
                            text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)['valid'] == '1'


@pytest.mark.parametrize('image', ['backend', 'backend-api'])
def test_runtime_probe_works_in_shipped_layout_without_starting_server(owner, image):
    module = probe_module()
    backend, _ = image_layout(owner, image)
    result = subprocess.run(['node', '--input-type=module'], input=module.RUNTIME, cwd=backend,
                            env={**os.environ, 'REFERENCE_SHADOW': '1'},
                            text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {'shadow': '1'}


def test_docker_exec_uses_workdir_produced_by_both_dockerfiles(owner, monkeypatch):
    module = probe_module()
    directories = {image_layout(owner / image, image)[1] for image in ('backend', 'backend-api')}
    assert directories == {'/app/backend'}
    calls = []
    monkeypatch.setattr(module, 'run', lambda args, code: calls.append(args) or '{"shadow":"1"}')
    assert module.node('b' * 12, module.RUNTIME) == {'shadow': '1'}
    assert calls == [['docker', 'exec', '--workdir', '/app/backend', '-i', 'b' * 12,
                      'node', '--input-type=module']]


def test_owner_wrappers_execute_actual_three_steps(owner):
    env = {**os.environ, 'DOUBLE_ROOT': str(owner), 'PATH': str(owner) + ':' + os.environ['PATH']}
    for name in ('01-prepare', '02-enable', '03-record'):
        args = ['bash', str(ROOT / f'testnet/owner-steps/reference-shadow/{name}.sh'),
                str(owner / 'config.json'), str(owner / 'receipt.json')]
        if name == '03-record': args.append(str(owner / 'evidence.json'))
        result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=15)
        assert result.returncode == 0, result.stderr
    assert json.loads((owner / 'evidence.json').read_text())['counts']['valid'] == 2


@pytest.mark.skipif(subprocess.run(['docker', 'compose', 'version'], capture_output=True).returncode != 0,
                    reason='real Docker Compose not available')
def test_real_compose_images_include_dependencies_and_model_render_is_secret_free(tmp_path):
    # Pins the double above to real Compose: `config --images <service>` lists the service's
    # dependencies too (live STOP on CT101, 2026-10-06), and the model render the checker uses
    # instead yields the service's own image without any interpolated or env-file secret.
    (tmp_path / '.env').write_text('SHADOW_TEST_SECRET=interpolated-secret\n')
    (tmp_path / 'svc.env').write_text('SHADOW_TEST_FILE_SECRET=env-file-secret\n')
    (tmp_path / 'c.yml').write_text(
        'services:\n'
        '  db: {image: "postgres:15-alpine"}\n'
        '  wrfcoin-backend: {image: "example/backend:cached", depends_on: [db],\n'
        '    environment: {A: "${SHADOW_TEST_SECRET}"}, env_file: [svc.env]}\n')
    base = ['docker', 'compose', '-f', str(tmp_path / 'c.yml')]
    images = subprocess.run(base + ['config', '--images', 'wrfcoin-backend'], capture_output=True,
                            text=True, check=True, cwd=tmp_path).stdout.split()
    assert sorted(images) == ['example/backend:cached', 'postgres:15-alpine']
    out = subprocess.run(base + ['config', '--no-interpolate', '--no-env-resolution', '--format', 'json'],
                         capture_output=True, text=True, check=True, cwd=tmp_path).stdout
    assert json.loads(out)['services']['wrfcoin-backend']['image'] == 'example/backend:cached'
    assert 'interpolated-secret' not in out and 'env-file-secret' not in out
