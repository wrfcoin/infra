'use strict';

// A bonded node's signed attester application (ATTESTER_APPLICATIONS.md). Verified
// here before any node read, so garbage costs one signature check.
//
// Byte layout (the core4 CLI that signs it must produce exactly these bytes; the
// frozen vector in attester-application.test.js is the reference):
//
//   str(s) = u32LE(UTF-8 byte length) || UTF-8 bytes
//   M = UTF8("wrfcoin_attester_application_v1")
//       || str(kind) || str(chain_id) || str(network_id) || str(genesis_hash)
//       || str(bond_id) || str(server_key) || str(oracle_pubkey)
//       || u64LE(epoch) || u64LE(height) || u32LE(settings_version) || str(client_version)
//   signature        = Ed25519(bond server key K, M)                                    128 lowercase hex
//   oracle_signature = Ed25519(oracle key, UTF8("wrfcoin_attester_application_oracle_v1") || M)
//
// kind is "apply" or "step_down". Both signatures are strict Ed25519 (verify_strict).

const { RecordError, str, u32, u64, verifyStrict } = require('./address-record');

const APPLICATION_DOMAIN = 'wrfcoin_attester_application_v1';
const APPLICATION_ORACLE_DOMAIN = 'wrfcoin_attester_application_oracle_v1';
const KINDS = ['apply', 'step_down'];
const FIELDS = ['version', 'kind', 'chain_id', 'network_id', 'genesis_hash', 'bond_id', 'server_key', 'oracle_pubkey',
  'epoch', 'height', 'settings_version', 'client_version', 'signature', 'oracle_signature'];
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
const DECIMAL = /^(0|[1-9][0-9]{0,14})$/; // below 2^53: exact in Redis Lua numbers
const SETTINGS_VERSION = /^[1-9][0-9]{0,8}$/; // 1 .. 999999999, fits u32
const TEXT = /^[0-9A-Za-z_-]{1,32}$/;
const CLIENT_VERSION = /^[0-9A-Za-z._+-]{1,40}$/;

function applicationMessage(r) {
  return Buffer.concat([
    Buffer.from(APPLICATION_DOMAIN, 'utf8'),
    str(r.kind), str(r.chain_id), str(r.network_id), str(r.genesis_hash),
    str(r.bond_id), str(r.server_key), str(r.oracle_pubkey),
    u64(r.epoch), u64(r.height), u32(Number(r.settings_version)), str(r.client_version),
  ]);
}

function applicationOracleMessage(r) {
  return Buffer.concat([Buffer.from(APPLICATION_ORACLE_DOMAIN, 'utf8'), applicationMessage(r)]);
}

// Shape, then the pinned chain, then both signatures. Throws RecordError.
function parseApplication(body, { chainId, networkId, genesisHash }) {
  const bad = (message) => { throw new RecordError('INVALID_RECORD', message); };
  if (!body || typeof body !== 'object' || Array.isArray(body)) bad('Expected a JSON object');
  const keys = Object.keys(body);
  if (keys.length !== FIELDS.length || !FIELDS.every((f) => Object.prototype.hasOwnProperty.call(body, f))) {
    bad(`Expected exactly the fields ${FIELDS.join(', ')}`);
  }
  if (body.version !== 1) bad('version must be 1');
  if (!KINDS.includes(body.kind)) bad(`kind must be one of ${KINDS.join(', ')}`);
  for (const f of ['chain_id', 'network_id']) if (typeof body[f] !== 'string' || !TEXT.test(body[f])) bad(`${f} invalid`);
  for (const f of ['genesis_hash', 'bond_id', 'server_key', 'oracle_pubkey']) {
    if (typeof body[f] !== 'string' || !HEX64.test(body[f])) bad(`${f} must be 64 lowercase hex`);
  }
  for (const f of ['signature', 'oracle_signature']) if (typeof body[f] !== 'string' || !HEX128.test(body[f])) bad(`${f} must be 128 lowercase hex`);
  for (const f of ['epoch', 'height']) if (typeof body[f] !== 'string' || !DECIMAL.test(body[f])) bad(`${f} must be decimal text`);
  if (typeof body.settings_version !== 'string' || !SETTINGS_VERSION.test(body.settings_version)) {
    bad('settings_version must be decimal text, 1 to 999999999');
  }
  if (typeof body.client_version !== 'string' || !CLIENT_VERSION.test(body.client_version)) bad('client_version invalid');
  if (body.server_key === body.oracle_pubkey) {
    throw new RecordError('KEY_REUSE', 'The oracle key must not be the bond server key');
  }
  if (body.chain_id !== chainId || body.network_id !== networkId || body.genesis_hash !== genesisHash) {
    throw new RecordError('WRONG_CHAIN', 'The application is for another chain, network or genesis');
  }
  const ok = verifyStrict(applicationMessage(body), Buffer.from(body.server_key, 'hex'), Buffer.from(body.signature, 'hex'))
    && verifyStrict(applicationOracleMessage(body), Buffer.from(body.oracle_pubkey, 'hex'), Buffer.from(body.oracle_signature, 'hex'));
  if (!ok) throw new RecordError('BAD_SIGNATURE', 'The server-key or oracle-key signature does not verify');
  // One canonical field order, so the same application always stores as the same text.
  return Object.fromEntries(FIELDS.map((f) => [f, body[f]]));
}

module.exports = {
  APPLICATION_DOMAIN, APPLICATION_ORACLE_DOMAIN, FIELDS, KINDS, applicationMessage, applicationOracleMessage, parseApplication,
};
