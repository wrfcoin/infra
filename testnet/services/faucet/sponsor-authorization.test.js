'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');

const { loadGoldenVectorFixture } = require('../golden-vector-fixture.cjs');
const {
  buildSponsoredSendMessage,
  signSponsorAuthorization,
  assertWithinConsensusBounds,
  MAX_SPONSORED_FEE,
} = require('./sponsor-authorization');

const { fixture } = loadGoldenVectorFixture();
const vectors = fixture.cases.filter((c) => c.kind === 'sponsored_send_authorization_v1');

function fields(input) {
  return {
    chainId: input.chain_id,
    networkId: input.network_id,
    sponsor: input.sponsor,
    from: input.from,
    to: input.to,
    amount: input.amount,
    nonce: input.nonce,
    fee: input.fee,
    expiresAtHeight: input.expires_at_height,
    balanceFloor: input.balance_floor,
    firstSendOnly: input.first_send_only,
  };
}

test('the core4 fixture carries exactly one sponsored-send vector', () => {
  assert.equal(vectors.length, 1);
  assert.equal(vectors[0].frame, 'money_path_v2');
  assert.equal(vectors[0].tag, 'wrfcoin_sponsored_send_auth_v1');
});

test('the sponsor signer reproduces the core4 preimage, key and signature byte for byte', () => {
  const v = vectors[0];
  const preimage = buildSponsoredSendMessage(fields(v.input));
  assert.equal(preimage.toString('hex'), v.preimage_hex, 'sponsored-send preimage drifted from core4');
  const auth = signSponsorAuthorization({ ...fields(v.input), seedHex: v.signer_secret_hex });
  assert.equal(auth.sponsor_public_key, v.signer_public_key_hex);
  assert.equal(auth.signature, v.signature_hex);
  assert.equal(auth.first_send_only, true);
});

test('a tampered rule changes the preimage (a sponsor rule cannot be widened after signing)', () => {
  const v = vectors[0];
  const tampered = buildSponsoredSendMessage(fields(v.tampered_input));
  assert.notEqual(tampered.toString('hex'), v.preimage_hex);
});

test('the signer refuses what the chain would refuse', () => {
  assert.throws(() => assertWithinConsensusBounds({ fee: 999, expiresAtHeight: 10 }), RangeError);
  assert.throws(() => assertWithinConsensusBounds({ fee: MAX_SPONSORED_FEE + 1n, expiresAtHeight: 10 }), RangeError);
  assert.throws(() => assertWithinConsensusBounds({ fee: 5_000, expiresAtHeight: 100, currentHeight: 50 }), RangeError);
  assert.throws(() => assertWithinConsensusBounds({ fee: 5_000, expiresAtHeight: 49, currentHeight: 50 }), RangeError);
  assert.doesNotThrow(() => assertWithinConsensusBounds({ fee: 5_000, expiresAtHeight: 82, currentHeight: 50 }));
});
