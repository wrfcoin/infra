"""infra#1044: the Mango oracle attester must survive a node restart.

core4#3229 makes the node fail-stop (a P2P consumer panic aborts the process) and relies on
`restart: unless-stopped`. An attester that runs with `network_mode: service:wrfcoin-node` is
left in the node's dead network namespace by that restart. The fix puts the attester on the
compose bridge network, calling the node by its service name, and admits that name in the
node's Host allowlist.

These tests render the real testnet stack with `docker compose config` and check three things
together, because each one alone is not enough:
  1. no attester is bound to another container's network namespace;
  2. the attester's node URL is the service name, on a network the node is also on;
  3. the node's WRFCOIN_API_ALLOWED_HOSTS admits that host name (otherwise 403 HOST_NOT_ALLOWED).
The negative cases prove the checker is not blind: it fails on the 2026-09-25 Mango overlay and
on a render that omits the node overlay.
"""

from pathlib import Path
from urllib.parse import urlsplit
import os
import subprocess

import pytest
import yaml


ROOT = Path(__file__).resolve().parents[2]
TESTNET = ROOT / "testnet"
RENDER = TESTNET / "tests/render-testnet-compose.sh"
ENV_EXAMPLE = TESTNET / ".env.testnet.example"
BASE_FILES = ["docker-compose.testnet.yml", "docker-compose.override.yml"]
NODE_OVERLAY = "docker-compose.node-api-service-host.yml"
ATTESTER_BASE = "docker-compose.oracle-attester.yml"
MANGO_OVERLAY = "docker-compose.oracle-attester.mango.yml"
# The overlay that ran on Mango on 2026-09-25 (docs/plans/overnight-2026-09-24/, sha256
# 6aa53f5e…b39f), minus its image pins: the known-bad shape.
LEGACY_NETNS_OVERLAY = ROOT / "scripts/tests/fixtures/mango-attester-netns-overlay-20260925.yml"
# The loopback names core4's OriginGuard always admits (shared-protocol api_auth LOOPBACK_HOSTS).
LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "[::1]", "::1"}


class _ComposeLoader(yaml.SafeLoader):
    pass


def _compose_tag(loader, node):
    """Compose merge tags (`!reset`, `!override`) carry an ordinary value; read it as one."""
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
        return None if value in ("", "null", "~") else value
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node, deep=True)
    return loader.construct_mapping(node, deep=True)


_ComposeLoader.add_constructor("!reset", _compose_tag)
_ComposeLoader.add_constructor("!override", _compose_tag)


def _load(path: Path):
    return yaml.load(path.read_text(), Loader=_ComposeLoader)


def _attester_env() -> dict[str, str]:
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
        "WRFCOIN_ATTESTER_NWS_STATION": "KDLH",
    }


def _render(files: list[str]) -> dict:
    args = ["bash", str(RENDER), "--env-file", str(ENV_EXAMPLE), "-p", "testnet"]
    for f in files:
        args += ["-f", str(f)]
    args += ["--profile", "attester", "--profile", "attester-softhsm", "config", "--format", "json"]
    result = subprocess.run(
        args, cwd=TESTNET, env=_attester_env(), capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stderr
    return yaml.safe_load(result.stdout)["services"]


def _allowed_hosts(node: dict) -> set[str]:
    raw = (node.get("environment") or {}).get("WRFCOIN_API_ALLOWED_HOSTS") or ""
    return {h.strip().lower() for h in raw.split(",") if h.strip()}


def attester_reachability_problems(services: dict) -> list[str]:
    """Every reason the rendered attester could not reach the node across a node restart."""
    problems = []
    attester = services["oracle-attester"]
    node = services["wrfcoin-node"]

    mode = attester.get("network_mode") or ""
    if mode.startswith("service:") or mode.startswith("container:"):
        problems.append(
            f"oracle-attester uses network_mode {mode!r}: a node restart strands it in a dead netns"
        )

    host = (urlsplit(attester["environment"]["WRFCOIN_ATTESTER_NODE_URL"]).hostname or "").lower()
    if host != "wrfcoin-node":
        problems.append(f"oracle-attester node URL host is {host!r}, not the service name wrfcoin-node")

    shared = set(attester.get("networks") or {}) & set(node.get("networks") or {})
    if not shared:
        problems.append("oracle-attester shares no compose network with wrfcoin-node")

    if host and host not in LOOPBACK_HOSTS and host not in _allowed_hosts(node):
        problems.append(
            f"wrfcoin-node WRFCOIN_API_ALLOWED_HOSTS does not admit {host!r}: 403 HOST_NOT_ALLOWED"
        )
    return problems


def _require_compose():
    probe = subprocess.run(["docker", "compose", "version"], capture_output=True, check=False)
    if probe.returncode != 0:
        pytest.fail("docker compose is required to render the testnet stack (not a skip: infra#1044)")


def test_mango_overlay_source_has_no_shared_netns_and_uses_the_service_url():
    services = _load(TESTNET / MANGO_OVERLAY)["services"]
    attester = services["oracle-attester"]
    assert "network_mode" not in attester
    assert "networks" not in attester, "the attester must keep the base overlay's bridge network"
    assert attester["environment"]["WRFCOIN_ATTESTER_NODE_URL"] == "http://wrfcoin-node:8556"
    assert attester["build"] is None and attester["pull_policy"] == "never"
    init = services["oracle-softhsm-init"]
    assert init["network_mode"] == "none"


def test_node_overlay_admits_the_service_name():
    node = _load(TESTNET / NODE_OVERLAY)["services"]["wrfcoin-node"]
    assert node["environment"]["WRFCOIN_API_ALLOWED_HOSTS"] == "wrfcoin-node"


def test_no_repo_overlay_binds_an_attester_to_the_node_netns():
    offenders = []
    for path in sorted(TESTNET.glob("docker-compose*.yml")):
        doc = _load(path) or {}
        for name, svc in (doc.get("services") or {}).items():
            mode = str((svc or {}).get("network_mode") or "")
            if "attester" in name and (mode.startswith("service:") or mode.startswith("container:")):
                offenders.append(f"{path.name}:{name}:{mode}")
    assert offenders == []


def test_rendered_mango_stack_attester_reaches_node_across_restarts():
    _require_compose()
    services = _render(BASE_FILES + [NODE_OVERLAY, ATTESTER_BASE, MANGO_OVERLAY])
    assert attester_reachability_problems(services) == []
    attester = services["oracle-attester"]
    assert attester.get("network_mode") in (None, "")
    assert "wrfcoin-testnet" in attester["networks"]
    assert attester["environment"]["WRFCOIN_ATTESTER_NODE_URL"] == "http://wrfcoin-node:8556"
    assert "wrfcoin-node" in _allowed_hosts(services["wrfcoin-node"])
    assert attester["restart"] == "unless-stopped"
    assert services["oracle-softhsm-init"]["network_mode"] == "none"


def test_checker_is_red_on_the_20260925_netns_overlay():
    _require_compose()
    services = _render(BASE_FILES + [ATTESTER_BASE, LEGACY_NETNS_OVERLAY])
    problems = attester_reachability_problems(services)
    assert any("network_mode 'service:wrfcoin-node'" in p for p in problems), problems
    assert any("not the service name" in p for p in problems), problems


def test_checker_is_red_when_the_node_overlay_is_missing():
    _require_compose()
    services = _render(BASE_FILES + [ATTESTER_BASE, MANGO_OVERLAY])
    problems = attester_reachability_problems(services)
    assert problems == [
        "wrfcoin-node WRFCOIN_API_ALLOWED_HOSTS does not admit 'wrfcoin-node': 403 HOST_NOT_ALLOWED"
    ]
