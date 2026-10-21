'use strict';
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const modulePath = path.join(__dirname, 'submit-synthetic-contribution.cjs');
for (const chain of ['777', '888']) {
    const result = spawnSync(process.execPath, ['-e', `
        const assert = require('node:assert/strict');
        const collector = require(${JSON.stringify(modulePath)});
        const args = ['synthetic-station', 'synthetic-commit', 'weather'];
        const actual = collector.commitAuthorizationMessage(...args);
        const expected = collector.commitAuthorizationMessageWithDomain(
            process.env.WRFCOIN_CHAIN_ID, 'testnet', ...args);
        assert.deepEqual(actual, expected);
        const other = collector.commitAuthorizationMessageWithDomain(
            process.env.WRFCOIN_CHAIN_ID === '888' ? '777' : '888', 'testnet', ...args);
        assert.notDeepEqual(actual, other);
    `], { env: { ...process.env, WRFCOIN_CHAIN_ID: chain, WRFCOIN_NETWORK_ID: 'testnet' }, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
}
console.log('PASS: synthetic collector preimages bind configured 777/888 and differ across chains');
