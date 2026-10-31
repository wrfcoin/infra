#!/usr/bin/env python3
"""Unit tests for testnet/services/chain-ops-exporter/chain_ops_exporter.py.

No node, backend or network: the HTTP boundary is a fake keyed by URL, shaped
like chain 888's real answers (2026-10-31: /blockchain, /node/bonds/<id>,
/chain/block/<h>, /node/settlement/<e>, /api/earnings/leaderboard).
"""
from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

PATH = Path(__file__).parents[2] / "testnet" / "services" / "chain-ops-exporter" / "chain_ops_exporter.py"
SPEC = importlib.util.spec_from_file_location("chain_ops_exporter", PATH)
assert SPEC is not None and SPEC.loader is not None
exp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exp)

N = exp.NODE_URL
B = exp.BACKEND_URL
WS, N5 = "6d" + "4e" * 31, "d5" + "83" * 31
OWNER_WS, OWNER_N5 = [0x42] * 20, [0x05] * 20


def bond(bid, owner, status="REGISTERED", jailed=False, epoch=20):
    return {"activation_height": "2", "deployment_id": bid, "epoch": str(epoch), "status": status, "jailed": jailed,
            "registration": {"binding": {"owner_account": owner}}}


def block(*txs):
    return {"ok": True, "data": {"transactions": [{"sender": "0x" + "00" * 20, "type": "Coinbase"}, *txs]}}


class Fake:
    def __init__(self, routes, default=(404, None)):
        self.routes, self.default, self.calls = routes, default, []

    def __call__(self, url, token=None):
        self.calls.append(url)
        return self.routes.get(url, self.default)


def base_routes(tip=10300, ws_owner=OWNER_WS):
    # Epoch 20 on 888 spans h10242..10753; scan all of it from block 10242.
    routes = {
        f"{N}/blockchain": (200, {"ok": True, "data": {"height": tip}}),
        f"{N}/node/bonds/{WS}": (200, bond(WS, ws_owner)),
        f"{N}/node/bonds/{N5}": (200, bond(N5, OWNER_N5)),
        f"{N}/node/settlement/19": (200, {"status": "PROVISIONAL", "provisional_base_units": {WS: "1", N5: "1"},
                                          "payouts_base_units": {}}),
    }
    for h in range(10242, tip + 1):
        routes[f"{N}/chain/block/{h}"] = (200, block())
    return routes


def values(text):
    out = {}
    for line in text.splitlines():
        key, _, val = line.rpartition(" ")
        out[key] = float(val)
    return out


class ParseTest(unittest.TestCase):
    def test_parses_aliases(self):
        self.assertEqual(exp.parse_house_bonds(f"ws={WS}, n5={N5.upper()}"), [("ws", WS), ("n5", N5)])

    def test_rejects_bad_ids(self):
        with self.assertRaises(ValueError):
            exp.parse_house_bonds("ws=abc")

    def test_account_hex(self):
        self.assertEqual(exp.account_hex(OWNER_N5), "0x" + "05" * 20)
        self.assertEqual(exp.account_hex("ABCD"), "0xabcd")


class NodePayTest(unittest.TestCase):
    def setUp(self):
        exp.MAX_BLOCK_READS = 1000
        self.bonds = [("ws", WS), ("n5", N5)]

    def collect(self, routes, e=None):
        e = e or exp.Exporter(self.bonds, get=Fake(routes))
        e.get = Fake(routes)
        return e, values("\n".join(e.collect_node_pay("t")))

    def test_batch_from_owner_counts_and_other_senders_do_not(self):
        routes = base_routes()
        routes[f"{N}/chain/block/10266"] = (200, block({"sender": "0x" + "05" * 20, "type": "NodeServiceBatch"}))
        # ws's owner sent a different tx type: not a receipt.
        routes[f"{N}/chain/block/10270"] = (200, block({"sender": "0x" + "42" * 20, "type": "ContributionCommit"}))
        _, v = self.collect(routes)
        self.assertEqual(v['wrfcoin_node_pay_receipt_batch_included{bond="n5",deployment_id="d583838383838383"}'], 1)
        self.assertEqual(v['wrfcoin_node_pay_receipt_batch_included{bond="ws",deployment_id="6d4e4e4e4e4e4e4e"}'], 0)
        self.assertEqual(v["wrfcoin_node_pay_epoch"], 20)
        self.assertEqual(v["wrfcoin_node_pay_epoch_close_height"], 10753)  # receipts.sh: 513 + 512*20
        self.assertEqual(v["wrfcoin_node_pay_blocks_to_epoch_close"], 453)
        self.assertEqual(v["wrfcoin_node_pay_scan_lag_blocks"], 0)

    def test_scan_is_incremental_and_resets_on_new_epoch(self):
        routes = base_routes(tip=10250)
        routes[f"{N}/chain/block/10245"] = (200, block({"sender": "0x" + "42" * 20, "type": "NodeServiceBatch"}))
        e, v = self.collect(routes)
        self.assertEqual(v['wrfcoin_node_pay_receipt_batch_included{bond="ws",deployment_id="6d4e4e4e4e4e4e4e"}'], 1)
        routes = base_routes(tip=10252)
        e, _ = self.collect(routes, e)
        self.assertEqual([u for u in e.get.calls if "/chain/block/" in u],
                         [f"{N}/chain/block/10251", f"{N}/chain/block/10252"])
        # New epoch 21: the ws batch from epoch 20 no longer counts.
        routes = {k: v for k, v in base_routes(tip=10760).items()}
        routes[f"{N}/node/bonds/{WS}"] = (200, bond(WS, OWNER_WS, epoch=21))
        routes[f"{N}/node/bonds/{N5}"] = (200, bond(N5, OWNER_N5, epoch=21))
        routes[f"{N}/node/settlement/20"] = (200, {"status": "PROVISIONAL", "provisional_base_units": {N5: "1"}})
        e, v = self.collect(routes, e)
        self.assertEqual(v['wrfcoin_node_pay_receipt_batch_included{bond="ws",deployment_id="6d4e4e4e4e4e4e4e"}'], 0)
        self.assertEqual(v["wrfcoin_node_pay_last_closed_epoch_eligible_house_bonds"], 1)
        self.assertEqual(v['wrfcoin_node_pay_last_closed_epoch_bond_eligible{bond="ws",deployment_id="6d4e4e4e4e4e4e4e"}'], 0)

    def test_read_budget_reports_scan_lag(self):
        exp.MAX_BLOCK_READS = 5
        _, v = self.collect(base_routes(tip=10300))
        self.assertEqual(v["wrfcoin_node_pay_scan_lag_blocks"], 10300 - 10246)

    def test_unissued_is_zero_eligible_and_unknown_is_not_reported(self):
        routes = base_routes()
        routes[f"{N}/node/settlement/19"] = (200, {"status": "UNISSUED"})
        _, v = self.collect(routes)
        self.assertEqual(v["wrfcoin_node_pay_last_closed_epoch_eligible_house_bonds"], 0)
        routes[f"{N}/node/settlement/19"] = (200, {"status": "UNKNOWN"})
        _, v = self.collect(routes)
        self.assertNotIn("wrfcoin_node_pay_last_closed_epoch_eligible_house_bonds", v)
        self.assertEqual(v['wrfcoin_node_pay_last_closed_epoch_status{status="UNKNOWN"}'], 1)

    def test_paid_uses_payouts(self):
        routes = base_routes()
        routes[f"{N}/node/settlement/19"] = (200, {"status": "PAID", "payouts_base_units": {WS: "1", N5: "1"}})
        _, v = self.collect(routes)
        self.assertEqual(v["wrfcoin_node_pay_last_closed_epoch_eligible_house_bonds"], 2)

    def test_node_error_raises_and_poll_drops_gauges(self):
        routes = base_routes()
        routes[f"{N}/node/bonds/{N5}"] = (401, None)
        with tempfile.NamedTemporaryFile("w", delete=False) as fh:
            fh.write("fixture-token\n")
        exp.TOKEN_FILE = fh.name
        try:
            e = exp.Exporter(self.bonds, get=Fake(routes), clock=lambda: 1000.0)
            e.poll_once()
            text = e.render()
        finally:
            os.unlink(fh.name)
        self.assertNotIn("wrfcoin_node_pay_epoch ", text)
        v = values(text)
        self.assertEqual(v['wrfcoin_chain_ops_exporter_errors_total{check="node_pay"}'], 1)
        self.assertEqual(v['wrfcoin_chain_ops_exporter_last_success_timestamp_seconds{check="node_pay"}'], 1000.0)

    def test_missing_token_file_counts_errors(self):
        exp.TOKEN_FILE = "/nonexistent/token"
        e = exp.Exporter(self.bonds, get=Fake({}))
        e.poll_once()
        v = values(e.render())
        self.assertEqual(v['wrfcoin_chain_ops_exporter_errors_total{check="index"}'], 1)


class IndexTest(unittest.TestCase):
    def test_available_reports_height_lag_and_checked(self):
        routes = {
            f"{N}/blockchain": (200, {"data": {"height": 10362}}),
            f"{B}/api/earnings/leaderboard?role=producer&period=all&limit=1":
                (200, {"status": "available", "asOf": {"height": "10359", "checkedAt": "2026-10-31T23:11:14.208Z"}}),
            f"{B}/api/forecasters?period=all&limit=1": (503, {"status": "unavailable", "error": {"code": "FORECASTERS_DISABLED"}}),
        }
        v = values("\n".join(exp.Exporter([], get=Fake(routes)).collect_index("t")))
        self.assertEqual(v['wrfcoin_chain_index_available{surface="earnings"}'], 1)
        self.assertEqual(v['wrfcoin_chain_index_lag_blocks{surface="earnings"}'], 3)
        self.assertAlmostEqual(v['wrfcoin_chain_index_checked_timestamp_seconds{surface="earnings"}'], 1793488274.208, places=2)
        self.assertEqual(v['wrfcoin_chain_index_enabled{surface="forecasters"}'], 0)
        self.assertEqual(v['wrfcoin_chain_index_available{surface="forecasters"}'], 0)

    def test_db_error_outage_is_enabled_but_unavailable(self):
        routes = {
            f"{N}/blockchain": (200, {"data": {"height": 10362}}),
            f"{B}/api/earnings/leaderboard?role=producer&period=all&limit=1": (503, {"error": {"code": "EARNINGS_UNAVAILABLE"}}),
            f"{B}/api/forecasters?period=all&limit=1": (0, None),
        }
        v = values("\n".join(exp.Exporter([], get=Fake(routes)).collect_index("t")))
        for surface in ("earnings", "forecasters"):
            self.assertEqual(v[f'wrfcoin_chain_index_enabled{{surface="{surface}"}}'], 1)
            self.assertEqual(v[f'wrfcoin_chain_index_available{{surface="{surface}"}}'], 0)
            self.assertNotIn(f'wrfcoin_chain_index_lag_blocks{{surface="{surface}"}}', v)


if __name__ == "__main__":
    unittest.main()
