#!/usr/bin/env python3
"""Execute reviewed suite lists; discovery only rejects unclassified files.

Private-input suites may be absent from the public snapshot. They are never
selected for public PRs. A selected missing/empty/failed suite is fatal.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / '.github/ci/scripts-test-suites.json'


def inventory(root, manifest):
    if manifest.get('version') != 1:
        raise ValueError('unknown suite policy version')
    declared = set()
    for profile in ('hosted', 'private'):
        for kind in ('python', 'shell', 'fixtures'):
            rows = manifest[profile][kind]
            if not isinstance(rows, list) or (kind != 'fixtures' and not rows):
                raise ValueError('empty or invalid suite list: ' + profile + '/' + kind)
            for row in rows:
                path = row['path']
                prefix = 'testnet/tests' if kind == 'fixtures' else 'scripts/tests'
                name = r'test[-_][A-Za-z0-9_-]+\.py' if kind == 'python' else (
                    r'test_[A-Za-z0-9_]+\.sh' if kind == 'fixtures' else r'test-[A-Za-z0-9_-]+\.sh')
                if not isinstance(path, str) or not re.fullmatch(prefix + '/' + name, path):
                    raise ValueError('unsafe suite path')
                if path in declared or not isinstance(row['reason'], str) or not row['reason'].strip():
                    raise ValueError('duplicate or unexplained suite: ' + path)
                declared.add(path)
                target = root / path
                if target.is_symlink() or (target.exists() and not target.is_file()):
                    raise ValueError('suite must be a regular file: ' + path)
                if profile == 'hosted' and not target.is_file():
                    raise ValueError('missing hosted suite: ' + path)
                if type(row.get('allow_unverified', False)) is not bool:
                    raise ValueError('invalid unverified policy: ' + path)
                if row.get('allow_unverified', False) and path != 'scripts/tests/test-dockerfile-core-deb-checksums.sh':
                    raise ValueError('only the existing external Debian-pool probe may return77')
    # This directory scan never chooses execution targets. New files require an
    # explicit reviewed classification before any selected suite can run.
    present = {p.relative_to(root).as_posix() for p in (root / 'scripts/tests').iterdir()
               if (re.fullmatch(r'test_[A-Za-z0-9_]+\.py', p.name) or
                   re.fullmatch(r'test-[A-Za-z0-9_-]+\.sh', p.name))}
    unknown = present - declared
    if unknown:
        raise ValueError('unclassified suites: ' + ', '.join(sorted(unknown)))
    return declared


def selected(root, manifest, profile, kind):
    inventory(root, manifest)
    rows = manifest[profile][kind]
    if not rows:
        raise ValueError('selected suite list is empty')
    for row in rows:
        if not (root / row['path']).is_file():
            raise ValueError('selected suite is unavailable: ' + row['path'])
    return rows


def run(root, manifest, profile, kind):
    rows = selected(root, manifest, profile, kind)
    paths = [row['path'] for row in rows]
    print('SUITE_SELECTION=' + json.dumps({'profile': profile, 'kind': kind, 'paths': paths}), flush=True)
    if kind == 'python':
        # Pytest's exit5 (zero tests) remains fatal. Select whole named modules,
        # never per-test exclusions, and use the same interpreter as the runner.
        collect = subprocess.run([sys.executable, '-m', 'pytest', '--collect-only', '-q', *paths], cwd=root)
        if collect.returncode:
            return collect.returncode
        return subprocess.run([sys.executable, '-m', 'pytest', '-q', *paths], cwd=root).returncode
    passed = failed = unverified = 0
    summary = []
    for row in rows:
        path = row['path']
        print('::group::' + path, flush=True)
        try:
            result = subprocess.run(['bash', path], cwd=root, timeout=600).returncode
        except subprocess.TimeoutExpired:
            result = 124
        print('::endgroup::', flush=True)
        if result == 0:
            passed += 1
            verdict = 'PASS'
        elif result == 77 and row.get('allow_unverified', False):
            unverified += 1
            verdict = 'UNVERIFIED (external mirror; not a pass)'
        else:
            failed += 1
            verdict = 'FAIL exit=' + str(result)
        line = verdict + ' ' + path
        print(line, flush=True)
        summary.append(line)
    totals = f'selected={len(rows)} passed={passed} failed={failed} unverified={unverified}'
    print('SUITE_TOTALS ' + totals, flush=True)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write('### ' + profile + '/' + kind + '\n\n```text\n' + '\n'.join(summary) + '\n' + totals + '\n```\n')
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('check', 'run'))
    parser.add_argument('--profile', choices=('hosted', 'private'), default='hosted')
    parser.add_argument('--kind', choices=('python', 'shell', 'fixtures'))
    args = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST.read_text())
        declared = inventory(ROOT, manifest)
        if args.mode == 'check':
            print('SUITE_INVENTORY=PASS declared=' + str(len(declared)))
            return 0
        if args.kind is None:
            raise ValueError('run requires --kind')
        return run(ROOT, manifest, args.profile, args.kind)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('SUITE_POLICY=RED ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
