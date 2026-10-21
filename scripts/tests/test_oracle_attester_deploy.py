from pathlib import Path
import os
import re
import subprocess

import yaml


ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = ROOT / "infra/docker/Dockerfile.core"
OVERLAY = ROOT / "testnet/docker-compose.oracle-attester.yml"
DESKTOP_YUBIKEY = ROOT / "testnet/docker-compose.oracle-attester-yubikey.desktop.yml"
N5_YUBIKEY = ROOT / "testnet/docker-compose.oracle-attester-yubikey.n5.yml"
HSM_ENTRYPOINT = ROOT / "infra/docker/hsm-service-entrypoint.sh"
IMAGE_WORKFLOW = ROOT / ".github/workflows/oracle-attester-image.yml"
CUTOVER = ROOT / "testnet/ORACLE_ATTESTER_CUTOVER.md"
ENV_EXAMPLE = ROOT / "testnet/.env.testnet.example"
ENV_COMPLETENESS = ROOT / "testnet/check-env-completeness.sh"


class _ComposeLoader(yaml.SafeLoader):
    pass


_ComposeLoader.add_constructor(
    "!reset", lambda loader, node: loader.construct_sequence(node)
)


def _load_compose(path: Path):
    return yaml.load(path.read_text(), Loader=_ComposeLoader)


def _without_comments(text: str) -> str:
    return "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def _attester_compose_env(station: str = "KDLH") -> dict[str, str]:
    return {
        **os.environ,
        "WRFCOIN_ORACLE_TOKEN": "fixture-oracle-token",
        "WRFCOIN_ATTESTER_HSM_TOKEN_LABEL": "fixture-token",
        "WRFCOIN_ATTESTER_HSM_KEY_LABEL": "fixture-key",
        "WRFCOIN_ATTESTER_HSM_PUBKEY_LABEL": "fixture-public-key",
        "WRFCOIN_ATTESTER_HSM_PIN": "fixture-pin",
        "WRFCOIN_ATTESTER_FORBID_GOVERNANCE_PUBKEY": "11" * 32,
        "WRFCOIN_ATTESTER_FORBID_SNAPSHOT_PUBKEY": "22" * 32,
        "WRFCOIN_ATTESTER_FORBID_PRODUCER_PUBKEY": "33" * 32,
        "WRFCOIN_ATTESTER_NWS_STATION": station,
    }


def _compose_config(tmp_path: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    base = tmp_path / "base.yml"
    base.write_text(
        "services:\n"
        "  wrfcoin-node:\n"
        "    image: fixture/node\n"
        "    healthcheck: {test: ['CMD', 'true']}\n"
        "networks:\n"
        "  wrfcoin-testnet: {}\n"
    )
    return subprocess.run(
        [
            "docker",
            "compose",
            "-f",
            str(base),
            "-f",
            str(OVERLAY),
            "--profile",
            "attester",
            "config",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_core_image_has_a_separate_attester_target_without_changing_node_role():
    dockerfile = _without_comments(DOCKERFILE.read_text())

    builds = re.findall(
        r"FROM builder-base AS (?P<stage>[^\n]+)\s+RUN cargo build(?P<body>.*?)(?=FROM)",
        dockerfile,
        flags=re.DOTALL,
    )
    assert len(builds) == 2, "node and attester must use separate Cargo builds"
    node_build = next(body for stage, body in builds if stage == "node-builder")
    attester_build = next(body for stage, body in builds if stage == "attester-builder")
    assert "--bin launch_api" in node_build
    assert "--bin oracle_attester" in attester_build

    node_features = re.search(r'--features\s+"([^"]+)"', node_build)
    attester_features = re.search(r'--features\s+"([^"]+)"', attester_build)
    assert node_features and attester_features
    # `upgrade-notice-fetch` (core4#3095/#3277 S7) is the node's own notice poll; the attester
    # feature tree stays out of the node build.
    assert set(node_features.group(1).split(",")) == {"full-mining", "p2p", "hsm", "upgrade-notice-fetch"}
    assert set(attester_features.group(1).split(",")) == {"hsm", "attester"}
    assert "COPY --from=attester-builder" in dockerfile
    assert "COPY --from=node-builder" in dockerfile

    assert re.search(
        r"FROM runtime-deps AS oracle-attester-runtime.*?"
        r"COPY --from=attester-builder /build/target/release/oracle_attester "
        r"/usr/local/bin/oracle_attester.*?"
        r"COPY infra/infra/docker/hsm-service-entrypoint.sh "
        r"/usr/local/bin/hsm-service-entrypoint.sh.*?"
        r'ENTRYPOINT \["/usr/local/bin/hsm-service-entrypoint.sh"\].*?'
        r'CMD \["/usr/local/bin/oracle_attester"\]',
        dockerfile,
        flags=re.DOTALL,
    ), "attester must be a distinct runtime target with its own entrypoint"

    # The default (last) target must remain the node. Merely placing the attester
    # stage last would make every existing no-target build produce the wrong
    # image even though both binaries compiled.
    assert dockerfile.rfind("FROM runtime-deps AS runtime") > dockerfile.rfind(
        "FROM runtime-deps AS oracle-attester-runtime"
    )
    assert dockerfile.rstrip().endswith(
        'ENTRYPOINT ["/usr/local/bin/hsm-entrypoint.sh"]'
    )


def test_attester_overlay_is_opt_in_fail_closed_and_custody_separated():
    document = _load_compose(OVERLAY)
    services = document["services"]
    init = services["oracle-softhsm-init"]
    attester = services["oracle-attester"]

    assert init["profiles"] == ["attester-softhsm"]
    assert attester["profiles"] == ["attester"]
    assert init["volumes"] == ["oracle-attester-data:/app/data"]
    assert attester["volumes"] == ["oracle-attester-data:/app/data"]
    assert "node-data:/app/data" not in OVERLAY.read_text()

    assert init["build"]["target"] == "oracle-attester-runtime"
    assert attester["build"]["target"] == "oracle-attester-runtime"
    assert attester["entrypoint"] == ["/usr/local/bin/hsm-service-entrypoint.sh"]
    assert attester["command"] == ["/usr/local/bin/oracle_attester"]
    assert attester["healthcheck"]["test"] == [
        "CMD-SHELL",
        'grep -Fxq "$$(printf %s oracle_attester | cut -b1-15)" /proc/1/comm',
    ]
    assert "readlink" not in str(attester["healthcheck"])
    assert attester["depends_on"]["wrfcoin-node"]["condition"] == "service_healthy"
    assert attester["depends_on"]["oracle-softhsm-init"] == {
        "condition": "service_healthy",
        "required": False,
    }

    env = attester["environment"]
    assert env["WRFCOIN_ATTESTER_NODE_URL"] == "http://wrfcoin-node:8556"
    assert env["WRFCOIN_CHAIN_ID"] == "${WRFCOIN_CHAIN_ID:-777}"
    assert env["WRFCOIN_NETWORK_ID"] == "testnet"
    assert ":?set the NWS reference station id" in env["WRFCOIN_ATTESTER_NWS_STATION"]

    required = [
        "WRFCOIN_ATTESTER_API_TOKEN",
        "WRFCOIN_HSM_TOKEN_LABEL",
        "WRFCOIN_HSM_ORACLE_KEY_LABEL",
        "WRFCOIN_HSM_ORACLE_PUBKEY_LABEL",
        "WRFCOIN_HSM_PIN",
        "WRFCOIN_ATTESTER_FORBID_GOVERNANCE_PUBKEY",
        "WRFCOIN_ATTESTER_FORBID_SNAPSHOT_PUBKEY",
        "WRFCOIN_ATTESTER_FORBID_PRODUCER_PUBKEY",
        "WRFCOIN_ATTESTER_NWS_STATION",
    ]
    for name in required:
        assert ":?" in env[name], f"{name} must fail Compose interpolation when absent"

    assert "WRFCOIN_ORACLE_SIGNER_PRIVATE_KEY" not in env
    assert "WRFCOIN_ORACLE_SIGNER_KEY_FILE" not in env

    init_script = init["command"][0]
    assert "WRFCOIN_ATTESTER_HSM_PROVISION" in init_script
    assert "--keypairgen" in init_script
    assert "PROVISION" in init_script and "exit 1" in init_script

    assert document["volumes"]["oracle-attester-data"] == {}


def test_reference_station_is_required(tmp_path):
    for station in (None, ""):
        env = _attester_compose_env()
        if station is None:
            env.pop("WRFCOIN_ATTESTER_NWS_STATION")
        else:
            env["WRFCOIN_ATTESTER_NWS_STATION"] = station
        result = _compose_config(tmp_path, env)
        assert result.returncode != 0
        assert "set the NWS reference station id" in result.stderr


def test_reference_station_passthrough(tmp_path):
    result = _compose_config(tmp_path, _attester_compose_env("KDLH"))
    assert result.returncode == 0, result.stderr
    rendered = yaml.safe_load(result.stdout)
    assert (
        rendered["services"]["oracle-attester"]["environment"]
        ["WRFCOIN_ATTESTER_NWS_STATION"]
        == "KDLH"
    )


def test_physics_only_sentinel_unsets(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_id = fake_bin / "id"
    fake_id.write_text("#!/bin/sh\necho 1001\n")
    fake_id.chmod(0o755)
    softhsm = tmp_path / "softhsm2.conf"
    softhsm.write_text("directories.tokendir = /tmp\n")
    env = {
        **os.environ,
        "PATH": str(fake_bin),
        "WRFCOIN_HSM_MODULE_PATH": "/fixture/softhsm/libsofthsm2.so",
        "SOFTHSM2_CONF": str(softhsm),
        "WRFCOIN_ATTESTER_NWS_STATION": "PHYSICS_ONLY",
    }
    result = subprocess.run(
        ["/bin/sh", str(HSM_ENTRYPOINT), "/usr/bin/env"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "WRFCOIN_ATTESTER_NWS_STATION=" not in result.stdout


def test_reference_station_is_documented_and_env_completeness_requires_it(tmp_path):
    assert "WRFCOIN_ATTESTER_NWS_STATION=" in ENV_EXAMPLE.read_text()
    assert "WRFCOIN_ATTESTER_NWS_STATION" in CUTOVER.read_text()
    assert "WRFCOIN_ATTESTER_NWS_STATION" in ENV_COMPLETENESS.read_text()

    env_file = tmp_path / "attester.env"
    env_file.write_text(
        "\n".join(
            f"{name}={value}"
            for name, value in _attester_compose_env().items()
            if name.startswith("WRFCOIN_") and name != "WRFCOIN_ATTESTER_NWS_STATION"
        )
        + "\n"
    )
    result = subprocess.run(
        [
            "bash",
            str(ENV_COMPLETENESS),
            "--env",
            str(env_file),
            "-f",
            OVERLAY.name,
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "MISSING or EMPTY: WRFCOIN_ATTESTER_NWS_STATION" in result.stdout


def test_yubikey_overlays_select_transport_without_changing_custody_identity():
    desktop = _load_compose(DESKTOP_YUBIKEY)["services"]["oracle-attester"]
    n5 = _load_compose(N5_YUBIKEY)["services"]["oracle-attester"]

    for service in (desktop, n5):
        assert service["user"] == "root"
        assert set(service["cap_add"]) == {"SETUID", "SETGID"}
        assert (
            service["environment"]["WRFCOIN_HSM_MODULE_PATH"]
            == "/usr/lib/x86_64-linux-gnu/libykcs11.so"
        )
        # Identity, labels and PIN stay in the fail-closed base overlay. These
        # host overlays choose transport only and must not smuggle a key choice.
        assert "WRFCOIN_HSM_TOKEN_LABEL" not in service["environment"]
        assert "WRFCOIN_HSM_ORACLE_KEY_LABEL" not in service["environment"]
        assert "WRFCOIN_HSM_PIN" not in service["environment"]

    assert desktop["devices"] == ["/dev/bus/usb:/dev/bus/usb"]
    assert "/run/pcscd" in desktop["tmpfs"]
    assert n5["volumes"] == ["/run/pcscd:/run/pcscd:ro"]

    launcher = _without_comments(HSM_ENTRYPOINT.read_text())
    assert "--keypairgen" not in launcher
    assert "gosu wrfcoin" in launcher
    assert "no pcscd socket is mounted" in launcher


def test_ci_builds_and_executes_the_explicit_attester_image_target():
    workflow = _without_comments(IMAGE_WORKFLOW.read_text())
    assert "repository: wrfcoin/core4" in workflow
    assert "ref: 40c4c1e1c1c2eeca1de4990a3c6d288f41e861aa" in workflow
    assert "target: oracle-attester-runtime" in workflow
    assert "load: true" in workflow
    assert "docker image inspect wrfcoin/oracle-attester:ci" in workflow
    assert "--entrypoint /usr/local/bin/oracle_attester" in workflow
    assert "WRFCOIN_ATTESTER_NODE_URL is not set" in workflow


def test_cutover_keeps_oracle_one_cold_and_runs_smoke_without_restart_policy():
    cutover = _without_comments(CUTOVER.read_text())
    assert re.search(r"Keep oracle 1\s+offline", cutover)
    assert not re.search(r"Keep oracle 3\s+offline", cutover)
    assert "--profile attester run --rm --no-deps oracle-attester" in cutover


def test_reference_mode_and_cap_are_passed_through_with_no_default():
    # core4#3240 / owner ruling 2026-10-05: no cap default (the radius is an owner
    # reward-policy choice); unset must leave the attester in `fixed` mode.
    text = OVERLAY.read_text()
    for name in ("WRFCOIN_ATTESTER_REFERENCE_MODE", "WRFCOIN_ATTESTER_MAX_REFERENCE_KM"):
        assert f"{name}: ${{{name}:-}}\n" in text, name
    example = ENV_EXAMPLE.read_text()
    assert "# WRFCOIN_ATTESTER_REFERENCE_MODE=shadow" in example
    assert "# WRFCOIN_ATTESTER_MAX_REFERENCE_KM=" in example
    assert "registry-reference-distance-p95.py" in example and "2026-10-05" in example
    assert not re.search(r"^WRFCOIN_ATTESTER_(REFERENCE_MODE|MAX_REFERENCE_KM)=", example, re.M)


def test_reference_cap_renders_empty_when_unset_and_set_when_given(tmp_path):
    env = _attester_compose_env("KDLH")
    for k in ("WRFCOIN_ATTESTER_REFERENCE_MODE", "WRFCOIN_ATTESTER_MAX_REFERENCE_KM"):
        env.pop(k, None)
    unset = yaml.safe_load(_compose_config(tmp_path, env).stdout)["services"]["oracle-attester"]["environment"]
    assert unset["WRFCOIN_ATTESTER_REFERENCE_MODE"] == ""  # attester trims+filters empty -> fixed
    assert unset["WRFCOIN_ATTESTER_MAX_REFERENCE_KM"] == ""
    env.update({"WRFCOIN_ATTESTER_REFERENCE_MODE": "shadow", "WRFCOIN_ATTESTER_MAX_REFERENCE_KM": "12.3"})
    given = yaml.safe_load(_compose_config(tmp_path, env).stdout)["services"]["oracle-attester"]["environment"]
    assert given["WRFCOIN_ATTESTER_REFERENCE_MODE"] == "shadow"
    assert given["WRFCOIN_ATTESTER_MAX_REFERENCE_KM"] == "12.3"
