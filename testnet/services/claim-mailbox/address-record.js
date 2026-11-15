'use strict';

// A bonded node's signed address record (NODE_ADDRESSES.md). Verified here
// before any node read, so garbage costs one signature check.
//
// Byte layout (core4 tools/cli/WrfcoinCLI/src/commands/node_address.rs,
// `AddressRecord::message`, frozen there by a test vector this file's tests
// repeat):
//
//   str(s) = u32LE(UTF-8 byte length) || UTF-8 bytes
//   M = UTF8("wrfcoin_node_address_record_v1")
//       || str(chain_id) || str(network_id) || str(genesis_hash)
//       || str(deployment_id) || str(server_key) || str(peer_id)
//       || u64LE(epoch) || u64LE(height) || u32LE(n) || str(multiaddr_1) .. str(multiaddr_n)
//   signature      = Ed25519(bond server key, M)                                  128 lowercase hex
//   peer_signature = Ed25519(peer identity key, "wrfcoin_node_address_record_peer_v1" || M)
//
// The peer id decoding matches bond-admission/peer.js: an identity multihash
// of a protobuf ed25519 PublicKey, nothing else.

const crypto = require('node:crypto');
const net = require('node:net');

const RECORD_DOMAIN = 'wrfcoin_node_address_record_v1';
const RECORD_PEER_DOMAIN = 'wrfcoin_node_address_record_peer_v1';
const MAX_ADDRESSES = 4;
const MAX_MULTIADDR_BYTES = 200;
const FIELDS = ['version', 'chain_id', 'network_id', 'genesis_hash', 'deployment_id', 'server_key', 'peer_id',
  'epoch', 'height', 'multiaddrs', 'signature', 'peer_signature'];
const HEX64 = /^[0-9a-f]{64}$/;
const HEX128 = /^[0-9a-f]{128}$/;
const DECIMAL = /^(0|[1-9][0-9]{0,14})$/; // below 2^53: exact in Redis Lua numbers
const TEXT = /^[0-9A-Za-z_-]{1,32}$/;
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const SPKI = Buffer.from('302a300506032b6570032100', 'hex');
const PEER_PREFIX = Buffer.from('002408011220', 'hex');
const MULTIADDR = /^\/(ip4|ip6)\/([0-9a-f:.]+)\/tcp\/([1-9][0-9]{0,4})\/p2p\/([1-9A-HJ-NP-Za-km-z]{40,60})$/;
const IPV4 = /^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$/;

class RecordError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

// The bond-admission refusal list: addresses a node can't be dialled on from
// outside, CGNAT, documentation and benchmark ranges.
const NOT_PUBLIC_V4 = new net.BlockList();
for (const [address, prefix] of [
  ['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.0.2.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15],
  ['198.51.100.0', 24], ['203.0.113.0', 24], ['224.0.0.0', 4], ['240.0.0.0', 4],
]) NOT_PUBLIC_V4.addSubnet(address, prefix, 'ipv4');

function ipv6Groups(address) {
  if (address.includes('.')) return null; // dotted tails are IPv4 in disguise
  const [head, tail, extra] = address.split('::');
  if (extra !== undefined) return null;
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  const groups = tail === undefined ? left : [...left, ...Array(8 - left.length - right.length).fill('0'), ...right];
  if (groups.length !== 8 || !groups.every((g) => /^[0-9a-f]{1,4}$/.test(g))) return null;
  return groups.map((g) => parseInt(g, 16));
}

// Global unicast (2000::/3) only, minus Teredo (2001::/32), docs (2001:db8::/32), 6to4 (2002::/16).
function publicAddress(family, address) {
  if (family === 'ip4') return IPV4.test(address) && !NOT_PUBLIC_V4.check(address, 'ipv4');
  if (net.isIP(address) !== 6) return false;
  const g = ipv6Groups(address);
  if (!g) return false;
  if (g[0] < 0x2000 || g[0] > 0x3fff) return false;
  if (g[0] === 0x2001 && (g[1] === 0 || g[1] === 0xdb8)) return false;
  return g[0] !== 0x2002;
}

function decodePeerPublicKey(peerId) {
  if (typeof peerId !== 'string' || peerId.length < 40 || peerId.length > 60) throw new RecordError('INVALID_RECORD', 'unsupported peer id');
  let n = 0n;
  for (const c of peerId) {
    const digit = BASE58.indexOf(c);
    if (digit < 0) throw new RecordError('INVALID_RECORD', 'invalid peer id');
    n = n * 58n + BigInt(digit);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const leading = peerId.match(/^1*/)[0].length;
  const bytes = Buffer.concat([Buffer.alloc(leading), n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex')]);
  if (bytes.length !== 38 || !bytes.subarray(0, 6).equals(PEER_PREFIX)) {
    throw new RecordError('INVALID_RECORD', 'peer id must embed an ed25519 identity key');
  }
  return bytes.subarray(6);
}

function str(value) {
  const bytes = Buffer.from(value, 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length);
  return Buffer.concat([len, bytes]);
}

function u64(value) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(value));
  return b;
}

function u32(value) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(value);
  return b;
}

function recordMessage(r) {
  return Buffer.concat([
    Buffer.from(RECORD_DOMAIN, 'utf8'),
    str(r.chain_id), str(r.network_id), str(r.genesis_hash), str(r.deployment_id), str(r.server_key), str(r.peer_id),
    u64(r.epoch), u64(r.height), u32(r.multiaddrs.length), ...r.multiaddrs.map(str),
  ]);
}

function recordPeerMessage(r) {
  return Buffer.concat([Buffer.from(RECORD_PEER_DOMAIN, 'utf8'), recordMessage(r)]);
}

function ed25519Key(raw) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI, raw]), format: 'der', type: 'spki' });
}

// Shape, then the pinned chain, then both signatures. Throws RecordError.
function parseRecord(body, { chainId, networkId, genesisHash }) {
  const bad = (message) => { throw new RecordError('INVALID_RECORD', message); };
  if (!body || typeof body !== 'object' || Array.isArray(body)) bad('Expected a JSON object');
  const keys = Object.keys(body);
  if (keys.length !== FIELDS.length || !FIELDS.every((f) => Object.prototype.hasOwnProperty.call(body, f))) {
    bad(`Expected exactly the fields ${FIELDS.join(', ')}`);
  }
  if (body.version !== 1) bad('version must be 1');
  for (const f of ['chain_id', 'network_id']) if (typeof body[f] !== 'string' || !TEXT.test(body[f])) bad(`${f} invalid`);
  for (const f of ['genesis_hash', 'deployment_id', 'server_key']) if (typeof body[f] !== 'string' || !HEX64.test(body[f])) bad(`${f} must be 64 lowercase hex`);
  for (const f of ['signature', 'peer_signature']) if (typeof body[f] !== 'string' || !HEX128.test(body[f])) bad(`${f} must be 128 lowercase hex`);
  for (const f of ['epoch', 'height']) if (typeof body[f] !== 'string' || !DECIMAL.test(body[f])) bad(`${f} must be decimal text`);
  if (!Array.isArray(body.multiaddrs) || body.multiaddrs.length < 1 || body.multiaddrs.length > MAX_ADDRESSES) {
    bad(`multiaddrs must hold 1 to ${MAX_ADDRESSES} addresses`);
  }
  const seen = new Set();
  for (const addr of body.multiaddrs) {
    if (typeof addr !== 'string' || Buffer.byteLength(addr) > MAX_MULTIADDR_BYTES) bad('multiaddr invalid');
    const match = MULTIADDR.exec(addr);
    if (!match) bad('multiaddr must be /ip4|ip6/<address>/tcp/<port>/p2p/<peer id>');
    const [, family, address, port, peer] = match;
    if (Number(port) > 65535) bad('multiaddr port invalid');
    if (peer !== body.peer_id) bad('every multiaddr must end in the record peer id');
    if (!publicAddress(family, address)) throw new RecordError('ADDRESS_NOT_PUBLIC', 'Only public addresses (no private, CGNAT, loopback or tunnel range)');
    if (seen.has(addr)) bad('a multiaddr appears twice');
    seen.add(addr);
  }
  if (body.chain_id !== chainId || body.network_id !== networkId || body.genesis_hash !== genesisHash) {
    throw new RecordError('WRONG_CHAIN', 'The record is for another chain, network or genesis');
  }
  const peerKey = decodePeerPublicKey(body.peer_id);
  let ok = false;
  try {
    ok = crypto.verify(null, recordMessage(body), ed25519Key(Buffer.from(body.server_key, 'hex')), Buffer.from(body.signature, 'hex'))
      && crypto.verify(null, recordPeerMessage(body), ed25519Key(peerKey), Buffer.from(body.peer_signature, 'hex'));
  } catch (_error) {
    ok = false;
  }
  if (!ok) throw new RecordError('BAD_SIGNATURE', 'The server or peer signature does not verify');
  // One canonical field order, so the same record always stores as the same text.
  return Object.fromEntries(FIELDS.map((f) => [f, f === 'multiaddrs' ? [...body.multiaddrs] : body[f]]));
}

module.exports = {
  MAX_ADDRESSES, RECORD_DOMAIN, RECORD_PEER_DOMAIN, RecordError, decodePeerPublicKey, parseRecord, publicAddress,
  recordMessage, recordPeerMessage,
};
