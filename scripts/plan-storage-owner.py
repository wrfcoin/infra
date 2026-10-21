#!/usr/bin/env python3
"""Print a conditional r19/r20 owner plan; execute only Compose config."""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import yaml


FILES = (
    "docker-compose.testnet.yml", "docker-compose.override.yml",
    "docker-compose.weather-archive.yml", "docker-compose.storage-owner.yml",
)
MIGRATION = "0028_weather_archive_day_index"
URL = "http://storage-node:7001"
PROJECT = "testnet"  # must match the live stack's compose project name


def require(condition, code):
    if not condition:
        raise ValueError(code)


def validate(model, base, stage, enable):
    services = model["services"]
    daemon, kubo, worker = (services[name] for name in
                            ("storage-node", "ipfs-kubo", "weather-ipfs-archive"))
    require(daemon.get("profiles") == kubo.get("profiles") == ["ipfs-storage"], "IPFS_PROFILE")
    require(worker.get("profiles") == ["weather-archive"], "ARCHIVE_PROFILE")
    require(daemon.get("build", {}).get("dockerfile") == "infra/infra/docker/Dockerfile.storage"
            and not daemon.get("command"), "REAL_DAEMON")
    require(daemon["environment"].get("STORAGE_NODE_PROFILE") == "testnet"
            and daemon["environment"].get("IPFS_API_URL") == "http://ipfs-kubo:5001", "IPFS_ONLY")
    require(daemon.get("cap_drop") == ["ALL"] and daemon.get("read_only") is True, "DAEMON_POLICY")
    require(not any(s.get("ports") for s in (daemon, kubo, worker)), "NO_HOST_PORTS")
    require(model["networks"]["ipfs-private"].get("internal") is True
            and set(kubo["networks"]) == {"ipfs-private"}
            and set(daemon["networks"]) == {"ipfs-private", "wrfcoin-testnet"}, "PRIVATE_KUBO")
    require(daemon["depends_on"]["ipfs-kubo"]["condition"] == "service_healthy", "KUBO_BARRIER")
    require(any(v.get("type") == "volume" and v.get("source") == "testnet-ipfs-data"
                and v.get("target") == "/data/ipfs" for v in kubo.get("volumes", [])), "KUBO_DATA")
    require(worker.get("command") == ["node", "dist/weather_ipfs_archive.cjs"], "REAL_WORKER")
    env = worker["environment"]
    require(env.get("WRFCOIN_WEATHER_ARCHIVE_ENABLED") == enable, "EXPLICIT_ENABLE")
    require(env.get("WRFCOIN_STORAGE_NODE_URL") == URL
            and env.get("ENABLE_REAL_STORAGE") == "false", "DAEMON_CLIENT_SWITCH")
    require(env.get("WRFCOIN_WEATHER_ARCHIVE_DIR") == "/app/weather-archive", "RECEIPT_DIR")
    require(any(v.get("type") == "volume" and v.get("source") == "weather-ipfs-receipts"
                and v.get("target") == "/app/weather-archive" for v in worker.get("volumes", [])), "DURABLE_RECEIPTS")
    require(services["db-migrate"]["environment"].get("WRFCOIN_EXPECTED_DB_MIGRATION") == MIGRATION
            and worker["depends_on"]["db-migrate"]["condition"] == "service_completed_successfully", "MIGRATION_BARRIER")
    if stage == "r20":
        # REGRESSION GUARD (not a live gate): the mock `wrfcoin-storage` was
        # retired (backend#1439, infra#1241) and is absent from current main.
        # Refuse if it ever reappears. Inspect the unfiltered base too, since
        # Compose may omit inactive full-profile services from config.
        require("wrfcoin-storage" not in base["services"], "MOCK_REAPPEARED")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--stage", choices=("r19", "r20"), required=True)
    parser.add_argument("--archive-enable", default="")
    args = parser.parse_args()
    try:
        require(args.archive_enable in ("", "true"), "EXACT_ENABLE_VALUE")
        require(args.stage != "r19" or not args.archive_enable, "R19_ARCHIVE_OFF")
        # Exactness is enforced above; r20 additionally requires the switch on.
        require(args.stage != "r20" or bool(args.archive_enable), "R20_EXPLICIT_ENABLE")
        root = args.root.resolve()
        paths = [root / "testnet" / name for name in FILES]
        env_file = args.env_file.resolve()
        require(all(p.is_file() for p in paths)
                and (env_file.is_file() or env_file == Path("/dev/null")), "INPUTS_REQUIRED")
        base = yaml.safe_load(paths[0].read_text())
        command = ["docker", "compose", "-p", PROJECT, "--env-file", str(env_file)]
        for path in paths:
            command += ["-f", str(path)]
        command += ["--profile", "ipfs-storage", "--profile", "weather-archive"]
        env = dict(os.environ)
        env.update(WRFCOIN_WEATHER_ARCHIVE_ENABLED=args.archive_enable, COMPOSE_PROFILES="")
        rendered = subprocess.run(command + ["config", "--format", "json"], env=env,
                                  capture_output=True, text=True, timeout=30)
        require(rendered.returncode == 0 and len(rendered.stdout) <= 16 * 1024 * 1024,
                "RENDER_FAILED")
        model = json.loads(rendered.stdout)
        validate(model, base, args.stage, args.archive_enable)
        print(f"STORAGE_OWNER=PASS render-only stage={args.stage} archive={'on' if args.archive_enable else 'off'}")
        print("DRAFT commands; not executed. Owner must satisfy README prerequisites first.")
        prefix = ["env", "COMPOSE_PROFILES=", "WRFCOIN_WEATHER_ARCHIVE_ENABLED=" + args.archive_enable] + command
        print(shlex.join(prefix + ["up", "-d", "--no-deps", "--no-build", "--pull", "never", "ipfs-kubo", "storage-node"]))
        probe = "fetch('http://storage-node:7001/health',{signal:AbortSignal.timeout(5000)}).then(r=>{if(r.status!==200)process.exit(1);console.log('STORAGE_HEALTH=PASS')}).catch(()=>process.exit(1))"
        print(shlex.join(prefix + ["exec", "-T", "wrfcoin-backend", "node", "-e", probe]))
        if args.stage == "r20":
            print(shlex.join(prefix + ["up", "-d", "--no-deps", "--no-build", "--pull", "never", "weather-ipfs-archive"]))
        return 0
    except (OSError, ValueError, KeyError, TypeError, yaml.YAMLError, subprocess.SubprocessError):
        # Never export the rendered model, env-file contents or Compose stderr.
        print("STORAGE_OWNER=STOP: required inputs, exact switch or reviewed wiring unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
