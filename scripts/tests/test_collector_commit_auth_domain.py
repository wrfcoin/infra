"""The weather collector must declare its chain identity in compose.

Since core4#1848 the mempool refuses a `ContributionCommit` whose `CommitPayload`
carries no valid `auth_pubkey`/`auth_signature`, and the collector signs that
authorization itself over a domain-separated message. It resolves the domain from
`WRFCOIN_CHAIN_ID`/`WRFCOIN_NETWORK_ID`, defaulting to `wrfcoin-main`/`mainnet`.

So an unset variable does not disable the signature and does not raise anything —
it produces a valid signature over the *mainnet* domain, which this chain rejects
as `commit sender authorization failed`. There is no error at startup, no warning
in the logs, and no symptom at all until a station has real readings to submit.
That is why this is a test and not a runbook line: the failure is invisible right
up to the moment it costs a contributor their rewards.

Measured 2026-08-06 against the live chain: 12/12 commits rejected with these
unset, 12/12 accepted with them set - same station, same keys, same minute.

Run: python3 -m pytest scripts/tests/test_collector_commit_auth_domain.py
"""
import pathlib
from chain_identity_policy import assert_safe_identity

import pytest
import yaml

COMPOSE = (
    pathlib.Path(__file__).resolve().parents[2] / "testnet" / "docker-compose.testnet.yml"
)

# Mirrors ambient-pipeline.cjs DEFAULT_CHAIN_ID / DEFAULT_NETWORK_ID, which mirror
# shared-protocol/src/crypto/domain_signing.rs. A collector left on these is
# signing for mainnet.
MAINNET_DEFAULTS = {"wrfcoin-main", "mainnet"}

# Every service that SIGNS a commit authorization. Each new contributor
# collector must be added here, because the failure it guards against is silent:
# an unset chain identity produces a valid signature over the mainnet domain and
# the node rejects every commit.
COLLECTOR_SERVICES = ["weather-collector", "weather-collector-multi"]


@pytest.fixture(scope="module")
def services():
    return yaml.safe_load(COMPOSE.read_text())["services"]


def _env(services, name):
    env = services[name].get("environment") or {}
    if isinstance(env, list):  # compose also accepts the KEY=VALUE list form
        env = dict(item.split("=", 1) for item in env if "=" in item)
    return {k: str(v) for k, v in env.items()}


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_collector_declares_chain_identity(services, service):
    env = _env(services, service)
    for var in ("WRFCOIN_CHAIN_ID", "WRFCOIN_NETWORK_ID"):
        assert var in env, (
            f"{service} does not declare {var}; the commit authorization would be "
            f"signed for the mainnet domain and rejected by this chain"
        )
        assert env[var].strip(), f"{service} declares {var} but leaves it empty"


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_chain_identity_is_not_env_substituted(services, service):
    """Absent and empty host inputs must not select the mainnet domain."""
    env = _env(services, service)
    for var in ("WRFCOIN_CHAIN_ID", "WRFCOIN_NETWORK_ID"):
        assert_safe_identity(var, env[var])


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
@pytest.mark.parametrize("value", ["${WRFCOIN_CHAIN_ID}", "${WRFCOIN_CHAIN_ID:-}", "${WRFCOIN_CHAIN_ID-777}"])
def test_collector_guard_rejects_empty_domain(services, service, value):
    import copy
    mutated = copy.deepcopy(services)
    mutated[service]['environment']['WRFCOIN_CHAIN_ID'] = value
    with pytest.raises(AssertionError):
        test_chain_identity_is_not_env_substituted(mutated, service)


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_chain_identity_is_not_the_mainnet_default(services, service):
    env = _env(services, service)
    for var in ("WRFCOIN_CHAIN_ID", "WRFCOIN_NETWORK_ID"):
        assert env[var].strip() not in MAINNET_DEFAULTS, (
            f"{service}.{var} is set to the mainnet default {env[var]!r}"
        )


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_chain_identity_matches_the_node(services, service):
    """Collector and node must agree, or the signature verifies against nothing.

    Compared against the node service rather than a literal, so a future chain
    cut that repins the node cannot leave the collector behind.
    """
    node = _env(services, "wrfcoin-node")
    env = _env(services, service)
    assert "WRFCOIN_CHAIN_ID" in env, f"{service} declares no WRFCOIN_CHAIN_ID to compare"
    assert env["WRFCOIN_CHAIN_ID"] == node["WRFCOIN_CHAIN_ID"], (
        f"{service} signs for chain {env['WRFCOIN_CHAIN_ID']} but the node "
        f"validates chain {node['WRFCOIN_CHAIN_ID']}"
    )


@pytest.mark.parametrize("service", ["weather-collector"])
def test_contributor_address_is_declared(services, service):
    """The payout address must be explicit, not inherited from a JS default.

    Rewards go to the reveal's first output address, not to the station
    registry's `owner_address` (core4#2743) - so this variable, not the
    registration, decides who is actually paid.
    """
    env = _env(services, service)
    assert "JONS_CONTRIBUTOR" in env, (
        f"{service} does not declare JONS_CONTRIBUTOR; the payout address falls "
        f"back to a literal inside fetch-ambient-weather.cjs"
    )
    assert "0xed36d00b294c5eecdc5e12bdf712d786bd919b08" in env["JONS_CONTRIBUTOR"], (
        "JONS_CONTRIBUTOR does not name the address PWS-EXAMPLE-WS5000 was "
        "registered to in block 674"
    )
