#!/usr/bin/env python3
"""Re-vendor core4's signing_preimage_v2.json with provenance. Stdlib only.

    revendor-core4-fixture.py --core4 PATH --rev REV [--pull-request N] [--ref NAME]

Reads the fixture from `git show REV:<path>` in the core4 checkout (so the bytes
are exactly the committed ones), writes it to testnet/fixtures/core4/ and
rewrites the .source.json manifest (repository, PR, ref, FULL commit sha, path,
schema, sha256) that `services/golden-vector-fixture.cjs` verifies. Run it again
after the core4 change merges, pointing REV at the merge commit on main, so the
manifest names a commit anyone can `git show`.
"""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

PATH = 'shared-protocol/tests/fixtures/golden/signing_preimage_v2.json'
DEST = Path(__file__).resolve().parents[1] / 'fixtures' / 'core4'


def git(core4, *args):
    return subprocess.run(['git', '-C', core4, *args], check=True, capture_output=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--core4', required=True)
    parser.add_argument('--rev', required=True)
    parser.add_argument('--pull-request', type=int, default=3433)
    parser.add_argument('--ref', default='main')
    args = parser.parse_args()
    commit = git(args.core4, 'rev-parse', '--verify', args.rev + '^{commit}').decode().strip()
    data = git(args.core4, 'show', f'{commit}:{PATH}')
    schema = json.loads(data)['schema']
    (DEST / 'signing_preimage_v2.json').write_bytes(data)
    manifest = {
        'repository': 'WRFCoin/core4',
        'pull_request': args.pull_request,
        'ref': args.ref,
        'commit': commit,
        'path': PATH,
        'schema': schema,
        'sha256': hashlib.sha256(data).hexdigest(),
    }
    (DEST / 'signing_preimage_v2.source.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'vendored {PATH} @ {commit[:12]} ({len(data)} bytes, sha256 {manifest["sha256"][:12]})')


if __name__ == '__main__':
    main()
