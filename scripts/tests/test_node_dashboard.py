"""
Pin the dashboard's blockchain decoder against a fixed JSON shape so that an
upstream rename in launch_api (e.g. `total_transactions` → `tx_total`) fails
CI rather than silently zeroing out a field on the physical-monitor dashboard.

The dashboard module has a hyphen in its filename, so we load it via
importlib. We stub `_pct` at the module level — every HTTP path in the
dashboard routes through there — and hand back fixture JSON keyed by path.
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import tempfile
import time
import unittest

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent.parent
DASHBOARD_PATH = SCRIPTS_DIR / "node-dashboard.py"


def _load_dashboard():
    spec = importlib.util.spec_from_file_location("node_dashboard", DASHBOARD_PATH)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["node_dashboard"] = mod
    assert spec and spec.loader
    spec.loader.exec_module(mod)
    return mod


# Canonical response shapes captured from a live testnet node on 2026-04-14.
# If launch_api ever renames a key used by _collect_blockchain, the assertions
# below will fail and tell us what drifted.
FIXTURE_RESPONSES = {
    "/health": {
        "status": "ok",
        "service": "wrfcoin-native-launch-api",
        "uptime_seconds": 88382,
    },
    "/readyz": {
        "status": "ready",
        "uptime_seconds": 88382,
        "checks": {
            "storage": {"status": "ok", "height": 4104},
            "block_production": {"status": "ok", "block_age_seconds": 99, "height": 4104},
            "peers": {"status": "no_peers", "connected": 0, "readiness_gate": False},
        },
    },
    "/blockchain": {
        "height": 4104,
        "tip": "403240d83e54ccfe5050d35af207222496094cc3ab2a4a09df130ae8afac3b94",
        "accounts": 0,
        "nfts": 0,
        "pending_transactions": 0,
    },
    "/network/info": {
        "peer_count": 0,
        "sync_status": "synced",
        "chain_height": 4104,
        "network_id": "testnet",
        "chain_id": 777,
        "node_version": "0.1.0",
    },
    "/node/sync/status": {
        "block_age_secs": 99,
        "blocks_in_memory": 200,
        "chain_height": 4104,
        "peer_count": 0,
        "sync_status": "synced",
    },
    "/node/resources": {
        "uptime_secs": 88382,
        "blocks_in_memory": 200,
        "account_count": 0,
        "nft_count": 0,
        "pending_transactions": 0,
    },
    "/mining/stats": {
        "avg_block_time_secs": 303.73,
        "blocks_in_memory": 200,
        "chain_height": 4104,
        "difficulty": 1,
        "total_transactions": 606,
    },
    "/transactions/oracle/status": {
        "oracle_quorum": 0,
        "oracle_set": [],
        "tracked_commit_count": 0,
        "commits_with_quorum": 0,
        "commits_pending_quorum": 0,
    },
    "/network/stats": {
        "blocks_published": 290,
        "blocks_received": 0,
        "bytes_inbound": 0,
        "bytes_outbound": 1547022,
        "connected_peers": 0,
        "txs_published": 588,
        "txs_received": 0,
        "uptime_secs": 88382,
        "weather_msgs_published": 0,
        "weather_msgs_received": 0,
    },
}


def _wrap_envelope(body):
    """launch_api wraps most responses in `{ok, data, meta, error}` except /health."""
    return {
        "ok": True,
        "data": body,
        "error": None,
        "meta": {"request_id": "req_test", "timestamp": "2026-04-14T00:00:00Z", "api_version": "v1"},
    }


class CollectBlockchainTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()

        def fake_pct_script(script, timeout=15, ct_id=None):
            # The dashboard runs a script that pulls the reader token from
            # inside the node container and appends the HTTP status as the last
            # line, so an auth failure can be told apart from a healthy zero.
            for path, body in FIXTURE_RESPONSES.items():
                if f'{path}"' in script:
                    # /health is not enveloped; everything else is.
                    payload = body if path == "/health" else _wrap_envelope(body)
                    return json.dumps(payload) + "\n200"
            return ""

        # _collect_blockchain also lists the weather collector's roster through
        # _pct (a `pct exec ... docker exec` call). These tests pin the HTTP
        # decoder only, so hand back an empty roster instead of leaving the
        # real transport reachable (infra#1230).
        self._orig_pct = self.dash._pct
        self.dash._pct = lambda cmd, timeout=12, ct_id=None: ""
        self._orig_pct_script = self.dash._pct_script
        self.dash._pct_script = fake_pct_script

    def tearDown(self):
        self.dash._pct = self._orig_pct
        self.dash._pct_script = self._orig_pct_script

    def test_collect_blockchain_extracts_all_dashboard_fields(self):
        d = self.dash._collect_blockchain(ct_id=101)

        # The dashboard assumes the node is online iff /health decoded as a dict.
        self.assertTrue(d["online"])
        self.assertEqual(d["source"], "http")
        self.assertEqual(d["status"], "ready")

        # Chain tip fields — /node/sync/status wins for height and block_age.
        self.assertEqual(d["height"], 4104)
        self.assertEqual(d["block_age_seconds"], 99)
        self.assertEqual(d["blocks_in_memory"], 200)
        self.assertEqual(d["sync_status"], "synced")
        self.assertEqual(
            d["tip"],
            "403240d83e54ccfe5050d35af207222496094cc3ab2a4a09df130ae8afac3b94",
        )

        # /blockchain fields.
        self.assertEqual(d["pending"], 0)
        self.assertEqual(d["accounts"], 0)
        self.assertEqual(d["nfts"], 0)

        # /network/info identity fields.
        self.assertEqual(d["network_id"], "testnet")
        self.assertEqual(d["chain_id"], 777)

        # /mining/stats — this is where `total_transactions` (the "606" on the
        # dashboard) comes from. If upstream renames this key the assertion
        # below fails loudly.
        self.assertEqual(d["total_transactions"], 606)
        self.assertAlmostEqual(d["avg_block_time_secs"], 303.73, places=2)
        self.assertEqual(d["difficulty"], 1)

        # P2P / oracle aggregates.
        self.assertEqual(d["peers"], 0)

    def test_offline_node_does_not_raise(self):
        """If /health doesn't respond, the collector must degrade, not crash."""
        self.dash._pct = lambda cmd, timeout=12, ct_id=None: ""
        self.dash._pct_script = lambda script, timeout=15, ct_id=None: ""
        d = self.dash._collect_blockchain(ct_id=101)
        self.assertFalse(d["online"])
        self.assertEqual(d["status"], "offline")


class CollectDockerServicesTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()
        self._orig_pct_script = self.dash._pct_script

    def tearDown(self):
        self.dash._pct_script = self._orig_pct_script

    def test_collect_docker_decodes_literal_tab_inspect_output(self):
        """Docker inspect can emit literal "\\t"; dashboard must still parse it."""
        self.dash._pct_script = lambda script, timeout=15, ct_id=None: "\n".join(
            [
                "wrfcoin-testnet-postgres\trunning\\thealthy\\t2026-05-12T08:31:56Z\\t2026-05-12T08:30:51Z\\t0\\t0\\tpostgres:15-alpine",
                "wrfcoin-testnet-redis\trunning\\thealthy\\t2026-05-12T08:31:56Z\\t2026-05-12T08:30:51Z\\t0\\t0\\tredis:7-alpine",
                "wrfcoin-testnet-db-migrate\texited\\tunhealthy\\t2026-05-12T08:32:06Z\\t2026-05-12T08:32:08Z\\t0\\t0\\twrfcoin/backend:testnet-local",
                "wrfcoin-testnet-node\trunning\\thealthy\\t2026-05-12T08:31:56Z\\t2026-05-12T08:30:51Z\\t0\\t0\\twrfcoin-node:testnet-local",
            ]
        )

        docker = self.dash._collect_docker(ct_id=101)

        self.assertEqual(docker["postgres"]["status"], "running")
        self.assertEqual(docker["postgres"]["health"], "healthy")
        self.assertEqual(docker["redis"]["status"], "running")
        self.assertEqual(docker["redis"]["health"], "healthy")
        self.assertEqual(docker["db-migrate"]["status"], "exited")
        self.assertEqual(docker["db-migrate"]["exit_code"], 0)

        self.assertEqual(
            self.dash._service_bucket(self.dash.SERVICE_DEFS[0], docker["postgres"]),
            "up",
        )
        self.assertEqual(
            self.dash._service_bucket(self.dash.SERVICE_DEFS[1], docker["redis"]),
            "up",
        )
        self.assertEqual(
            self.dash._service_bucket(self.dash.SERVICE_DEFS[2], docker["db-migrate"]),
            "init_done",
        )

    def test_core_services_do_not_raise_unhealthy_alert_when_healthy(self):
        docker = {
            "postgres": {"status": "running", "health": "healthy", "restart_count": 0},
            "redis": {"status": "running", "health": "healthy", "restart_count": 0},
            "db-migrate": {"status": "exited", "health": "unhealthy", "exit_code": 0, "restart_count": 0},
            "node": {"status": "running", "health": "healthy", "restart_count": 0},
        }

        alerts = self.dash._build_alerts(
            {"state": "ONLINE"},
            {"uptime_secs": 3600},
            {"running": True, "id": 101, "configured_id": 101},
            docker,
            {"online": True, "status": "ready", "sync_status": "synced", "peers": 1},
        )

        alert_text = " ".join(text for text, _ in alerts)
        self.assertNotIn("Postgres", alert_text)
        self.assertNotIn("Redis", alert_text)
        self.assertNotIn("DB migrate", alert_text)

    def test_headline_summary_uses_default_profile_services_and_counts_init_done(self):
        docker = {
            "postgres": {"status": "running", "health": "healthy", "restart_count": 0},
            "redis": {"status": "running", "health": "healthy", "restart_count": 0},
            "db-migrate": {"status": "exited", "health": "unhealthy", "exit_code": 0, "restart_count": 0},
            "node": {"status": "running", "health": "healthy", "restart_count": 0},
            "backend": {"status": "running", "health": "healthy", "restart_count": 0},
            "frontend": {"status": "running", "health": "healthy", "restart_count": 0},
            "explorer": {"status": "running", "health": "healthy", "restart_count": 0},
            "loki": {"status": "running", "health": "healthy", "restart_count": 0},
            "promtail": {"status": "running", "health": "healthy", "restart_count": 0},
            "weather-collector": {"status": "running", "health": "none", "restart_count": 0},
        }

        headline = self.dash._headline_service_summary(docker)

        self.assertEqual(headline["up"], 9)
        self.assertEqual(headline["total"], 16)

    def test_catalog_tracks_default_profile_logging_and_explorer_services(self):
        required_keys = {
            svc["key"]
            for svc in self.dash.HEADLINE_SERVICE_DEFS
        }
        optional_keys = {
            svc["key"]
            for svc in self.dash.SERVICE_DEFS
            if svc.get("profile")
        }

        self.assertIn("explorer", required_keys)
        self.assertIn("loki", required_keys)
        self.assertIn("promtail", required_keys)
        self.assertEqual({"seed", "weather-collector"}, optional_keys)
        self.assertEqual(16, len(self.dash.HEADLINE_SERVICE_DEFS))


class WeatherStationDiscoveryTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()
        self._orig_pct = self.dash._pct
        self._orig_pct_script = self.dash._pct_script
        self.dash._pct_script = lambda script, timeout=15, ct_id=None: ""

    def tearDown(self):
        self.dash._pct = self._orig_pct
        self.dash._pct_script = self._orig_pct_script

    def test_fixture_directory_discovers_two_one_and_zero_stations(self):
        now_ms = int(time.time() * 1000)
        with tempfile.TemporaryDirectory() as fixture_dir:
            fixture_dir = pathlib.Path(fixture_dir)

            def write_station(key):
                (fixture_dir / f"ambient-weather-{key}-latest.json").write_text(
                    json.dumps({
                        "station": {"name": key.title(), "location": key},
                        "normalized": [{"temperature_c": 20, "recorded_at": now_ms}],
                        "fetched_at": "2026-08-31T00:00:00",
                    })
                )
                (fixture_dir / f"ambient-weather-{key}-accuracy.json").write_text(
                    json.dumps({"metrics": None})
                )

            def collect(keys):
                for path in fixture_dir.iterdir():
                    path.unlink()
                for key in keys:
                    write_station(key)

                def fake_pct(script, timeout=15, ct_id=None):
                    if "ambient-weather-*-latest.json" in script:
                        return "\n".join(sorted(
                            path.name for path in fixture_dir.glob("ambient-weather-*-latest.json")
                        ))
                    marker = "cat /app/data/"
                    if marker in script:
                        filename = script.split(marker, 1)[1].split(" ", 1)[0]
                        path = fixture_dir / filename
                        return path.read_text() if path.exists() else ""
                    return ""

                self.dash._pct = fake_pct
                return self.dash._collect_blockchain(ct_id=101)

            for keys, expected in [(["alpha", "beta"], "2/2"), (["alpha"], "1/1"), ([], "0/0")]:
                with self.subTest(keys=keys):
                    data = collect(keys)
                    stations = data["weather_stations"]
                    fresh = sum(1 for station in stations if station["fresh"])
                    self.assertEqual(f"{fresh}/{len(stations)}", expected)
                    self.assertEqual(set(data["weather_latest"]), set(keys))
                    self.assertEqual(set(data["weather_accuracy"]), set(keys))



RUNNER_REPORT = "\n".join([
    "HOST\t20\t20.23\t22.77\t34359738368\t30201037824",
    "n5pro-ct102\twrfcoin/core4\tactive\t1\t136.0\t92\tdeploy feature set compile + test --no-run",
    "n5pro-ct102-backend\twrfcoin/backend\tactive\t0\t0.0\t0\t",
    "n5pro-ct102-2\twrfcoin/core4\tinactive\t0\t0.0\t0\t",
    "n5pro-ct102-3\twrfcoin/core4\tactive\t1\t44.0\t10\tmocked-integration",
    "n5pro-ct102-infra\twrfcoin/infra\tactive\t0\tnot-a-number\t0\t",
])


class CiRunnerPanelTests(unittest.TestCase):
    """The CI RUNNERS panel: collector decoding, queue ordering, token lookup, alerts, draw."""

    def setUp(self):
        self.dash = _load_dashboard()

    def test_parse_runner_report_decodes_host_and_runners_core4_first(self):
        report = self.dash._parse_runner_report(RUNNER_REPORT)
        self.assertEqual(report["host"]["nproc"], 20)
        self.assertEqual(report["host"]["load1"], "20.23")
        self.assertEqual(report["host"]["mem_avail"], 30201037824)
        names = [r["name"] for r in report["runners"]]
        self.assertEqual(names, ["n5pro-ct102", "n5pro-ct102-2", "n5pro-ct102-3",
                                 "n5pro-ct102-backend", "n5pro-ct102-infra"])
        first = report["runners"][0]
        self.assertTrue(first["busy"])
        self.assertEqual(first["cpu_pct"], 136.0)
        self.assertEqual(first["elapsed"], 92)
        self.assertEqual(first["job"], "deploy feature set compile + test --no-run")
        idle = report["runners"][3]
        self.assertFalse(idle["busy"])
        self.assertEqual(idle["job"], "")
        # A malformed CPU field degrades to 0, never to a crash on the console.
        self.assertEqual(report["runners"][4]["cpu_pct"], 0.0)

    def test_collect_runners_reports_empty_ct_as_error_not_crash(self):
        orig = self.dash._pct_script
        try:
            self.dash._pct_script = lambda script, timeout=15, ct_id=None: ""
            report = self.dash._collect_runners(ct_id=102)
        finally:
            self.dash._pct_script = orig
        self.assertEqual(report["runners"], [])
        self.assertIn("102", report["error"])

    def test_order_ci_queue_is_oldest_first(self):
        runs = [
            {"id": 3, "created_at": "2026-09-09T19:03:00Z"},
            {"id": 1, "created_at": "2026-09-09T18:01:00Z"},
            {"id": 2, "created_at": "2026-09-09T18:01:00Z"},
        ]
        self.assertEqual([r["id"] for r in self.dash._order_ci_queue(runs)], [1, 2, 3])

    def test_fetch_ci_queue_shapes_runs_and_attaches_running_jobs(self):
        calls = []

        def fake_get(path, token, timeout=6):
            calls.append(path)
            if path.endswith("/jobs?per_page=50"):
                if "/runs/10/" in path:      # the oldest queued run: one hosted job, one self-hosted
                    return {"jobs": [
                        {"name": "hosted lint", "status": "queued", "labels": ["ubuntu-latest"]},
                        {"name": "detect-secrets baseline audit (merge tree)", "status": "queued",
                         "labels": ["self-hosted", "n5pro"]},
                    ]}
                if "/runs/20/" in path:
                    return {"jobs": [{"name": "determinism", "status": "queued",
                                      "labels": ["self-hosted"]}]}
                return {"jobs": [
                    {"name": "schedule-lint", "status": "completed", "runner_name": "n5pro-ct102",
                     "labels": ["self-hosted"]},
                    {"name": "cargo test", "status": "in_progress", "runner_name": "n5pro-ct102-2",
                     "labels": ["self-hosted"]},
                ]}
            if "status=queued" in path and "core4" in path:
                return {"workflow_runs": [
                    {"id": 20, "name": "Determinism Lint", "run_number": 9, "head_branch": "b2",
                     "display_title": "t2", "created_at": "2026-09-09T19:02:00Z", "event": "pull_request"},
                    {"id": 10, "name": "Secret scanning", "run_number": 8, "head_branch": "b1",
                     "display_title": "t1", "created_at": "2026-09-09T19:01:00Z", "event": "pull_request"},
                ]}
            if "status=in_progress" in path and "infra" in path:
                return {"workflow_runs": [
                    {"id": 30, "name": "scripts/tests suites", "run_number": 3, "head_branch": "main",
                     "display_title": "t3", "created_at": "2026-09-09T19:00:00Z", "event": "push"},
                ]}
            return {"workflow_runs": []}

        q = self.dash._fetch_ci_queue("tok", repos=["wrfcoin/core4", "wrfcoin/infra"], get=fake_get)
        self.assertIsNone(q["error"])
        self.assertEqual([r["id"] for r in q["queued"]], [10, 20])       # oldest first
        self.assertEqual(q["queued"][0]["repo"], "core4")
        self.assertEqual(q["queued"][0]["branch"], "b1")
        self.assertEqual(len(q["running"]), 1)
        self.assertEqual(q["running"][0]["jobs"],
                         [{"name": "cargo test", "runner": "n5pro-ct102-2", "self_hosted": True}])
        # Next up = self-hosted jobs of the oldest runs, in run order; hosted jobs are skipped.
        self.assertEqual([(j["job"], j["repo"]) for j in q["queued_jobs"]],
                         [("detect-secrets baseline audit (merge tree)", "core4"), ("determinism", "core4")])
        self.assertEqual(q["probed"], 2)
        self.assertIn("/repos/wrfcoin/infra/actions/runs/30/jobs?per_page=50", calls)

    def test_ci_token_prefers_env_then_env_file(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("# dashboard env\nWRFCOIN_GH_TOKEN=\"from-file\"\n")
            path = f.name
        self.assertEqual(self.dash._ci_token(env={"GITHUB_TOKEN": "from-env"}, env_file=path), "from-env")
        self.assertEqual(self.dash._ci_token(env={}, env_file=path), "from-file")
        self.assertEqual(self.dash._ci_token(env={}, env_file=path + ".missing"), "")

    def test_collect_ci_queue_without_token_is_explicit_not_empty(self):
        self.dash._CI_QUEUE_CACHE.update({"expires_at": 0.0, "data": None})
        orig = self.dash._ci_token
        try:
            self.dash._ci_token = lambda env=None, env_file=None: ""
            q = self.dash._collect_ci_queue()
        finally:
            self.dash._ci_token = orig
            self.dash._CI_QUEUE_CACHE.update({"expires_at": 0.0, "data": None})
        self.assertEqual(q["error"], "no token")
        self.assertEqual(q["queued"], [])

    def test_build_alerts_flags_a_down_runner_service(self):
        report = self.dash._parse_runner_report(RUNNER_REPORT)
        alerts = self.dash._build_alerts({}, {"uptime_secs": 100000}, {"running": True, "id": 101,
                                         "configured_id": 101}, {}, {"online": False}, runners=report)
        texts = [t for t, _ in alerts]
        self.assertTrue(any("n5pro-ct102-2" in t and "inactive" in t for t in texts), texts)
        self.assertFalse(any("n5pro-ct102-3" in t for t in texts), texts)

    def test_draw_renders_runner_panel_without_curses_errors(self):
        """Drive _draw with a stub screen so a panel layout bug fails here, not on tty1."""
        dash = self.dash
        dash._init_colors = lambda: None
        dash.curses.color_pair = lambda n: 0
        dash.curses.A_BOLD = 0
        dash.curses.doupdate = lambda: None

        class Screen:
            def __init__(self):
                self.cells = {}
            def getmaxyx(self):
                return (80, 140)
            def erase(self):
                pass
            def addstr(self, row, col, text, attr=0):
                self.cells[(row, col)] = text
            def noutrefresh(self):
                pass

        state = dash.NodeState()
        state.runners = dash._parse_runner_report(RUNNER_REPORT)
        state.ci_queue = {"queued": [
            {"repo": "core4", "name": "Secret scanning", "branch": "luna/x",
             "created_at": "2026-09-09T18:00:00Z", "id": 1},
        ], "queued_jobs": [
            {"repo": "core4", "workflow": "Secret scanning", "job": "detect-secrets baseline audit (merge tree)",
             "branch": "luna/x", "created_at": "2026-09-09T18:00:00Z", "labels": ["self-hosted"]},
        ], "probed": 1, "running": [], "error": None}
        scr = Screen()
        dash._draw(scr, state)
        text = " ".join(scr.cells.values())
        self.assertIn("CI RUNNERS", text)
        self.assertIn("n5pro-ct102-3", text)
        self.assertIn("mocked-integration", text)
        self.assertIn("Secret scanning", text)
        self.assertIn("detect-secrets baseline audit", text)
        self.assertIn("1 self-hosted jobs queued · 1 runs queued · 0 running", text)

if __name__ == "__main__":
    unittest.main(verbosity=2)


# ---------------------------------------------------------------------------
# Oracle truth and earnings visibility.
#
# Both regressions below were measured on the live testnet on 2026-08-05, hours
# after the genesis cut: the oracle set was populated and consensus-enforced,
# and ZERO OracleAttestation transactions had ever existed. Every oracle counter
# therefore read 0 — which the dashboard rendered as "pend 0", indistinguishable
# from a healthy chain with nothing outstanding. See core4#2464 and core4#2737.
# ---------------------------------------------------------------------------
class OracleTruthTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()

    def test_populated_oracle_set_with_nothing_tracked_raises_an_alert(self):
        """All-zero oracle counters must NOT read as healthy.

        A populated oracle set with tracked_commit_count == 0 means no
        attestation has ever been seen. Silence here is what let a month of
        zero-earning contributions pass unnoticed.
        """
        bc = {
            "online": True,
            "oracle_set_size": 3,
            "oracle_quorum": 2,
            "tracked_commit_count": 0,
            "commits_with_quorum": 0,
            "commits_pending_quorum": 0,
        }
        self.assertTrue(
            self.dash._oracle_is_inert(bc),
            "a populated oracle set tracking nothing must be reported as inert",
        )

    def test_tracking_commits_is_not_inert(self):
        """Once attestations flow, the alert must stop firing."""
        bc = {
            "online": True,
            "oracle_set_size": 3,
            "oracle_quorum": 2,
            "tracked_commit_count": 7,
            "commits_with_quorum": 5,
            "commits_pending_quorum": 2,
        }
        self.assertFalse(self.dash._oracle_is_inert(bc))

    def test_empty_oracle_set_is_not_reported_as_inert(self):
        """No oracle set is a different (pre-cut) condition, reported elsewhere."""
        bc = {
            "online": True,
            "oracle_set_size": 0,
            "oracle_quorum": 2,
            "tracked_commit_count": 0,
        }
        self.assertFalse(self.dash._oracle_is_inert(bc))


class ContributorEarningsTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()
        # Contributors come from the host-local config; use synthetic ones.
        self.dash.CONTRIBUTOR_ADDRESSES = [
            ("alpha", "0x" + "11" * 20),
            ("beta", "0x" + "22" * 20),
        ]

    def test_contributor_with_no_account_reports_zero_not_missing(self):
        """A 404 contributor means zero earned, and must say so explicitly.

        Measured: both real contributor addresses returned 404 while the
        producer's payout address held 163,280 WRF of coinbase. "Not found"
        must not render as absence of information.
        """
        self.dash._json_get_ex = (
            lambda path, port=None, timeout=5, ct_id=None: (None, "NOT_FOUND")
        )
        rows = self.dash._collect_contributor_earnings(ct_id=101)
        self.assertTrue(rows, "configured contributors must always produce a row")
        self.assertTrue(all(r["paid"] == 0 for r in rows))
        self.assertTrue(all(r["exists"] is False for r in rows))
        self.assertTrue(all(r["error"] is None for r in rows))

    def test_paid_contributor_is_reported(self):
        def fake_json_get_ex(path, port=None, timeout=5, ct_id=None):
            return {
                "address": path.rsplit("/", 1)[-1],
                "balance": "2500000000",
                "contribution_rewards": {
                    "real_paid": "2500000000",
                    "real_decision_count": 4,
                },
            }, None

        self.dash._json_get_ex = fake_json_get_ex
        rows = self.dash._collect_contributor_earnings(ct_id=101)
        self.assertTrue(rows)
        self.assertTrue(all(r["exists"] for r in rows))
        self.assertTrue(all(r["paid"] > 0 for r in rows))
        self.assertTrue(all(r["decisions"] == 4 for r in rows))

    def test_unauthorized_contributor_is_not_reported_as_zero(self):
        """A 401 is an unanswered question, not an answer of zero.

        This is the defect the whole change exists for: the panel queried
        unauthenticated, every request was refused, and both contributors
        rendered as a confident `0 WRF` - identical to a healthy chain where
        nobody had earned yet.
        """
        self.dash._json_get_ex = (
            lambda path, port=None, timeout=5, ct_id=None: (None, "HTTP 401")
        )
        rows = self.dash._collect_contributor_earnings(ct_id=101)
        self.assertTrue(rows)
        self.assertTrue(all(r["error"] == "HTTP 401" for r in rows))
        self.assertTrue(
            all(r["paid"] is None for r in rows),
            "an unanswered query must not carry a numeric total",
        )

        line = self.dash._earnings_row({"contributor_earnings": rows})
        self.assertIn("UNAVAILABLE", line)
        self.assertNotIn("0 WRF", line)

    def test_one_unavailable_contributor_does_not_zero_the_others(self):
        rows = [
            {"label": "A", "address": "0xa", "exists": True, "paid": 250000000,
             "decisions": 1, "error": None},
            {"label": "B", "address": "0xb", "exists": None, "paid": None,
             "decisions": None, "error": "HTTP 401"},
        ]
        line = self.dash._earnings_row({"contributor_earnings": rows})
        self.assertIn("A 2.50", line)
        self.assertIn("1 unavailable", line)


class OracleRowFailureTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()

    def test_failed_oracle_query_is_not_rendered_as_nothing_pending(self):
        """`pend 0` from a refused request is the exact bug #788 half-fixed.

        #788 taught the row to distinguish a populated-but-inert oracle set from
        a healthy one. It could never fire on the real host, because the query
        was refused and `oracle_set_size` therefore read 0 - so the row fell
        through to the all-zeros branch and looked calm.
        """
        line = self.dash._oracle_row({"online": True, "oracle_query_error": "HTTP 401"})
        self.assertIn("UNAVAILABLE", line)
        self.assertIn("401", line)
        self.assertNotIn("pend 0", line)

    def test_successful_query_still_renders_counters(self):
        line = self.dash._oracle_row({
            "online": True, "oracle_query_error": None,
            "oracle_quorum": 2, "oracle_set_size": 3,
            "tracked_commit_count": 7, "commits_with_quorum": 5,
            "commits_pending_quorum": 2,
        })
        self.assertIn("trk 7", line)
        self.assertIn("pend 2", line)
        self.assertNotIn("UNAVAILABLE", line)


class EpochMathTest(unittest.TestCase):
    """Chain 888 node epochs: 512 blocks, epoch e = h(e*512+1)..h((e+1)*512),
    closing at h((e+1)*512+1). Verified live: epoch 35 started at h17921 and
    closes at h18433."""

    def setUp(self):
        self.dash = _load_dashboard()

    def test_first_height_of_epoch(self):
        info = self.dash._epoch_info(17921)
        self.assertEqual(info["epoch"], 35)
        self.assertEqual(info["first_height"], 17921)
        self.assertEqual(info["last_height"], 18432)
        self.assertEqual(info["close_height"], 18433)
        self.assertEqual(info["blocks_to_close"], 512)

    def test_last_height_of_epoch(self):
        info = self.dash._epoch_info(18432)
        self.assertEqual(info["epoch"], 35)
        self.assertEqual(info["blocks_to_close"], 1)
        self.assertEqual(info["eta_seconds"], 77)
        self.assertAlmostEqual(info["progress"], 1.0)

    def test_close_height_starts_next_epoch(self):
        info = self.dash._epoch_info(18433)
        self.assertEqual(info["epoch"], 36)
        self.assertEqual(info["first_height"], 18433)
        self.assertEqual(info["close_height"], 18945)

    def test_mid_epoch_and_eta(self):
        info = self.dash._epoch_info(18331)
        self.assertEqual(info["epoch"], 35)
        self.assertEqual(info["blocks_to_close"], 102)
        self.assertEqual(info["eta_seconds"], 102 * 77)

    def test_genesis_boundaries(self):
        self.assertEqual(self.dash._epoch_info(1)["epoch"], 0)
        self.assertEqual(self.dash._epoch_info(512)["epoch"], 0)
        self.assertEqual(self.dash._epoch_info(513)["epoch"], 1)

    def test_unknown_height_is_none(self):
        for h in (None, "?", "18331", 0, -5, True, 1.5):
            with self.subTest(h=h):
                self.assertIsNone(self.dash._epoch_info(h))

    def test_epoch_row(self):
        row = self.dash._epoch_row({"chain_height": 18331, "height": 1})
        self.assertIn("EPOCH  35", row)
        self.assertIn("102 blocks to close at h18433", row)
        self.assertIn("~2h 10m", row)
        # Falls back to `height` when chain_height is absent.
        self.assertIn("EPOCH  35", self.dash._epoch_row({"height": 17921}))
        self.assertIn("height unknown", self.dash._epoch_row({"height": "—"}))


class NodeReleaseParseTest(unittest.TestCase):
    IMG = "sha256:" + "ab12" * 16
    REV = "cd34" * 10

    def setUp(self):
        self.dash = _load_dashboard()

    def test_labels_and_repo_tag(self):
        out = (f"{self.IMG}\t{self.IMG}\trelease-x\t{self.REV}\n"
               '["wrfcoin/native-chain:tag-x-amd64"]\n')
        rel = self.dash._parse_node_version(out)
        self.assertEqual(rel, {
            "release": "release-x",
            "tag": "tag-x-amd64",
            "revision": "cd34cd34cd34",
            "image_id": "ab12ab12ab12",
        })
        row = self.dash._release_row({"node_release": rel, "node_version": "0.4.0"})
        self.assertEqual(
            row, "NODE   v0.4.0  ·  release-x  ·  rev cd34cd34cd34  ·  image ab12ab12ab12")

    def test_missing_labels(self):
        # docker's template prints "<no value>" for an absent label.
        out = (f"wrfcoin/native-chain:tag-y\t{self.IMG}\t<no value>\t<no value>\n"
               "[]\n")
        rel = self.dash._parse_node_version(out)
        self.assertIsNone(rel["release"])
        self.assertIsNone(rel["revision"])
        self.assertEqual(rel["tag"], "tag-y")
        self.assertEqual(rel["image_id"], "ab12ab12ab12")
        row = self.dash._release_row({"node_release": rel})
        self.assertEqual(row, "NODE   tag-y  ·  rev —  ·  image ab12ab12ab12")

    def test_untagged_image_without_labels(self):
        out = f"{self.IMG}\t{self.IMG}\t\t\n" + '["<none>:<none>"]\n'
        rel = self.dash._parse_node_version(out)
        self.assertIsNone(rel["tag"])
        self.assertIn("untagged", self.dash._release_row({"node_release": rel}))

    def test_truncated_output(self):
        rel = self.dash._parse_node_version(f"{self.IMG}\n")
        self.assertEqual(rel["image_id"], "ab12ab12ab12")
        self.assertIsNone(rel["release"])
        self.assertIsNone(rel["tag"])

    def test_empty_output_is_unknown(self):
        self.assertIsNone(self.dash._parse_node_version(""))
        self.assertIn("release unknown", self.dash._release_row({"node_release": None}))

    def test_bad_repo_tags_json(self):
        rel = self.dash._parse_node_version(f"{self.IMG}\t{self.IMG}\tr\t{self.REV}\nnot-json\n")
        self.assertEqual(rel["release"], "r")
        self.assertIsNone(rel["tag"])

    def test_digest_reference_is_not_a_tag(self):
        self.assertIsNone(self.dash._image_tag("repo/name@sha256:" + "0" * 64))
        self.assertIsNone(self.dash._image_tag("localhost:5000/name"))
        self.assertEqual(self.dash._image_tag("localhost:5000/name:t1"), "t1")

    def test_collector_never_dumps_the_container_env(self):
        script = self.dash._NODE_VERSION_SH
        self.assertNotIn("Env", script)
        self.assertNotIn("printenv", script)
        self.assertNotIn("{{json .}}", script.replace("{{{{", "{{").replace("}}}}", "}}"))

    def test_collect_is_cached(self):
        calls = []

        def fake(script, timeout=15, ct_id=None):
            calls.append(script)
            return f"{self.IMG}\t{self.IMG}\trel\t{self.REV}\n[]\n"

        self.dash._pct_script = fake
        self.dash._NODE_VERSION_CACHE.update({"expires_at": 0.0, "value": None, "ct_id": None})
        a = self.dash._collect_node_version(ct_id=101, now=1000.0)
        b = self.dash._collect_node_version(ct_id=101, now=1030.0)
        self.assertEqual(a, b)
        self.assertEqual(len(calls), 1)
        self.dash._collect_node_version(ct_id=101, now=1000.0 + self.dash.NODE_RELEASE_TTL + 1)
        self.assertEqual(len(calls), 2)
        self.assertIn("wrfcoin-testnet-node", calls[0])


class LocalConfigTest(unittest.TestCase):
    def setUp(self):
        self.dash = _load_dashboard()

    def test_missing_config_is_empty(self):
        self.assertEqual(self.dash._load_local_config("/nonexistent/x.json"), {})

    def test_contributors_parsed_and_validated(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            json.dump({"title": "t1", "contributors": [
                ["alpha", "0x" + "AB" * 20],
                ["bad", "0x123"],
                ["", "0x" + "11" * 20],
                "nope",
            ]}, fh)
        cfg = self.dash._load_local_config(fh.name)
        self.assertEqual(self.dash._contributors_from_config(cfg),
                         [("alpha", "0x" + "ab" * 20)])
        self.assertEqual(self.dash._title_host(cfg), "t1")
        pathlib.Path(fh.name).unlink()

    def test_no_contributor_addresses_in_source(self):
        import re
        src = DASHBOARD_PATH.read_text()
        self.assertIsNone(re.search(r"0x[0-9a-fA-F]{40}", src))

class BannerLayoutTest(unittest.TestCase):
    """EPOCH/NODE lines: inline on the 200-column console (no rows added, the
    console is full), on their own rows when narrow."""

    class _Scr:
        def __init__(self, h, w):
            self.h, self.w = h, w
            self.grid = [[" "] * w for _ in range(h)]

        def getmaxyx(self):
            return self.h, self.w

        def addstr(self, r, c, text, attr=0):
            for i, ch in enumerate(text):
                if c + i < self.w:
                    self.grid[r][c + i] = ch

        def __getattr__(self, name):
            return lambda *a, **k: None

    def _render(self, width):
        import curses
        dash = _load_dashboard()
        orig = (curses.color_pair, curses.doupdate)
        curses.color_pair = lambda n: 0
        curses.doupdate = lambda: None
        try:
            st = dash.NodeState()
            st.blockchain = {
                "online": True, "status": "ready", "chain_height": 18331,
                "height": 18331, "block_age_seconds": 30, "blocks_per_min": 0.8,
                "peers": 4, "sync_status": "synced", "peer_rx_age": 10,
                "node_version": "0.4.0",
                "node_release": {"release": "rel-x", "tag": None,
                                 "revision": "cd34cd34cd34", "image_id": "ab12ab12ab12"},
            }
            st.ct = {"id": 101, "running": True}
            scr = self._Scr(56, width)
            dash._draw(scr, st)
            return ["".join(row) for row in scr.grid]
        finally:
            curses.color_pair, curses.doupdate = orig

    def test_wide_console_is_inline(self):
        rows = self._render(200)
        self.assertIn("CHAIN PRODUCING", rows[4])
        self.assertIn("EPOCH  35", rows[4])
        self.assertIn("PEER", rows[5])
        self.assertIn("rev cd34cd34cd34", rows[5])
        self.assertTrue(rows[6].startswith("├"))

    def test_narrow_console_gets_own_rows(self):
        rows = self._render(120)
        self.assertNotIn("EPOCH", rows[4])
        self.assertIn("EPOCH  35", rows[6])
        self.assertIn("NODE   v0.4.0  ·  rel-x", rows[7])
