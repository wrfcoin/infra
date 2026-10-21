#!/usr/bin/env python3
"""Watches Docker container HEALTHCHECK status and pages a human via the
existing AlertManager webhook receiver when a container stays unhealthy
past a grace threshold (infra#902).

Why this exists: cAdvisor (scraped by Prometheus in this stack) exposes
cgroup/resource metrics, not Docker's own HEALTHCHECK verdict. A container
can sit `unhealthy` — process running, healthcheck failing every interval —
indefinitely with zero signal anywhere in Prometheus/Alertmanager/Grafana.
Measured live: wrfcoin-testnet-funnel-edge sat unhealthy for 45h across
5501+ consecutive failed checks (infra#900) before anyone noticed, and the
container was, in that case, actually fine — a genuine failure would have
been equally silent.

Design, deliberately small: this does NOT add a new Prometheus scrape job
or Alertmanager rule/route, and does NOT depend on the `docker` CLI. It
talks to the Docker Engine API directly over the mounted socket (read-only
bind mount) via plain HTTP-over-Unix-socket, and when a watched container's
FailingStreak crosses a threshold, POSTs directly to the already-live,
already-forwarding wrfcoin-alert-receiver at `/alerts` (see
testnet/docker-compose.alert-receiver.yml, infra#601) using the same
webhook JSON shape AlertManager itself sends — so it reuses the existing,
verified-live delivery path (receiver -> ALERT_FORWARD_URL) with no changes
to Prometheus, Alertmanager, or their configs.

Container discovery is stateless per poll: no config listing which
containers to watch. `GET /containers/json` enumerates every running
container, then `GET /containers/{name}/json` is checked for
`.State.Health`; anything without a HEALTHCHECK defined is silently skipped
(`.State.Health` is absent), so this automatically covers every current AND
future service that defines one, not just the two edges that motivated it.

Alert de-duplication and resolution: an in-memory set of container names
currently considered "alerting" is tracked so a single firing episode
produces one `firing` POST and, on recovery, one `resolved` POST — not one
POST per poll. This state does not persist across a watcher restart; a
container already past the threshold when the watcher restarts will
re-alert on the next poll (fail-open toward re-notifying, not fail-closed
toward silence).

Undelivered-alert retry is BOUNDED, not per-poll-forever (review round 3 on
infra#903 caught this: an unconditionally-retryable episode against a
receiver that persistently can't forward would spam that receiver, and
whatever external channel it forwards to, once per poll indefinitely — the
exact "alerting system gets muted by whoever receives it" failure). Each
undelivered attempt schedules the next one with exponential backoff
(`min(2 ** (attempts - 1), RETRY_BACKOFF_CAP_POLLS)` polls out), so the
first two attempts still happen on consecutive polls, then the interval
grows and caps — it never gives up entirely, since a fully-silent give-up
would recreate the same failure this watcher exists to prevent, but the
POST rate against a persistently-broken receiver is bounded. Every
undelivered attempt still logs to stderr, and any container with an
undelivered episode in flight is listed under `undelivered_pending` in this
watcher's own `/health` response — so "delivery never succeeded" stays
visible even while the retry backs off, not just in the moment it happens.

Environment variables:
  ALERT_RECEIVER_URL           default http://wrfcoin-alert-receiver:19093/alerts
  POLL_INTERVAL_SECS           default 30
  FAILING_STREAK_THRESHOLD     consecutive failed healthchecks before firing (default 5)
  RETRY_BACKOFF_CAP_POLLS      max polls between undelivered-alert retries (default 20)
  DOCKER_SOCK                  default /var/run/docker.sock
"""

from __future__ import annotations

import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Any

ALERT_RECEIVER_URL = os.environ.get(
    "ALERT_RECEIVER_URL", "http://wrfcoin-alert-receiver:19093/alerts"
)
POLL_INTERVAL_SECS = float(os.environ.get("POLL_INTERVAL_SECS", "30"))
FAILING_STREAK_THRESHOLD = int(os.environ.get("FAILING_STREAK_THRESHOLD", "5"))
RETRY_BACKOFF_CAP_POLLS = int(os.environ.get("RETRY_BACKOFF_CAP_POLLS", "20"))
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
ALERTNAME = "ContainerUnhealthy"

# name -> True once a firing alert has been sent for the current episode,
# cleared on recovery. In-memory only, by design (see module docstring).
_alerting: dict[str, bool] = {}
# name -> {"attempts": int, "next_attempt_at_poll": int}; present only while
# an alert (firing or resolved) has been attempted and NOT yet confirmed
# delivered. Cleared on successful delivery. In-memory, same as _alerting.
_pending_retry: dict[str, dict[str, int]] = {}
_poll_count = 0
_last_poll_ok = False
_last_poll_at: str = ""


class UnixSocketHTTPConnection(HTTPConnection):
    """http.client.HTTPConnection over a Unix domain socket (the Docker
    Engine API's native transport) instead of TCP. Avoids depending on the
    `docker` CLI binary — this talks to the daemon directly."""

    def __init__(self, sock_path: str, timeout: float = 10.0) -> None:
        super().__init__("localhost", timeout=timeout)
        self._sock_path = sock_path

    def connect(self) -> None:
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._sock_path)


def _docker_api_get(path: str) -> Any:
    conn = UnixSocketHTTPConnection(DOCKER_SOCK)
    try:
        conn.request("GET", path)
        response = conn.getresponse()
        raw = response.read()
        if response.status != 200:
            raise RuntimeError(f"GET {path} -> HTTP {response.status}: {raw[:200]!r}")
        return json.loads(raw)
    finally:
        conn.close()


def list_container_names() -> list[str]:
    containers = _docker_api_get("/containers/json")
    names = []
    for container in containers:
        # Engine API returns names as ["/name"] with a leading slash.
        raw_names = container.get("Names") or []
        if raw_names:
            names.append(raw_names[0].lstrip("/"))
    return names


def inspect_health(name: str) -> dict[str, Any] | None:
    """Returns {"status": ..., "failing_streak": int} or None if the
    container has no HEALTHCHECK defined."""
    detail = _docker_api_get(f"/containers/{name}/json")
    health = (detail.get("State") or {}).get("Health")
    if not health:
        return None
    return {
        "status": health.get("Status", "unknown"),
        "failing_streak": int(health.get("FailingStreak") or 0),
    }


def build_payload(name: str, status: str, failing_streak: int, firing: bool) -> dict[str, Any]:
    now = datetime.now(timezone.utc).isoformat()
    alert_status = "firing" if firing else "resolved"
    return {
        "status": alert_status,
        "groupLabels": {"alertname": ALERTNAME, "service": name},
        "commonLabels": {"severity": "critical", "service": name, "alertname": ALERTNAME},
        "externalURL": "",
        "alerts": [
            {
                "status": alert_status,
                "labels": {
                    "alertname": ALERTNAME,
                    "severity": "critical",
                    "service": name,
                    "instance": name,
                },
                "annotations": {
                    "summary": (
                        f"{name} has been unhealthy for {failing_streak} consecutive checks"
                        if firing
                        else f"{name} healthcheck has recovered"
                    ),
                    "description": (
                        f"Docker reports {name} health status '{status}' with "
                        f"FailingStreak={failing_streak} (threshold "
                        f"{FAILING_STREAK_THRESHOLD}). This does not necessarily mean "
                        "the service is down (see infra#900) — verify before assuming "
                        "an outage."
                        if firing
                        else f"Docker reports {name} health status '{status}'."
                    ),
                },
                "startsAt": now,
                "endsAt": "0001-01-01T00:00:00Z" if firing else now,
            }
        ],
    }


def post_alert(payload: dict[str, Any]) -> bool:
    """Returns True only when the receiver's own response body confirms it
    forwarded the notification to a human.

    wrfcoin-alert-receiver's /alerts handler ALWAYS returns HTTP 200 once it
    has parsed and logged the payload — including when ALERT_FORWARD_URL is
    unset or the outbound forward itself failed, in which case its JSON body
    is {"status": "accepted", ..., "forwarded": false} (see
    testnet/alertmanager-webhook-receiver.py's do_POST). An HTTP 2xx from the
    receiver therefore means "accepted", not "delivered". Treating 2xx alone
    as delivered would silently swallow a transient forwarding failure (or a
    deploy where ALERT_FORWARD_URL was never set): the episode gets marked
    alerting after one attempt and never retried, while no human ever saw
    it — the exact false-confidence class this whole watcher exists to
    catch elsewhere in the stack (infra#900). Confirmed by review reproduction
    against this exact behavior; see scripts/tests/test_container_health_watch.py.
    """
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        ALERT_RECEIVER_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            if not (200 <= response.status < 300):
                print(
                    f"[container-health-watch] receiver returned HTTP {response.status}",
                    file=sys.stderr,
                )
                return False
            raw = response.read()
    except (urllib.error.URLError, OSError, ValueError) as error:
        print(f"[container-health-watch] POST to receiver failed: {error}", file=sys.stderr)
        return False

    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, ValueError, TypeError) as error:
        print(
            f"[container-health-watch] receiver response was not valid JSON: {error}",
            file=sys.stderr,
        )
        return False

    if parsed.get("forwarded") is not True:
        print(
            "[container-health-watch] receiver accepted but did not forward "
            f"(forwarded={parsed.get('forwarded')!r}) — treating as undelivered, "
            "will retry on the next poll",
            file=sys.stderr,
        )
        return False
    return True


def _due_for_retry(name: str) -> bool:
    """True on a container's first delivery attempt (no pending state yet)
    or once its backed-off retry interval has elapsed, in poll counts."""
    pending = _pending_retry.get(name)
    if not pending:
        return True
    return _poll_count >= pending["next_attempt_at_poll"]


def _record_delivery_attempt(name: str, delivered: bool) -> None:
    """Clears pending-retry state on success; on failure, schedules the next
    attempt with exponential backoff capped at RETRY_BACKOFF_CAP_POLLS polls
    out. attempts 1 and 2 land on consecutive polls (backoff = 2**0 = 1
    before growing), then the interval doubles each miss until it hits the
    cap, where it holds — bounded request volume, but never fully silenced."""
    if delivered:
        _pending_retry.pop(name, None)
        return
    attempts = _pending_retry.get(name, {}).get("attempts", 0) + 1
    backoff = min(2 ** (attempts - 1), RETRY_BACKOFF_CAP_POLLS)
    next_at = _poll_count + backoff
    _pending_retry[name] = {"attempts": attempts, "next_attempt_at_poll": next_at}
    print(
        f"[container-health-watch] {name} still undelivered after {attempts} "
        f"attempt(s) — next retry no sooner than poll {next_at} (+{backoff} poll(s)); "
        "human notification has NOT happened yet",
        file=sys.stderr,
    )


def poll_once() -> None:
    global _last_poll_ok, _last_poll_at, _poll_count
    _poll_count += 1
    _last_poll_at = datetime.now(timezone.utc).isoformat()
    try:
        names = list_container_names()
    except (RuntimeError, OSError, ValueError) as error:
        print(f"[container-health-watch] docker API list failed: {error}", file=sys.stderr)
        _last_poll_ok = False
        return
    _last_poll_ok = True

    for name in names:
        try:
            health = inspect_health(name)
        except (RuntimeError, OSError, ValueError) as error:
            print(f"[container-health-watch] inspect {name} failed: {error}", file=sys.stderr)
            continue
        if health is None:
            continue  # no HEALTHCHECK defined on this container

        status = health["status"]
        streak = health["failing_streak"]
        currently_alerting = _alerting.get(name, False)

        if status == "unhealthy" and streak >= FAILING_STREAK_THRESHOLD and not currently_alerting:
            if not _due_for_retry(name):
                continue
            payload = build_payload(name, status, streak, firing=True)
            ok = post_alert(payload)
            print(
                f"[container-health-watch] FIRING {name} status={status} "
                f"streak={streak} delivered={ok}"
            )
            if ok:
                _alerting[name] = True
            _record_delivery_attempt(name, ok)
        elif status == "healthy" and currently_alerting:
            if not _due_for_retry(name):
                continue
            payload = build_payload(name, status, streak, firing=False)
            ok = post_alert(payload)
            print(f"[container-health-watch] RESOLVED {name} delivered={ok}")
            if ok:
                _alerting[name] = False
            _record_delivery_attempt(name, ok)
        elif status == "healthy" and name in _pending_retry:
            # Recovered before an undelivered FIRING notification for this
            # episode was ever confirmed delivered. From the operator's
            # point of view the episode never happened (nobody was told it
            # started), so don't let a stale queued "firing" retry land
            # after the container is already healthy again.
            print(
                f"[container-health-watch] {name} recovered before its undelivered "
                "firing alert was ever confirmed delivered; dropping the pending retry",
                file=sys.stderr,
            )
            _pending_retry.pop(name, None)


def health_response() -> tuple[HTTPStatus, dict[str, Any]]:
    """Computes this watcher's own /health status and body, split out from
    the HTTP framing so it's testable without spinning up a real socket.

    Returns 503 (not 200) when the last Docker poll itself failed — a
    missing/inaccessible Docker socket must not leave this watcher reported
    Docker-healthy while it is blind to every container it's supposed to be
    watching. A 200-always endpoint whose body silently said "degraded"
    would repeat the exact mistake this watcher exists to catch (infra#900):
    a green healthcheck sitting on top of a real failure, unseen.

    `undelivered_pending` lists every container whose most recent alert
    attempt has NOT been confirmed delivered and is currently backed off
    waiting for its next retry — so "delivery never succeeded" stays
    observable here even while the retry interval grows, not just in the
    stderr log line at the moment of each failed attempt."""
    ok = _last_poll_ok
    return (
        HTTPStatus.OK if ok else HTTPStatus.SERVICE_UNAVAILABLE,
        {
            "status": "ok" if ok else "degraded",
            "last_poll_at": _last_poll_at,
            "currently_alerting": [name for name, on in _alerting.items() if on],
            "undelivered_pending": sorted(_pending_retry.keys()),
        },
    )


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path != "/health":
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
            return
        status, payload = health_response()
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args: object) -> None:
        return


def run_health_server() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 9201), HealthHandler)
    server.serve_forever()


def main() -> None:
    print(
        "[container-health-watch] starting: "
        f"receiver={ALERT_RECEIVER_URL} interval={POLL_INTERVAL_SECS}s "
        f"threshold={FAILING_STREAK_THRESHOLD}"
    )
    Thread(target=run_health_server, daemon=True).start()
    while True:
        poll_once()
        time.sleep(POLL_INTERVAL_SECS)


if __name__ == "__main__":
    main()
