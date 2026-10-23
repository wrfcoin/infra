'use strict';

const crypto = require('node:crypto');
const PEER_DOMAIN = 'wrfcoin_faucet_bond_grant_peer_v1';
const BASE58 = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
const SPKI = Buffer.from('302a300506032b6570032100', 'hex');
const PKCS8 = Buffer.from('302e020100300506032b657004220420', 'hex');
// libp2p identity multihash (code 0, length 36), protobuf PublicKey
// (Type=Ed25519=1, Data=32 bytes). Other key types/hashes fail closed.
const PEER_PREFIX = Buffer.from('002408011220', 'hex');
const PRIVATE_PREFIX = Buffer.from('08011240', 'hex');

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

function encodePeerId(publicKey) {
  if (publicKey.length !== 32) throw new Error('invalid ed25519 public key');
  const bytes = Buffer.concat([PEER_PREFIX, publicKey]);
  let n = BigInt('0x' + bytes.toString('hex'));
  let out = '';
  while (n > 0n) { out = BASE58[Number(n % 58n)] + out; n /= 58n; }
  for (const byte of bytes) { if (byte !== 0) break; out = '1' + out; }
  return out;
}

function peerMessage(message) {
  return Buffer.concat([Buffer.from(PEER_DOMAIN, 'utf8'), message]);
}
function keyFromSeed(seed) {
  if (!Buffer.isBuffer(seed) || seed.length !== 32) throw new Error('invalid ed25519 seed');
  return crypto.createPrivateKey({ key: Buffer.concat([PKCS8, seed]), format: 'der', type: 'pkcs8' });
}
function publicBytes(key) { return crypto.createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32); }
function peerIdFromSeed(seedHex) {
  if (!/^[0-9a-fA-F]{64}$/.test(seedHex)) throw new Error('invalid peer seed');
  return encodePeerId(publicBytes(keyFromSeed(Buffer.from(seedHex, 'hex'))));
}

// Core4 p2p/src/identity.rs persists Keypair::to_protobuf_encoding():
// protobuf PrivateKey Type=Ed25519=1, Data=64 bytes (seed || public key).
function keyFromIdentityFile(bytes) {
  if (!Buffer.isBuffer(bytes) || bytes.length !== 68 || !bytes.subarray(0, 4).equals(PRIVATE_PREFIX)) {
    throw new Error('peer identity file must be a libp2p ed25519 protobuf private key');
  }
  const key = keyFromSeed(bytes.subarray(4, 36));
  if (!publicBytes(key).equals(bytes.subarray(36))) throw new Error('invalid peer identity keypair');
  return key;
}
function signPeerMessage(peerIdentityBytes, peerId, message) {
  const key = keyFromIdentityFile(peerIdentityBytes);
  if (!publicBytes(key).equals(decodePeerPublicKey(peerId))) throw new Error('peer identity key does not match the node peer id');
  return crypto.sign(null, peerMessage(message), key).toString('hex');
}
function verifyPeerSignature(peerId, signature, message) {
  try {
    if (typeof signature !== 'string' || !/^[0-9a-f]{128}$/.test(signature)) return false;
    const key = crypto.createPublicKey({ key: Buffer.concat([SPKI, decodePeerPublicKey(peerId)]), format: 'der', type: 'spki' });
    return crypto.verify(null, peerMessage(message), key, Buffer.from(signature, 'hex'));
  } catch { return false; }
}
module.exports = { PEER_DOMAIN, decodePeerPublicKey, peerMessage, verifyPeerSignature, signPeerMessage,
  peerIdFromSeed, keyFromIdentityFile };
