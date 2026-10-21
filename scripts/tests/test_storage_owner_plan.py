"""Actual render-only CLI; fake images never need a Docker daemon."""
import os
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/plan-storage-owner.py"
OVERLAY = ROOT / "testnet/docker-compose.storage-owner.yml"


@pytest.fixture
def workspace(tmp_path):
    root = tmp_path / "infra"
    testnet = root / "testnet"
    testnet.mkdir(parents=True)
    services = {
        "postgres": {"image": "postgres:fixture"},
        "db-migrate": {"image": "wrfcoin/backend:fixture"},
        "wrfcoin-backend": {"image": "wrfcoin/backend:fixture"},
        "wrfcoin-storage": {"image": "wrfcoin/backend:fixture",
                            "profiles": ["full"], "command": ["node", "dist/storage_networks_server.cjs"]},
        "storage-node": {"image": "wrfcoin/storage-node:testnet-local", "profiles": ["ipfs-storage"],
                         "build": {"context": ".", "dockerfile": "infra/infra/docker/Dockerfile.storage"},
                         "environment": {"STORAGE_NODE_PROFILE": "testnet", "IPFS_API_URL": "http://ipfs-kubo:5001"},
                         "depends_on": {"ipfs-kubo": {"condition": "service_healthy"}},
                         "networks": ["wrfcoin-testnet", "ipfs-private"], "cap_drop": ["ALL"], "read_only": True},
        "ipfs-kubo": {"image": "ipfs/kubo:v0.24.0", "profiles": ["ipfs-storage"],
                      "networks": ["ipfs-private"], "volumes": ["testnet-ipfs-data:/data/ipfs"]},
    }
    base = {"services": services, "networks": {"wrfcoin-testnet": {}, "ipfs-private": {"internal": True}},
            "volumes": {"testnet-ipfs-data": {}}}
    archive = {
        "services": {
            "db-migrate": {"environment": {"WRFCOIN_EXPECTED_DB_MIGRATION": "0028_weather_archive_day_index"}},
            "weather-ipfs-archive": {
                "image": "wrfcoin/backend:testnet-local", "profiles": ["weather-archive"],
                "command": ["node", "dist/weather_ipfs_archive.cjs"],
                "environment": {"WRFCOIN_WEATHER_ARCHIVE_ENABLED": "true", "WRFCOIN_STORAGE_NODE_URL": "http://storage-node:7001",
                                "WRFCOIN_WEATHER_ARCHIVE_DIR": "/app/weather-archive", "DATABASE_URL": "private-fixture-value"},
                "depends_on": {"db-migrate": {"condition": "service_completed_successfully"}},
                "volumes": ["weather-ipfs-receipts:/app/weather-archive"],
            },
        }, "volumes": {"weather-ipfs-receipts": {}},
    }
    (testnet / "docker-compose.testnet.yml").write_text(yaml.safe_dump(base))
    (testnet / "docker-compose.override.yml").write_text("services: {}\n")
    (testnet / "docker-compose.weather-archive.yml").write_text(yaml.safe_dump(archive))
    # A missing shipped overlay must fail, not be supplied by the test.
    if OVERLAY.exists():
        (testnet / OVERLAY.name).write_bytes(OVERLAY.read_bytes())
    return root


def run(root, stage="r19", enable="", extra_env=None):
    return subprocess.run(
        ["python3", str(SCRIPT), "--root", str(root), "--env-file", "/dev/null",
         "--stage", stage, "--archive-enable", enable],
        env={"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], **(extra_env or {})},
        capture_output=True, text=True, timeout=40,
    )


def change(root, file, edit):
    path = root / "testnet" / file
    data = yaml.safe_load(path.read_text())
    edit(data)
    path.write_text(yaml.safe_dump(data))


def retire_mock(root):
    """Model current main: the retired mock is absent from the base."""
    change(root, "docker-compose.testnet.yml", lambda d: d["services"].pop("wrfcoin-storage", None))


def test_r19_real_render_defaults_off_and_named_only(workspace):
    result = run(workspace)
    assert result.returncode == 0, result.stderr
    assert "STORAGE_OWNER=PASS render-only stage=r19 archive=off" in result.stdout
    assert "--no-build --pull never ipfs-kubo storage-node" in result.stdout
    assert "--profile synthetic" not in result.stdout and " up -d" in result.stdout
    assert "weather-ipfs-archive" not in result.stdout
    assert "private-fixture-value" not in result.stdout + result.stderr


def test_r20_real_render_exact_flag_after_retirement(workspace):
    retire_mock(workspace)
    result = run(workspace, "r20", "true")
    assert result.returncode == 0, result.stderr
    assert "STORAGE_OWNER=PASS render-only stage=r20 archive=on" in result.stdout
    assert "WRFCOIN_WEATHER_ARCHIVE_ENABLED=true" in result.stdout
    assert "--no-build --pull never weather-ipfs-archive" in result.stdout


def test_r20_regression_guard_refuses_reappeared_mock(workspace):
    # The fixture base synthetically re-adds the retired wrfcoin-storage service.
    result = run(workspace, "r20", "true")
    assert result.returncode == 1 and "STOP" in result.stderr
    assert " up " not in result.stdout


@pytest.mark.parametrize("value", ["false", "TRUE", "1", "on", " true", "true "])
def test_malformed_enable_is_refused(workspace, value):
    retire_mock(workspace)
    assert run(workspace, "r20", value).returncode == 1


def test_printed_commands_pin_live_project_name(workspace):
    result = run(workspace)
    assert "docker compose -p testnet --env-file" in result.stdout


def test_r19_cannot_enable_worker(workspace):
    assert run(workspace, "r19", "true").returncode == 1


def test_r20_requires_explicit_true(workspace):
    retire_mock(workspace)
    assert run(workspace, "r20").returncode == 1


def test_inherited_process_switch_cannot_enable_r19(workspace):
    assert run(workspace, extra_env={"WRFCOIN_WEATHER_ARCHIVE_ENABLED": "true"}).returncode == 0


@pytest.mark.parametrize("kind", ["daemon", "kubo", "private", "endpoint", "paid", "worker", "migration", "profile", "receipt"])
def test_unavailable_or_incompatible_wiring_stops(workspace, kind):
    if kind == "daemon":
        change(workspace, "docker-compose.testnet.yml", lambda d: d["services"]["storage-node"].update(command=["node", "dist/storage_networks_server.cjs"]))
    elif kind == "kubo":
        change(workspace, "docker-compose.testnet.yml", lambda d: d["services"]["ipfs-kubo"].update(ports=["5001:5001"]))
    elif kind == "private":
        change(workspace, "docker-compose.testnet.yml", lambda d: d["networks"]["ipfs-private"].update(internal=False))
    elif kind == "endpoint":
        change(workspace, OVERLAY.name, lambda d: d["services"]["weather-ipfs-archive"]["environment"].update(WRFCOIN_STORAGE_NODE_URL="http://wrfcoin-storage:7000"))
    elif kind == "paid":
        change(workspace, OVERLAY.name, lambda d: d["services"]["weather-ipfs-archive"]["environment"].update(ENABLE_REAL_STORAGE="true"))
    elif kind == "worker":
        change(workspace, "docker-compose.weather-archive.yml", lambda d: d["services"]["weather-ipfs-archive"].update(command=["node", "dist/storage_networks_server.cjs"]))
    elif kind == "migration":
        change(workspace, "docker-compose.weather-archive.yml", lambda d: d["services"]["db-migrate"].update(environment={"WRFCOIN_EXPECTED_DB_MIGRATION": "0027"}))
    elif kind == "profile":
        change(workspace, "docker-compose.weather-archive.yml", lambda d: d["services"]["weather-ipfs-archive"].update(profiles=["synthetic"]))
    else:
        change(workspace, "docker-compose.weather-archive.yml", lambda d: d["services"]["weather-ipfs-archive"].update(volumes=[]))
    result = run(workspace)
    assert result.returncode == 1 and "STORAGE_OWNER=STOP" in result.stderr
    assert " up " not in result.stdout


def test_missing_reviewed_overlay_stops(workspace):
    (workspace / "testnet/docker-compose.weather-archive.yml").unlink()
    assert run(workspace).returncode == 1


@pytest.mark.parametrize("mode", ["error", "malformed"])
def test_render_errors_never_export_private_text(workspace, tmp_path, mode):
    docker = tmp_path / "docker"
    docker.write_text('#!/bin/sh\necho private-fixture-value\necho private-fixture-value >&2\nexit ' + ("1" if mode == "error" else "0") + '\n')
    docker.chmod(0o755)
    result = run(workspace, extra_env={"PATH": str(tmp_path) + ":" + os.environ["PATH"]})
    assert result.returncode == 1 and "STORAGE_OWNER=STOP" in result.stderr
    assert "private-fixture-value" not in result.stdout + result.stderr


def test_transport_only_executes_config_and_does_not_export_secrets(workspace, tmp_path):
    # Record the actual subprocess boundary, then supply the real-render model.
    retire_mock(workspace)
    command = ["docker", "compose", "--env-file", "/dev/null"]
    for filename in ["docker-compose.testnet.yml", "docker-compose.override.yml", "docker-compose.weather-archive.yml", OVERLAY.name]:
        command += ["-f", str(workspace / "testnet" / filename)]
    command += ["--profile", "ipfs-storage", "--profile", "weather-archive", "config", "--format", "json"]
    env = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"], "WRFCOIN_WEATHER_ARCHIVE_ENABLED": "true"}
    model = subprocess.check_output(command, env=env)
    (tmp_path / "model.json").write_bytes(model)
    docker = tmp_path / "docker"
    docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\ncat "$MODEL"\n')
    docker.chmod(0o755)
    calls = tmp_path / "calls"
    result = run(workspace, "r20", "true", {"PATH": str(tmp_path) + ":" + os.environ["PATH"], "MODEL": str(tmp_path / "model.json"), "CALLS": str(calls)})
    assert result.returncode == 0, result.stderr
    lines = calls.read_text().splitlines()
    assert len(lines) == 1 and lines[0].endswith("config --format json")
    assert "private-fixture-value" not in result.stdout + result.stderr
