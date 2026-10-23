#!/usr/bin/env node
'use strict';

// Builds a signed faucet bond-grant request for a node operator (BOND_GRANT.md).
// No dependencies: Node 18+ only. Prints the request JSON; never prints the key.
//
//   node bond-grant-request.js --owner 0x<bond owner address> \
//     --server-key-file <file holding the 32-byte server key seed as hex> \
//     --peer-key-file <node-data-dir>/peer_identity.key \
//     --chain-id 888 --network-id testnet \
//     [--node http://127.0.0.1:8556] [--behind 2] [--expect-server-key <64 hex>]
//
// It reads the node's own peer id and a block `--behind` blocks under its tip
// from --node, signs, and prints JSON to POST to /faucet/bond-grant (add a
// captchaToken on the public page). The seed and peer identity files are read once and never echoed.

const crypto = require('node:crypto');
const fs = require('node:fs');
const peer = require('./bond-grant-peer');

const BOND_GRANT_DOMAIN = 'wrfcoin_faucet_bond_grant_v1';
const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');

function str(s) {
  const bytes = Buffer.from(String(s), 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32LE(bytes.length);
  return Buffer.concat([len, bytes]);
}

function u64(v) {
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(BigInt(v));
  return b;
}

function normalizeOwner(address) {
  const v = String(address).trim().toLowerCase();
  if (/^wrf[0-9a-f]{40}$/.test(v)) return `0x${v.slice(3)}`;
  if (/^0x[0-9a-f]{40}$/.test(v)) return v;
  throw new Error('--owner must be a 0x- or wrf-prefixed 40-character hex address');
}

// Must stay byte-identical to server.js buildBondGrantMessage (parity test).
function buildBondGrantMessage({ chainId, networkId, ownerAddress, serverKey, peerId, height, blockHash }) {
  return Buffer.concat([
    Buffer.from(BOND_GRANT_DOMAIN, 'utf8'),
    str(chainId),
    str(networkId),
    str(ownerAddress),
    str(serverKey),
    str(peerId),
    u64(height),
    str(blockHash),
  ]);
}

function signBondGrant({ seedHex, peerIdentityBytes, chainId, networkId, ownerAddress, peerId, height, blockHash }) {
  const seedText = String(seedHex).trim().replace(/^0x/i, '');
  if (!/^[0-9a-fA-F]{64}$/.test(seedText)) throw new Error('the server key file must hold a 32-byte ed25519 seed in hex');
  const seed = Buffer.from(seedText, 'hex');
  if (seed.length !== 32) throw new Error('the server key file must hold a 32-byte ed25519 seed in hex');
  const key = crypto.createPrivateKey({ key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]), format: 'der', type: 'pkcs8' });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  const serverKey = spki.subarray(spki.length - 32).toString('hex');
  const owner = normalizeOwner(ownerAddress);
  const hash = String(blockHash).trim().replace(/^0x/i, '').toLowerCase();
  const message = buildBondGrantMessage({ chainId, networkId, ownerAddress: owner, serverKey, peerId, height, blockHash: hash });
  return {
    ownerAddress: owner,
    serverKey,
    peerId,
    height,
    blockHash: hash,
    signature: crypto.sign(null, message, key).toString('hex'),
    peerSignature: peer.signPeerMessage(peerIdentityBytes, peerId, message),
  };
}

function parseArgs(argv) {
  const out = { node: 'http://127.0.0.1:8556', behind: 2 };
  const names = {
    '--peer-key-file': 'peerKeyFile', '--owner': 'owner', '--server-key-file': 'keyFile', '--chain-id': 'chainId', '--network-id': 'networkId',
    '--node': 'node', '--behind': 'behind', '--expect-server-key': 'expect',
  };
  for (let i = 0; i < argv.length; i += 2) {
    const name = names[argv[i]];
    if (!name || argv[i + 1] === undefined) throw new Error(`unknown or incomplete argument ${argv[i]}`);
    out[name] = argv[i + 1];
  }
  for (const required of ['owner', 'keyFile', 'peerKeyFile', 'chainId', 'networkId']) {
    if (!out[required]) throw new Error(`--${required === 'keyFile' ? 'server-key-file' : required.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)} is required`);
  }
  out.behind = Number.parseInt(out.behind, 10);
  if (!Number.isSafeInteger(out.behind) || out.behind < 0) throw new Error('--behind must be a non-negative integer');
  return out;
}

async function getJson(url) {
  const response = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
  if (!response.ok) throw new Error(`node answered ${response.status} for ${new URL(url).pathname}`);
  const body = await response.json();
  return body?.data ?? body;
}

function readPeerKeyFile(path) {
  const fd = fs.openSync(path, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size !== 68 || (process.platform !== 'win32' && (stat.mode & 0o077) !== 0)) {
      throw new Error('peer identity file must be a 68-byte regular file with owner-only permissions');
    }
    const bytes = fs.readFileSync(fd);
    peer.keyFromIdentityFile(bytes);
    return bytes;
  } finally { fs.closeSync(fd); }
}

async function main(argv) {
  const args = parseArgs(argv);
  const info = await getJson(`${args.node}/network/info`);
  const tip = Number(info?.chain_height);
  const peerId = info?.local_peer_id;
  if (!Number.isSafeInteger(tip) || tip <= args.behind) throw new Error('the node did not report a usable chain_height');
  if (typeof peerId !== 'string' || !peerId) throw new Error('the node did not report its local_peer_id (P2P off?)');
  const height = tip - args.behind;
  const block = await getJson(`${args.node}/chain/block/${height}`);
  const request = signBondGrant({
    seedHex: fs.readFileSync(args.keyFile, 'utf8'),
    peerIdentityBytes: readPeerKeyFile(args.peerKeyFile),
    chainId: args.chainId,
    networkId: args.networkId,
    ownerAddress: args.owner,
    peerId,
    height,
    blockHash: block?.hash,
  });
  if (args.expect && args.expect.toLowerCase() !== request.serverKey) {
    throw new Error('the key file does not hold the expected server key');
  }
  process.stdout.write(`${JSON.stringify(request, null, 2)}\n`);
}

if (require.main === module) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error instanceof Error ? error.message : 'bond grant request failed');
    process.exit(1);
  });
}

module.exports = { BOND_GRANT_DOMAIN, buildBondGrantMessage, signBondGrant, parseArgs, readPeerKeyFile, ...peer };
