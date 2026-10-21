#!/usr/bin/env python3
"""Opt-in end-to-end: activate-mobile-stations.py's build + submit path driven
with the REAL pinned `wrfcoin` CLI against a stub node.

Skipped unless WRFCOIN_REAL_CLI names the binary (default harness stays
hermetic):

    WRFCOIN_REAL_CLI=/path/to/wrfcoin bash testnet/tests/test_real_cli_activation.sh

What runs for real: the script's `build()` (per-row fresh `expected_nonce` read
from the stub's owner-ledger route, then the real CLI's `station
build-registration --batch`) and its `submit_batch()` POST of the artifact. What is
stubbed: the node (HTTP only) and, as in the rest of the harness, docker/psql
(`activate()` itself needs the backend containers, so it is not driven whole).
Throwaway keys in a scratch directory; no real key, node or network.

The stub node mirrors what core4 620902bf7 does, with file:line cites (unchanged since 3553f2803):
- Admission (native-chain/src/bin/launch_api/routes/station.rs:279-295, via
  registration_nonce_refusal, :786) refuses a v2 registration whose signed
  expected_nonce differs from the station's ledger nonce SYNCHRONOUSLY: HTTP 422,
  envelope {"ok": false, "error": {"code": "STATION_REGISTRATION_NONCE_MISMATCH"}}
  (code from shared-protocol/src/blockchain/station_owner.rs:1647).
- If the ledger moves between admission and the block, the registration is
  accepted with 201 and then applied as an inert no-op
  (shared-protocol/src/blockchain/state.rs:5416-5435). `drop_on_apply` models
  that 2xx-then-drop, which only a read-back can detect.
"""
import hashlib
import importlib.util
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

from test_real_cli_smoke import ed25519_public, onchain_address

CLI = os.environ.get('WRFCOIN_REAL_CLI')
SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'activate-mobile-stations.py'
SPEC = importlib.util.spec_from_file_location('activate_mobile_stations', SCRIPT)
mod = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mod)

FRESH = 'mob-' + 'a' * 32       # never registered: no ledger entry, nonce 0
RETURNING = 'mob-' + 'b' * 32   # registered before; the stub reports owner_nonce 4
RACED = 'mob-' + 'c' * 32       # ledger moves between the nonce read and the submit
LEDGER = '/transactions/station/registrations/%s/owner-ledger'


class StubNode(BaseHTTPRequestHandler):
    ledger = {}        # station -> owner_nonce (absent = not registered)
    registered = {}    # station -> owner_address (GET registration answers 200)
    drop_on_apply = set()  # stations whose accepted registration is dropped at apply
    bump_on_read = {}  # station -> nonce to install right AFTER the next ledger read
    received = []      # decoded POST bodies
    refusals = []

    def _send(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        prefix = '/transactions/station/registrations/'
        if self.path.startswith(prefix) and '/' not in self.path[len(prefix):]:
            station = self.path[len(prefix):]
            if station not in StubNode.registered:
                return self._send(404, {'ok': False, 'error': {
                    'code': 'NOT_FOUND', 'message': f'station is not registered: {station}'}})
            return self._send(200, {'station_id': station, 'owner_address': StubNode.registered[station],
                                    'provenance_class': 'real', 'is_active': True})
        for station in list(StubNode.ledger) + list(StubNode.bump_on_read) + [FRESH]:
            if self.path == LEDGER % station:
                if station not in StubNode.ledger:
                    return self._send(404, {'ok': False, 'error': {
                        'code': 'NOT_FOUND', 'message': f'station is not registered: {station}'}})
                nonce = StubNode.ledger[station]
                if station in StubNode.bump_on_read:
                    StubNode.ledger[station] = StubNode.bump_on_read.pop(station)
                return self._send(200, {'station_id': station, 'owner_ledger': {
                    'owner_nonce': nonce, 'frozen': None, 'owner_deactivated': False,
                    'pending_recovery': None}})
        self._send(404, {'ok': False, 'error': {'code': 'X', 'message': 'no route'}})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        StubNode.received.append(body)
        staged, owners = {}, {}
        for tx in body['transactions']:
            payload = json.loads(tx['data'])
            station, nonce = payload['station_id'], payload.get('expected_nonce')
            if payload['tx_kind'] != 'station_registration_v2':
                return self._refuse(station, 'STATION_REGISTRATION_V1_REFUSED')
            if nonce != staged.get(station, StubNode.ledger.get(station, 0)):
                return self._refuse(station, 'STATION_REGISTRATION_NONCE_MISMATCH')
            staged[station] = nonce + 1
            owners[station] = payload['owner_address']
        for station in list(staged):
            if station in StubNode.drop_on_apply:  # accepted (201), then an inert no-op
                del staged[station]
        StubNode.ledger.update(staged)
        StubNode.registered.update({s: owners[s] for s in staged})
        self._send(201, {'accepted': len(body['transactions'])})

    def _refuse(self, station, code):
        StubNode.refusals.append((station, code))
        self._send(422, {'ok': False, 'error': {'code': code, 'message': f'{station}: refused'}})

    def log_message(self, *_):
        pass


@unittest.skipUnless(CLI and Path(CLI).is_file(), 'set WRFCOIN_REAL_CLI to the pinned wrfcoin binary to run')
class RealCliActivation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), StubNode)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f'http://127.0.0.1:{cls.server.server_address[1]}'
        cls.tmp = tempfile.TemporaryDirectory(prefix='wrfcoin-activation-e2e-')
        cls.dir = Path(cls.tmp.name)
        cls.keys = {}
        for name in ('gov', FRESH, RETURNING, RACED):
            seed = hashlib.sha256(b'wrfcoin-real-cli-activation:' + name.encode()).digest()
            path = cls.dir / (name + '.key')
            path.write_text(seed.hex())
            path.chmod(0o600)
            cls.keys[name] = (path, ed25519_public(seed))
        cls.base_env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'LANG')}
        cls.gov_pub = cls.keys['gov'][1].hex()
        cls.rows = {s: cls.owner_row(s) for s in (FRESH, RETURNING, RACED)}

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.tmp.cleanup()

    @classmethod
    def owner_row(cls, station):
        """A batch row. The owner's ownership signature is produced by the real
        CLI (single-registration mode) so it is bound to chain 777/testnet."""
        path, public = cls.keys[station]
        address = onchain_address(public)
        out = cls.dir / (station + '-own.json')
        env = dict(cls.base_env, WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS=cls.gov_pub)
        run = subprocess.run(
            [CLI, 'station', 'build-registration', '--station-id', station, '--owner-address', address,
             '--owner-key', str(path), '--governance-key', str(cls.keys['gov'][0]), '--chain-id', '777',
             '--network-id', 'testnet', '--latitude', '46.7', '--longitude', '-92.1',
             '--elevation-meters', '10', '--hardware-model', 'phone-barometer',
             '--data-quality-tier', 'unverified', '--submitted-at', '1900000000', '--out', str(out)],
            env=env, capture_output=True, text=True, timeout=120)
        assert run.returncode == 0, run.stdout + run.stderr
        payload = json.loads(json.loads(out.read_text())['transactions'][0]['data'])
        return {'station_id': station, 'owner_address': address, 'owner_pubkey': payload['owner_pubkey'],
                'owner_signature': payload['owner_signature'], 'latitude': 46.7, 'longitude': -92.1,
                'hardware_model': 'phone-barometer', 'provenance_class': 'real',
                'data_quality_tier': 'unverified', 'submitted_at': 1900000000}

    def setUp(self):
        StubNode.ledger = {RETURNING: 4, RACED: 2}
        StubNode.bump_on_read, StubNode.received, StubNode.refusals = {}, [], []
        StubNode.drop_on_apply = set()
        StubNode.registered = {s: self.rows[s]['owner_address'] for s in (RETURNING, RACED)}
        self.work = tempfile.TemporaryDirectory(prefix='activation-run-', dir=self.dir)
        self.addCleanup(self.work.cleanup)
        os.chmod(self.work.name, 0o700)
        self.directory = Path(self.work.name)
        old = os.umask(0o077)  # activate() runs under this umask
        self.addCleanup(os.umask, old)
        self.args = SimpleNamespace(
            node_url=self.url, cli=CLI, governance_key=str(self.keys['gov'][0]),
            governance_pubkey=self.gov_pub, registration_format='v2')

    def run_script(self, stations):
        """The script's own build (fresh nonces + real CLI) then its own submit_batch."""
        rows = [dict(self.rows[s]) for s in stations]
        stamp = mod.now()
        submit = mod.build(self.args, self.directory, 'tok', rows, stamp, 'v2')
        return rows, mod.submit_batch(self.args, self.directory, 'tok', submit, stamp, rows)

    def payloads(self, body):
        return [json.loads(tx['data']) for tx in body['transactions']]

    def test_first_registration_is_nonce_zero_and_the_stub_receives_the_cli_output(self):
        rows, response = self.run_script([FRESH])
        self.assertEqual(rows[0]['expected_nonce'], 0)
        self.assertEqual(response['accepted'], 1)
        (payload,) = self.payloads(StubNode.received[0])
        self.assertEqual(payload['tx_kind'], 'station_registration_v2')
        self.assertEqual(payload['expected_nonce'], 0)
        self.assertEqual(payload['station_id'], FRESH)
        self.assertEqual(payload['owner_pubkey'], self.rows[FRESH]['owner_pubkey'])
        # The bytes the stub received are the CLI's artifact, unmodified.
        artifact = json.loads((self.directory / 'artifact.json').read_text())
        self.assertEqual(StubNode.received[0]['transactions'], artifact['transactions'])
        self.assertEqual(StubNode.ledger[FRESH], 1, 'the stub advanced the nonce on apply')

    def test_re_registration_carries_the_nonce_the_ledger_reports(self):
        rows, _ = self.run_script([RETURNING])
        self.assertEqual(rows[0]['expected_nonce'], 4)
        (payload,) = self.payloads(StubNode.received[0])
        self.assertEqual((payload['tx_kind'], payload['expected_nonce']), ('station_registration_v2', 4))
        self.assertEqual(StubNode.ledger[RETURNING], 5)

    def test_a_mixed_batch_stamps_each_row_with_its_own_nonce(self):
        rows, response = self.run_script([FRESH, RETURNING])
        self.assertEqual([r['expected_nonce'] for r in rows], [0, 4])
        self.assertEqual(response['accepted'], 2)
        self.assertEqual([(p['station_id'], p['expected_nonce'])
                          for p in self.payloads(StubNode.received[0])], [(FRESH, 0), (RETURNING, 4)])

    def test_a_ledger_that_moved_before_the_build_is_read_fresh(self):
        StubNode.ledger[RETURNING] = 9
        rows, _ = self.run_script([RETURNING])
        self.assertEqual(rows[0]['expected_nonce'], 9)

    def test_a_stale_nonce_is_refused_by_the_stub_and_surfaced_by_the_script(self):
        # An owner action lands between the script's nonce read and the submit.
        StubNode.bump_on_read[RACED] = 3
        with self.assertRaises(mod.Stop) as caught:
            self.run_script([RACED])
        self.assertIn('submission refused', str(caught.exception))
        self.assertNotIn(RACED, [p['station_id'] for b in StubNode.received[1:] for p in self.payloads(b)])
        self.assertEqual(StubNode.refusals, [(RACED, 'STATION_REGISTRATION_NONCE_MISMATCH')])
        (payload,) = self.payloads(StubNode.received[0])
        self.assertEqual(payload['expected_nonce'], 2, 'the CLI signed the nonce that was read')
        self.assertEqual(StubNode.ledger[RACED], 3, 'a refused submission changed nothing')

    def test_one_stale_row_refuses_the_whole_batch(self):
        StubNode.bump_on_read[RACED] = 3
        with self.assertRaises(mod.Stop):
            self.run_script([FRESH, RACED])
        self.assertNotIn(FRESH, StubNode.ledger, 'the good row was not applied either')

    # --- read-back after a 201 --------------------------------------------
    def inclusion(self, stations, rows):
        return mod.inclusion_state(self.args, self.directory, 'tok', rows)

    def test_an_applied_re_registration_is_still_only_unverified(self):
        # The stub applied it, but no core4 route proves which registration applied.
        rows, _ = self.run_script([RETURNING])
        self.assertEqual(self.inclusion([RETURNING], rows), 0)

    def test_a_201_then_drop_re_registration_is_not_counted(self):
        StubNode.drop_on_apply.add(RETURNING)
        rows, response = self.run_script([RETURNING])
        self.assertEqual(response['accepted'], 1, 'the node said 201')
        self.assertEqual(StubNode.ledger[RETURNING], 4, 'but nothing applied')
        self.assertEqual(self.inclusion([RETURNING], rows), 0)

    def test_a_201_then_drop_first_registration_stays_pending(self):
        StubNode.drop_on_apply.add(FRESH)
        rows, _ = self.run_script([FRESH])
        self.assertEqual(mod.row_states(self.args, self.directory, 'tok', rows), ['pending'])

    def test_a_mixed_batch_never_claims_applied_for_v2_rows(self):
        rows, _ = self.run_script([FRESH, RETURNING])
        self.assertEqual(mod.row_states(self.args, self.directory, 'tok', rows),
                         ['unverified', 'unverified'])


if __name__ == '__main__':
    unittest.main()
