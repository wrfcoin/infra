"""The backend API must declare the chain identity the node validates.

backend#1287 added POST /api/oracle/submit-data/prepare, which returns the
commit-authorization inputs a phone signs (server/routes/oracle-submit-routes.ts,
declaredChainIdentity()). It reads WRFCOIN_CHAIN_ID and WRFCOIN_NETWORK_ID and
returns NO chain identity unless both are set: it deliberately never guesses a
default. Without them the phone has no domain to sign, and it cannot build a
commit authorization this chain accepts.

Same policy as collectors: chain defaults must be nonempty or required,
network stays literal testnet, and both equal the node values.

Run: python3 -m pytest scripts/tests/test_backend_chain_identity.py
"""
import pathlib

import pytest
from chain_identity_policy import assert_safe_identity

import yaml

COMPOSE = (
    pathlib.Path(__file__).resolve().parents[2] / "testnet" / "docker-compose.testnet.yml"
)
MAINNET_DEFAULTS = {"wrfcoin-main", "mainnet"}
IDENTITY = ("WRFCOIN_CHAIN_ID", "WRFCOIN_NETWORK_ID")


def _env(name):
    env = yaml.safe_load(COMPOSE.read_text())["services"][name].get("environment") or {}
    if isinstance(env, list):
        env = dict(item.split("=", 1) for item in env if "=" in item)
    return {k: str(v) for k, v in env.items()}


def test_backend_declares_chain_identity():
    env = _env("wrfcoin-backend")
    for var in IDENTITY:
        assert var in env, (
            f"wrfcoin-backend does not declare {var}; /api/oracle/submit-data/prepare "
            f"then returns no chain identity"
        )
        value = env[var].strip()
        assert value, f"wrfcoin-backend declares {var} but leaves it empty"
        assert_safe_identity(var, value)
        assert value not in MAINNET_DEFAULTS, f"wrfcoin-backend.{var} is the mainnet default {value!r}"


def test_backend_chain_identity_matches_the_node():
    """Compared with the node rather than a literal, so a re-cut cannot leave the backend behind."""
    node, backend = _env("wrfcoin-node"), _env("wrfcoin-backend")
    assert backend.get("WRFCOIN_CHAIN_ID") == node["WRFCOIN_CHAIN_ID"], (
        f"wrfcoin-backend declares chain {backend.get('WRFCOIN_CHAIN_ID')!r}, "
        f"the node validates {node['WRFCOIN_CHAIN_ID']!r}"
    )
    assert backend.get("WRFCOIN_NETWORK_ID") == node["WRFCOIN_NETWORK_ID"], (
        f"wrfcoin-backend declares network {backend.get('WRFCOIN_NETWORK_ID')!r}, "
        f"the node validates {node['WRFCOIN_NETWORK_ID']!r}"
    )


@pytest.mark.parametrize("value", ["${WRFCOIN_CHAIN_ID}", "${WRFCOIN_CHAIN_ID:-}", "${WRFCOIN_CHAIN_ID-777}", "${OTHER:-777}"])
def test_backend_guard_rejects_empty_or_wrong_input(monkeypatch, value):
    original = _env
    monkeypatch.setattr(__import__(__name__), '_env',
                        lambda name: {**original(name), 'WRFCOIN_CHAIN_ID': value})
    with pytest.raises(AssertionError):
        test_backend_declares_chain_identity()
