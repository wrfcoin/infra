#!/usr/bin/env python3
"""Focused tests for alert receiver notification identity rendering."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import socket
import ssl
import subprocess
import threading
import time
import unittest
import urllib.error
import urllib.request
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch


RECEIVER_PATH = (
    Path(__file__).parents[2] / "testnet" / "alertmanager-webhook-receiver.py"
)
CANARY_PATH = Path(__file__).parents[2] / "testnet" / "scripts" / "alert-delivery-canary.sh"
SPEC = importlib.util.spec_from_file_location(
    "alertmanager_webhook_receiver", RECEIVER_PATH
)
assert SPEC is not None and SPEC.loader is not None
receiver = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(receiver)


class AlertReceiverComposeTest(unittest.TestCase):
    def test_standard_stack_publishes_health_endpoint_on_loopback_only(self) -> None:
        compose_path = Path(__file__).parents[2] / "testnet" / "docker-compose.override.yml"
        text = compose_path.read_text(encoding="utf-8")
        self.assertIn(
            '      - "127.0.0.1:${ALERT_RECEIVER_HOST_PORT:-19093}:19093"',
            text,
        )


class ForwardDiagnosticsTest(unittest.TestCase):
    def test_failure_categories_are_explicit_and_do_not_expose_destination(self):
        secret_url = "https://example.invalid/SYNTHETIC_PRIVATE_TOPIC?token=SYNTHETIC_TOKEN"
        cases = [
            (urllib.error.URLError(socket.gaierror(socket.EAI_AGAIN, "Try again")), "dns_error", "gaierror"),
            (urllib.error.URLError(ssl.SSLError(secret_url)), "tls_error", "SSLError"),
            (TimeoutError(), "timeout", "TimeoutError"),
            (urllib.error.URLError(TimeoutError()), "timeout", "TimeoutError"),
            (urllib.error.URLError(ConnectionRefusedError(111, secret_url)), "connection_error", "ConnectionRefusedError"),
            (urllib.error.URLError(secret_url), "network_error", "URLError"),
            (urllib.error.HTTPError(secret_url, 403, secret_url, {}, None), "http_error", "HTTPError"),
        ]
        for error, expected, error_type in cases:
            with self.subTest(expected=expected), patch.object(receiver.urllib.request, "urlopen", side_effect=error):
                output = io.StringIO()
                with redirect_stderr(output):
                    result = receiver.forward_summary(secret_url, "ntfy", 0.1, summary_for({"alertname": "DiagnosticTest"}))
                self.assertEqual(result["status"], expected)
                self.assertEqual(result["error_type"], error_type)
                self.assertIn(expected, output.getvalue())
                for private in [secret_url, "SYNTHETIC_PRIVATE_TOPIC", "SYNTHETIC_TOKEN"]:
                    self.assertNotIn(private, output.getvalue() + json.dumps(result))
                if expected == "dns_error":
                    self.assertEqual(result["errno"], socket.EAI_AGAIN)
                if expected == "http_error":
                    self.assertEqual(result["http_status"], 403)

    def test_self_test_does_not_print_forward_destination_or_chat_id(self):
        args = type("Args", (), {"forward_url": "https://example.invalid/SYNTHETIC_PRIVATE_TOPIC?chat_id=SYNTHETIC_CHAT", "forward_format": "telegram", "forward_timeout": 0.1})()
        output = io.StringIO()
        with patch.object(receiver, "forward_summary", return_value={"status": "succeeded"}), redirect_stdout(output):
            self.assertEqual(receiver.run_self_test(args), 0)
        self.assertNotIn("SYNTHETIC_PRIVATE_TOPIC", output.getvalue())
        self.assertNotIn("SYNTHETIC_CHAT", output.getvalue())


class LocalSinkHandler(BaseHTTPRequestHandler):
    response_status = 204
    delay_seconds = 0.0
    requests: list[dict[str, object]] = []

    def do_POST(self) -> None:
        if self.delay_seconds:
            time.sleep(self.delay_seconds)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        self.requests.append({"path": self.path, "body": body})
        self.send_response(self.response_status)
        self.end_headers()

    def log_message(self, fmt: str, *args: object) -> None:
        return


@contextmanager
def running_server(handler: type[BaseHTTPRequestHandler]):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def request_json(url: str, method: str = "GET", body: dict[str, object] | None = None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
        method=method,
    )
    try:
        with urllib.request.urlopen(request, timeout=2) as response:
            return response.status, json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read().decode("utf-8"))


def critical_canary() -> dict[str, object]:
    return {
        "status": "firing",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "LaunchReadinessCanary",
                    "severity": "critical",
                    "service": "readiness-fixture",
                    "proof_class": "local-canary",
                },
                "annotations": {"summary": "loopback delivery proof"},
            }
        ],
    }


def noncritical_alert() -> dict[str, object]:
    return {
        "status": "firing",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "CapacityWarning",
                    "severity": "warning",
                    "service": "readiness-fixture",
                },
                "annotations": {"summary": "noncritical overlap control"},
            }
        ],
    }


def resolved_critical_alert() -> dict[str, object]:
    payload = critical_canary()
    payload["status"] = "resolved"
    alert = payload["alerts"][0]
    alert["status"] = "resolved"
    alert["endsAt"] = "2026-09-17T12:01:00+00:00"
    return payload


def summary_for(labels: dict[str, str]) -> dict[str, object]:
    alert = {
        "status": "firing",
        "labels": {"severity": "critical", **labels},
        "annotations": {"summary": "operator action required"},
    }
    payload = {"status": "firing", "alerts": [alert]}
    return receiver.build_summary(payload, payload["alerts"])


def request_text(forward_format: str, summary: dict[str, object]) -> str:
    request = receiver.build_forward_request(
        "https://example.invalid/topic?chat_id=123", forward_format, summary
    )
    assert request.data is not None
    if forward_format == "ntfy":
        return request.data.decode("utf-8")
    return json.loads(request.data.decode("utf-8"))["text"]


class AlertIdentityFallbackTest(unittest.TestCase):
    def test_service_takes_precedence(self) -> None:
        summary = summary_for(
            {
                "alertname": "ChainHalted",
                "service": "wrfcoin-node",
                "instance": "node-1:8556",
                "job": "core4",
            }
        )

        self.assertIn("ChainHalted (wrfcoin-node)", receiver.format_alert_text(summary))
        alert = summary["alerts"][0]
        self.assertEqual(alert["service"], "wrfcoin-node")
        self.assertEqual(alert["instance"], "node-1:8556")

    def test_bft_finality_inert_uses_instance_in_every_forward_format(self) -> None:
        summary = summary_for(
            {
                "alertname": "BftFinalityInert",
                "instance": "core4-node-1:9090",
                "job": "core4",
            }
        )

        for forward_format in receiver.FORWARD_FORMATS:
            with self.subTest(forward_format=forward_format):
                text = request_text(forward_format, summary)
                self.assertIn(
                    "BftFinalityInert (core4-node-1:9090): operator action required",
                    text,
                )

        alert = summary["alerts"][0]
        self.assertEqual(alert["service"], "unknown")
        self.assertEqual(alert["instance"], "core4-node-1:9090")
        self.assertEqual(alert["status"], "firing")

        ntfy_request = receiver.build_forward_request(
            "https://example.invalid/topic", "ntfy", summary
        )
        self.assertEqual(ntfy_request.get_header("Priority"), "urgent")
        generic_request = receiver.build_forward_request(
            "https://example.invalid/hook", "generic", summary
        )
        assert generic_request.data is not None
        generic_body = json.loads(generic_request.data.decode("utf-8"))
        self.assertEqual(
            generic_body["summary"]["alerts"][0]["alertname"], "BftFinalityInert"
        )

    def test_job_is_used_when_service_and_instance_are_empty(self) -> None:
        summary = summary_for(
            {
                "alertname": "TargetDown",
                "service": "",
                "instance": "   ",
                "job": "prometheus-targets",
            }
        )

        self.assertIn(
            "TargetDown (prometheus-targets)", receiver.format_alert_text(summary)
        )

    def test_unknown_is_used_when_identity_labels_are_missing(self) -> None:
        summary = summary_for({"alertname": "LabelSparseAlert"})

        self.assertIn("LabelSparseAlert (unknown)", receiver.format_alert_text(summary))


class AlertDeliveryCanaryTest(unittest.TestCase):
    def setUp(self) -> None:
        receiver.AlertWebhookHandler.forward_format = "generic"
        receiver.AlertWebhookHandler.forward_timeout = 0.5
        receiver.AlertWebhookHandler.reset_delivery_evidence()
        LocalSinkHandler.response_status = 204
        LocalSinkHandler.delay_seconds = 0.0
        LocalSinkHandler.requests = []

    def test_critical_canary_reaches_injected_loopback_sink(self) -> None:
        with running_server(LocalSinkHandler) as sink_url:
            receiver.AlertWebhookHandler.forward_url = f"{sink_url}/capture"
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                status, response = request_json(
                    f"{receiver_url}/alerts", "POST", critical_canary()
                )
                self.assertEqual(status, 200)
                self.assertTrue(response["forwarded"])
                self.assertEqual(len(LocalSinkHandler.requests), 1)

                health_status, health = request_json(f"{receiver_url}/health")
                self.assertEqual(health_status, 200)
                self.assertTrue(health["forwarding"])
                evidence = health["delivery_evidence"]
                self.assertEqual(
                    evidence["rule_firing"]["status"], "injected_local_canary"
                )
                self.assertEqual(evidence["receiver_acceptance"]["status"], "accepted")
                self.assertTrue(evidence["receiver_acceptance"]["critical_firing"])
                self.assertEqual(evidence["outbound_forwarding"]["status"], "succeeded")
                self.assertEqual(
                    evidence["receiver_acceptance"]["request_id"],
                    evidence["outbound_forwarding"]["request_id"],
                )
                self.assertEqual(
                    evidence["human_delivery"]["status"],
                    "operator_verification_required",
                )
                retained = health["last_successful_critical_delivery"]
                self.assertEqual(retained["status"], "succeeded")
                self.assertEqual(retained["request_id"], evidence["request_id"])
                self.assertEqual(
                    retained["outbound_forwarding"]["status"], "succeeded"
                )
                self.assertIn("observed_at", retained["outbound_forwarding"])

    def test_operational_canary_script_generates_fresh_delivery_evidence(self) -> None:
        with running_server(LocalSinkHandler) as sink_url:
            receiver.AlertWebhookHandler.forward_url = f"{sink_url}/capture"
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                completed = subprocess.run(
                    ["bash", str(CANARY_PATH)],
                    check=False,
                    capture_output=True,
                    text=True,
                    env={**os.environ, "ALERT_RECEIVER_API": receiver_url},
                    timeout=5,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn("alert delivery canary PASS", completed.stdout)
                _, health = request_json(f"{receiver_url}/health")
                retained = health["last_successful_critical_delivery"]
                self.assertEqual(retained["status"], "succeeded")
                self.assertEqual(
                    retained["rule_firing"]["status"], "injected_local_canary"
                )

    def test_later_resolved_success_does_not_erase_critical_delivery(self) -> None:
        with running_server(LocalSinkHandler) as sink_url:
            receiver.AlertWebhookHandler.forward_url = f"{sink_url}/capture"
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                critical_status, _ = request_json(
                    f"{receiver_url}/alerts", "POST", critical_canary()
                )
                self.assertEqual(critical_status, 200)
                _, before = request_json(f"{receiver_url}/health")
                retained_request_id = before["last_successful_critical_delivery"][
                    "request_id"
                ]

                resolved_status, _ = request_json(
                    f"{receiver_url}/alerts", "POST", resolved_critical_alert()
                )
                self.assertEqual(resolved_status, 200)
                _, after = request_json(f"{receiver_url}/health")
                self.assertFalse(
                    after["delivery_evidence"]["receiver_acceptance"][
                        "critical_firing"
                    ]
                )
                self.assertEqual(
                    after["last_successful_critical_delivery"]["request_id"],
                    retained_request_id,
                )

    def test_concurrent_requests_cannot_mix_critical_acceptance_with_another_forward(self) -> None:
        noncritical_started = threading.Event()
        release_noncritical = threading.Event()

        def overlapping_forward(_url, _format, _timeout, summary):
            if receiver.has_firing_critical(summary):
                return {"status": "http_error", "http_status": 503}
            noncritical_started.set()
            self.assertTrue(release_noncritical.wait(timeout=1))
            return {"status": "succeeded", "http_status": 204}

        receiver.AlertWebhookHandler.forward_url = "https://sink.invalid"
        with patch.object(receiver, "forward_summary", side_effect=overlapping_forward):
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                noncritical_result: list[tuple[int, dict[str, object]]] = []
                thread = threading.Thread(
                    target=lambda: noncritical_result.append(
                        request_json(
                            f"{receiver_url}/alerts", "POST", noncritical_alert()
                        )
                    )
                )
                thread.start()
                self.assertTrue(noncritical_started.wait(timeout=1))

                critical_status, _ = request_json(
                    f"{receiver_url}/alerts", "POST", critical_canary()
                )
                self.assertEqual(critical_status, 502)
                release_noncritical.set()
                thread.join(timeout=2)
                self.assertFalse(thread.is_alive())
                self.assertEqual(noncritical_result[0][0], 200)

                _, health = request_json(f"{receiver_url}/health")
                evidence = health["delivery_evidence"]
                acceptance = evidence["receiver_acceptance"]
                forwarding = evidence["outbound_forwarding"]
                self.assertEqual(acceptance["request_id"], forwarding["request_id"])
                self.assertFalse(
                    acceptance["critical_firing"]
                    and forwarding["status"] == "succeeded"
                )

    def test_blank_forward_url_rejects_critical_alert(self) -> None:
        receiver.AlertWebhookHandler.forward_url = ""
        with running_server(receiver.AlertWebhookHandler) as receiver_url:
            status, response = request_json(
                f"{receiver_url}/alerts", "POST", critical_canary()
            )
        self.assertEqual(status, 503)
        self.assertEqual(response["forward_result"]["status"], "disabled")

    def test_non_2xx_forward_rejects_critical_alert(self) -> None:
        LocalSinkHandler.response_status = 503
        with running_server(LocalSinkHandler) as sink_url:
            receiver.AlertWebhookHandler.forward_url = sink_url
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                status, response = request_json(
                    f"{receiver_url}/alerts", "POST", critical_canary()
                )
        self.assertEqual(status, 502)
        self.assertEqual(response["forward_result"]["status"], "http_error")
        self.assertEqual(response["forward_result"]["http_status"], 503)

    def test_forward_timeout_rejects_critical_alert(self) -> None:
        LocalSinkHandler.delay_seconds = 0.2
        with running_server(LocalSinkHandler) as sink_url:
            receiver.AlertWebhookHandler.forward_url = sink_url
            receiver.AlertWebhookHandler.forward_timeout = 0.02
            with running_server(receiver.AlertWebhookHandler) as receiver_url:
                status, response = request_json(
                    f"{receiver_url}/alerts", "POST", critical_canary()
                )
        self.assertEqual(status, 504)
        self.assertEqual(response["forward_result"]["status"], "timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
