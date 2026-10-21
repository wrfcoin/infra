'use strict';

const assert = require('assert/strict');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const FIXTURE_DIR = path.resolve(__dirname, '../fixtures/core4');
const VENDORED_FIXTURE = path.join(FIXTURE_DIR, 'signing_preimage_v2.json');
const SOURCE_MANIFEST = path.join(
    FIXTURE_DIR,
    'signing_preimage_v2.source.json',
);

function loadGoldenVectorFixture(explicitPath) {
    const fixtureFile = path.resolve(
        explicitPath ||
        process.env.WRFCOIN_GOLDEN_VECTOR_FIXTURE ||
        VENDORED_FIXTURE,
    );
    const source = JSON.parse(fs.readFileSync(SOURCE_MANIFEST, 'utf8'));
    const fixtureBytes = fs.readFileSync(fixtureFile);
    const fixtureSha256 = crypto
        .createHash('sha256')
        .update(fixtureBytes)
        .digest('hex');

    assert.equal(
        fixtureSha256,
        source.sha256,
        `core4 golden-vector fixture hash drifted from ${source.commit}`,
    );

    const fixture = JSON.parse(fixtureBytes.toString('utf8'));
    assert.equal(
        fixture.schema,
        source.schema,
        'unsupported core4 golden-vector schema; review and update this consumer deliberately',
    );
    assert.ok(
        Array.isArray(fixture.cases),
        'golden-vector fixture must contain cases[]',
    );

    return { fixture, fixtureFile, source };
}

module.exports = {
    loadGoldenVectorFixture,
};
