'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');

process.env.SYNTH_MINER_ADDRESS = '0x680d51f7543ca70029866956376306d47ce60ed0';

const { canonicalRevealIncluded, generateReading } = require(path.join(
    __dirname,
    '..',
    '..',
    'testnet',
    'services',
    'synthetic-collector',
    'submit-synthetic-contribution.cjs',
));

const maxPressureDeltaPerSecond = 0.05;
const cadenceSeconds = 60;
const start = 1_787_200_000;

for (let offset = 0; offset < 24 * 60 * 60; offset += cadenceSeconds) {
    const first = generateReading(start + offset);
    const second = generateReading(start + offset + cadenceSeconds);
    const rate = Math.abs(second.pressure_hpa - first.pressure_hpa) / cadenceSeconds;
    assert.ok(
        rate <= maxPressureDeltaPerSecond,
        `pressure rate ${rate}/s exceeds ${maxPressureDeltaPerSecond}/s at offset ${offset}`,
    );
}

console.log('PASS: synthetic pressure stays within the Core4 temporal consensus bound');

let roundingTransitions = 0;
let maxRestartRate = 0;
for (let offset = 0; offset < 24 * 60 * 60; offset += 1) {
    const first = generateReading(start + offset);
    const second = generateReading(start + offset + 1);
    const rate = Math.abs(second.pressure_hpa - first.pressure_hpa);
    if (rate > 0) roundingTransitions += 1;
    maxRestartRate = Math.max(maxRestartRate, rate);
    assert.ok(
        rate <= maxPressureDeltaPerSecond,
        `one-second restart pressure rate ${rate}/s exceeds ${maxPressureDeltaPerSecond}/s at offset ${offset}`,
    );
}
assert.ok(roundingTransitions > 0, 'one-second restart probe must cross rounding boundaries');

console.log(
    `PASS: ${roundingTransitions} one-second rounding transitions stay restart-safe ` +
    `(max ${maxRestartRate}/s)`,
);

const canonicalIncluded = {
    status: 200,
    data: {
        commit_id: 'commit-ok',
        station_id: 'PWS-SYNTH',
        revealed_at: 42,
        reward_finalized: false,
        status: 'revealed_pending_attestation',
    },
};
assert.equal(canonicalRevealIncluded(canonicalIncluded, 'commit-ok', 'PWS-SYNTH'), true);
assert.equal(canonicalRevealIncluded({
    ...canonicalIncluded,
    data: { ...canonicalIncluded.data, station_id: 'PWS-WRONG' },
}, 'commit-ok', 'PWS-SYNTH'), false);
assert.equal(canonicalRevealIncluded({
    status: 200,
    data: {
        commit_id: 'commit-bad',
        station_id: 'PWS-SYNTH',
        revealed_at: null,
        reward_finalized: false,
        status: 'committed_pending_reveal',
    },
}, 'commit-bad', 'PWS-SYNTH'), false);

console.log('PASS: block creation and a wrong station binding cannot report reveal success');
