"""infra#982: every tracked compose file's build.context / build.dockerfile must exist."""
import json, os, subprocess, sys, textwrap

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
GATE = os.path.join(ROOT, "scripts", "check-compose-build-inputs.py")


def run(root, *args):
    return subprocess.run([sys.executable, GATE, "--root", str(root), *args], capture_output=True, text=True)


def write(p, text=""):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        f.write(textwrap.dedent(text))


def test_missing_dockerfile_fails(tmp_path):  # RED fixture
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build:\n      context: .\n      dockerfile: Dockerfile.gone\n")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "build.dockerfile missing" in r.stdout


def test_missing_context_fails(tmp_path):
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./nope\n")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "build.context missing" in r.stdout


def test_present_inputs_pass_and_defaults_resolve(tmp_path):
    write(tmp_path / "d/x/Dockerfile.ok")
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build:\n      context: ${CTX:-./x}\n      dockerfile: Dockerfile.ok\n  b:\n    image: foo\n")
    assert run(tmp_path, "--files", "d/compose.yml").returncode == 0


def test_unresolved_variable_fails(tmp_path):
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ${NOPE}\n")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "UNRESOLVED" in r.stdout


def test_attic_and_reset_tags_and_external_context(tmp_path):
    write(tmp_path / "docker/attic/compose.yml", "services:\n  a:\n    build: ./nope\n")
    write(tmp_path / "t/compose.yml", "services:\n  a:\n    build: !reset null\n  b:\n    build: ../../outside\n")
    r = run(tmp_path, "--files", "docker/attic/compose.yml", "t/compose.yml")
    assert r.returncode == 0, r.stdout


def test_exception_requires_reason_and_is_honoured(tmp_path):
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./nope\n")
    exc = tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json"
    write(exc, json.dumps({"exceptions": [{"file": "d/compose.yml", "service": "a"}]}))
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1  # no reason: not honoured
    assert "INVALID exception" in r.stdout and "missing reason" in r.stdout
    write(exc, json.dumps({"exceptions": [{"file": "d/compose.yml", "service": "a", "reason": "r"}]}))
    assert run(tmp_path, "--files", "d/compose.yml").returncode == 0


def test_real_repo_compose_files_pass():  # GREEN on real main
    r = run(ROOT)
    assert r.returncode == 0, r.stdout
    assert "scanned" in r.stdout and " 0 offender(s)" in r.stdout


def _git_repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    return tmp_path


def test_zero_compose_files_fails(tmp_path):
    repo = _git_repo(tmp_path)
    r = run(repo)  # default path: git ls-files finds nothing
    assert r.returncode == 1 and "zero compose files" in r.stdout
    r = run(repo, "--files")  # explicit empty list
    assert r.returncode == 1 and "zero compose files" in r.stdout


def test_yaml_parse_failure_fails(tmp_path):
    write(tmp_path / "d/compose.yml", "services:\n  a: [unclosed\n")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "YAML parse error" in r.stdout and "Traceback" not in r.stderr


def test_non_mapping_top_level_fails_cleanly(tmp_path):
    write(tmp_path / "d/compose.yml", "- a\n- b\n")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "not a mapping" in r.stdout and "Traceback" not in r.stderr
    write(tmp_path / "d/compose2.yml", "services:\n  - a\n")
    r = run(tmp_path, "--files", "d/compose2.yml")
    assert r.returncode == 1 and "`services` is not a mapping" in r.stdout and "Traceback" not in r.stderr


def test_stale_exception_fails(tmp_path):
    write(tmp_path / "d/x/Dockerfile")
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./x\n")  # fixed: no longer offends
    write(tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json",
          json.dumps({"exceptions": [{"file": "d/compose.yml", "service": "a", "reason": "was broken"}]}))
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "STALE exception d/compose.yml [a]" in r.stdout


def test_stale_exception_for_untracked_file_fails_on_full_scan(tmp_path):
    repo = _git_repo(tmp_path)
    write(repo / "d/x/Dockerfile")
    write(repo / "d/compose.yml", "services:\n  a:\n    build: ./x\n")
    write(repo / "scripts/tests/fixtures/compose-build-exceptions.json",
          json.dumps({"exceptions": [{"file": "d/gone.yml", "service": "a", "reason": "file removed"}]}))
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
    r = run(repo)
    assert r.returncode == 1 and "STALE exception d/gone.yml [a]" in r.stdout


def test_live_exception_is_not_stale(tmp_path):
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./nope\n")
    write(tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json",
          json.dumps({"exceptions": [{"file": "d/compose.yml", "service": "a", "reason": "r"}]}))
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 0 and "0 stale" in r.stdout


def test_sdr_ingest_has_no_exception_entry():
    # infra#1270 fixed it; the entry must stay gone (also enforced as STALE by the gate).
    with open(os.path.join(ROOT, "scripts/tests/fixtures/compose-build-exceptions.json")) as f:
        assert not [e for e in json.load(f)["exceptions"] if e["service"] == "sdr-ingest"]


def test_exception_without_reason_fails_even_when_nothing_offends(tmp_path):
    write(tmp_path / "d/x/Dockerfile")
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./x\n")
    exc = tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json"
    for entry in ({"file": "d/compose.yml", "service": "a"},
                  {"file": "d/compose.yml", "service": "a", "reason": "   "},
                  {"service": "a", "reason": "r"}):
        write(exc, json.dumps({"exceptions": [entry]}))
        r = run(tmp_path, "--files", "d/compose.yml")
        assert r.returncode == 1 and "INVALID exception" in r.stdout, entry


def test_unreadable_exceptions_file_fails(tmp_path):
    write(tmp_path / "d/x/Dockerfile")
    write(tmp_path / "d/compose.yml", "services:\n  a:\n    build: ./x\n")
    write(tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json", "{not json")
    r = run(tmp_path, "--files", "d/compose.yml")
    assert r.returncode == 1 and "unreadable" in r.stdout


def test_partial_run_only_judges_exceptions_for_scanned_files(tmp_path):
    # Pins `e[0] in scanned`: with --files, an exception for a file NOT in this run is
    # neither stale nor an error, but the same exception IS stale when its file is
    # scanned and fixed, and on a full scan when its file is gone.
    write(tmp_path / "d/x/Dockerfile")
    write(tmp_path / "d/ok.yml", "services:\n  a:\n    build: ./x\n")
    write(tmp_path / "d/other.yml", "services:\n  b:\n    build: ./x\n")
    write(tmp_path / "scripts/tests/fixtures/compose-build-exceptions.json",
          json.dumps({"exceptions": [{"file": "d/other.yml", "service": "b", "reason": "r"}]}))
    r = run(tmp_path, "--files", "d/ok.yml")  # d/other.yml not scanned
    assert r.returncode == 0 and "0 stale" in r.stdout, r.stdout
    r = run(tmp_path, "--files", "d/ok.yml", "d/other.yml")  # scanned, and b no longer offends
    assert r.returncode == 1 and "STALE exception d/other.yml [b]" in r.stdout


def test_nested_defaults_local_inputs_and_external_context(tmp_path):
    write(tmp_path / 'd/x/Dockerfile.ok')
    write(tmp_path / 'd/compose.yml', '''\
        services:
          local:
            build:
              context: ${OUTER:-${INNER:-./x}}
              dockerfile: ${FILE-${OTHER:-Dockerfile.ok}}
          external:
            build: ${ROOT:-${DEPLOY:-/path/to/deploy}}
    ''')
    r = run(tmp_path, '--files', 'd/compose.yml')
    assert r.returncode == 0, r.stdout
    assert '0 offender(s)' in r.stdout and '1 external-context service(s)' in r.stdout
    os.unlink(tmp_path / 'd/x/Dockerfile.ok')
    r = run(tmp_path, '--files', 'd/compose.yml')
    assert r.returncode == 1 and 'build.dockerfile missing' in r.stdout


def test_nested_default_unresolved_variable_still_fails(tmp_path):
    write(tmp_path / 'd/compose.yml', 'services:\n  a:\n    build: ${ROOT:-${MISSING}}\n')
    r = run(tmp_path, '--files', 'd/compose.yml')
    assert r.returncode == 1 and 'UNRESOLVED' in r.stdout and 'MISSING' in r.stdout
