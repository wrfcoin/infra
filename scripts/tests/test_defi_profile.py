"""Render the real opt-in overlay with inert settings; never start the testnet."""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "testnet/docker-compose.defi.yml"
BASE = ROOT / "testnet/docker-compose.testnet.yml"


class DeFiProfileTest(unittest.TestCase):
    def render(self, enabled=False, url=""):
        self.assertTrue(OVERLAY.is_file(), "missing opt-in DeFi Compose surface")
        env = {"PATH": os.environ["PATH"], "COMPOSE_DISABLE_ENV_FILE": "1", "DEFI_NODE_URL": url}
        for name in ("POSTGRES_PASSWORD", "REDIS_PASSWORD", "JWT_SECRET", "GRAFANA_ADMIN_PASSWORD",
                     "OAUTH_STATE_SECRET", "RPC_API_KEY", "ADMIN_TOKEN", "N8N_WEBHOOK_SECRET",
                     "WRFCOIN_OPERATOR_TOKEN", "WRFCOIN_CONTRIBUTOR_TOKEN", "WRFCOIN_HSM_PIN",
                     "WRFCOIN_HSM_SO_PIN"):
            env[name] = "synthetic-config-only"
        env["WRFCOIN_P2P_EXTERNAL_ADDR"] = "/ip4/198.51.100.7/tcp/9000"
        command = ["docker", "compose", "--env-file", "/dev/null", "-p", "solm-defi-config",
                   "-f", str(BASE), "-f", str(OVERLAY)]
        if enabled:
            command += ["--profile", "defi"]
        result = subprocess.run(command + ["config", "--format", "json"], env=env,
                                cwd=ROOT, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_default_profile_has_no_defi_service_or_backend_target(self):
        config = self.render()
        self.assertNotIn("wrfcoin-defi", config["services"])
        self.assertEqual(config["services"]["wrfcoin-backend"]["environment"]["DEFI_NODE_URL"], "")

    def test_enabled_service_uses_offline_build_and_real_probe(self):
        service = self.render(True)["services"]["wrfcoin-defi"]
        self.assertEqual(service["profiles"], ["defi"])
        self.assertEqual(service["pull_policy"], "never")
        self.assertEqual(service["healthcheck"]["test"], ["CMD", "/usr/local/bin/defi-healthcheck"])
        self.assertEqual(service["environment"]["DEFI_NODE_BIND"], "0.0.0.0:7100")
        self.assertEqual(service["environment"]["DEFI_NODE_POOLS"], "/etc/defi-node/pools.toml")
        dockerfile = ROOT / "testnet/services/defi/Dockerfile"
        self.assertIn("--offline --locked -p defi-node", dockerfile.read_text())
        self.assertIn("COPY .cache/registry/", dockerfile.read_text())
        self.assertNotIn("additional_contexts", service["build"])

    def test_simulator_has_no_host_port_or_custody_storage(self):
        service = self.render(True)["services"]["wrfcoin-defi"]
        for key in ("ports", "volumes", "devices", "secrets", "privileged", "container_name"):
            self.assertFalse(service.get(key), key)
        self.assertEqual(set(service["networks"]), {"wrfcoin-testnet"})
        self.assertTrue(service["read_only"])
        self.assertEqual(service["cap_drop"], ["ALL"])
        self.assertIn("no-new-privileges:true", service["security_opt"])

    def test_existing_backend_relay_target_is_explicit_and_health_ordered(self):
        config = self.render(True, "http://wrfcoin-defi:7100")
        backend = config["services"]["wrfcoin-backend"]
        self.assertEqual(backend["environment"]["DEFI_NODE_URL"], "http://wrfcoin-defi:7100")
        dependency = backend["depends_on"]["wrfcoin-defi"]
        self.assertEqual(dependency["condition"], "service_healthy")
        self.assertFalse(dependency["required"])


if __name__ == "__main__":
    unittest.main()
