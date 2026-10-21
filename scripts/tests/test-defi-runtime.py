#!/usr/bin/env python3
"""Explicit cached-image smoke in a disposable project, never the testnet stack."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

from test_defi_profile import DeFiProfileTest


def run():
    service = DeFiProfileTest().render(True)["services"]["wrfcoin-defi"]
    # Never build or pull here: an absent prebuilt image is a hard failure.
    subprocess.run(["docker", "image", "inspect", service["image"]], check=True,
                   stdout=subprocess.DEVNULL)
    service.pop("build")
    service["networks"] = {"isolated": {}}
    service["restart"] = "no"
    project = "solm-defi-smoke-" + uuid.uuid4().hex[:10]
    config = {"services": {"wrfcoin-defi": service}, "networks": {"isolated": {"internal": True}}}
    env = {"PATH": os.environ["PATH"], "COMPOSE_DISABLE_ENV_FILE": "1"}
    with tempfile.TemporaryDirectory(prefix=project) as directory:
        path = Path(directory) / "compose.json"
        path.write_text(json.dumps(config))
        command = ["docker", "compose", "--env-file", "/dev/null", "-p", project,
                   "-f", str(path), "--profile", "defi"]
        try:
            subprocess.run(command + ["up", "-d", "--no-build", "--pull", "never",
                                      "--wait", "--wait-timeout", "45"], env=env, check=True, timeout=60)
            container = subprocess.check_output(command + ["ps", "-q", "wrfcoin-defi"],
                                                env=env, text=True).strip()
            client = "node:24-alpine"
            subprocess.run(["docker", "image", "inspect", client], check=True,
                           stdout=subprocess.DEVNULL)

            def request(path, expected, payload=None):
                # Client shares only our disposable service's network namespace.
                javascript = """const [path, payload] = process.argv.slice(1);
                  const options = payload === 'null' ? {} : {method:'POST',
                    headers:{'content-type':'application/json'}, body:payload};
                  const r = await fetch('http://127.0.0.1:7100'+path,
                    {...options,signal:AbortSignal.timeout(5000)});
                  console.log(JSON.stringify({status:r.status,body:await r.text()}));"""
                result = subprocess.check_output(["docker", "run", "--rm", "--pull=never",
                    "--network", "container:" + container, "--read-only", "--cap-drop=ALL",
                    "--security-opt", "no-new-privileges:true", client, "node", "--input-type=module",
                    "-e", javascript, path, json.dumps(payload)], text=True, timeout=15)
                response = json.loads(result)
                assert response["status"] == expected, (path, response["status"])
                return json.loads(response["body"]) if response["body"] else None

            def simulator(body):
                assert body["simulated"] is True
                assert body["custodial"] is False
                assert body["settlement"] == "none"

            simulator(request("/health", 200))
            pools = request("/api/defi/pools", 200)
            simulator(pools)
            assert len(pools["pools"]) == 2
            quote = request("/api/defi/pools/1/quote", 200,
                            {"amount_in": "100000000", "direction": "a_to_b"})
            simulator(quote)
            expected = (100000000 * 9970 * 250000000000) // (100000000000 * 10000 + 100000000 * 9970)
            assert quote["amount_out"] == str(expected), quote
            portfolio = request("/api/defi/portfolio/0xabc", 501)
            simulator(portfolio)
            assert portfolio["unavailable"] is True
            for route in ("swap", "transfer", "deposit", "withdraw"):
                request("/api/defi/" + route, 404, {})
                request("/api/defi/pools/1/" + route, 404, {})
            # The production executable must reject a stopped endpoint, not merely exist.
            negative = subprocess.run(command + ["exec", "-T", "-e", "DEFI_NODE_BIND=0.0.0.0:1",
                                                 "wrfcoin-defi", "/usr/local/bin/defi-healthcheck"], env=env)
            assert negative.returncode != 0, "health probe accepted an unavailable endpoint"
            print("PASS: real Compose boot/healthy, pools, exact quote, unavailable portfolio, eight absent monetary routes, negative health")
        finally:
            subprocess.run(command + ["down", "--volumes", "--remove-orphans", "--timeout", "5"],
                           env=env, check=True, timeout=30)


if __name__ == "__main__":
    run()
