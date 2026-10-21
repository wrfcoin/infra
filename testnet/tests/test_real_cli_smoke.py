#!/usr/bin/env python3
"""Opt-in smoke test: the REAL pinned `wrfcoin` CLI, not the fake.

Skipped unless WRFCOIN_REAL_CLI names the binary, so the default harness stays
hermetic:

    WRFCOIN_REAL_CLI=/path/to/wrfcoin bash testnet/tests/test_real_cli_smoke.sh

Runs `station build-registration` (v1, and v2 with --expected-nonce) and every
owner-action builder (report-stolen, unfreeze, deactivate, reactivate,
recover-cancel, transfer + accept) with THROWAWAY keys generated in a scratch
directory, and checks that each artifact parses and carries the expected
tx_kind / action / nonce and the id the CLI reported. Nothing touches a node,
the network, docker or a real key. Stdlib only: the ed25519 public key (needed
for the owner address and --to-pubkey) comes from a small RFC 8032 derivation
below, checked against the CLI's own self-verification (a wrong address or
pubkey is refused by the CLI).
"""
import hashlib
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

CLI = os.environ.get('WRFCOIN_REAL_CLI')
CHAIN = 'wrfcoin-testnet'
STATION = 'mob-' + '0' * 32
SUBMITTED_AT = '1900000000'

_P = 2 ** 255 - 19
_D = -121665 * pow(121666, -1, _P) % _P


def _add(a, b):
    (x1, y1, z1, t1), (x2, y2, z2, t2) = a, b
    aa, bb = (y1 - x1) * (y2 - x2) % _P, (y1 + x1) * (y2 + x2) % _P
    cc, dd = 2 * t1 * t2 * _D % _P, 2 * z1 * z2 % _P
    e, f, g, h = bb - aa, dd - cc, dd + cc, bb + aa
    return e * f % _P, g * h % _P, f * g % _P, e * h % _P


def _mul(s, point):
    acc = (0, 1, 1, 0)
    while s:
        if s & 1:
            acc = _add(acc, point)
        point = _add(point, point)
        s >>= 1
    return acc


def _base():
    gy = 4 * pow(5, -1, _P) % _P
    gx2 = (gy * gy - 1) * pow(_D * gy * gy + 1, -1, _P) % _P
    gx = pow(gx2, (_P + 3) // 8, _P)
    if (gx * gx - gx2) % _P:
        gx = gx * pow(2, (_P - 1) // 4, _P) % _P
    if gx & 1:
        gx = _P - gx
    return gx, gy, 1, gx * gy % _P


def ed25519_public(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], 'little')
    a &= (1 << 254) - 8
    a |= 1 << 254
    x, y, z, _ = _mul(a, _base())
    zi = pow(z, -1, _P)
    x, y = x * zi % _P, y * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, 'little')


def onchain_address(public):
    return '0x' + hashlib.sha3_256(public).digest()[:20].hex()


@unittest.skipUnless(CLI and Path(CLI).is_file(), 'set WRFCOIN_REAL_CLI to the pinned wrfcoin binary to run')
class RealCliSmoke(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='wrfcoin-cli-smoke-')
        cls.dir = Path(cls.tmp.name)
        cls.keys = {}
        for name in ('owner', 'gov', 'new'):
            # Deterministic throwaway seeds: derived from the name, never a real key.
            seed = hashlib.sha256(b'wrfcoin-real-cli-smoke:' + name.encode()).digest()
            path = cls.dir / f'{name}.key'
            path.write_text(seed.hex())
            path.chmod(0o600)
            cls.keys[name] = (path, ed25519_public(seed))
        cls.owner_address = onchain_address(cls.keys['owner'][1])
        cls.env = {k: v for k, v in os.environ.items() if k in ('PATH', 'HOME', 'LANG')}
        cls.env['WRFCOIN_ORACLE_GOVERNANCE_PUBKEYS'] = cls.keys['gov'][1].hex()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def cli(self, *args):
        run = subprocess.run([CLI, *args], cwd=self.dir, env=self.env, capture_output=True,
                             text=True, timeout=120)
        self.assertEqual(run.returncode, 0, f'{args[:2]} failed: {run.stdout}{run.stderr}')
        return json.loads(run.stdout)['data']

    def artifact(self, name):
        doc = json.loads((self.dir / name).read_text())
        self.assertEqual(doc['chain_id'], CHAIN)
        self.assertEqual(len(doc['transactions']), 1)
        tx = doc['transactions'][0]
        self.assertEqual(tx['tx_type'], 'StationRegistration')
        # The id serialises as {'bytes': [32 ints], 'hash_type': ...}.
        self.assertEqual(len(tx['id']['bytes']), 32)
        tx['id_hex'] = bytes(tx['id']['bytes']).hex()
        return tx, json.loads(tx['data'])

    def registration(self, name, *extra):
        data = self.cli(
            'station', 'build-registration', '--station-id', STATION,
            '--owner-address', self.owner_address, '--owner-key', str(self.keys['owner'][0]),
            '--governance-key', str(self.keys['gov'][0]), '--chain-id', CHAIN,
            '--latitude', '46.7', '--longitude', '-92.1', '--elevation-meters', '10',
            '--submitted-at', SUBMITTED_AT, *extra, '--out', name)
        self.assertTrue(data['self_verified'])
        return self.artifact(name)

    def test_registration_v1_has_no_nonce(self):
        _, payload = self.registration('reg_v1.json')
        self.assertEqual(payload['tx_kind'], 'station_registration_v1')
        self.assertNotIn('expected_nonce', payload)

    def test_registration_v2_binds_the_expected_nonce(self):
        _, payload = self.registration('reg_v2.json', '--expected-nonce', '3')
        self.assertEqual(payload['tx_kind'], 'station_registration_v2')
        self.assertEqual(payload['expected_nonce'], 3)
        self.assertEqual(payload['station_id'], STATION)

    def test_a_different_nonce_changes_the_signed_transaction(self):
        tx3, _ = self.registration('reg_v2_n3.json', '--expected-nonce', '3')
        tx4, _ = self.registration('reg_v2_n4.json', '--expected-nonce', '4')
        self.assertNotEqual(tx3['id_hex'], tx4['id_hex'])

    def test_owner_actions(self):
        cases = [('report-stolen', 'report_stolen'), ('unfreeze', 'unfreeze'),
                 ('deactivate', 'deactivate'), ('reactivate', 'reactivate')]
        for command, action in cases:
            with self.subTest(command):
                out = f'{command}.json'
                data = self.cli(
                    'station', command, '--station-id', STATION,
                    '--owner-key', str(self.keys['owner'][0]), '--nonce', '7',
                    '--expires-at-height', '999999', '--chain-id', CHAIN,
                    '--submitted-at', SUBMITTED_AT, '--out', out)
                tx, payload = self.artifact(out)
                self.assertEqual(payload['tx_kind'], 'station_owner_action_v1')
                self.assertEqual(payload['action'], action)
                self.assertEqual(payload['action_nonce'], 7)
                self.assertEqual(data['transaction_id'], tx['id_hex'])
                self.assertTrue(data['self_verified'])

    def test_recover_cancel(self):
        data = self.cli(
            'station', 'recover-cancel', '--station-id', STATION,
            '--owner-key', str(self.keys['owner'][0]), '--nonce', '7',
            '--expires-at-height', '999999', '--chain-id', CHAIN,
            '--submitted-at', SUBMITTED_AT, '--out', 'recover_cancel.json')
        tx, payload = self.artifact('recover_cancel.json')
        self.assertEqual(payload['tx_kind'], 'station_owner_recovery_cancel_v1')
        self.assertEqual(data['transaction_id'], tx['id_hex'])

    def test_transfer_then_accept(self):
        proposal = self.cli(
            'station', 'transfer', '--station-id', STATION,
            '--owner-key', str(self.keys['owner'][0]),
            '--to-pubkey', self.keys['new'][1].hex(), '--nonce', '7',
            '--expires-at-height', '999999', '--chain-id', CHAIN, '--out', 'proposal.json')
        self.assertEqual(proposal['kind'], 'station_owner_transfer_v1')
        doc = json.loads((self.dir / 'proposal.json').read_text())
        self.assertEqual(doc['payload']['from_owner_pubkey'], self.keys['owner'][1].hex())
        accepted = self.cli(
            'station', 'accept', '--proposal', 'proposal.json',
            '--new-owner-key', str(self.keys['new'][0]), '--submitted-at', SUBMITTED_AT,
            '--out', 'accepted.json')
        tx, payload = self.artifact('accepted.json')
        self.assertEqual(payload['tx_kind'], 'station_owner_transfer_v1')
        self.assertEqual(payload['to_owner_pubkey'], self.keys['new'][1].hex())
        self.assertEqual(accepted['transaction_id'], tx['id_hex'])
        self.assertTrue(re.fullmatch(r'[0-9a-f]{128}', payload['to_owner_signature']))

    def test_the_cli_digest_is_reported_for_the_record(self):
        digest = hashlib.sha256(Path(CLI).read_bytes()).hexdigest()
        print(f'\nREAL CLI sha256 {digest}')


if __name__ == '__main__':
    unittest.main()
