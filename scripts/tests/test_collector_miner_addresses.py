"""Every collector that calls /blocks/mine must use this host's authorized payout.

The live multi-contributor collector accepted Steven's commit/reveal pairs but
then mined with Core4's historical 0x000...001 default. Producer authorization
rejected every mine, the per-station watermark never advanced, and overlapping
readings were resubmitted every five minutes while the summary still said
"12 submitted / 0 failed".

This test renders the portable base, local-build override, and host-specific
cut-miner overlay with both the real collector and explicit synthetic profiles.
The overlay is mandatory in boot-heal.sh and must carry the same effective
producer payout to every mining collector without making synthetic production a
default service.

Run: python3 -m pytest scripts/tests/test_collector_miner_addresses.py
"""

import json
import os
import pathlib
import re
import subprocess

import pytest


ROOT = pathlib.Path(__file__).resolve().parents[2]
RENDER = ROOT / "testnet" / "tests" / "render-testnet-compose.sh"
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")

MINER_VARIABLES = {
    "synthetic-collector": "SYNTH_MINER_ADDRESS",
    "weather-collector": "WRFCOIN_MINER_ADDRESS",
    "weather-collector-multi": "WRFCOIN_MINER_ADDRESS",
}


@pytest.fixture(scope="module")
def services():
    env = os.environ.copy()
    env.update(
        {
            "ADMIN_TOKEN": "ci-render-only",
            "FAUCET_API_TOKEN": "ci-render-only",
            "GRAFANA_ADMIN_PASSWORD": "ci-render-only",
            "JWT_SECRET": "ci-render-only",
            "N8N_WEBHOOK_SECRET": "ci-render-only",
            "OAUTH_STATE_SECRET": "ci-render-only",
            "POSTGRES_PASSWORD": "ci-render-only",
            "REDIS_PASSWORD": "ci-render-only",
            "RPC_API_KEY": "ci-render-only",
            "WRFCOIN_OPERATOR_TOKEN": "ci-render-only",
            "WRFCOIN_CONTRIBUTOR_TOKEN": "ci-contributor-render-only",
        }
    )
    command = [
        "bash",
        str(RENDER),
        "--profile",
        "collector",
        "--profile",
        "synthetic",
        "-f",
        "testnet/docker-compose.testnet.yml",
        "-f",
        "testnet/docker-compose.override.yml",
        "-f",
        "testnet/docker-compose.cut-miner.yml",
        "config",
        "--format",
        "json",
    ]
    rendered = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )
    assert rendered.returncode == 0, (
        "effective collector Compose profile did not render:\n" + rendered.stderr
    )
    return json.loads(rendered.stdout)["services"]


@pytest.mark.parametrize("service,variable", MINER_VARIABLES.items())
def test_each_mining_collector_has_an_explicit_address(services, service, variable):
    assert service in services, f"{service} is absent from the mandatory cut-miner overlay"
    env = services[service].get("environment") or {}
    assert variable in env, f"{service} does not declare {variable}"
    value = str(env[variable]).strip()
    assert "${" not in value, f"{service}.{variable} must not depend on a possibly-empty host env"
    assert ADDRESS_RE.fullmatch(value), f"{service}.{variable} is not a 20-byte hex address"


def test_all_collectors_mine_to_the_same_host_payout(services):
    addresses = {
        service: str(services[service]["environment"][variable]).lower()
        for service, variable in MINER_VARIABLES.items()
    }
    assert len(set(addresses.values())) == 1, (
        "collectors on one producer host disagree on the authorized payout: "
        f"{addresses}"
    )


def test_legacy_unowned_default_is_absent(services):
    values = {
        str(services[service]["environment"][variable]).lower()
        for service, variable in MINER_VARIABLES.items()
    }
    assert "0x0000000000000000000000000000000000000001" not in values


@pytest.mark.parametrize(
    "service,volume,targets",
    [
        (
            "weather-collector",
            "weather-collector-state",
            {
                "/root/.wrfcoin/collector-state",
                # fetch-ambient-weather.cjs writes this collector's watermark
                # to /app/data/last-submitted-ts.txt.
                "/app/data",
            },
        ),
        (
            "weather-collector-multi",
            "weather-collector-multi-state",
            {"/root/.wrfcoin/collector-state"},
        ),
    ],
)
def test_real_collector_state_survives_container_recreation(
    services, service, volume, targets
):
    mounts = services[service].get("volumes") or []
    matching = {
        mount.get("target"): mount
        for mount in mounts
        if mount.get("target") in targets
    }
    assert set(matching) == targets, f"{service} must persist each runtime state path"
    for target, mount in matching.items():
        assert mount.get("type") == "volume", f"{service}:{target} must use a volume"
        assert mount.get("source") == volume, f"{service}:{target} uses the wrong volume"
        assert mount.get("read_only") is not True, f"{service}:{target} must be writable"
