#!/usr/bin/env python3
"""Unit tests for testnet/services/container-health-watch/container_health_watch.py
(infra#902).

No live Docker socket or network needed: the Engine API boundary
(_docker_api_get) and the outbound POST boundary (post_alert) are
monkeypatched, following the same stub-the-boundary pattern already used in
test_alertmanager_webhook_receiver.py for the sibling alert-receiver.
"""
from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

WATCH_PATH = (
    Path(__file__).parents[2]
    / "testnet"
    / "services"
    / "container-health-watch"
    / "container_health_watch.py"
)
SPEC = importlib.util.spec_from_file_location("container_health_watch", WATCH_PATH)
assert SPEC is not None and SPEC.loader is not None
watch = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(watch)


class ListContainerNamesTest(unittest.TestCase):
    def test_strips_leading_slash(self):
        watch._docker_api_get = lambda path: [
            {"Names": ["/wrfcoin-testnet-funnel-edge"]},
            {"Names": ["/wrfcoin-testnet-edge"]},
        ]
        self.assertEqual(
            watch.list_container_names(),
            ["wrfcoin-testnet-funnel-edge", "wrfcoin-testnet-edge"],
        )

    def test_skips_entries_with_no_names(self):
        watch._docker_api_get = lambda path: [{"Names": []}, {"Names": ["/x"]}]
        self.assertEqual(watch.list_container_names(), ["x"])


class InspectHealthTest(unittest.TestCase):
    def test_no_health_block_returns_none(self):
        watch._docker_api_get = lambda path: {"State": {"Status": "running"}}
        self.assertIsNone(watch.inspect_health("no-healthcheck-container"))

    def test_unhealthy_with_streak(self):
        watch._docker_api_get = lambda path: {
            "State": {"Health": {"Status": "unhealthy", "FailingStreak": 5505}}
        }
        result = watch.inspect_health("wrfcoin-testnet-funnel-edge")
        self.assertEqual(result, {"status": "unhealthy", "failing_streak": 5505})

    def test_healthy_zero_streak(self):
        watch._docker_api_get = lambda path: {
            "State": {"Health": {"Status": "healthy", "FailingStreak": 0}}
        }
        result = watch.inspect_health("x")
        self.assertEqual(result, {"status": "healthy", "failing_streak": 0})


class BuildPayloadTest(unittest.TestCase):
    def test_firing_payload_matches_alertmanager_shape_and_routes_critical(self):
        payload = watch.build_payload(
            "wrfcoin-testnet-funnel-edge", "unhealthy", 5505, firing=True
        )
        self.assertEqual(payload["status"], "firing")
        alert = payload["alerts"][0]
        self.assertEqual(alert["status"], "firing")
        # severity: critical is what routes through the existing
        # critical-notifications receiver in testnet/alertmanager.yml —
        # this is the whole point, so pin it explicitly.
        self.assertEqual(alert["labels"]["severity"], "critical")
        self.assertEqual(alert["labels"]["alertname"], "ContainerUnhealthy")
        self.assertEqual(alert["labels"]["service"], "wrfcoin-testnet-funnel-edge")
        self.assertEqual(alert["endsAt"], "0001-01-01T00:00:00Z")
        self.assertIn("5505", alert["annotations"]["summary"])
        self.assertIn("infra#900", alert["annotations"]["description"])

    def test_resolved_payload_has_real_endsat(self):
        payload = watch.build_payload("x", "healthy", 0, firing=False)
        alert = payload["alerts"][0]
        self.assertEqual(alert["status"], "resolved")
        self.assertNotEqual(alert["endsAt"], "0001-01-01T00:00:00Z")


class PollOnceDedupTest(unittest.TestCase):
    def setUp(self):
        watch._alerting.clear()
        watch._pending_retry.clear()
        watch._poll_count = 0
        self._orig_list = watch.list_container_names
        self._orig_inspect = watch.inspect_health
        self._orig_post = watch.post_alert
        self.posted = []
        watch.post_alert = lambda payload: self.posted.append(payload) or True

    def tearDown(self):
        watch.list_container_names = self._orig_list
        watch.inspect_health = self._orig_inspect
        watch.post_alert = self._orig_post
        watch._alerting.clear()
        watch._pending_retry.clear()
        watch._poll_count = 0

    def test_fires_once_then_stays_quiet_while_still_unhealthy(self):
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {"status": "unhealthy", "failing_streak": 10}

        watch.poll_once()
        watch.poll_once()
        watch.poll_once()

        firing = [p for p in self.posted if p["status"] == "firing"]
        self.assertEqual(len(firing), 1, "must not re-fire every poll while still unhealthy")
        self.assertTrue(watch._alerting["edge"])

    def test_does_not_fire_below_threshold(self):
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {
            "status": "unhealthy",
            "failing_streak": watch.FAILING_STREAK_THRESHOLD - 1,
        }
        watch.poll_once()
        self.assertEqual(self.posted, [])
        self.assertNotIn("edge", watch._alerting)

    def test_fires_then_resolves_on_recovery(self):
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {"status": "unhealthy", "failing_streak": 99}
        watch.poll_once()

        watch.inspect_health = lambda name: {"status": "healthy", "failing_streak": 0}
        watch.poll_once()

        statuses = [p["status"] for p in self.posted]
        self.assertEqual(statuses, ["firing", "resolved"])
        self.assertFalse(watch._alerting["edge"])

    def test_container_with_no_healthcheck_is_skipped(self):
        watch.list_container_names = lambda: ["no-healthcheck"]
        watch.inspect_health = lambda name: None
        watch.poll_once()
        self.assertEqual(self.posted, [])


class _FakeResponse:
    """Minimal urllib response stand-in: status + read() + context manager."""

    def __init__(self, status: int, body: bytes) -> None:
        self.status = status
        self._body = body

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc: object) -> bool:
        return False


class PostAlertRespectsForwardedFlagTest(unittest.TestCase):
    """Regression coverage for the review finding on PR #903: an HTTP 2xx
    from wrfcoin-alert-receiver means "accepted", not "delivered to a
    human" — its own /alerts handler always returns 200, with `forwarded`
    reflecting whether ALERT_FORWARD_URL was set and the external channel
    actually accepted the notification (testnet/alertmanager-webhook-receiver.py
    do_POST). Reviewer reproduction: a 200 response with forwarded:false
    was previously treated as delivered, which suppressed retry while no
    human ever saw the alert."""

    def setUp(self):
        self._orig_urlopen = watch.urllib.request.urlopen

    def tearDown(self):
        watch.urllib.request.urlopen = self._orig_urlopen

    def _stub(self, status: int, body: dict):
        payload = json.dumps(body).encode("utf-8")
        watch.urllib.request.urlopen = lambda req, timeout=10: _FakeResponse(status, payload)

    def test_forwarded_true_is_delivered(self):
        self._stub(200, {"status": "accepted", "alert_count": 1, "forwarded": True})
        self.assertTrue(watch.post_alert({"status": "firing", "alerts": []}))

    def test_200_with_forwarded_false_is_NOT_delivered(self):
        """Exact reproduction of the reviewer's repro shape on PR #903."""
        self._stub(200, {"status": "accepted", "alert_count": 1, "forwarded": False})
        self.assertFalse(watch.post_alert({"status": "firing", "alerts": []}))

    def test_missing_forwarded_key_is_not_delivered(self):
        self._stub(200, {"status": "accepted", "alert_count": 1})
        self.assertFalse(watch.post_alert({"status": "firing", "alerts": []}))

    def test_non_2xx_is_not_delivered(self):
        self._stub(500, {"forwarded": True})
        self.assertFalse(watch.post_alert({"status": "firing", "alerts": []}))

    def test_malformed_json_is_not_delivered(self):
        watch.urllib.request.urlopen = lambda req, timeout=10: _FakeResponse(200, b"not json")
        self.assertFalse(watch.post_alert({"status": "firing", "alerts": []}))


class UndeliveredAlertsRetryWithBoundedBackoffTest(unittest.TestCase):
    """End-to-end regression through poll_once (real post_alert, not a stub
    of it) against a receiver that always 200s with forwarded:false.

    Covers TWO things review round 3 on PR #903 required, from opposite
    directions:
      1. it must still retry, not get deduped away as delivered
         (test_stays_retryable_on_consecutive_polls) — the property round 2
         fixed and this must not regress;
      2. the retry rate must be BOUNDED over a sustained outage
         (test_retry_is_bounded_over_a_sustained_outage), reproducing the
         reviewer's own 100-poll probe, which found the pre-fix code sent
         100 POSTs with no bound. This asserts an exact, empirically-measured
         count for the fixed backoff schedule (min(2**(attempts-1), 20)
         polls between attempts) rather than a loose upper bound, so a
         regression in the backoff math itself — not just its presence —
         gets caught.
    """

    def setUp(self):
        watch._alerting.clear()
        watch._pending_retry.clear()
        watch._poll_count = 0
        self._orig_list = watch.list_container_names
        self._orig_inspect = watch.inspect_health
        self._orig_urlopen = watch.urllib.request.urlopen

    def tearDown(self):
        watch.list_container_names = self._orig_list
        watch.inspect_health = self._orig_inspect
        watch.urllib.request.urlopen = self._orig_urlopen
        watch._alerting.clear()
        watch._pending_retry.clear()
        watch._poll_count = 0

    def _stub_undelivered(self, posted_requests: list) -> None:
        def fake_urlopen(req, timeout=10):
            posted_requests.append(json.loads(req.data))
            body = json.dumps({"status": "accepted", "forwarded": False}).encode("utf-8")
            return _FakeResponse(200, body)

        watch.urllib.request.urlopen = fake_urlopen

    def test_stays_retryable_on_consecutive_polls(self):
        """The first two attempts land on consecutive polls (backoff=1
        before the interval starts growing), so an undelivered alert is
        still visibly retried right away, not silently deduped."""
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {"status": "unhealthy", "failing_streak": 10}
        posted_requests: list = []
        self._stub_undelivered(posted_requests)

        watch.poll_once()
        watch.poll_once()

        self.assertEqual(
            len(posted_requests), 2, "an undelivered alert's first two attempts must both fire"
        )
        self.assertNotIn(
            "edge", watch._alerting, "episode must not be marked alerting until actually forwarded"
        )
        self.assertIn("edge", watch._pending_retry, "undelivered episode must stay visibly pending")

    def test_retry_is_bounded_over_a_sustained_outage(self):
        """Reproduces the reviewer's 100-poll probe. Pre-fix: 100 POSTs, no
        bound. Post-fix, empirically measured: exactly 9 POSTs over 100
        polls under the min(2**(attempts-1), 20) schedule — attempts at
        polls 1, 2, 4, 8, 16, 32, 52, 72, 92 — then it holds at a 20-poll
        cadence indefinitely rather than ever stopping outright."""
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {"status": "unhealthy", "failing_streak": 10}
        posted_requests: list = []
        self._stub_undelivered(posted_requests)

        for _ in range(100):
            watch.poll_once()

        self.assertEqual(
            len(posted_requests),
            9,
            "retry rate must be bounded, not one POST per poll for all 100 polls",
        )
        self.assertLess(
            len(posted_requests), 100, "sanity floor: must be far fewer than one POST per poll"
        )
        self.assertNotIn("edge", watch._alerting, "still never confirmed delivered")
        self.assertIn(
            "edge",
            watch._pending_retry,
            "the outage must remain visibly pending, not silently forgotten, after 100 polls",
        )

    def test_recovery_before_delivery_drops_the_stale_pending_retry(self):
        """If the container recovers before its firing alert was EVER
        confirmed delivered, a queued retry must not fire a stale 'firing'
        POST once it's already healthy again."""
        watch.list_container_names = lambda: ["edge"]
        watch.inspect_health = lambda name: {"status": "unhealthy", "failing_streak": 10}
        posted_requests: list = []
        self._stub_undelivered(posted_requests)

        watch.poll_once()  # attempt 1 fails, schedules attempt 2 for poll 2
        self.assertIn("edge", watch._pending_retry)

        watch.inspect_health = lambda name: {"status": "healthy", "failing_streak": 0}
        watch.poll_once()  # recovers before delivery was ever confirmed

        self.assertNotIn(
            "edge", watch._pending_retry, "pending retry for a now-healthy container must be dropped"
        )
        self.assertEqual(len(posted_requests), 1, "no stale firing POST after recovery")


class HealthResponseReflectsPollStatusTest(unittest.TestCase):
    """Regression coverage for review finding 2 on PR #903: the /health
    endpoint must return non-2xx when the last Docker poll failed, so the
    Compose healthcheck (which only checks wget's HTTP exit status) can
    actually observe a degraded watcher instead of reporting it healthy
    while blind to every container."""

    def tearDown(self):
        watch._last_poll_ok = False
        watch._last_poll_at = ""
        watch._pending_retry.clear()

    def test_ok_poll_is_200(self):
        watch._last_poll_ok = True
        status, payload = watch.health_response()
        self.assertEqual(status, watch.HTTPStatus.OK)
        self.assertEqual(payload["status"], "ok")

    def test_undelivered_episodes_are_visible_in_the_body(self):
        """Regression for review round 3: a bounded-backoff retry must stay
        observable via /health, not just in the stderr line at the moment
        of each failed attempt — this is the 'remains visible' requirement."""
        watch._last_poll_ok = True
        watch._pending_retry["edge"] = {"attempts": 3, "next_attempt_at_poll": 8}
        _, payload = watch.health_response()
        self.assertEqual(payload["undelivered_pending"], ["edge"])

    def test_degraded_poll_is_non_2xx(self):
        watch._last_poll_ok = False
        status, payload = watch.health_response()
        self.assertEqual(status, watch.HTTPStatus.SERVICE_UNAVAILABLE)
        self.assertFalse(200 <= int(status) < 300)
        self.assertEqual(payload["status"], "degraded")


if __name__ == "__main__":
    unittest.main(verbosity=2)
