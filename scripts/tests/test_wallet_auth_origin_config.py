"""The backend gateway must be handed a single HTTPS wallet-login origin.

Since backend#1052 the wallet-login (SIWE) flow binds each challenge to a
relying-party origin, and `createWalletAuthService()` resolves that origin at
process start. Under `NODE_ENV=production` (which every backend service in
docker-compose.testnet.yml runs) it *throws* when the origin is missing, not a
single value, or not HTTPS — and the throw is rethrown out of gateway startup,
so the whole API gateway crashes at boot rather than merely disabling login.

The trap is that the resolver falls back to `CORS_ORIGIN`, and CORS_ORIGIN is
legitimately a comma-separated list elsewhere in this stack (and until infra#1056
defaulted to `http://localhost:5000`). So relying on that fallback turns a normal CORS
configuration into a boot crash. This test pins the explicit, boot-safe wiring:

  * base wrfcoin-backend derives WRFCOIN_WALLET_AUTH_ORIGIN from the public
    funnel origin the operator already sets, with an https-localhost fallback so
    the tailnet-only base stack still boots, and an explicit override on top;
  * the public edge overlay binds it to the exact WRFCOIN_PUBLIC_DOMAIN host.

Run: python3 -m pytest scripts/tests/test_wallet_auth_origin_config.py
"""
import pathlib
import shutil
import subprocess

import pytest
import yaml

TESTNET = pathlib.Path(__file__).resolve().parents[2] / "testnet"
COMPOSE_BASE = TESTNET / "docker-compose.testnet.yml"
COMPOSE_EDGE = TESTNET / "docker-compose.edge.yml"

# The gateway service that instantiates createWalletAuthService() at boot.
GATEWAY = "wrfcoin-backend"
KEY = "WRFCOIN_WALLET_AUTH_ORIGIN"


def _env(compose_path, service):
    services = yaml.safe_load(compose_path.read_text())["services"]
    env = services[service].get("environment") or {}
    if isinstance(env, list):  # compose also accepts the KEY=VALUE list form
        env = dict(item.split("=", 1) for item in env if "=" in item)
    return {k: str(v) for k, v in env.items()}


def test_base_gateway_declares_a_wallet_auth_origin():
    env = _env(COMPOSE_BASE, GATEWAY)
    assert KEY in env, f"{GATEWAY} must set {KEY} or it crashes at boot under production"


def test_base_default_is_a_single_https_origin_not_http_localhost():
    value = _env(COMPOSE_BASE, GATEWAY)[KEY]
    # A single origin only — a comma list is rejected by resolveWalletAuthOrigin.
    assert "," not in value, f"{KEY} must be exactly one origin, got: {value}"
    # The literal fallback must be HTTPS; an http:// default would throw under
    # NODE_ENV=production and crash the gateway on the tailnet-only base stack.
    assert "http://localhost" not in value, (
        f"{KEY} fallback must be https, not http (production boot fails closed): {value}"
    )
    assert "https://localhost:5000" in value


def test_base_auto_derives_from_the_funnel_origin():
    # No separate operator step: a funnel deploy that sets WRFCOIN_FUNNEL_ORIGIN
    # must automatically bind wallet login to that same public origin, so it can
    # never silently diverge from the browser origin.
    value = _env(COMPOSE_BASE, GATEWAY)[KEY]
    assert "WRFCOIN_FUNNEL_ORIGIN" in value, (
        f"{KEY} must fall back to WRFCOIN_FUNNEL_ORIGIN so funnel deploys need no extra step: {value}"
    )
    # An explicit override must still win (outer :- on the var itself).
    assert value.startswith("${" + KEY + ":-"), (
        f"an explicit {KEY} must take precedence: {value}"
    )


def test_edge_overlay_binds_wallet_auth_origin_to_the_public_domain():
    value = _env(COMPOSE_EDGE, GATEWAY)[KEY]
    assert "," not in value
    assert value.startswith("https://${WRFCOIN_PUBLIC_DOMAIN"), (
        f"edge overlay must bind {KEY} to the public domain over https: {value}"
    )


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not available")
def test_base_expression_resolves_as_intended():
    """Render the *actual* base expression through docker compose and check the
    three resolution cases, so an edit that resolves to http/comma/missing under
    production is caught semantically, not just by string shape."""
    expr = _env(COMPOSE_BASE, GATEWAY)[KEY]
    synthetic = (
        "services:\n"
        "  t:\n"
        "    image: busybox\n"
        "    environment:\n"
        f"      WAO: {expr}\n"
    )

    def render(env_extra):
        proc = subprocess.run(
            ["docker", "compose", "-f", "-", "config"],
            input=synthetic,
            env={"PATH": "/usr/bin:/bin:/usr/local/bin", **env_extra},
            capture_output=True,
            text=True,
        )
        assert proc.returncode == 0, proc.stderr
        rendered = yaml.safe_load(proc.stdout)
        return rendered["services"]["t"]["environment"]["WAO"]

    # unset -> boot-safe https placeholder (NOT http, or production throws)
    assert render({}) == "https://localhost:5000"
    # funnel origin set -> auto-binds to the public origin, no extra step
    assert (
        render({"WRFCOIN_FUNNEL_ORIGIN": "https://wrfcoin-testnet.taila1c049.ts.net"})
        == "https://wrfcoin-testnet.taila1c049.ts.net"
    )
    # explicit override wins over both
    assert (
        render(
            {
                "WRFCOIN_WALLET_AUTH_ORIGIN": "https://override.example",
                "WRFCOIN_FUNNEL_ORIGIN": "https://funnel.example",
            }
        )
        == "https://override.example"
    )
