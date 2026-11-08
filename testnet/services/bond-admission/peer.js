'use strict';

// The node's peer-identity proof in a bond admission request.
//
// Byte layout (core4 tools/cli/WrfcoinCLI/src/commands/node_bond_admit.rs,
// `admission_peer_message`, frozen there by a test vector this file's tests
// repeat):
//
//   M = UTF8("wrfcoin_bond_admission_peer_v1")
//       || str(chain_id) || str(network_id)
//       || str(authorization_hash)   (64 lowercase hex, from `node bond admit`)
//       || str(multiaddr)            (the request's address, as given)
//   str(s) = u32LE(UTF-8 byte length) || UTF-8 bytes
//   peerSignature = Ed25519.sign(peer identity key, M), 128 lowercase hex
//
// The peer id decoding matches the faucet's bond grant
// (testnet/services/faucet/bond-grant-peer.js): an identity multihash of a
// protobuf ed25519 PublicKey, nothing else.

const crypto = require('node:crypto');

const ADMISSION_PEER_DOMAIN = 'wrfcoin_bond_admission_peer_v1';
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const SPKI = Buffer.from('302a300506032b6570032100', 'hex');
const PEER_PREFIX = Buffer.from('002408011220', 'hex');

function decodePeerPublicKey(peerId) {
  if (typeof peerId !== 'string' || peerId.length < 40 || peerId.length > 60) throw new Error('unsupported peer id');
  let n = 0n;
  for (const c of peerId) {
    const digit = BASE58.indexOf(c);
    if (digit < 0) throw new Error('invalid peer id');
    n = n * 58n + BigInt(digit);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const leading = peerId.match(/^1*/)[0].length;
  const bytes = Buffer.concat([Buffer.alloc(leading), n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex')]);
  if (bytes.length !== 38 || !bytes.subarray(0, 6).equals(PEER_PREFIX)) throw new Error('peer id must embed an ed25519 identity key');
  return bytes.subarray(6);
}

function str(value) {
  const bytes = Buffer.from(value, 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length);
  return Buffer.concat([len, bytes]);
}

function admissionPeerMessage({ chainId, networkId, authorizationHash, multiaddr }) {
  return Buffer.concat([
    Buffer.from(ADMISSION_PEER_DOMAIN, 'utf8'),
    str(chainId), str(networkId), str(authorizationHash), str(multiaddr),
  ]);
}

function verifyAdmissionPeerSignature(peerId, signature, fields) {
  try {
    if (typeof signature !== 'string' || !/^[0-9a-f]{128}$/.test(signature)) return false;
    const key = crypto.createPublicKey({ key: Buffer.concat([SPKI, decodePeerPublicKey(peerId)]), format: 'der', type: 'spki' });
    return crypto.verify(null, admissionPeerMessage(fields), key, Buffer.from(signature, 'hex'));
  } catch (_error) {
    return false;
  }
}

module.exports = { ADMISSION_PEER_DOMAIN, admissionPeerMessage, decodePeerPublicKey, verifyAdmissionPeerSignature };
