'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const test = require('node:test');

const {
  loadGoldenVectorFixture,
} = require('../golden-vector-fixture.cjs');

const { fixture, source } = loadGoldenVectorFixture();
const vectors = fixture.cases.filter(
  (candidate) => candidate.kind === 'transparent_transfer_authorization_v2',
);
assert.equal(
  vectors.length,
  1,
  'shared fixture must contain exactly one transparent-transfer authorization vector',
);

const vector = vectors[0];
assert.equal(vector.frame, 'money_path_v2');
assert.equal(vector.tag, 'wrfcoin_transparent_transfer_auth_v2');
assert.match(
  vector.signer_secret_hex || '',
  /^[0-9a-f]{64}$/i,
  'transparent-transfer vector must publish a raw 32-byte Ed25519 seed',
);

// signTransferAuthorization resolves chain identity at module load, just like
// the deployed service. Set the fixture identity before loading production code.
process.env.WRFCOIN_CHAIN_ID = vector.input.chain_id;
process.env.WRFCOIN_NETWORK_ID = vector.input.network_id;

const {
  buildTransferAuthMessage,
  signTransferAuthorization,
} = require('./server');

const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function expectedPreimageHex(candidate) {
  return candidate.preimage_hex || candidate.preimage_v2_hex;
}

function expectedSignatureHex(candidate) {
  return candidate.signature_hex || candidate.signature_v2_hex;
}

function assertProductionSignerMatches(candidate) {
  const input = candidate.input;
  const preimage = buildTransferAuthMessage(
    input.from,
    input.to,
    input.amount,
    input.nonce,
    input.chain_id,
    input.network_id,
  );
  assert.equal(
    preimage.toString('hex'),
    expectedPreimageHex(candidate),
    'faucet transfer-authorization preimage drifted from core4',
  );

  const auth = signTransferAuthorization({
    from: input.from,
    to: input.to,
    amountBaseUnits: input.amount,
    nonce: input.nonce,
    privkeyHex: candidate.signer_secret_hex,
  });
  assert.equal(
    auth.auth_pubkey,
    candidate.signer_public_key_hex,
    'faucet transfer-authorization public key drifted',
  );
  assert.equal(
    auth.auth_signature,
    expectedSignatureHex(candidate),
    'faucet transfer-authorization signature drifted',
  );

  return { auth, preimage };
}

test('signTransferAuthorization executes the pinned core4 transfer vector byte-for-byte', () => {
  const { auth, preimage } = assertProductionSignerMatches(vector);
  const publicKey = crypto.createPublicKey({
    key: Buffer.concat([
      ED25519_SPKI_PREFIX,
      Buffer.from(auth.auth_pubkey, 'hex'),
    ]),
    format: 'der',
    type: 'spki',
  });
  const goldenSignature = Buffer.from(expectedSignatureHex(vector), 'hex');

  assert.equal(
    crypto.verify(null, preimage, publicKey, goldenSignature),
    true,
    'golden transfer-authorization signature did not verify',
  );

  const tampered = vector.tampered_input;
  const tamperedPreimage = buildTransferAuthMessage(
    tampered.from,
    tampered.to,
    tampered.amount,
    tampered.nonce,
    tampered.chain_id,
    tampered.network_id,
  );
  assert.notEqual(
    tamperedPreimage.toString('hex'),
    expectedPreimageHex(vector),
    'tampered transfer input produced the golden preimage',
  );
  assert.equal(
    crypto.verify(null, tamperedPreimage, publicKey, goldenSignature),
    false,
    'golden signature verified over the tampered transfer input',
  );

  // §7 falsifiability control: a corrupted expected vector must be rejected by
  // this same production-signer assertion, not merely differ in an unused field.
  const corrupted = structuredClone(vector);
  const signature = expectedSignatureHex(corrupted);
  corrupted.signature_hex =
    `${signature.slice(0, -1)}${signature.endsWith('0') ? '1' : '0'}`;
  delete corrupted.signature_v2_hex;
  assert.throws(
    () => assertProductionSignerMatches(corrupted),
    /signature drifted/,
    'corrupted transfer vector was accepted',
  );

  // Provenance is anchored by the fixture sha256 (enforced in
  // golden-vector-fixture.cjs); source.commit is the verifiable git-show link
  // to core4 main. Assert its SHAPE, not an exact value, so a deliberate
  // re-pin (e.g. a new squash SHA) is a data-only change to source.json and
  // this consumer needs no edit. (core4#2372 provenance-trap decision.)
  assert.match(
    source.commit,
    /^[0-9a-f]{40}$/,
    'fixture provenance commit must be a full 40-hex core4 SHA',
  );
});
