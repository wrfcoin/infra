import importlib.util
import json
import os
import subprocess
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("postinstall", ROOT / "scripts/check-selfhosted-postinstall.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def test_current_infra_workflows_use_the_reviewed_install_boundary():
    assert guard.findings(ROOT / ".github/workflows") == []
    workflow = yaml.safe_load((ROOT / ".github/workflows/node-probes-gate.yml").read_text())
    installers = [step["run"] for step in workflow["jobs"]["node-probes"]["steps"] if "run" in step and "ci-node-install.sh" in step["run"]]
    assert len(installers) == 2


@pytest.mark.parametrize("service", ["testnet/explorer", "testnet/services/faucet"])
def test_probe_dependencies_do_not_require_lifecycle_builds(service):
    lock = json.loads((ROOT / service / "package-lock.json").read_text())
    assert [name for name, package in lock["packages"].items() if package.get("hasInstallScript")] == []


@pytest.mark.parametrize("runner,command,unsafe", [
    ("[self-hosted, n5pro]", "npm ci", True),
    ("n5pro", "npm install", True),
    ("ubuntu-ct102", "npm ci", True),
    ("{group: ct102, labels: linux}", "npm rebuild", True),
    ("'${{ matrix.runner }}'", "npm ci", True),
    ("[self-hosted, n5pro]", "npm ci --ignore-scripts", False),
    ("[self-hosted, n5pro]", "npm ci --ignore-scripts --ignore-scripts=false", True),
    ("[self-hosted, n5pro]", "npm ci --ignore-scripts --no-ignore-scripts", True),
    ("[self-hosted, n5pro]", "npm ci --ignore-scripts false", True),
    ("[self-hosted, n5pro]", "npm --loglevel=error ci", True),
    ("[self-hosted, n5pro]", "/usr/bin/npm ci", True),
    ("[self-hosted, n5pro]", "npm ci \\\n  --prefer-offline", True),
    ("[self-hosted, n5pro]", "npx playwright install chromium", True),
    ("[self-hosted, n5pro]", "npx puppeteer browsers install chrome", True),
    ("[self-hosted, n5pro]", "npx cypress install", True),
    ("ubuntu-latest", "npm ci && npx playwright install", False),
    ("[self-hosted, n5pro]", "bash scripts/ci-node-install.sh testnet/explorer", False),
])
def test_install_policy(tmp_path, runner, command, unsafe):
    (tmp_path / "w.yml").write_text(f"jobs:\n  j:\n    runs-on: {runner}\n    steps:\n      - run: {json.dumps(command)}\n")
    assert bool(guard.findings(tmp_path)) == unsafe


def test_zero_workflows_is_not_a_pass(tmp_path):
    assert guard.findings(tmp_path)


def test_helper_change_runs_both_service_probes(tmp_path):
    workflow = yaml.safe_load((ROOT / ".github/workflows/node-probes-gate.yml").read_text())
    assert "scripts/ci-node-install.sh" in workflow[True]["pull_request"]["paths"]
    step = next(step for step in workflow["jobs"]["node-probes"]["steps"] if step.get("id") == "changed")
    shim = tmp_path / "gh"
    shim.write_text("#!/bin/sh\nprintf '%s\\n' scripts/ci-node-install.sh\n")
    shim.chmod(0o755)
    output = tmp_path / "output"
    env = {**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}", "PR": "123", "GITHUB_REPOSITORY": "synthetic/infra", "GITHUB_OUTPUT": str(output)}
    result = subprocess.run(["bash", "-c", step["run"]], cwd=tmp_path, env=env, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert output.read_text().splitlines() == ["gate_self=true", "explorer=true", "faucet=true"]


def test_real_npm_dependency_postinstall_cannot_run(tmp_path):
    # Real npm, zero registry access. The planted dependency's lifecycle would
    # create a marker; run ordinary offline npm first to prove it is executable.
    dependency = tmp_path / "dependency"
    dependency.mkdir()
    marker = tmp_path / "postinstall-ran"
    (dependency / "package.json").write_text(json.dumps({
        "name": "synthetic-download-probe", "version": "1.0.0",
        "scripts": {"postinstall": f"node -e 'require(\"fs\").writeFileSync({json.dumps(str(marker))}, \"ran\")'"},
    }))
    # Use a regular package directory as a local tarball source, not a symlink:
    # npm does not run lifecycle scripts for a file: directory dependency.
    cache = tmp_path / "persistent-npm"
    packed = subprocess.run(["npm", "pack", "--ignore-scripts", "--json", "--offline", "--cache", str(cache)], cwd=dependency, capture_output=True, text=True, check=True)
    tarball = dependency / json.loads(packed.stdout)[0]["filename"]
    app = tmp_path / "app"
    app.mkdir()
    (app / "package.json").write_text(json.dumps({"name": "synthetic-app", "version": "1.0.0", "dependencies": {"synthetic-download-probe": f"file:{tarball}"}}))
    env = {**os.environ, "WRFCOIN_CI_NPM_CACHE": str(cache), "npm_config_offline": "true"}
    subprocess.run(["npm", "install", "--package-lock-only", "--ignore-scripts", "--cache", str(cache), "--offline", "--no-audit", "--no-fund"], cwd=app, env=env, capture_output=True, check=True)
    subprocess.run(["npm", "ci", "--cache", str(cache), "--offline", "--no-audit", "--no-fund"], cwd=app, env=env, capture_output=True, check=True)
    assert marker.exists(), "negative control did not execute the synthetic lifecycle"
    marker.unlink()
    for _ in range(2):
        result = subprocess.run(["bash", str(ROOT / "scripts/ci-node-install.sh"), str(app)], env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        assert not marker.exists(), "reviewed boundary executed a postinstall"
        assert (cache / "_cacache").is_dir()


@pytest.mark.parametrize("args", [[], ["missing"], ["x", "y"]])
def test_install_boundary_rejects_invalid_arguments(args):
    result = subprocess.run(["bash", str(ROOT / "scripts/ci-node-install.sh"), *args], capture_output=True)
    assert result.returncode == 2
