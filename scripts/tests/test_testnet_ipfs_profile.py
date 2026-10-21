"""Render-only checks for the opt-in testnet IPFS profile; no daemon access."""
import json
from pathlib import Path
import subprocess
import pytest
import yaml

ROOT = Path(__file__).parents[2]


@pytest.mark.parametrize("service", ["storage-node", "ipfs-kubo"])
def test_ipfs_services_have_no_host_exposure(service):
    ledger = yaml.safe_load((ROOT / "testnet/edge/route-ledger.yml").read_text())
    assert ledger["services"][service]["exposure"] == "never"


def render(*extra):
    result = subprocess.run([
        "docker", "compose", "--env-file", "/dev/null", "-f",
        str(ROOT / "testnet/docker-compose.testnet.yml"), *extra,
        "config", "--no-interpolate", "--format", "json",
    ], capture_output=True, text=True, check=True)
    return json.loads(result.stdout)


def test_default_and_full_profiles_do_not_start_storage():
    # Compose config versions may render inactive descriptors too. Startup
    # selects unprofiled services plus services matching an enabled profile.
    services = render()["services"]
    for enabled in [set(), {"full"}]:
        selected = {name for name, service in services.items()
                    if not service.get("profiles") or enabled.intersection(service["profiles"])}
        assert "storage-node" not in selected
        assert "ipfs-kubo" not in selected
        for name in selected:
            assert not {"storage-node", "ipfs-kubo"}.intersection(
                services[name].get("depends_on", {}))


def test_explicit_profile_wires_real_daemon_and_private_kubo():
    config = render("--profile", "ipfs-storage")
    services = config["services"]
    daemon, kubo = services["storage-node"], services["ipfs-kubo"]
    assert daemon["profiles"] == kubo["profiles"] == ["ipfs-storage"]
    assert daemon["build"]["dockerfile"] == "infra/infra/docker/Dockerfile.storage"
    assert "command" not in daemon
    assert daemon["environment"] == {
        "STORAGE_NODE_PROFILE": "testnet", "IPFS_API_URL": "http://ipfs-kubo:5001",
    }
    assert daemon["depends_on"]["ipfs-kubo"]["condition"] == "service_healthy"
    assert daemon.get("healthcheck") is None  # distroless has no shell/curl
    assert kubo["image"] == "ipfs/kubo:v0.24.0"
    assert config["networks"]["ipfs-private"]["internal"] is True
    assert set(kubo["networks"]) == {"ipfs-private"}
    assert set(daemon["networks"]) == {"ipfs-private", "wrfcoin-testnet"}
    for service in (daemon, kubo):
        assert not service.get("ports")
        assert service["cap_drop"] == ["ALL"]
        assert "no-new-privileges:true" in service["security_opt"]
    assert any(v["type"] == "volume" and v["source"] == "testnet-ipfs-data"
               and v["target"] == "/data/ipfs" for v in kubo["volumes"])


def test_kubo_healthcheck_probes_rpc_without_reading_the_repo():
    # The entrypoint drops the daemon to uid 1000, but healthchecks exec as
    # root. With cap_drop ALL there is no DAC_OVERRIDE, so `ipfs id` cannot
    # open the 0600 /data/ipfs/config and kubo never turns healthy, which
    # blocks storage-node's service_healthy dependency (r20 step 26).
    kubo = render("--profile", "ipfs-storage")["services"]["ipfs-kubo"]
    assert kubo["healthcheck"]["test"] == [
        "CMD-SHELL",
        "wget -q -O /dev/null --post-data='' http://127.0.0.1:5001/api/v0/id || exit 1",
    ]
    # The probe is fixed without widening the container's privileges.
    assert kubo["cap_add"] == ["CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"]
    assert {"interval": "30s", "timeout": "10s", "retries": 3, "start_period": "30s"}.items() \
        <= kubo["healthcheck"].items()
