"""Round15: actual build guard and daemon-free deployment render (Refs #1192)."""
import json
import os
from pathlib import Path
import re
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "testnet/frontend-build-flags-guard.sh"
FLAGS = (
    "VITE_ENABLE_CONTRACT_SURFACES",
    "VITE_ENABLE_DEMO_SURFACES",
    "VITE_ENABLE_FULL_STUDIO",
    "VITE_ENABLE_OPERATOR_PREVIEW",
)


def guard(app, **values):
    return subprocess.run(
        ["sh", str(GUARD), str(app)],
        env={"PATH": os.environ["PATH"], **values},
        capture_output=True, text=True, timeout=10,
    )


@pytest.mark.parametrize("name", FLAGS)
@pytest.mark.parametrize("value", ["", "true"])
def test_explicit_staging_values(tmp_path, name, value):
    result = guard(tmp_path, WRFCOIN_FRONTEND_BUILD_VARIANT="staging", **{name: value})
    assert result.returncode == 0, result.stderr
    assert "variant=staging (NOT a release image)" in result.stdout


@pytest.mark.parametrize("name", (*FLAGS, "VITE_ENABLE_FUTURE_SURFACE"))
@pytest.mark.parametrize("value", ["false", "TRUE", "True", "1", "on", " true", "true ", "\ntrue"])
def test_staging_typos_refused(tmp_path, name, value):
    result = guard(tmp_path, WRFCOIN_FRONTEND_BUILD_VARIANT="staging", **{name: value})
    assert result.returncode == 1, result.stdout
    assert f"FRONTEND_FLAGS=REFUSED {name}" in result.stderr


@pytest.mark.parametrize("name", (*FLAGS, "VITE_ENABLE_FUTURE_SURFACE"))
@pytest.mark.parametrize("filename", [".env", ".env.local", ".env.production", ".env.staging.local", ".env.custom"])
@pytest.mark.parametrize("declared", [False, True])
def test_frontend_dotenv_cannot_supply_staging_switch(tmp_path, name, filename, declared):
    (tmp_path / filename).write_text(f'export {name}: "true"\n')
    values = {name: ""} if declared else {}
    result = guard(tmp_path, WRFCOIN_FRONTEND_BUILD_VARIANT="staging", **values)
    assert result.returncode == 1, result.stdout
    assert name in result.stderr and filename in result.stderr


@pytest.mark.parametrize("variant", ["public", "staging"])
def test_empty_frontend_dotenv_and_examples_are_inert(tmp_path, variant):
    (tmp_path / ".env.production").write_text("\n".join(f'{name}="" # off' for name in FLAGS))
    (tmp_path / ".env.production.example").write_text("\n".join(f'{name}=true' for name in FLAGS))
    assert guard(tmp_path, WRFCOIN_FRONTEND_BUILD_VARIANT=variant).returncode == 0


@pytest.mark.parametrize("name", (*FLAGS, "VITE_ENABLE_FUTURE_SURFACE"))
def test_public_still_refuses_enabled_surfaces(tmp_path, name):
    result = guard(tmp_path, **{name: "true"})
    assert result.returncode == 1 and "variant=public" in result.stderr


def render(**values):
    result = subprocess.run(
        ["docker", "compose", "--env-file", str(ROOT / "testnet/.env.testnet.example"),
         "-f", str(ROOT / "testnet/docker-compose.testnet.yml"),
         "-f", str(ROOT / "testnet/docker-compose.override.yml"), "config", "--format", "json"],
        env={"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
             "WRFCOIN_FUNNEL_ORIGIN": "https://fixture.invalid",
             "WRFCOIN_P2P_EXTERNAL_ADDR": "/ip4/198.51.100.7/tcp/9000",
             "WRFCOIN_SEED_P2P_EXTERNAL_ADDR": "/ip4/203.0.113.9/tcp/9000", **values},
        capture_output=True, text=True, timeout=30,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)["services"]["wrfcoin-frontend"]


def test_default_render_and_guard_remain_public_off(tmp_path):
    service = render()
    args = service["build"]["args"]
    assert args["WRFCOIN_FRONTEND_BUILD_VARIANT"] == "public"
    assert {name: args.get(name) for name in FLAGS} == dict.fromkeys(FLAGS, "")
    assert not any(name in service.get("environment", {}) for name in FLAGS)
    assert guard(tmp_path, **args).returncode == 0


@pytest.mark.parametrize("name", FLAGS)
def test_each_staging_deployment_passes_to_guard(tmp_path, name):
    args = render(WRFCOIN_FRONTEND_BUILD_VARIANT="staging", **{name: "true"})["build"]["args"]
    assert args.get(name) == "true"
    assert all(args.get(other) == "" for other in FLAGS if other != name)
    assert guard(tmp_path, **args).returncode == 0


def test_dockerfile_stages_share_all_inputs_and_internal_labels():
    text = (ROOT / "testnet/Dockerfile.frontend").read_text()
    _, build, serve = re.split(r"^FROM ", text, flags=re.M)
    before_guard, after_guard = build.split("sh /usr/local/bin/frontend-build-flags-guard /app")
    assert "COPY frontend/ ." in before_guard and "RUN npm run build" in after_guard
    for name in FLAGS:
        assert re.findall(rf"^ARG {name}=(.*)$", build, re.M) == [""]
        assert re.findall(rf"^ARG {name}=(.*)$", serve, re.M) == [""]
        assert f"ARG {name}=\n" in before_guard
        assert f"ENV {name}=${name}\n" in before_guard
        label = "org.wrfcoin.frontend." + name.removeprefix("VITE_ENABLE_").lower().replace("_", "-")
        assert f'{label}="${name}"' in serve
        assert f"ENV {name}" not in serve
