#!/usr/bin/env python3
"""Public download mode for render-release-manifest.sh; no deployment evidence."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
REPO = re.compile(r"wrfcoin/[A-Za-z0-9][A-Za-z0-9._-]*")
SHA = re.compile(r"[0-9a-f]{40}")
METADATA = ("manifest.json", "SHA256SUMS", "manifest.json.asc")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def build(spec, out, published=False):
    """Read local bytes, bind source tags, and emit only allowlisted public fields."""
    require(REPO.fullmatch(spec['repository']), 'invalid release repository')
    require(NAME.fullmatch(spec['release']), 'invalid release tag')
    require(spec['artifacts'], 'no artifacts')
    artifacts, files, ids, names = [], [], set(), set(METADATA)
    for item in spec['artifacts']:
        ident = item['id']
        require(NAME.fullmatch(ident) and ident not in ids, 'invalid or duplicate id')
        ids.add(ident)
        require(REPO.fullmatch(item['repository']), 'invalid source repository')
        require(SHA.fullmatch(item['commit']), 'full source commit required')
        require(NAME.fullmatch(item['tag']), 'invalid source tag')
        commit = run('git', '-C', item['checkout'], 'rev-parse', '--verify',
                     'refs/tags/' + item['tag'] + '^{commit}')
        require(commit == item['commit'], 'source tag does not match commit')
        if ident == 'node-source':
            require(item['repository'] == 'wrfcoin/core4', 'node-source must be core4')
        entry = {k: item[k] for k in ('id', 'kind', 'repository', 'commit', 'tag')}
        entry.update(published=published, size=None, sha256=None)
        if item['kind'] == 'git':
            entry['url'] = f"https://github.com/{item['repository']}/tree/{commit}"
        else:
            require(item['kind'] == 'file', 'unsupported artifact kind')
            path = Path(item['path'])
            require(path.is_file() and not path.is_symlink(), 'artifact must be a regular file')
            require(NAME.fullmatch(path.name) and path.name not in names, 'unsafe or duplicate filename')
            names.add(path.name)
            copy = out / path.name
            shutil.copyfile(path, copy)
            with copy.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            entry.update(size=copy.stat().st_size,
                         sha256=digest,
                         url=f"https://github.com/{spec['repository']}/releases/download/{spec['release']}/{path.name}")
            files.append(copy)
        artifacts.append(entry)
    require(any(a['kind'] == 'git' and a['id'] == 'node-source' for a in artifacts),
            'node-source git artifact required')
    manifest = {'generated': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'release': spec['release'], 'artifacts': artifacts}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    sums = ''.join(f"{a['sha256']}  {Path(a['url']).name}\n" for a in artifacts if a['kind'] == 'file')
    (out / 'SHA256SUMS').write_text(sums)
    return files


def remote_tag_commit(repository, tag):
    ref = json.loads(run('gh', 'api', f'repos/{repository}/git/ref/tags/{tag}'))
    require(isinstance(ref, dict) and ref.get('ref') == f'refs/tags/{tag}',
            'explicit remote tag reference required')
    obj = ref.get('object', {})
    seen = set()
    for _ in range(16):
        require(isinstance(obj, dict) and SHA.fullmatch(obj.get('sha', '')),
                'invalid remote tag object')
        if obj.get('type') == 'commit':
            return obj['sha']
        require(obj.get('type') == 'tag' and obj['sha'] not in seen,
                'remote tag must lead to a commit without cycles')
        seen.add(obj['sha'])
        annotated = json.loads(run('gh', 'api', f"repos/{repository}/git/tags/{obj['sha']}"))
        require(isinstance(annotated, dict) and annotated.get('sha') == obj['sha'],
                'annotated tag identity mismatch')
        obj = annotated.get('object', {})
    raise ValueError('remote tag nesting exceeds limit')


def publish(spec, bundle, files, fingerprint, origin):
    require(re.fullmatch(r'[A-Fa-f0-9]{40}|[A-Fa-f0-9]{64}', fingerprint), 'full signing fingerprint required')
    repositories = {spec['repository'], *(item['repository'] for item in spec['artifacts'])}
    for repository in sorted(repositories):
        require(run('gh', 'repo', 'view', repository, '--json', 'isPrivate', '--jq', '.isPrivate') == 'false',
                'release and all source repositories must be public')
    # Public source tags must exist remotely and match the signed catalog.
    for item in spec['artifacts']:
        remote = remote_tag_commit(item['repository'], item['tag'])
        require(remote == item['commit'], 'remote source tag does not match commit')
    release = json.loads(run('gh', 'release', 'view', spec['release'], '-R', spec['repository'],
                             '--json', 'isDraft,isPrerelease,tagName'))
    require(release['tagName'] == spec['release'] and not release['isDraft'], 'existing public release required')
    signature = bundle / 'manifest.json.asc'
    # The owner supplies an existing key; never generate, import, or print it.
    run('gpg', '--batch', '--armor', '--local-user', fingerprint + '!',
        '--output', str(signature), '--detach-sign', str(bundle / 'manifest.json'))
    status = run('gpg', '--batch', '--status-fd', '1', '--verify', str(signature), str(bundle / 'manifest.json'))
    require(any(line.startswith('[GNUPG:] VALIDSIG ' + fingerprint.upper() + ' ') for line in status.splitlines()),
            'signature fingerprint verification failed')
    # No --clobber: an existing release asset requires an explicit owner decision.
    run('gh', 'release', 'upload', spec['release'], '-R', spec['repository'],
        *map(str, [*files, *(bundle / name for name in METADATA)]))
    # Website changes only after successful upload. Mount the parent directory,
    # so the relative current symlink can be replaced atomically.
    origin.mkdir(parents=True, exist_ok=True)
    version = hashlib.sha256((bundle / 'manifest.json').read_bytes()).hexdigest()
    target = origin / version
    target.mkdir()  # refuse overwrite
    try:
        for name in METADATA:
            shutil.copyfile(bundle / name, target / name)
        temp = origin / ('.current-' + version)
        temp.symlink_to(version, target_is_directory=True)
        os.replace(temp, origin / 'current')
    except Exception:
        # Retain the old current pointer and uploaded assets for owner recovery.
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spec', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--publish', action='store_true')
    parser.add_argument('--signing-fingerprint')
    parser.add_argument('--website-dir', type=Path)
    args = parser.parse_args()
    require(not args.out.exists(), 'output directory already exists')
    require(not args.publish or (args.signing_fingerprint and args.website_dir),
            'publication requires owner fingerprint and website directory')
    spec = json.loads(args.spec.read_text())
    # Stage atomically so a validation error cannot leave a usable catalog.
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.out.parent) as temp:
        bundle = Path(temp)
        files = build(spec, bundle, published=args.publish)
        if args.publish:
            publish(spec, bundle, files, args.signing_fingerprint, args.website_dir)
        shutil.copytree(bundle, args.out)
    print('PUBLIC_RELEASE=PASS ' + ('published' if args.publish else 'staged-only; do not serve before signing/publication'))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'PUBLIC_RELEASE=FAIL {error}')
