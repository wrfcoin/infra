"""Render-only worker wiring; parent profile and backend worker must land first."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).parents[2]


def test_worker_is_opt_in_and_records_cids_on_a_persistent_volume():
    result = subprocess.run([
        "docker", "compose", "--env-file", "/dev/null",
        "-f", str(ROOT / "testnet/docker-compose.testnet.yml"),
        "-f", str(ROOT / "testnet/docker-compose.weather-archive.yml"),
        "--profile", "ipfs-storage", "--profile", "weather-archive",
        "config", "--no-interpolate", "--format", "json",
    ], capture_output=True, text=True, check=True)
    services = json.loads(result.stdout)["services"]
    service = services["weather-ipfs-archive"]
    assert service["profiles"] == ["weather-archive"]
    assert service["command"] == ["node", "dist/weather_ipfs_archive.cjs"]
    assert service["environment"]["WRFCOIN_WEATHER_ARCHIVE_ENABLED"] == "true"
    assert service["environment"]["WRFCOIN_STORAGE_NODE_URL"] == "http://storage-node:7001"
    assert service["environment"]["WRFCOIN_WEATHER_ARCHIVE_DIR"] == "/app/weather-archive"
    assert service["user"] == "1001:1001"
    assert service["healthcheck"]["disable"] is True
    assert service["depends_on"]["storage-node"]["condition"] == "service_started"
    assert service["depends_on"]["postgres"]["condition"] == "service_healthy"
    assert service["depends_on"]["db-migrate"]["condition"] == "service_completed_successfully"
    migration_env = services["db-migrate"]["environment"]
    if isinstance(migration_env, list):
        migration_env = dict(item.split("=", 1) for item in migration_env)
    assert migration_env["WRFCOIN_EXPECTED_DB_MIGRATION"] == "0028_weather_archive_day_index"
    assert not service.get("ports")
    assert service["read_only"] is True
    assert any(v["type"] == "volume" and v["source"] == "weather-ipfs-receipts"
               and v["target"] == "/app/weather-archive" for v in service["volumes"])


def test_backend_image_packages_the_worker_and_prepares_its_writable_mount():
    entries = (ROOT / "infra/docker/esbuild-backend.sh").read_text()
    assert "server/weather-ipfs-archive-worker.ts:dist/weather_ipfs_archive.cjs" in entries
    dockerfile = (ROOT / "infra/docker/Dockerfile.backend").read_text()
    assert "mkdir -p /app/weather-archive" in dockerfile
    assert "chown -R wrfcoin:nodejs /app" in dockerfile
