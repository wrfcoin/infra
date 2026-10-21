#!/usr/bin/env python3
"""Owner-only opt-in and aggregate proof for the existing advisory reveal hook."""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

SERVICES = ('oracle-reference', 'wrfcoin-backend')
OVERLAY = 'docker-compose.reference-shadow.yml'
BACKEND_ROOT = '/app/backend'
RUNTIME = """
console.log(JSON.stringify({shadow:process.env.REFERENCE_SHADOW ?? '0'}));
"""
SQL_BASELINE = """SELECT COALESCE(max(id),0)::text AS max_id,
count(*)::text AS count, now()::text AS since FROM reference_scores"""
SQL_RECORD = """SELECT count(*)::text AS total,
count(*) FILTER (WHERE c.status='revealed' AND s.station_id=c.station_id
  AND s.scored_at >= $2::timestamptz AND s.bands_version=$3
  AND s.tier IN ('good','degraded','outlier')
  AND EXISTS (SELECT 1 FROM jsonb_array_elements(s.residuals) r
      WHERE jsonb_typeof(r->'residuals')='object' AND r->'residuals' <> '{}'::jsonb)
)::text AS valid,
count(*) FILTER (WHERE s.tier='good')::text AS good,
count(*) FILTER (WHERE s.tier='degraded')::text AS degraded,
count(*) FILTER (WHERE s.tier='outlier')::text AS outlier
FROM reference_scores s LEFT JOIN weather_commitments c ON c.id=s.commitment_id
WHERE s.id > $1"""


def database_code(query, params):
    # No route call, no migration, no write; transaction enforces the boundary.
    return """
import {createRequire} from 'node:module';
const {Client}=createRequire(process.cwd() + '/package.json')('pg');
const client=new Client({connectionString:process.env.DATABASE_URL,
 connectionTimeoutMillis:3000,query_timeout:5000});
try {
 await client.connect();
 await client.query('BEGIN READ ONLY');
 await client.query("SET LOCAL statement_timeout='5s'");
 const result=await client.query(%s,%s);
 console.log(JSON.stringify(result.rows[0]));
} finally {await client.end();}
""" % (json.dumps(query), json.dumps(params))


def run(args, code=None, timeout=15, limit=16384):
    try:
        result = subprocess.run(args, input=code, text=True, capture_output=True,
                                timeout=timeout, check=True)
    except (OSError, subprocess.SubprocessError):
        raise ValueError('command unavailable or failed; inspect privately') from None
    if len(result.stdout) > limit:
        raise ValueError('oversized command response')
    return result.stdout.strip()


def private_json(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        raise ValueError('owner JSON must be a regular 0600 file')
    if info.st_uid != os.getuid() or info.st_size > 16384:
        raise ValueError('owner JSON ownership/size invalid')
    return json.loads(path.read_text())


def save(path, value):
    # A new receipt per attempt; no previous baseline/evidence can be replaced.
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as out:
        json.dump(value, out, sort_keys=True)
        out.write('\n')
        out.flush()
        os.fsync(out.fileno())


def config(path):
    cfg = private_json(path)
    files = cfg['compose_files']
    if not isinstance(files, list) or not files or len(files) > 16:
        raise ValueError('explicit ordered Compose file set required')
    for name in files:
        if not isinstance(name, str) or not Path(name).is_absolute() or not Path(name).is_file():
            raise ValueError('Compose file must exist at an absolute path')
    if Path(files[-1]).name != OVERLAY or sum(Path(f).name == OVERLAY for f in files) != 1:
        raise ValueError('shadow overlay must occur exactly once, last')
    # Only the shipped, flag-only overlay; no hidden reward/profile edits.
    shipped = Path(__file__).parents[1] / 'testnet' / OVERLAY
    if Path(files[-1]).read_bytes() != shipped.read_bytes():
        raise ValueError('shadow overlay differs from shipped source')
    for service in SERVICES:
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', cfg['image_ids'][service]):
            raise ValueError('expected immutable image IDs required')
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    cmd = ['docker', 'compose']
    for name in files:
        cmd.extend(['-f', name])
    cmd.extend(['--profile', 'oracle-reference'])
    return cfg, cmd, digest


def rendered(cmd, cfg):
    services = run(cmd + ['config', '--services']).splitlines()
    if any(services.count(s) != 1 for s in SERVICES):
        raise ValueError('render lacks exactly one backend and sidecar')
    # `config --images <service>` also prints the service's DEPENDENCIES' images (Compose 5.1), so each
    # service's own image comes from one model render. No interpolation and no env-file resolution:
    # no secret value is ever read; an image that still needs interpolation is refused.
    model = json.loads(run(cmd + ['config', '--no-interpolate', '--no-env-resolution', '--format', 'json'],
                           limit=4 * 1024 * 1024))
    hashes = {}
    for service in SERVICES:
        lines = run(cmd + ['config', '--hash', service]).splitlines()
        if len(lines) != 1 or not re.fullmatch(service + r' [0-9a-f]{64}', lines[0]):
            raise ValueError('invalid effective Compose hash')
        hashes[service] = lines[0].split()[1]
        image = (model.get('services', {}).get(service) or {}).get('image')
        if not isinstance(image, str) or not image or '$' in image:
            raise ValueError('ambiguous rendered image')
        image_id = run(['docker', 'image', 'inspect', '--format', '{{.Id}}', image])
        if image_id != cfg['image_ids'][service]:
            raise ValueError('cached image differs from owner-reviewed ID; no pull/build')
    return hashes


def running(cmd, cfg, hashes, services=SERVICES):
    backend = None
    for service in services:
        ids = run(cmd + ['ps', '-q', service]).splitlines()
        if len(ids) != 1 or not re.fullmatch(r'[0-9a-f]{12,64}', ids[0]):
            raise ValueError('service must have exactly one running container')
        # Selected non-secret metadata only; never read the container environment.
        value = run(['docker', 'inspect', '--format',
            '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}', ids[0]])
        if value != 'running healthy':
            raise ValueError('service is not running healthy')
        image = run(['docker', 'inspect', '--format', '{{.Image}}', ids[0]])
        actual_hash = run(['docker', 'inspect', '--format',
            '{{index .Config.Labels "com.docker.compose.config-hash"}}', ids[0]])
        if image != cfg['image_ids'][service] or actual_hash != hashes[service]:
            raise ValueError('running image/config differs from prepared source')
        if service == 'wrfcoin-backend':
            backend = ids[0]
    return backend


def node(container, code):
    return json.loads(run(['docker', 'exec', '--workdir', BACKEND_ROOT, '-i', container, 'node',
                          '--input-type=module'], code))


def execute(phase, cfg_path, receipt, evidence):
    cfg, cmd, digest = config(cfg_path)
    hashes = rendered(cmd, cfg)
    if phase == 'prepare':
        # The same reviewed image/DB inputs must already run with the flag off.
        original = cmd[:-4] + cmd[-2:]  # remove final '-f shadow-overlay' only
        old_hash = run(original + ['config', '--hash', 'wrfcoin-backend']).split()
        if len(old_hash) != 2 or old_hash[0] != 'wrfcoin-backend' or not re.fullmatch(r'[0-9a-f]{64}', old_hash[1]):
            raise ValueError('invalid original backend hash')
        backend = running(original, cfg, {'wrfcoin-backend': old_hash[1]}, ('wrfcoin-backend',))
        runtime = node(backend, RUNTIME)
        if runtime != {'shadow': '0'}:
            raise ValueError('expected shadow flag off')
        baseline = node(backend, database_code(SQL_BASELINE, []))
        if not all(re.fullmatch(r'0|[1-9][0-9]*', str(baseline[k])) for k in ('max_id', 'count')):
            raise ValueError('invalid database baseline')
        dt.datetime.fromisoformat(baseline['since'])
        save(receipt, {'config': digest, 'hashes': hashes, 'baseline': baseline,
                       'prepared': dt.datetime.now(dt.timezone.utc).isoformat()})
        print('PASS prepared: existing score table and cached images; shadow still off')
        return
    prior = private_json(receipt)
    if prior['config'] != digest or prior['hashes'] != hashes:
        raise ValueError('owner config/render changed since prepare')
    if phase == 'enable':
        age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(prior['prepared'])
        if not 0 <= age.total_seconds() <= 1800:
            raise ValueError('prepared receipt expired; create a new attempt')
        run(cmd + ['up', '-d', '--wait', '--wait-timeout', '60', '--no-deps',
                   '--no-build', '--pull', 'never', *SERVICES], timeout=90)
    backend = running(cmd, cfg, hashes)
    if node(backend, RUNTIME) != {'shadow': '1'}:
        raise ValueError('running advisory scorer flag unavailable')
    if phase == 'enable':
        print('PASS enabled: advisory hook only; persisted-score evidence still pending')
        return
    baseline = prior['baseline']
    # Bands-v3 is proved by new persisted rows, not an unavailable source import.
    # Fold/pressure/consensus parity still require owner-reviewed source evidence.
    result = node(backend, database_code(SQL_RECORD, [int(baseline['max_id']), baseline['since'], 3]))
    if not all(re.fullmatch(r'0|[1-9][0-9]*', str(result[k])) for k in ('total', 'valid', 'good', 'degraded', 'outlier')):
        raise ValueError('invalid score summary')
    counts = {k: int(v) for k, v in result.items()}
    if counts['total'] < 1 or counts['valid'] != counts['total']:
        raise ValueError('no fresh valid persisted scores; wait for normal accepted reveals')
    if counts['good'] + counts['degraded'] + counts['outlier'] != counts['total']:
        raise ValueError('invalid tier counts')
    save(evidence, {'prepared': prior, 'recorded': dt.datetime.now(dt.timezone.utc).isoformat(),
                    'counts': counts, 'scope': 'advisory plumbing only; no parity or reward proof'})
    print(f"PASS recorded: {counts['total']} fresh durable advisory scores; aggregate receipt saved")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=('prepare', 'enable', 'record'))
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    try:
        if any(not p.is_absolute() for p in (args.config, args.receipt, args.evidence) if p is not None):
            raise ValueError('absolute owner paths required')
        if args.phase == 'record' and args.evidence is None:
            raise ValueError('new evidence path required')
        # Serializes owner retries without truncating an existing receipt.
        lock = args.receipt.with_suffix('.lock')
        with os.fdopen(os.open(lock, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600), 'w') as out:
            fcntl.flock(out, fcntl.LOCK_EX | fcntl.LOCK_NB)
            execute(args.phase, args.config, args.receipt, args.evidence)
    except (OSError, ValueError, KeyError, TypeError):
        print('STOP: shadow step incomplete; check private inputs/runtime; no success evidence claimed', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
