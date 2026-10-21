"""Pin the legacy storage stack's kubo healthcheck (same bug as infra#1280).

Healthchecks exec as root. With cap_drop ALL there is no DAC_OVERRIDE, so
`ipfs id` cannot open the daemon-owned 0600 /data/ipfs/config and kubo never
turns healthy. Probe the local RPC API instead. File-parse only; no docker.
"""
from pathlib import Path
import yaml

ROOT = Path(__file__).parents[2]
COMPOSE = ROOT / "infra/docker/docker-compose.storage.yml"
PROBE = "wget -q -O /dev/null --post-data='' http://127.0.0.1:5001/api/v0/id || exit 1"


def test_legacy_storage_kubo_probes_rpc_without_reading_the_repo():
    ipfs = yaml.safe_load(COMPOSE.read_text())["services"]["ipfs"]
    assert ipfs["cap_drop"] == ["ALL"]
    assert "DAC_OVERRIDE" not in ipfs.get("cap_add", [])
    assert ipfs["healthcheck"]["test"] == ["CMD-SHELL", PROBE]
    assert {"interval": "30s", "timeout": "10s", "retries": 3, "start_period": "30s"}.items() \
        <= ipfs["healthcheck"].items()
