#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const crypto = require('crypto');
const path = require('path');

const {
    loadGoldenVectorFixture,
} = require('../golden-vector-fixture.cjs');

function commitAuthorizationCase(fixture) {
    const acceptedKinds = new Set([
        'CommitAuthorization',
        'CommitAuthorizationV2',
        'commit_authorization_v2',
    ]);
    const vectors = fixture.cases.filter((candidate) => acceptedKinds.has(candidate.kind));
    assert.equal(
        vectors.length,
        1,
        'shared fixture must contain exactly one dedicated commit-authorization vector; ' +
        'the generic Transaction vector exercises a different signing preimage',
    );
    return vectors[0];
}

function rawSeedHex(fixture, vector) {
    const seed = vector.signer_secret_hex ||
        vector.signer_seed_hex ||
        vector.signer_private_seed_hex ||
        vector.private_key_seed_hex ||
        fixture.signer_secret_hex ||
        fixture.signer_seed_hex ||
        fixture.signer_private_seed_hex ||
        fixture.private_key_seed_hex;
    assert.match(
        seed || '',
        /^[0-9a-f]{64}$/i,
        'commit-authorization vector must publish a portable raw 32-byte Ed25519 seed',
    );
    return seed;
}

const { fixture, fixtureFile, source } = loadGoldenVectorFixture(process.argv[2]);

const vector = commitAuthorizationCase(fixture);
assert.equal(vector.frame, 'money_path_v2', 'commit-authorization vector has the wrong frame');
assert.equal(vector.tag, 'wrfcoin_commit_auth_v2', 'commit-authorization domain drifted');
const input = vector.input || {};
const tamperedInput = vector.tampered_input || {
    ...input,
    commit_id: `${input.commit_id || ''}-tampered`,
};
const chainId = input.chain_id || fixture.chain_id;
const networkId = input.network_id || fixture.network_id;
const stationId = input.station_id;
const commitId = input.commit_id;
const contributionType = input.contribution_type;
const seedHex = rawSeedHex(fixture, vector);

for (const [name, value] of Object.entries({
    chain_id: chainId,
    network_id: networkId,
    station_id: stationId,
    commit_id: commitId,
    contribution_type: contributionType,
})) {
    assert.equal(typeof value, 'string', `${name} must be a string`);
    assert.notEqual(value.length, 0, `${name} must not be empty`);
}

// The production wrapper resolves these values at module load, as core4 does.
process.env.WRFCOIN_CHAIN_ID = chainId;
process.env.WRFCOIN_NETWORK_ID = networkId;
process.env.COLLECTOR_SIGNING_SEED = seedHex;

const collector = require('./submit-synthetic-contribution.cjs');

const preimageV2 = collector.commitAuthorizationMessage(
    stationId,
    commitId,
    contributionType,
);
assert.equal(
    preimageV2.toString('hex'),
    vector.preimage_hex || vector.preimage_v2_hex,
    'collector v2 preimage drifted from core4 commit_authorization_message_with_domain',
);

const signingKey = collector.keyPairFromSeed(Buffer.from(seedHex, 'hex'));
const auth = collector.signCommitAuthorization(
    stationId,
    commitId,
    contributionType,
);
assert.equal(auth.auth_pubkey, vector.signer_public_key_hex, 'collector public key drifted');
function assertSignatureMatches(candidate) {
    assert.equal(
        auth.auth_signature,
        candidate.signature_hex || candidate.signature_v2_hex,
        'collector signature drifted',
    );
}
assertSignatureMatches(vector);

// §7 falsifiability control: the same assertion must reject a corrupted
// expected signature, ruling out a fixture reader that never reaches the signer.
const corrupted = structuredClone(vector);
const signatureHex = vector.signature_hex || vector.signature_v2_hex;
corrupted.signature_hex =
    `${signatureHex.slice(0, -1)}${signatureHex.endsWith('0') ? '1' : '0'}`;
delete corrupted.signature_v2_hex;
assert.throws(
    () => assertSignatureMatches(corrupted),
    /signature drifted/,
    'corrupted commit-authorization vector was accepted',
);
assert.equal(
    crypto.verify(
        null,
        preimageV2,
        signingKey.publicKey,
        Buffer.from(vector.signature_hex || vector.signature_v2_hex, 'hex'),
    ),
    true,
    'golden commit-authorization signature did not verify',
);

const tamperedV2 = collector.commitAuthorizationMessageWithDomain(
    tamperedInput.chain_id || chainId,
    tamperedInput.network_id || networkId,
    tamperedInput.station_id,
    tamperedInput.commit_id,
    tamperedInput.contribution_type,
);
assert.notEqual(
    tamperedV2.toString('hex'),
    vector.preimage_hex || vector.preimage_v2_hex,
    'tampered commit-authorization input produced the golden preimage',
);
assert.equal(
    crypto.verify(
        null,
        tamperedV2,
        signingKey.publicKey,
        Buffer.from(vector.signature_hex || vector.signature_v2_hex, 'hex'),
    ),
    false,
    'golden signature verified over the tampered commit-authorization input',
);

// Plan §5 P3: prove the v2->v1 compatibility fallback is GONE. This block is the
// inverse of the P2 step-2 assertions it replaces: after the fresh-genesis cut
// every node verifies v2 only, so a surviving v1 path is dead code that could
// silently mask a v2 signing regression. Reinstating any part of the fallback
// turns these RED.
assert.equal(
    collector.authVersionOrder,
    undefined,
    'v2->v1 fallback try-order was reinstated (authVersionOrder must not exist)',
);
assert.equal(
    collector.COMMIT_AUTH_DOMAIN_V1,
    undefined,
    'v1 commit-auth domain was reinstated (COMMIT_AUTH_DOMAIN_V1 must not exist)',
);

// The preimage builder must have no version knob left: the v2 preimage is the
// only one it can produce, so a stray extra argument cannot change a byte.
assert.equal(
    collector.commitAuthorizationMessageWithDomain(
        chainId,
        networkId,
        stationId,
        commitId,
        contributionType,
        'v1',
    ).toString('hex'),
    preimageV2.toString('hex'),
    'a version argument still alters the preimage — the v1 branch survives',
);

// Source-level guard: nothing in the shipped collector may mention the v1 auth
// domain or the env knob that selected it. (`source_device: 'synthetic-v1'` is a
// device label, not an auth version, and is deliberately still present.)
const collectorSource = require('fs').readFileSync(
    path.join(__dirname, 'submit-synthetic-contribution.cjs'),
    'utf8',
);
const executableSource = collectorSource
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .join('\n');
assert.equal(
    /wrfcoin_commit_auth_v1/.test(executableSource),
    false,
    'collector still contains the v1 commit-auth domain string',
);
assert.equal(
    /COLLECTOR_AUTH_VERSION/.test(executableSource),
    false,
    'collector still reads COLLECTOR_AUTH_VERSION',
);
assert.equal(
    /source_device: 'synthetic-v1'/.test(collectorSource),
    true,
    'source_device device label must be preserved (it is not an auth version)',
);

// Provenance is anchored by the fixture sha256 (enforced in
// golden-vector-fixture.cjs); source.commit is the verifiable git-show link to
// core4 main. Assert its SHAPE, not an exact value, so a re-pin is a data-only
// change to source.json (core4#2372 provenance-trap decision).
assert.match(
    source.commit,
    /^[0-9a-f]{40}$/,
    'fixture provenance commit must be a full 40-hex core4 SHA',
);

console.log(
    `PASS synthetic-collector commit authorization: ${path.resolve(fixtureFile)} ` +
    '(v2 golden preimage + signature + tamper control; v2->v1 fallback DELETED — §5 P3)',
);
