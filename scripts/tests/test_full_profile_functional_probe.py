#!/usr/bin/env python3
"""Loopback fixture-server tests for full-profile functional probes."""

from __future__ import annotations

import datetime
import importlib.util
import json
import subprocess
import sys
import threading
import unittest
import urllib.parse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PROBE_PATH = (
    Path(__file__).parents[2]
    / "testnet"
    / "scripts"
    / "full-profile-functional-probe.py"
)
SMOKE_PATH = Path(__file__).parents[2] / "testnet" / "scripts" / "smoke-full.sh"
SPEC = importlib.util.spec_from_file_location(
    "full_profile_functional_probe", PROBE_PATH
)
assert SPEC is not None and SPEC.loader is not None
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class FixtureHandler(BaseHTTPRequestHandler):
    mode = "functional"
    service = "cross-chain"

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/health":
            self._json(200, {"status": "healthy"})
            return
        contract = probe.SERVICE_CONTRACTS[self.service]
        if parsed.path != contract["path"]:
            self._json(404, {"error": "not found"})
            return
        nonce = urllib.parse.parse_qs(parsed.query).get("readiness_nonce", [""])[0]
        if self.mode == "unavailable":
            self._json(
                501,
                {
                    "success": False,
                    "unavailable": True,
                    "reason": "real dependency is not wired",
                    "error": {
                        "code": "NOT_IMPLEMENTED",
                        "capability": contract["capability"],
                    },
                },
            )
            return
        if self.mode == "health-only":
            self._json(200, {"status": "healthy"})
            return
        if self.mode == "constant":
            nonce = "canned-nonce"
        connected = self.mode != "disconnected"
        self._json(
            200,
            {
                "success": True,
                "capability": contract["capability"],
                "readiness": {
                    "evidence_class": "FUNCTIONAL",
                    "source": "live_dependency_probe",
                    "nonce": nonce,
                    "observed_at": datetime.datetime.now(
                        datetime.timezone.utc
                    ).isoformat(),
                    "dependency": {
                        "kind": contract["dependency_kind"],
                        "connected": connected,
                        "target": f"fixture-{self.service}",
                    },
                },
            },
        )

    def _json(self, status: int, body: dict[str, object]) -> None:
        encoded = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, fmt: str, *args: object) -> None:
        return


@contextmanager
def fixture_server(service: str, mode: str):
    FixtureHandler.service = service
    FixtureHandler.mode = mode
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def run_probe(service: str, base_url: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(PROBE_PATH), "--service", service, "--base-url", base_url],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
    )


class FullProfileFunctionalProbeTest(unittest.TestCase):
    def test_smoke_wires_one_functional_probe_per_full_profile_service(self) -> None:
        smoke = SMOKE_PATH.read_text(encoding="utf-8")
        expected = {
            'run_functional_probe "Cross-chain" "cross-chain"',
            'run_functional_probe "Compute" "compute"',
            'run_functional_probe "AI/ML" "ml"',
            'run_functional_probe "Node discovery" "node-discovery"',
        }
        for invocation in expected:
            with self.subTest(invocation=invocation):
                self.assertEqual(smoke.count(invocation), 1)

    def test_each_service_accepts_fresh_nonce_bound_dependency_evidence(self) -> None:
        for service in probe.SERVICE_CONTRACTS:
            with (
                self.subTest(service=service),
                fixture_server(service, "functional") as url,
            ):
                result = run_probe(service, url)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("live ", result.stdout)

    def test_health_200_cannot_mask_broken_domain_endpoint(self) -> None:
        for service in probe.SERVICE_CONTRACTS:
            with (
                self.subTest(service=service),
                fixture_server(service, "health-only") as url,
            ):
                health_status, _ = probe.request_json(f"{url}/health", 1)
                self.assertEqual(health_status, 200)
                result = run_probe(service, url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "UNAVAILABLE (unproven, not release-green)", result.stdout
                )
                self.assertIn("health-only/canned", result.stdout)

    def test_constant_payload_cannot_replay_probe_nonce(self) -> None:
        for service in probe.SERVICE_CONTRACTS:
            with (
                self.subTest(service=service),
                fixture_server(service, "constant") as url,
            ):
                result = run_probe(service, url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("constant/cached", result.stdout)

    def test_disconnected_dependency_is_red(self) -> None:
        for service in probe.SERVICE_CONTRACTS:
            with (
                self.subTest(service=service),
                fixture_server(service, "disconnected") as url,
            ):
                result = run_probe(service, url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("dependency is not connected", result.stdout)

    def test_honest_unavailable_is_explicit_but_not_release_green(self) -> None:
        for service in ("cross-chain", "compute", "ml"):
            with (
                self.subTest(service=service),
                fixture_server(service, "unavailable") as url,
            ):
                result = run_probe(service, url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("UNAVAILABLE (honest, not release-green)", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
