"""Weather collectors must not carry a station elevation default (core4#3285).

The collectors submit a `pressure_sea_level_hpa` reduced from the station's raw
pressure with the station's elevation, and the oracle attester recomputes it from
the on-chain registration. About 0.12 hPa per metre: a guessed elevation is a
wrong sea-level pressure. Owner ruling 2026-09-24: the elevation comes from the
on-chain registration (USGS DEM + sensor height, operator override wins), and a
station without one submits no sea-level value. No default, no guess.

Two defaults were wrong at the time of the ruling: core4's collector fell back to
220 m, and infra's unwired `scripts/collectors/ambient-weather-ws5000-collector.cjs`
said 250.7 m. Jon's owner-measured elevation is 227.7 m (747 ft). That script is
retired; this test keeps compose from reintroducing a default.

Run: python3 -m pytest scripts/tests/test_collector_station_elevation.py
"""
import pathlib
import re

import pytest
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]
COMPOSE = ROOT / "testnet" / "docker-compose.testnet.yml"
RETIRED = ROOT / "scripts" / "collectors" / "ambient-weather-ws5000-collector.cjs"

COLLECTOR_SERVICES = ["weather-collector", "weather-collector-multi"]
# Every variable the core4 collectors read as a station elevation.
ELEVATION_VARS = ["JONS_ELEVATION_M", "PWS_ELEVATION_M"]
# `${VAR}` or `${VAR:-}` with an EMPTY default; anything after `:-` is a default.
EMPTY_SUBSTITUTION = re.compile(r"^\$\{(?P<name>[A-Z_]+)(:-)?\}$")


@pytest.fixture(scope="module")
def services():
    return yaml.safe_load(COMPOSE.read_text())["services"]


def _env(services, name):
    env = services[name].get("environment") or {}
    if isinstance(env, list):  # compose also accepts the KEY=VALUE list form
        env = dict(item.split("=", 1) for item in env if "=" in item)
    return {k: "" if v is None else str(v) for k, v in env.items()}


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_collector_has_no_elevation_default(services, service):
    env = _env(services, service)
    for var in ELEVATION_VARS:
        if var not in env:
            continue
        value = env[var].strip()
        match = EMPTY_SUBSTITUTION.match(value)
        assert match and match.group("name") == var, (
            f"{service}.{var} = {value!r} hard-codes or defaults a station elevation; "
            f"it must be absent or `${{{var}:-}}` (an explicit operator override only)"
        )


@pytest.mark.parametrize("service", COLLECTOR_SERVICES)
def test_collector_can_reach_the_station_registry(services, service):
    """The elevation is read from the node's station registry, so the collector
    must be pointed at the node, not left on a localhost default."""
    env = _env(services, service)
    assert env.get("WRFCOIN_API_HOST") == "wrfcoin-node", (
        f"{service} is not pointed at wrfcoin-node for the registration lookup"
    )
    assert env.get("WRFCOIN_API_PORT") == "8556"


def test_retired_ws5000_script_is_gone_and_unreferenced():
    assert not RETIRED.exists(), (
        f"{RETIRED.relative_to(ROOT)} was retired under core4#3285 (unwired, could not "
        f"load, wrong 250.7 m elevation); the live collector is core4's"
    )
    assert RETIRED.name not in COMPOSE.read_text()
