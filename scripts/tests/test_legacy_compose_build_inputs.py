"""Offline production-checker regressions; discovered by scripts-tests pytest."""
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "scripts/check-legacy-compose-build-inputs.py"
spec = importlib.util.spec_from_file_location("legacy_compose_inputs", CHECKER)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


@pytest.fixture
def repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / "infra/docker").mkdir(parents=True)
    return tmp_path


def run(root):
    return subprocess.run(["python3", str(CHECKER), "--root", str(root)],
                          capture_output=True, text=True, timeout=15)


def variant(root, build):
    file = root / "infra/docker/docker-compose.fixture.yml"
    file.write_text(f"services:\n  example:\n    build: {build}\n")
    return file


def test_retained_variants_have_no_missing_local_inputs():
    result = run(ROOT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "local=5 external=9 missing=0 errors=0" in result.stdout
    assert "files=4" in result.stdout


def test_missing_dockerfile_is_real_red(repo):
    file = variant(repo, "{context: ., dockerfile: Dockerfile.nope}")
    result = run(repo)
    assert result.returncode == 1
    assert "MISSING:" in result.stdout and "Dockerfile.nope" in result.stdout
    (file.parent / "Dockerfile.nope").write_text("FROM scratch\n")
    assert run(repo).returncode == 0
    (file.parent / "Dockerfile.nope").unlink()
    assert run(repo).returncode == 1


def test_missing_context_is_real_red(repo):
    variant(repo, "{context: absent, dockerfile: Dockerfile}")
    result = run(repo)
    assert result.returncode == 1
    assert "MISSING:" in result.stdout and "context infra/docker/absent" in result.stdout


@pytest.mark.parametrize("context", ["../../../sibling", "${EXTERNAL_ROOT:?required}",
                                    "https://example.invalid/source.git"])
def test_external_context_is_reported_not_passed(repo, context):
    variant(repo, f"{{context: '{context}', dockerfile: Dockerfile}}")
    result = run(repo)
    assert result.returncode == 0
    assert "EXTERNAL:" in result.stdout
    assert "local=0 external=1 missing=0 errors=0" in result.stdout
    assert "LOCAL:" not in result.stdout


def test_shorthand_build_checks_default_dockerfile(repo):
    file = variant(repo, ".")
    assert run(repo).returncode == 1
    (file.parent / "Dockerfile").write_text("FROM scratch\n")
    assert run(repo).returncode == 0


@pytest.mark.parametrize("content", ["services: [broken]\n", "services: {bad: {build: 42}}\n",
                                     "services: {bad: {build: {context: 42}}}\n", "services: [\n"])
def test_malformed_input_is_red(repo, content):
    file = variant(repo, ".")
    file.write_text(content)
    result = run(repo)
    assert result.returncode == 1
    assert "ERROR:" in result.stdout


def test_empty_inventory_is_void(repo):
    assert run(repo).returncode == 2


def test_compose_reset_and_override_tags_are_supported(repo):
    file = variant(repo, "{context: ., dockerfile: Dockerfile}")
    file.write_text(file.read_text() + "    ports: !reset []\n    environment: !override {TEST: yes}\n")
    (file.parent / "Dockerfile").write_text("FROM scratch\n")
    assert run(repo).returncode == 0


@pytest.mark.parametrize("name,digest", [
    ("docker-compose.offline.yml", "b6c53533b5928252015064a5d5f256321e376689e90d179258228f37eed5df6a"),
    ("docker-compose.microservices.yml", "6512ace505a0184251096fa86500719391cabed8359dc36919ff765b4493b1e5"),
])
def test_archive_preserves_bytes_and_reintroduction_is_red(repo, name, digest):
    file = ROOT / "infra/docker/attic" / name
    assert file.is_file()
    assert hashlib.sha256(file.read_bytes()).hexdigest() == digest
    assert not (ROOT / "infra/docker" / name).exists()
    assert name in (file.parent / "README.md").read_text()
    shutil.copyfile(file, repo / "infra/docker" / name)
    result = run(repo)
    assert result.returncode == 1, result.stdout
    assert "MISSING:" in result.stdout


def test_archived_generator_refuses_before_imports_or_outputs(tmp_path):
    # A fresh cwd has no Hardhat installed. The archival refusal must happen
    # before require('hardhat') or any generated deployment instructions.
    historical = ROOT / "infra/docker/attic/seed-test-data.js.txt"
    assert hashlib.sha256(historical.read_bytes()).hexdigest() == "5f6b40e2d8b9e25022d037d2ec4735d42dfbe639cc9ea3da177c7baba4c68e4c"
    result = subprocess.run(["node", str(ROOT / "scripts/seed-test-data-retired.js")], cwd=tmp_path,
                            text=True, capture_output=True, timeout=15)
    assert result.returncode != 0
    assert "Legacy offline tooling is archived" in result.stderr
    assert "MODULE_NOT_FOUND" not in result.stderr
    assert list(tmp_path.iterdir()) == []


def test_migration_validator_uses_guard_and_never_renders_archive(repo):
    # Run the actual validator with an offline compose transport. Its build
    # checker is real; missing a local input must stop before success narration.
    for directory in ("helm", "k8s", "monitoring", "terraform", "deployment"):
        (repo / "infra" / directory).mkdir()
    for name in ("infra/docker/Dockerfile.core", "infra/docker/Dockerfile.backend",
                 "infra/docker/prometheus.yml", "infra/k8s/base/deployment.yaml",
                 "infra/terraform/main.tf", "infra/monitoring/prometheus-enhanced.yml",
                 "infra/deployment/deploy.sh", "infra/README.md"):
        file = repo / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("fixture\n")
    compose = repo / "infra/docker/docker-compose.yml"
    compose.write_text("services: {fixture: {build: {context: ., dockerfile: Dockerfile.core}}}\n")
    monitoring = repo / "infra/monitoring/docker-compose.monitoring.yml"
    monitoring.write_text("services: {fixture: {image: fixture:1.0.0}}\n")
    (repo / "docker-compose.yml").symlink_to(compose)
    (repo / "docker-compose.monitoring.yml").symlink_to(monitoring)
    (repo / "scripts").mkdir()
    shutil.copyfile(CHECKER, repo / "scripts" / CHECKER.name)
    validator = repo / "infra/validate-migration.sh"
    shutil.copyfile(ROOT / "infra/validate-migration.sh", validator)
    transport = repo / "bin/docker-compose"
    transport.parent.mkdir()
    transport.write_text("#!/bin/sh\ncase \"$*\" in *attic*|*microservices*|*offline*) exit 99;; esac\nexit 0\n")
    transport.chmod(0o755)
    env = dict(os.environ, PATH=f"{transport.parent}:{os.environ['PATH']}")
    result = subprocess.run(["bash", str(validator)], cwd=repo, env=env,
                            text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "local=1 external=0 missing=0 errors=0" in result.stdout
    assert "migration validation completed" in result.stdout
    (repo / "infra/docker/Dockerfile.core").unlink()
    result = subprocess.run(["bash", str(validator)], cwd=repo, env=env,
                            text=True, capture_output=True, timeout=15)
    assert result.returncode != 0
    assert "MISSING:" in result.stdout
    assert "migration validation completed" not in result.stdout
