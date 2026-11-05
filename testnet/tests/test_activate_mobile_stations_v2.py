#!/usr/bin/env python3
"""activate-mobile-stations.py: v2 registration format and fresh nonce reads,
against a stubbed node. Stdlib only. No docker, key or real node is touched."""
import importlib.util
import json
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import SimpleNamespace

import os
# ACTIVATE_SCRIPT lets a reviewer run these controls against another revision of the tool.
SCRIPT = Path(os.environ.get('ACTIVATE_SCRIPT') or
              Path(__file__).resolve().parents[1] / 'scripts' / 'activate-mobile-stations.py')
spec = importlib.util.spec_from_file_location('activate_mobile_stations', SCRIPT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

STATION = 'mob-' + '0' * 32
OTHER = 'mob-' + '1' * 32


class Node(BaseHTTPRequestHandler):
    routes = {}
    seen = []
    auth = {}

    def do_GET(self):
        Node.seen.append(self.path)
        Node.auth[self.path] = self.headers.get('Authorization')
        status, body = Node.routes.get(self.path, (404, {'ok': False, 'error': {'code': 'X', 'message': 'no route'}}))
        raw = body if isinstance(body, (bytes, bytearray)) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_):
        pass


def ledger(station, nonce, **extra):
    view = {'owner_nonce': nonce, 'frozen': None, 'owner_deactivated': False, 'pending_recovery': None}
    view.update(extra)
    return (200, {'station_id': station, 'owner_ledger': view})


def not_registered():
    return (404, {'ok': False, 'error': {'code': 'NOT_FOUND', 'message': f'station is not registered: {STATION}'}})


def status(features):
    return (200, {'active_features': features})


class V2Registration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Node)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.url = f'http://127.0.0.1:{cls.server.server_address[1]}'

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Node.routes, Node.seen = {}, []
        self.tmp = tempfile.TemporaryDirectory(prefix='msr-test-')
        self.dir = Path(self.tmp.name)
        self.args = SimpleNamespace(node_url=self.url, registration_format='auto')

    def tearDown(self):
        self.tmp.cleanup()

    def nonce(self, station=STATION):
        return mod.expected_nonce(self.args, self.dir, 'tok', station)

    def route(self, station):
        return '/transactions/station/registrations/' + station + '/owner-ledger'

    # --- format selection -------------------------------------------------
    def test_auto_picks_v1_before_and_v2_after_activation(self):
        Node.routes[mod.FEATURES_PATH] = status(['domain_separated_preimages'])
        self.assertEqual(mod.registration_format(self.args, self.dir, 'tok'), 'v1')
        Node.routes[mod.FEATURES_PATH] = status(['x', 'station_registration_nonce'])
        self.assertEqual(mod.registration_format(self.args, self.dir, 'tok'), 'v2')

    def test_explicit_format_does_not_read_the_node(self):
        for fmt in ('v1', 'v2'):
            self.args.registration_format = fmt
            self.assertEqual(mod.registration_format(self.args, self.dir, 'tok'), fmt)
        self.assertEqual(Node.seen, [])

    def test_feature_read_failures_stop_the_run(self):
        for reply in [(500, {}), (404, {}), (200, {'active_features': 'nope'}), (200, {'active_features': [1]}), (200, [])]:
            Node.routes[mod.FEATURES_PATH] = reply
            with self.assertRaises(mod.Stop):
                mod.registration_format(self.args, self.dir, 'tok')

    # --- the nonce read ---------------------------------------------------
    def test_registered_station_uses_its_ledger_nonce(self):
        Node.routes[self.route(STATION)] = ledger(STATION, 7)
        self.assertEqual(self.nonce(), 7)

    def test_an_unregistered_station_has_no_ledger_entry_so_nonce_zero(self):
        Node.routes[self.route(STATION)] = not_registered()
        self.assertEqual(self.nonce(), 0)

    def test_every_other_outcome_refuses_rather_than_guessing(self):
        bad = [
            (404, {'ok': False, 'error': {'code': 'X', 'message': 'no route'}}),  # old node: unknown route
            (404, b'<html>not found</html>'),
            (404, {'ok': False, 'error': {'code': 'NOT_FOUND', 'message': 'something else'}}),
            (500, {}), (401, {}), (403, {}),
            (200, {}), (200, {'station_id': STATION}),
            (200, {'station_id': STATION, 'owner_ledger': {}}),
            (200, {'station_id': STATION, 'owner_ledger': {'owner_nonce': -1}}),
            (200, {'station_id': STATION, 'owner_ledger': {'owner_nonce': True}}),
            (200, {'station_id': STATION, 'owner_ledger': {'owner_nonce': '3'}}),
            (200, {'station_id': STATION, 'owner_ledger': {'owner_nonce': 2 ** 64}}),
            ledger(OTHER, 3),  # another station's answer
        ]
        for reply in bad:
            Node.routes[self.route(STATION)] = reply
            with self.subTest(reply=str(reply)[:60]):
                with self.assertRaises((mod.Stop, ValueError)):
                    self.nonce()

    def test_a_dead_node_refuses(self):
        self.args.node_url = 'http://127.0.0.1:9'
        with self.assertRaises(mod.Stop):
            self.nonce()

    # --- row stamping and freshness ---------------------------------------
    def test_every_row_is_stamped_with_its_own_fresh_nonce(self):
        Node.routes[self.route(STATION)] = ledger(STATION, 3)
        Node.routes[self.route(OTHER)] = not_registered()
        rows = [{'station_id': STATION}, {'station_id': OTHER}]
        mod.add_nonces(self.args, self.dir, 'tok', rows)
        self.assertEqual([r['expected_nonce'] for r in rows], [3, 0])
        # Read again after the ledger moved: the new value wins (nothing is cached).
        Node.routes[self.route(STATION)] = ledger(STATION, 4)
        mod.add_nonces(self.args, self.dir, 'tok', rows)
        self.assertEqual(rows[0]['expected_nonce'], 4)

    def test_a_failed_read_leaves_no_partially_stamped_batch_signed(self):
        Node.routes[self.route(STATION)] = ledger(STATION, 3)
        Node.routes[self.route(OTHER)] = (500, {})
        rows = [{'station_id': STATION}, {'station_id': OTHER}]
        with self.assertRaises(mod.Stop):
            mod.add_nonces(self.args, self.dir, 'tok', rows)
        self.assertNotIn('expected_nonce', rows[1])


FAKE_CLI = """#!/usr/bin/env python3
import json, os, sys
a = sys.argv
assert a[a.index('--chain-id') + 1] == os.environ.get('WRFCOIN_CHAIN_ID', '888')
batch = json.load(open(a[a.index('--batch') + 1]))
out = a[a.index('--out') + 1]
import urllib.request
urllib.request.urlopen(os.environ['FAKE_NODE_URL'] + '/__cli__/' + batch[0]['station_id']).read()
open(os.environ['FAKE_CLI_RECORD'], 'a').write(json.dumps(batch) + '\\n')
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    json.dump({'version': 'station_registration_artifact_v1', 'chain_id': os.environ.get('WRFCOIN_CHAIN_ID', '888'),
               'network_id': 'testnet', 'transactions': [{} for _ in batch]}, f)
print(json.dumps({'data': {'self_verified': True}}))
"""


class BuildWiring(unittest.TestCase):
    """`build()` hands the CLI v2 rows (with fresh nonces) or untouched v1 rows."""

    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Node)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_build(self, fmt, rows):
        import os
        old = os.umask(0o077)  # activate() runs under this umask
        self.addCleanup(os.umask, old)
        tmp = tempfile.TemporaryDirectory(prefix='msr-test-')
        self.addCleanup(tmp.cleanup)
        directory = Path(tmp.name)
        cli = directory / 'fake-cli'
        cli.write_text(FAKE_CLI)
        cli.chmod(0o700)
        record = directory / 'record.json'
        os.environ['FAKE_CLI_RECORD'] = str(record)
        os.environ['FAKE_NODE_URL'] = f'http://127.0.0.1:{self.server.server_address[1]}'
        args = SimpleNamespace(
            node_url=f'http://127.0.0.1:{self.server.server_address[1]}', cli=str(cli),
            governance_key='/nonexistent', governance_pubkey='00' * 32, registration_format=fmt)
        stamp = mod.now()
        mod.build(args, directory, 'tok', rows, stamp, fmt)
        return [r for line in record.read_text().splitlines() for r in json.loads(line)]

    def setUp(self):
        Node.routes, Node.seen = {}, []

    def test_v2_signs_one_row_at_a_time_each_after_its_own_nonce_read(self):
        led = '/transactions/station/registrations/%s/owner-ledger'
        Node.routes[led % STATION] = ledger(STATION, 5)
        Node.routes[led % OTHER] = not_registered()
        Node.routes['/__cli__/' + STATION] = (200, {})
        Node.routes['/__cli__/' + OTHER] = (200, {})
        self.run_build('v2', [{'station_id': STATION}, {'station_id': OTHER}])
        self.assertEqual(Node.seen, [led % STATION, '/__cli__/' + STATION,
                                     led % OTHER, '/__cli__/' + OTHER])

    def test_v2_rows_carry_a_fresh_expected_nonce(self):
        Node.routes['/transactions/station/registrations/%s/owner-ledger' % STATION] = ledger(STATION, 5)
        Node.routes['/transactions/station/registrations/%s/owner-ledger' % OTHER] = not_registered()
        Node.routes['/__cli__/' + STATION] = (200, {})
        Node.routes['/__cli__/' + OTHER] = (200, {})
        sent = self.run_build('v2', [{'station_id': STATION}, {'station_id': OTHER}])
        self.assertEqual([r['expected_nonce'] for r in sent], [5, 0])

    def test_v1_rows_are_unchanged_and_the_node_is_not_read(self):
        Node.routes['/__cli__/' + STATION] = (200, {})
        sent = self.run_build('v1', [{'station_id': STATION, 'expected_nonce': 9}])
        self.assertNotIn('expected_nonce', sent[0])
        self.assertEqual(Node.seen, ['/__cli__/' + STATION])  # the CLI only; no ledger read

    def test_a_failed_nonce_read_means_the_cli_is_never_run(self):
        Node.routes['/transactions/station/registrations/%s/owner-ledger' % STATION] = (500, {})
        with self.assertRaises(mod.Stop):
            self.run_build('v2', [{'station_id': STATION}])


class ReadBack(unittest.TestCase):
    """`inclusion_state` counts a row only on evidence THIS registration applied."""

    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Node)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Node.routes, Node.seen = {}, []
        self.tmp = tempfile.TemporaryDirectory(prefix='msr-test-')
        self.addCleanup(self.tmp.cleanup)
        self.args = SimpleNamespace(postgres_container='pg', node_url=f'http://127.0.0.1:{self.server.server_address[1]}',
                                    fresh_stations=set())  # ignored by the tool; kept for the reviewer's harness

    def registered(self, station, nonce, active=True, **extra):
        Node.routes['/transactions/station/registrations/' + station] = (
            200, {'station_id': station, 'owner_address': '0xabc', 'provenance_class': 'real', 'is_active': active})
        Node.routes['/transactions/station/registrations/%s/owner-ledger' % station] = ledger(station, nonce, **extra)

    def count(self, rows):
        return mod.inclusion_state(self.args, Path(self.tmp.name), 'tok', rows)

    def states(self, rows):
        return mod.row_states(self.args, Path(self.tmp.name), 'tok', rows)

    def row(self, station, expected=None):
        row = {'station_id': station, 'owner_address': '0xabc'}
        if expected is not None:
            row['expected_nonce'] = expected
        return row

    def test_a_v2_row_is_never_called_applied_from_ledger_or_registry_state(self):
        # No core4 620902bf7 route identifies WHICH registration applied, so a
        # v2 row is UNVERIFIED however clean the ledger looks.
        self.registered(STATION, 5)
        self.assertEqual(self.count([self.row(STATION, 4)]), 0)
        self.assertEqual(self.states([self.row(STATION, 4)]), ['unverified'])

    def test_clean_ledger_owner_reactivate_consumed_the_nonce(self):
        # Reviewer regression (a): sign at nonce 4, 201, an owner Reactivate takes
        # nonce 4. Registration inert; ledger clean at 5; record active.
        self.registered(STATION, 5)
        self.assertEqual(self.count([self.row(STATION, 4)]), 0,
                         'owner action nonce advance must not prove registration applied')

    def test_competing_same_owner_registration_consumed_nonce_zero(self):
        # Reviewer regression (b): our read saw 404 -> nonce 0; a competing
        # same-owner registration consumed nonce 0 so ours is inert.
        self.registered(STATION, 1)
        self.assertEqual(self.count([self.row(STATION, 0)]), 0)
        self.assertEqual(self.states([self.row(STATION, 0)]), ['unverified'])

    def test_dirty_ledgers_and_other_shapes_are_unverified_too(self):
        for extra in ({'owner_deactivated': True}, {'frozen': {'reason': 'x'}},
                      {'pending_recovery': {'to_owner_address': '0xdef'}}, {}):
            for nonce in (4, 5, 6):
                self.registered(STATION, nonce, **extra)
                with self.subTest(extra=extra, nonce=nonce):
                    self.assertEqual(self.count([self.row(STATION, 4)]), 0)
        self.registered(STATION, 5, active=False)
        self.assertEqual(self.count([self.row(STATION, 4)]), 0)

    def test_poll_reports_unverified_and_exit_status_is_distinct(self):
        self.registered(STATION, 1)
        with self.assertRaises(mod.Unverified) as caught:
            mod.poll(self.args, Path(self.tmp.name), 'tok', [self.row(STATION, 0)])
        self.assertIn('NOT a pass', str(caught.exception))
        self.assertTrue(issubclass(mod.Unverified, mod.Stop))
        self.assertIn('return 3', SCRIPT.read_text())

    def test_a_v1_row_is_an_observation_of_station_state_not_application(self):
        self.registered(STATION, 0)
        self.assertEqual(self.states([self.row(STATION)]), ['observed'])
        self.assertEqual(self.count([self.row(STATION)]), 1)  # count of observed rows

    def test_competing_v1_record_does_not_prove_our_registration_applied(self):
        # Reviewer regression: our v1 tx is pending/dropped; a competing same-owner
        # v1 registration made the station active; the backend syncs it. The run may
        # report what it observed, never that THIS registration applied or PASS.
        import io
        from contextlib import redirect_stdout
        from unittest import mock
        self.registered(STATION, 0)
        self.args.postgres_container = 'synthetic-postgres'
        out = io.StringIO()
        original = mod.command
        with mock.patch.object(mod, 'command', lambda argv, *a, **k:
                               '1' if argv[0] == 'docker' else original(argv, *a, **k)), redirect_stdout(out):
            mod.poll(self.args, Path(self.tmp.name), 'tok', [self.row(STATION)])
        self.assertNotIn('ACTIVATION PASS', out.getvalue())
        self.assertNotIn('applied\n', out.getvalue())
        self.assertIn('NOT proof that this run', out.getvalue())

    def test_an_unregistered_station_is_pending(self):
        Node.routes['/transactions/station/registrations/' + STATION] = not_registered()
        self.assertEqual(self.count([self.row(STATION, 0)]), 0)


class ManagerHandoff(unittest.TestCase):
    """UNVERIFIED output is an identifiable list; a durable receipt survives;
    a manager-confirmed reconciliation advances staged work without any POST."""

    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Node)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Node.routes, Node.seen = {}, []
        self.tmp = tempfile.TemporaryDirectory(prefix='msr-handoff-')
        self.addCleanup(self.tmp.cleanup)
        os.chmod(self.tmp.name, 0o700)
        self.work = Path(self.tmp.name) / 'msr-activation-abc12345'
        self.work.mkdir(mode=0o700)
        self.args = SimpleNamespace(postgres_container='pg', node_url=f'http://127.0.0.1:{self.server.server_address[1]}',
                                    receipt_dir=str(Path(self.tmp.name) / 'receipts'),
                                    complete_marker=str(Path(self.tmp.name) / 'receipts' / 'batch-1.complete'),
                                    mark_reconciled=None, confirmed_rows=None)
        self.rows = [{'station_id': STATION, 'owner_address': '0xabcdef0123456789abcdef0123456789abcdef01',
                      'expected_nonce': 0, 'latitude': 44.9, 'longitude': -93.2}]
        Node.routes['/transactions/station/registrations/' + STATION] = (
            200, {'station_id': STATION, 'owner_address': self.rows[0]['owner_address'],
                  'provenance_class': 'real', 'is_active': True})

    def run_poll(self):
        import io
        from contextlib import redirect_stdout
        os.umask(0o077)
        write, path = mod.receipt_writer(self.args, self.work.name, 1790000000, 'v2', self.rows)
        out = io.StringIO()
        try:
            with redirect_stdout(out):
                mod.poll(self.args, self.work, 'tok', self.rows, write)
        except mod.Unverified:
            pass
        return out.getvalue(), path

    def test_unverified_emits_an_identifiable_privacy_safe_list_and_a_durable_receipt(self):
        text, path = self.run_poll()
        self.assertIn(f'HANDOFF: batch {self.work.name}; 1 rows', text)
        self.assertIn(f'{STATION} owner 0xabcdef... unverified', text)
        self.assertNotIn('0xabcdef0123456789', text)
        self.assertNotIn('44.9', text)
        body = json.loads(path.read_text())
        self.assertEqual((body['batch_id'], body['status']), (self.work.name, 'unverified'))
        self.assertEqual(body['rows'][0]['station_id'], STATION)
        self.assertNotIn('44.9', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def reconcile(self, **overrides):
        values = dict(self.args.__dict__, mark_reconciled=self.work.name, confirmed_rows=1)
        values.update(overrides)
        return mod.mark_reconciled(SimpleNamespace(**values))

    def test_reconcile_writes_the_staged_marker_only_after_matching_confirmation(self):
        _, path = self.run_poll()
        marker = Path(self.args.complete_marker)
        for wrong in (None, 0, 2):
            with self.assertRaises(mod.Stop):
                self.reconcile(confirmed_rows=wrong)
        self.assertFalse(marker.exists())
        self.reconcile()
        self.assertTrue(marker.exists())
        self.assertEqual(json.loads(path.read_text())['status'], 'reconciled')
        self.assertEqual(Node.seen.count('/transactions/station/registrations'), 0)  # no POST path
        with self.assertRaises(mod.Stop):  # cannot advance twice
            self.reconcile()

    def test_receipt_writer_adopts_a_new_stamp_and_keeps_it(self):
        os.umask(0o077)
        write, path = mod.receipt_writer(self.args, self.work.name, 1790000000, 'v2', self.rows)
        write('built')
        self.assertEqual(json.loads(path.read_text())['submitted_at'], 1790000000)
        write('submit-attempted', stamp=1790000100)
        write('submitted')  # later updates keep the restamped value
        self.assertEqual(json.loads(path.read_text())['submitted_at'], 1790000100)

    def test_reconcile_schema_checks_the_receipt(self):
        _, path = self.run_poll()
        original = path.read_text()
        for change in ({'complete_marker': str(Path(self.tmp.name) / 'receipts' / 'evil.complete')},
                       {'complete_marker': str(Path(self.tmp.name) / 'elsewhere' / 'batch-1.complete')},
                       {'rows': []}):
            body = json.loads(original); body.update(change); path.write_text(json.dumps(body))
            with self.subTest(change=str(change)[:40]):
                with self.assertRaises(mod.Stop):
                    self.reconcile(confirmed_rows=0 if change.get('rows') == [] else 1)
        self.assertFalse(Path(self.args.complete_marker).exists())

    def test_reconcile_refuses_an_unknown_or_unrecorded_batch(self):
        with self.assertRaises(mod.Stop):
            self.reconcile(mark_reconciled='msr-activation-nothere')
        with self.assertRaises(mod.Stop):
            self.reconcile(mark_reconciled='../etc/passwd')


class TokenlessPublicReads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(('127.0.0.1', 0), Node)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_public_routes_carry_no_authorization_and_gated_routes_do(self):
        Node.routes, Node.seen, Node.auth = {}, [], {}
        Node.routes['/readyz'] = (200, {'ready': True})
        Node.routes['/network/info'] = (200, {})
        Node.routes[mod.FEATURES_PATH] = status([])
        args = SimpleNamespace(node_url=f'http://127.0.0.1:{self.server.server_address[1]}')
        with tempfile.TemporaryDirectory(prefix='msr-test-') as tmp:
            os.chmod(tmp, 0o700)
            for path in ('/readyz', '/network/info', mod.FEATURES_PATH):
                mod.http(args, Path(tmp), 'SECRET-TOKEN', 'GET', path)
        self.assertIsNone(Node.auth['/readyz'])
        self.assertIsNone(Node.auth['/network/info'])
        self.assertEqual(Node.auth[mod.FEATURES_PATH], 'Bearer SECRET-TOKEN')


class ProducerFence(unittest.TestCase):
    """All three producers must report one live revision; anything else refuses."""

    GOOD = 'a' * 40
    INPUTS = ['alpha=prod-a', 'beta=ssh://beta.example::prod-b', 'gamma=prod-c']

    def run_fence(self, revisions, inputs=None, readings=None):
        tmp = tempfile.TemporaryDirectory(prefix='msr-fence-')
        self.addCleanup(tmp.cleanup)
        bindir = Path(tmp.name)
        fake = bindir / 'docker'
        fake.write_text('#!/usr/bin/env python3\nimport json,os,sys\n'
                        'c=sys.argv[-1]\nr=json.loads(os.environ["FAKE_REVISIONS"]).get(c)\n'
                        'if r is None: sys.exit(1)\nprint(r if "|" in r else "true|" + r)\n')
        fake.chmod(0o755)
        old = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ['PATH'] = str(bindir) + ':' + os.environ['PATH']
        os.environ['FAKE_REVISIONS'] = json.dumps(revisions)
        mod.producer_fence(mod.parse_producers(inputs or self.INPUTS, list(readings or ())),
                           mod.parse_readings(readings or ()))

    def test_all_three_on_one_build_passes(self):
        self.run_fence({'prod-a': self.GOOD, 'prod-b': self.GOOD, 'prod-c': self.GOOD})

    def test_no_revision_is_pinned_so_a_new_release_passes(self):
        new = 'b' * 40
        self.run_fence({'prod-a': new, 'prod-b': new, 'prod-c': new})
        self.assertNotIn('RELEASE_REVISION', SCRIPT.read_text())

    def test_a_split_set_refuses_even_when_each_revision_is_valid(self):
        with self.assertRaises(mod.Stop):
            self.run_fence({'prod-a': self.GOOD, 'prod-b': 'b' * 40, 'prod-c': self.GOOD})

    def test_a_stopped_container_refuses(self):
        with self.assertRaises(mod.Stop):
            self.run_fence({'prod-a': self.GOOD, 'prod-b': 'false|' + self.GOOD, 'prod-c': self.GOOD})

    def reading_clock(self, value):
        original = mod.now
        mod.now = lambda: value
        self.addCleanup(lambda: setattr(mod, 'now', original))

    def test_readings_from_other_hosts_count_when_fresh_and_equal(self):
        self.reading_clock(1000)
        self.run_fence({'prod-a': self.GOOD}, inputs=['a=prod-a'],
                       readings=[f'b={self.GOOD}@900', f'c={self.GOOD}@1010'])

    def test_a_bad_reading_refuses(self):
        self.reading_clock(1000)
        for reading in (f'c={self.GOOD}@600', f'c={self.GOOD}@1100', 'c=@990', f'c={"b" * 40}@990', 'c=short@990'):
            with self.subTest(reading=reading):
                with self.assertRaises(mod.Stop):
                    self.run_fence({'prod-a': self.GOOD}, inputs=['a=prod-a'],
                                   readings=[f'b={self.GOOD}@990', reading])

    def test_a_reading_cannot_share_a_name_or_exceed_three(self):
        with self.assertRaises(mod.Stop):
            mod.parse_readings([f'a={self.GOOD}@1'], names={'a': ('', 'x')})
        with self.assertRaises(mod.Stop):
            mod.parse_producers(self.INPUTS, [f'd={self.GOOD}@1'])

    def test_one_old_node_refuses(self):
        for old in ('0' * 40, '', self.GOOD[:9], self.GOOD.upper(), '<no value>'):
            with self.subTest(old=old):
                with self.assertRaises(mod.Stop):
                    self.run_fence({'prod-a': self.GOOD, 'prod-b': old, 'prod-c': self.GOOD})

    def test_a_read_error_refuses(self):
        with self.assertRaises(mod.Stop):  # prod-c unreadable
            self.run_fence({'prod-a': self.GOOD, 'prod-b': self.GOOD})

    def test_three_aliases_of_one_target_are_not_three_producers(self):
        for bad in (['a=same', 'b=same', 'c=same'],
                    ['a=ssh://h::same', 'b=ssh://h::same', 'c=other']):
            with self.subTest(bad=bad):
                with self.assertRaises(mod.Stop):
                    mod.parse_producers(bad)
        # Same container name on different hosts is distinct.
        mod.parse_producers(['a=ssh://h1::p', 'b=ssh://h2::p', 'c=ssh://h3::p'])

    def test_exactly_three_distinct_configured_producers_are_required(self):
        for bad in ([], self.INPUTS[:2], self.INPUTS + ['delta=prod-d'],
                    ['a=prod-a', 'a=prod-b', 'c=prod-c'], ['a=prod-a', 'b=', 'c=prod-c'],
                    ['a=prod-a', 'b=x y', 'c=prod-c']):
            with self.subTest(bad=bad):
                with self.assertRaises(mod.Stop):
                    mod.parse_producers(bad)

    def test_no_producer_address_is_baked_in(self):
        import re
        self.assertFalse(re.search(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b',
                                   SCRIPT.read_text().replace('127.0.0.1', '')))


class CliDigest(unittest.TestCase):
    def test_no_digest_is_built_in(self):
        text = SCRIPT.read_text()
        self.assertNotIn('CLI_SHA', text)
        self.assertIn("'--cli-sha is required'", text)


class LiveChain(unittest.TestCase):
    def test_the_default_is_chain_888_and_old_pins_are_gone(self):
        text = SCRIPT.read_text()
        self.assertIn("LIVE_CHAIN_ID = '888'", text)
        for stale in ("'777'", '620902bf', '604af030'):
            self.assertNotIn(stale, text)

    def test_grid_check(self):
        for value in (44.9, -93.2, 0, 90, -179.9, 0.1):
            self.assertTrue(mod.grid_coordinate(value, 180), value)
        for value in (44.95, 44.987, 181, '44.9', None, True):
            self.assertFalse(mod.grid_coordinate(value, 180), value)


class WorkstationWrapper(unittest.TestCase):
    """The workstation script reads two producers, dry-runs, then activates. All fakes."""

    WRAPPER = SCRIPT.with_name('activate-mobile-stations-888.sh')
    REV = 'c' * 40

    def run_wrapper(self, reader_two=None, tool_exit=0, **overrides):
        tmp = tempfile.TemporaryDirectory(prefix='msr-wrap-')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        log = root / 'calls'
        (root / 'host').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> ' + str(log) +
                                   f'\nexit {tool_exit}\n')
        (root / 'host').chmod(0o755)
        reader = root / 'reader'
        reader.write_text(f'#!/usr/bin/env bash\necho {self.REV}\n')
        reader.chmod(0o755)
        args = dict(key_host=str(root / 'host'), tool_dir='/opt/tool', direct='n=node', cli='/opt/cli', sha='d' * 64)
        args.update(overrides)
        argv = ['bash', str(self.WRAPPER), '--key-host', args['key_host'], '--tool-dir', args['tool_dir'],
                '--key-host-producer', args['direct'], '--reader', f'a={reader}',
                '--reader', reader_two or f'b={reader}', '--cli', args['cli'], '--cli-sha', args['sha']]
        result = subprocess.run(argv, text=True, capture_output=True, timeout=30)
        return result, log.read_text().splitlines() if log.exists() else []

    def test_dry_run_comes_first_then_the_real_run_with_fresh_readings(self):
        result, calls = self.run_wrapper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn('--dry-run', calls[0])
        self.assertNotIn('--dry-run', calls[1])
        for call in calls:
            self.assertIn('--producer n=node', call)
            self.assertIn(f'--producer-reading a={self.REV}@', call)
            self.assertIn(f'--producer-reading b={self.REV}@', call)
            self.assertIn('--cli-sha ' + 'd' * 64, call)

    def test_a_failed_dry_run_stops_before_the_real_run(self):
        result, calls = self.run_wrapper(tool_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn('--dry-run', calls[0])

    def test_a_failed_reader_reaches_nothing(self):
        result, calls = self.run_wrapper(reader_two='b=false')
        self.assertEqual(result.returncode, 1)
        self.assertIn('producer b', result.stdout)
        self.assertEqual(calls, [])

    def test_a_value_unsafe_for_a_remote_shell_is_refused(self):
        result, calls = self.run_wrapper(cli='/opt/cli; touch x')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, [])

    def test_no_host_is_named(self):
        import re
        text = self.WRAPPER.read_text()
        self.assertFalse(re.search(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', text))


if __name__ == '__main__':
    unittest.main()
