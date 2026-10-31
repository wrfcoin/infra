'use strict';

// Sponsored first sends: the faucet-side signer for a sponsor's promise to pay
// one transfer's fee (core4 shared-protocol accounts/paymaster.rs,
// `sponsored_send_authorization_message_with_domain`). Not mounted on any
// route: the chain ignores a sponsorship until the owner schedules the
// `paymaster` feature, and the sponsor service ships with that release (see
// core4 docs/adr/2026-11-01-sponsored-first-sends.md). This module exists now
// so its bytes are pinned to the core4 golden vector
// `sponsored_send_authorization_v1` from day one.

const crypto = require('node:crypto');

const SPONSORED_SEND_AUTH_DOMAIN = 'wrfcoin_sponsored_send_auth_v1';

// Consensus bounds (paymaster.rs MIN_SPONSORED_FEE / MAX_SPONSORED_FEE /
// MAX_SPONSORSHIP_VALIDITY_BLOCKS). The chain refuses anything outside them.
const MIN_SPONSORED_FEE = 1_000n;
const MAX_SPONSORED_FEE = 1_000_000n;
const MAX_SPONSORSHIP_VALIDITY_BLOCKS = 32n;

const ED25519_PKCS8_PREFIX = Buffer.from('302e020100300506032b657004220420', 'hex');
const U64_MAX = (1n << 64n) - 1n;

function u32le(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(n);
  return b;
}

function u64le(value, name) {
  const v = BigInt(value);
  if (v < 0n || v > U64_MAX) throw new RangeError(`${name} must fit a u64`);
  const b = Buffer.alloc(8);
  b.writeBigUInt64LE(v);
  return b;
}

function lenPrefixed(s) {
  const bytes = Buffer.from(String(s), 'utf8');
  return Buffer.concat([u32le(bytes.length), bytes]);
}

/**
 * The exact preimage core4 verifies: tag || str(chain_id) || str(network_id)
 * || str(sponsor) || str(from) || str(to) || u64le(amount) || u64le(nonce)
 * || u64le(fee) || u64le(expires_at_height) || u64le(balance_floor)
 * || u8(first_send_only).
 */
function buildSponsoredSendMessage({
  chainId, networkId, sponsor, from, to, amount, nonce, fee, expiresAtHeight, balanceFloor, firstSendOnly,
}) {
  return Buffer.concat([
    Buffer.from(SPONSORED_SEND_AUTH_DOMAIN, 'utf8'),
    lenPrefixed(chainId),
    lenPrefixed(networkId),
    lenPrefixed(sponsor),
    lenPrefixed(from),
    lenPrefixed(to),
    u64le(amount, 'amount'),
    u64le(nonce, 'nonce'),
    u64le(fee, 'fee'),
    u64le(expiresAtHeight, 'expiresAtHeight'),
    u64le(balanceFloor, 'balanceFloor'),
    Buffer.from([firstSendOnly ? 1 : 0]),
  ]);
}

function keyFromSeedHex(seedHex) {
  const seed = Buffer.from(String(seedHex).replace(/^0x/i, ''), 'hex');
  if (seed.length !== 32) throw new Error('sponsor key must be a 32-byte hex ed25519 seed');
  return crypto.createPrivateKey({
    key: Buffer.concat([ED25519_PKCS8_PREFIX, seed]),
    format: 'der',
    type: 'pkcs8',
  });
}

/**
 * Refuse, before signing, anything the chain would refuse anyway: fee outside
 * the consensus bounds, or an expiry more than 32 blocks past `currentHeight`.
 */
function assertWithinConsensusBounds({ fee, expiresAtHeight, currentHeight }) {
  const f = BigInt(fee);
  if (f < MIN_SPONSORED_FEE || f > MAX_SPONSORED_FEE) {
    throw new RangeError(`fee must be between ${MIN_SPONSORED_FEE} and ${MAX_SPONSORED_FEE} base units`);
  }
  if (currentHeight !== undefined) {
    const expires = BigInt(expiresAtHeight);
    const now = BigInt(currentHeight);
    if (expires < now || expires - now > MAX_SPONSORSHIP_VALIDITY_BLOCKS) {
      throw new RangeError(`expiresAtHeight must be within ${MAX_SPONSORSHIP_VALIDITY_BLOCKS} blocks of the tip`);
    }
  }
}

/**
 * Sign a sponsorship and return it in the wire shape core4 deserializes
 * (`SponsorAuthorization`). Never logs or returns the seed.
 */
function signSponsorAuthorization({
  seedHex, chainId, networkId, sponsor, from, to, amount, nonce, fee, expiresAtHeight, balanceFloor,
  firstSendOnly, currentHeight,
}) {
  assertWithinConsensusBounds({ fee, expiresAtHeight, currentHeight });
  const key = keyFromSeedHex(seedHex);
  const message = buildSponsoredSendMessage({
    chainId, networkId, sponsor, from, to, amount, nonce, fee, expiresAtHeight, balanceFloor, firstSendOnly,
  });
  const spki = crypto.createPublicKey(key).export({ format: 'der', type: 'spki' });
  return {
    sponsor,
    fee: Number(fee),
    expires_at_height: Number(expiresAtHeight),
    balance_floor: Number(balanceFloor),
    first_send_only: Boolean(firstSendOnly),
    sponsor_public_key: spki.subarray(spki.length - 32).toString('hex'),
    signature: crypto.sign(null, message, key).toString('hex'),
  };
}

module.exports = {
  SPONSORED_SEND_AUTH_DOMAIN,
  MIN_SPONSORED_FEE,
  MAX_SPONSORED_FEE,
  MAX_SPONSORSHIP_VALIDITY_BLOCKS,
  buildSponsoredSendMessage,
  assertWithinConsensusBounds,
  signSponsorAuthorization,
};
