"""Offline artifact/CLI controls; signing and GitHub are stubbed, never invoked."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
from unittest.mock import patch

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('public_release', ROOT / 'testnet/scripts/public_release.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
FPR = 'A' * 40


@pytest.fixture
def bundle(tmp_path):
    repo = tmp_path / 'source'
    repo.mkdir()
    subprocess.run(['git', 'init', '-q', str(repo)], check=True)
    subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    'commit', '-q', '--allow-empty', '-m', 'fixture'], check=True)
    subprocess.run(['git', '-C', str(repo), 'tag', 'v-test'], check=True)
    sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    binary = tmp_path / 'cli.tar.gz'
    binary.write_bytes(b'synthetic release bytes\n')
    common = dict(repository='wrfcoin/core4', commit=sha, tag='v-test', checkout=str(repo))
    spec = dict(repository='wrfcoin/infra', release='v-test', artifacts=[
        dict(common, id='node-source', kind='git'),
        dict(common, id='cli', kind='file', path=str(binary)),
    ])
    out = tmp_path / 'bundle'
    out.mkdir()
    return spec, out, binary


def test_cli_hashes_bytes_and_emits_no_local_paths(bundle, tmp_path):
    spec, _, binary = bundle
    path = tmp_path / 'spec.json'
    path.write_text(json.dumps(spec))
    out = tmp_path / 'cli-out'
    result = subprocess.run(['bash', str(ROOT / 'testnet/scripts/render-release-manifest.sh'),
                             '--downloads', '--spec', str(path), '--out', str(out)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert 'staged-only' in result.stdout
    text = (out / 'manifest.json').read_text()
    assert str(tmp_path) not in text
    manifest = json.loads(text)
    assert all(a['published'] is False for a in manifest['artifacts'])
    assert manifest['artifacts'][0]['sha256'] is None
    assert manifest['artifacts'][1]['sha256'] == hashlib.sha256(binary.read_bytes()).hexdigest()
    assert manifest['artifacts'][1]['size'] == binary.stat().st_size
    subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=out, check=True, capture_output=True)
    (out / binary.name).write_bytes(b'tampered')
    assert subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=out, capture_output=True).returncode != 0


@pytest.mark.parametrize('mutation', ['commit', 'duplicate', 'filename', 'node', 'symlink'])
def test_refuses_invalid_artifacts(bundle, mutation, tmp_path):
    spec, out, binary = bundle
    if mutation == 'commit': spec['artifacts'][0]['commit'] = '0' * 40
    if mutation == 'duplicate': spec['artifacts'][1]['id'] = 'node-source'
    if mutation == 'filename':
        bad = tmp_path / 'bad name'; binary.rename(bad); spec['artifacts'][1]['path'] = str(bad)
    if mutation == 'node': spec['artifacts'][0]['repository'] = 'wrfcoin/mobile'
    if mutation == 'symlink':
        link = tmp_path / 'link'; link.symlink_to(binary); spec['artifacts'][1]['path'] = str(link)
    with pytest.raises(ValueError): m.build(spec, out)


def publication_stub(spec, calls, failure=None):
    def fake(*args):
        calls.append(args)
        if args[:3] == ('gh', 'repo', 'view'): return 'false'
        if args[:2] == ('gh', 'api'):
            assert '/git/ref/tags/' in args[2]
            return json.dumps({'ref': 'refs/tags/v-test', 'object': {'type': 'commit', 'sha': spec['artifacts'][0]['commit'] if failure != 'remote' else '0'*40}})
        if args[:3] == ('gh', 'release', 'view'): return json.dumps(dict(isDraft=False, tagName='v-test'))
        if '--detach-sign' in args:
            if failure == 'sign': raise subprocess.CalledProcessError(1, args)
            Path(args[args.index('--output') + 1]).write_text('STUB SIGNATURE')
            return ''
        if '--verify' in args: return '[GNUPG:] VALIDSIG ' + (FPR if failure != 'verify' else 'B'*40) + ' 0'
        if args[:3] == ('gh', 'release', 'upload'):
            assert '--clobber' not in args
            if failure == 'upload': raise subprocess.CalledProcessError(1, args)
            return ''
        raise AssertionError(args)
    return fake


def test_publication_upload_precedes_atomic_website_switch(bundle, tmp_path):
    spec, out, _ = bundle
    files = m.build(spec, out, published=True)
    calls = []
    origin = tmp_path / 'website'
    with patch.object(m, 'run', side_effect=publication_stub(spec, calls)):
        m.publish(spec, out, files, FPR, origin)
    assert (origin / 'current').is_symlink()
    for name in m.METADATA: assert (origin / 'current' / name).read_bytes() == (out / name).read_bytes()
    assert not list((origin / 'current').glob('*.tar.gz'))
    assert calls[-1][:3] == ('gh', 'release', 'upload')
    assert FPR+'!' in next(c for c in calls if '--detach-sign' in c)


@pytest.mark.parametrize('failure', ['remote', 'sign', 'verify', 'upload'])
def test_failure_preserves_website_pointer(bundle, tmp_path, failure):
    spec, out, _ = bundle
    files = m.build(spec, out, published=True)
    origin = tmp_path / 'website'; origin.mkdir()
    (origin / 'old').mkdir(); (origin / 'current').symlink_to('old')
    calls = []
    with patch.object(m, 'run', side_effect=publication_stub(spec, calls, failure)):
        with pytest.raises((ValueError, subprocess.CalledProcessError)):
            m.publish(spec, out, files, FPR, origin)
    assert (origin / 'current').readlink() == Path('old')
    if failure != 'upload': assert not any(c[:3] == ('gh', 'release', 'upload') for c in calls)


def test_both_edges_import_exact_metadata_and_mount_parent():
    snippet = (ROOT / 'testnet/edge/downloads.caddy').read_text()
    assert '@release_metadata path /downloads/manifest.json /downloads/SHA256SUMS /downloads/manifest.json.asc' in snippet
    assert 'root * /srv/wrfcoin-downloads/current' in snippet
    assert 'browse' not in snippet and 'reverse_proxy' not in snippet
    for caddy, compose in [('Caddyfile', 'docker-compose.edge.yml'), ('Caddyfile.funnel', 'docker-compose.funnel-edge.yml')]:
        s = (ROOT / 'testnet/edge' / caddy).read_text()
        assert s.count('import public_downloads') == 1
        assert 'import downloads.caddy' in s
        services = yaml.safe_load((ROOT / 'testnet' / compose).read_text())['services']
        volumes = [v for service in services.values() for v in service.get('volumes', [])]
        assert './edge/downloads.caddy:/etc/caddy/downloads.caddy:ro' in volumes
        assert '${WRFCOIN_DOWNLOADS_DIR:-/var/lib/wrfcoin-downloads}:/srv/wrfcoin-downloads:ro' in volumes


def test_invalid_cli_leaves_no_output(bundle, tmp_path):
    spec, _, _ = bundle
    spec['artifacts'][1]['commit'] = '0' * 40
    path = tmp_path / 'invalid.json'; path.write_text(json.dumps(spec))
    out = tmp_path / 'must-not-exist'
    result = subprocess.run(['bash', str(ROOT / 'testnet/scripts/render-release-manifest.sh'),
                             '--downloads', '--spec', str(path), '--out', str(out)], capture_output=True)
    assert result.returncode != 0
    assert not out.exists()


@pytest.mark.parametrize('private,draft', [(True, False), (False, True)])
def test_unpublished_release_refused_before_signing(bundle, tmp_path, private, draft):
    spec, out, _ = bundle
    files = m.build(spec, out, published=True)
    calls = []
    fallback = publication_stub(spec, calls)
    def fake(*args):
        if args[:3] == ('gh', 'repo', 'view'): return 'true' if private else 'false'
        if args[:3] == ('gh', 'release', 'view'): return json.dumps(dict(isDraft=draft, tagName='v-test'))
        return fallback(*args)
    with patch.object(m, 'run', side_effect=fake):
        with pytest.raises(ValueError): m.publish(spec, out, files, FPR, tmp_path / 'website')
    assert not any(c[0] == 'gpg' for c in calls)
    assert not (tmp_path / 'website').exists()


def test_artifact_keeps_source_repository(bundle):
    spec, out, _ = bundle
    m.build(spec, out)
    manifest = json.loads((out / 'manifest.json').read_text())
    assert all(a['repository'] == 'wrfcoin/core4' for a in manifest['artifacts'])


def test_branch_named_like_tag_cannot_authorize_publication(bundle, tmp_path):
    spec, out, _ = bundle
    files = m.build(spec, out, published=True)
    calls = []
    fallback = publication_stub(spec, calls)
    def fake(*args):
        if args[:2] == ('gh', 'api') and '/git/ref/tags/' in args[2]:
            raise subprocess.CalledProcessError(1, args)  # branch exists; tag does not
        return fallback(*args)
    with patch.object(m, 'run', side_effect=fake):
        with pytest.raises(subprocess.CalledProcessError):
            m.publish(spec, out, files, FPR, tmp_path / 'website')
    assert not any(c[0] == 'gpg' for c in calls)


def test_private_source_refused_even_with_public_release_repo(bundle, tmp_path):
    spec, out, _ = bundle
    files = m.build(spec, out, published=True)
    calls = []
    fallback = publication_stub(spec, calls)
    def fake(*args):
        if args[:4] == ('gh', 'repo', 'view', 'wrfcoin/core4'): return 'true'
        return fallback(*args)
    with patch.object(m, 'run', side_effect=fake):
        with pytest.raises(ValueError):
            m.publish(spec, out, files, FPR, tmp_path / 'website')
    assert not any(c[0] == 'gpg' for c in calls)


def test_remote_annotated_tags_are_peeled_to_commit():
    calls = []
    def fake(*args):
        calls.append(args)
        if args[2].endswith('/git/ref/tags/v-test'):
            return json.dumps({'ref': 'refs/tags/v-test', 'object': {'type': 'tag', 'sha': 'a'*40}})
        if args[2].endswith('/git/tags/'+'a'*40):
            return json.dumps({'sha': 'a'*40, 'object': {'type': 'tag', 'sha': 'b'*40}})
        if args[2].endswith('/git/tags/'+'b'*40):
            return json.dumps({'sha': 'b'*40, 'object': {'type': 'commit', 'sha': 'c'*40}})
        raise AssertionError(args)
    with patch.object(m, 'run', side_effect=fake):
        assert m.remote_tag_commit('wrfcoin/core4', 'v-test') == 'c'*40
    assert len(calls) == 3


@pytest.mark.parametrize('kind', ['tree', 'cycle', 'branch'])
def test_remote_tag_rejects_noncommit_cycle_or_wrong_ref(kind):
    def fake(*args):
        if '/git/ref/' in args[2]:
            return json.dumps({'ref': 'refs/heads/v-test' if kind == 'branch' else 'refs/tags/v-test',
                               'object': {'type': 'tree' if kind == 'tree' else 'tag', 'sha': 'a'*40}})
        return json.dumps({'sha': 'a'*40, 'object': {'type': 'tag', 'sha': 'a'*40}})
    with patch.object(m, 'run', side_effect=fake):
        with pytest.raises(ValueError): m.remote_tag_commit('wrfcoin/core4', 'v-test')
