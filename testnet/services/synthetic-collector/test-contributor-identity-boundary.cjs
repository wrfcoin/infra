#!/usr/bin/env node
'use strict';

const assert = require('assert/strict');
const { spawnSync } = require('child_process');
const collector = require('./submit-synthetic-contribution.cjs');

assert.notEqual(
    collector.DEFAULT_SYNTH_CONTRIBUTOR.toLowerCase(),
    collector.DEFAULT_REAL_CONTRIBUTOR.toLowerCase(),
    'synthetic default must not equal the real Ambient contributor default',
);

assert.doesNotThrow(
    () => collector.assertDistinctContributorIdentities(),
    'default synthetic and real identities must be accepted when distinct',
);

assert.throws(
    () => collector.assertDistinctContributorIdentities(
        collector.DEFAULT_REAL_CONTRIBUTOR,
        collector.DEFAULT_REAL_CONTRIBUTOR,
    ),
    /must differ/,
    'a synthetic override that reuses the real identity must fail closed',
);

assert.throws(
    () => collector.assertDistinctContributorIdentities('not-an-address', collector.DEFAULT_REAL_CONTRIBUTOR),
    /20-byte/,
    'an invalid synthetic identity must fail closed',
);

const startup = spawnSync(
    process.execPath,
    [require.resolve('./submit-synthetic-contribution.cjs')],
    {
        env: {
            ...process.env,
            SYNTH_CONTRIBUTOR: collector.DEFAULT_REAL_CONTRIBUTOR,
            SYNTH_REAL_CONTRIBUTOR: collector.DEFAULT_REAL_CONTRIBUTOR,
            WRFCOIN_OPERATOR_TOKEN: '',
            WRFCOIN_API_HOST: '127.0.0.1',
            WRFCOIN_API_PORT: '9',
        },
        encoding: 'utf8',
    },
);
assert.notEqual(
    startup.status,
    0,
    'collector must refuse to start on collapsed identities',
);
assert.match(startup.stderr, /must differ from SYNTH_REAL_CONTRIBUTOR/);
assert.doesNotMatch(
    startup.stderr,
    /OPERATOR_TOKEN is not set/,
    'identity guard must fail closed before the credential check',
);

console.log('PASS synthetic contributor identity boundary');
