#!/usr/bin/env python3
"""Small local receiver for WRFCoin testnet AlertManager webhooks.

Beyond local capture (stdout + optional JSONL log), the receiver can forward a
compact human-readable summary of each webhook to an external notification
channel so critical alerts actually page a human (infra#601). Forwarding is
opt-in via env or CLI. Local capture survives an outbound failure, but a firing
critical alert receives a non-2xx response when forwarding is disabled, times
out, or fails so AlertManager can retry instead of recording false delivery.

Supported forward formats:
  ntfy      POST the text body to an ntfy topic URL (https://ntfy.sh/<topic>),
            with Title/Priority/Tags headers derived from the alert status.
  telegram  POST JSON {chat_id, text} to a Telegram Bot API sendMessage URL.
            chat_id may be embedded in the URL query string or passed via
            ALERT_FORWARD_TELEGRAM_CHAT_ID.
  generic   POST JSON {"text": ..., "summary": {...}} — works with Slack
            "incoming webhook"-compatible receivers and custom hooks.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

FORWARD_FORMATS = ("ntfy", "telegram", "generic")


def alert_identity(labels: dict[str, Any]) -> str:
    """Return the best available operator-facing identity for an alert."""
    for label_name in ("service", "instance", "job"):
        value = labels.get(label_name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return "unknown"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Receive AlertManager webhook payloads for the WRFCoin testnet stack."
    )
    parser.add_argument(
        "--host", default="0.0.0.0", help="Bind address. Default: 0.0.0.0"
    )
    parser.add_argument(
        "--port", type=int, default=19093, help="Bind port. Default: 19093"
    )
    parser.add_argument(
        "--log-file",
        default="",
        help="Optional JSONL file that receives a copy of each webhook payload.",
    )
    parser.add_argument(
        "--forward-url",
        default=os.environ.get("ALERT_FORWARD_URL", ""),
        help=(
            "Optional URL to forward a human-readable alert summary to "
            "(env: ALERT_FORWARD_URL). Forwarding is disabled when blank."
        ),
    )
    parser.add_argument(
        "--forward-format",
        choices=FORWARD_FORMATS,
        default=os.environ.get("ALERT_FORWARD_FORMAT", "generic"),
        help="Payload shape for --forward-url (env: ALERT_FORWARD_FORMAT). Default: generic",
    )
    parser.add_argument(
        "--forward-timeout",
        type=float,
        default=float(os.environ.get("ALERT_FORWARD_TIMEOUT_SECS", "10")),
        help="Forward request timeout in seconds (env: ALERT_FORWARD_TIMEOUT_SECS). Default: 10",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help=(
            "Render every forward format from a canned AlertManager payload and exit. "
            "If --forward-url is set, also send one real forward request."
        ),
    )
    return parser.parse_args()


def build_summary(
    payload: dict[str, Any], alerts: list[dict[str, Any]]
) -> dict[str, Any]:
    compact_alerts: list[dict[str, Any]] = []
    alert_names: list[str] = []

    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alert_name = labels.get("alertname", "unknown")
        alert_names.append(alert_name)
        compact_alerts.append(
            {
                "alertname": alert_name,
                "severity": labels.get("severity", "unknown"),
                "service": labels.get("service", "unknown"),
                "instance": labels.get("instance", "unknown"),
                "identity": alert_identity(labels),
                "status": alert.get("status", "unknown"),
                "summary": annotations.get("summary", ""),
                "description": annotations.get("description", ""),
                "startsAt": alert.get("startsAt", ""),
                "endsAt": alert.get("endsAt", ""),
            }
        )

    return {
        "received_at": datetime.now(timezone.utc).isoformat(),
        "status": payload.get("status", "unknown"),
        "group_labels": payload.get("groupLabels", {}),
        "common_labels": payload.get("commonLabels", {}),
        "external_url": payload.get("externalURL", ""),
        "alert_count": len(alerts),
        "alert_names": sorted(set(alert_names)),
        "alerts": compact_alerts,
    }


def format_alert_text(summary: dict[str, Any]) -> str:
    """Render a compact, phone-notification-friendly text for a webhook summary."""
    status = summary.get("status", "unknown")
    lines = [
        f"WRFCoin testnet: {summary.get('alert_count', 0)} alert(s) {status}",
    ]
    for alert in summary.get("alerts", []):
        headline = alert.get("summary") or alert.get("alertname", "unknown")
        lines.append(
            f"[{alert.get('severity', 'unknown')}] {alert.get('alertname', 'unknown')}"
            f" ({alert.get('identity') or 'unknown'}): {headline}"
        )
        description = alert.get("description", "")
        if description:
            lines.append(f"  {description}")
    return "\n".join(lines)


def has_firing_critical(summary: dict[str, Any]) -> bool:
    return any(
        alert.get("severity") == "critical" and alert.get("status") == "firing"
        for alert in summary.get("alerts", [])
    )


def build_forward_request(
    forward_url: str, forward_format: str, summary: dict[str, Any]
) -> urllib.request.Request:
    """Build the outbound notification request for the configured channel."""
    text = format_alert_text(summary)
    firing = summary.get("status") == "firing"

    if forward_format == "ntfy":
        headers = {
            "Title": f"WRFCoin testnet alert ({summary.get('status', 'unknown')})",
            "Priority": "urgent"
            if has_firing_critical(summary)
            else ("high" if firing else "default"),
            "Tags": "rotating_light" if firing else "white_check_mark",
        }
        return urllib.request.Request(
            forward_url,
            data=text.encode("utf-8"),
            headers=headers,
            method="POST",
        )

    if forward_format == "telegram":
        parsed = urllib.parse.urlparse(forward_url)
        query = urllib.parse.parse_qs(parsed.query)
        chat_id = query.get("chat_id", [""])[0] or os.environ.get(
            "ALERT_FORWARD_TELEGRAM_CHAT_ID", ""
        )
        base_url = urllib.parse.urlunparse(parsed._replace(query=""))
        body: dict[str, Any] = {"text": text, "disable_web_page_preview": True}
        if chat_id:
            body["chat_id"] = chat_id
        return urllib.request.Request(
            base_url,
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

    # generic: Slack-incoming-webhook-compatible, plus the full compact summary
    body = {"text": text, "summary": summary}
    return urllib.request.Request(
        forward_url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )


def forward_failure(error: Exception, forward_format: str) -> dict[str, Any]:
    """Classify without serializing exception text or a secret-bearing URL."""
    reason = getattr(error, "reason", None)
    cause = reason if isinstance(reason, Exception) else error
    result: dict[str, Any] = {"error_type": type(cause).__name__}
    if isinstance(error, urllib.error.HTTPError):
        result.update(status="http_error", http_status=error.code)
    elif isinstance(cause, (TimeoutError, socket.timeout)):
        result["status"] = "timeout"
    elif isinstance(cause, socket.gaierror):
        result["status"] = "dns_error"
    elif isinstance(cause, ssl.SSLError):
        result["status"] = "tls_error"
    elif isinstance(cause, ConnectionError):
        result["status"] = "connection_error"
    elif isinstance(cause, ValueError):
        result["status"] = "configuration_error"
    else:
        result["status"] = "network_error"
    if isinstance(getattr(cause, "errno", None), int):
        result["errno"] = cause.errno
    print(
        f"[alertmanager-webhook] FORWARD FAILED ({forward_format}): "
        + json.dumps(result, sort_keys=True),
        file=sys.stderr,
    )
    return result


def forward_summary(
    forward_url: str,
    forward_format: str,
    forward_timeout: float,
    summary: dict[str, Any],
) -> dict[str, Any]:
    """Forward a summary and return structured evidence for readiness reporting."""
    try:
        request = build_forward_request(forward_url, forward_format, summary)
        with urllib.request.urlopen(request, timeout=forward_timeout) as response:
            code = response.status
    except (urllib.error.URLError, OSError, ValueError) as error:
        return forward_failure(error, forward_format)
    if 200 <= code < 300:
        return {"status": "succeeded", "http_status": code}
    print(
        f"[alertmanager-webhook] FORWARD FAILED ({forward_format}): HTTP {code}",
        file=sys.stderr,
    )
    return {"status": "http_error", "http_status": code}


class AlertWebhookHandler(BaseHTTPRequestHandler):
    log_file: Path | None = None
    forward_url: str = ""
    forward_format: str = "generic"
    forward_timeout: float = 10.0
    evidence_lock = threading.Lock()
    delivery_evidence: dict[str, dict[str, Any]] = {
        "rule_firing": {"status": "not_observed"},
        "receiver_acceptance": {"status": "not_observed"},
        "outbound_forwarding": {"status": "not_observed"},
        "human_delivery": {"status": "operator_verification_required"},
    }
    last_successful_critical_delivery: dict[str, Any] = {"status": "not_observed"}

    @classmethod
    def reset_delivery_evidence(cls) -> None:
        with cls.evidence_lock:
            cls.delivery_evidence = {
                "rule_firing": {"status": "not_observed"},
                "receiver_acceptance": {"status": "not_observed"},
                "outbound_forwarding": {"status": "not_observed"},
                "human_delivery": {"status": "operator_verification_required"},
            }
            cls.last_successful_critical_delivery = {"status": "not_observed"}

    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return

        with self.evidence_lock:
            evidence = json.loads(json.dumps(self.delivery_evidence))
            last_successful_critical = json.loads(
                json.dumps(self.last_successful_critical_delivery)
            )
        self._send_json(
            HTTPStatus.OK,
            {
                "status": "ok" if self.forward_url else "degraded",
                "forwarding": bool(self.forward_url),
                "delivery_evidence": evidence,
                "last_successful_critical_delivery": last_successful_critical,
            },
        )

    def do_POST(self) -> None:
        if self.path != "/alerts":
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return

        length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(length)

        try:
            payload = json.loads(raw_body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid JSON payload"})
            return

        alerts = payload.get("alerts")
        if not isinstance(alerts, list):
            self._send_json(HTTPStatus.BAD_REQUEST, {"error": "missing alerts array"})
            return

        summary = build_summary(payload, alerts)
        critical_firing = has_firing_critical(summary)
        is_local_canary = any(
            alert.get("labels", {}).get("proof_class") == "local-canary"
            for alert in alerts
            if isinstance(alert, dict)
        )
        request_id = uuid.uuid4().hex
        print(
            "[alertmanager-webhook] "
            f"{summary['received_at']} alerts={summary['alert_count']} "
            f"status={summary['status']} names={summary['alert_names']}"
        )

        if self.log_file is not None:
            self.log_file.parent.mkdir(parents=True, exist_ok=True)
            with self.log_file.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(summary, sort_keys=True) + "\n")

        forward_result: dict[str, Any] = {"status": "disabled"}
        if self.forward_url:
            forward_result = forward_summary(
                self.forward_url, self.forward_format, self.forward_timeout, summary
            )
        # Publish all stages as one correlated record. ThreadingHTTPServer can
        # overlap requests; separate acceptance/forwarding writes can otherwise
        # combine a failed critical alert with another request's success.
        correlated_evidence = {
            "request_id": request_id,
            "rule_firing": {
                "status": "injected_local_canary"
                if is_local_canary
                else "alertmanager_payload_observed",
                "request_id": request_id,
            },
            "receiver_acceptance": {
                "status": "accepted",
                "alert_count": len(alerts),
                "critical_firing": critical_firing,
                "observed_at": summary["received_at"],
                "request_id": request_id,
            },
            "outbound_forwarding": {
                **forward_result,
                "observed_at": datetime.now(timezone.utc).isoformat(),
                "request_id": request_id,
            },
            "human_delivery": {
                "status": "operator_verification_required",
                "request_id": request_id,
            },
        }
        handler_type = type(self)
        with handler_type.evidence_lock:
            handler_type.delivery_evidence = correlated_evidence
            if critical_firing and forward_result["status"] == "succeeded":
                handler_type.last_successful_critical_delivery = {
                    "status": "succeeded",
                    **json.loads(json.dumps(correlated_evidence)),
                }

        if critical_firing and forward_result["status"] != "succeeded":
            status = (
                HTTPStatus.SERVICE_UNAVAILABLE
                if forward_result["status"] == "disabled"
                else HTTPStatus.GATEWAY_TIMEOUT
                if forward_result["status"] == "timeout"
                else HTTPStatus.BAD_GATEWAY
            )
            self._send_json(
                status,
                {
                    "status": "delivery_failed",
                    "alert_count": len(alerts),
                    "forwarded": False,
                    "forward_result": forward_result,
                },
            )
            return

        self._send_json(
            HTTPStatus.OK,
            {
                "status": "accepted",
                "alert_count": len(alerts),
                "forwarded": forward_result["status"] == "succeeded",
                "forward_result": forward_result,
            },
        )

    def log_message(self, fmt: str, *args: object) -> None:
        return

    def _send_json(self, status: HTTPStatus, body: dict[str, Any]) -> None:
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


SELF_TEST_PAYLOAD: dict[str, Any] = {
    "status": "firing",
    "groupLabels": {"alertname": "ChainHalted"},
    "commonLabels": {"severity": "critical", "service": "wrfcoin-node"},
    "externalURL": "http://alertmanager:9093",
    "alerts": [
        {
            "status": "firing",
            "labels": {
                "alertname": "ChainHalted",
                "severity": "critical",
                "service": "wrfcoin-node",
                "instance": "wrfcoin-node:8556",
            },
            "annotations": {
                "summary": "Block height has not advanced for 10 minutes",
                "description": "Latest block is stale; consensus may be halted.",
            },
            "startsAt": "2026-07-02T00:00:00Z",
            "endsAt": "0001-01-01T00:00:00Z",
        }
    ],
}


def run_self_test(args: argparse.Namespace) -> int:
    summary = build_summary(SELF_TEST_PAYLOAD, SELF_TEST_PAYLOAD["alerts"])
    print("=== formatted text ===")
    print(format_alert_text(summary))
    for fmt in FORWARD_FORMATS:
        request = build_forward_request(
            args.forward_url or "https://example.invalid/hook", fmt, summary
        )
        body = request.data.decode("utf-8") if request.data else ""
        print(f"=== {fmt} → [destination redacted] ===")
        headers = {
            k: v for k, v in request.header_items() if k.lower() != "content-length"
        }
        print(f"headers: {headers}")
        if fmt == "telegram":
            preview = json.loads(body)
            if "chat_id" in preview:
                preview["chat_id"] = "[redacted]"
            body = json.dumps(preview)
        print(body[:400])
    if args.forward_url:
        print(f"=== live forward ({args.forward_format}) → [destination redacted] ===")
        result = forward_summary(
            args.forward_url, args.forward_format, args.forward_timeout, summary
        )
        print(f"forwarded: {result['status'] == 'succeeded'}")
        return 0 if result["status"] == "succeeded" else 1
    return 0


def main() -> None:
    args = parse_args()
    if args.self_test:
        raise SystemExit(run_self_test(args))
    AlertWebhookHandler.log_file = (
        Path(args.log_file).expanduser() if args.log_file else None
    )
    AlertWebhookHandler.forward_url = args.forward_url
    AlertWebhookHandler.forward_format = args.forward_format
    AlertWebhookHandler.forward_timeout = args.forward_timeout
    AlertWebhookHandler.reset_delivery_evidence()
    server = ThreadingHTTPServer((args.host, args.port), AlertWebhookHandler)
    forward_note = (
        f"forwarding {args.forward_format} → {args.forward_url}"
        if args.forward_url
        else "forwarding disabled (set ALERT_FORWARD_URL to page a human — infra#601)"
    )
    print(
        "[alertmanager-webhook] "
        f"listening on http://{args.host}:{args.port}/alerts "
        f"(health: http://{args.host}:{args.port}/health; {forward_note})"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
