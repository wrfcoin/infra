#!/usr/bin/env node
import * as crypto from 'node:crypto';
import * as fs from 'node:fs';
import * as path from 'node:path';

const outPath = process.argv[2] || 'wallet.json';

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const pubHex = publicKey.export({ type: 'spki', format: 'der' }).toString('hex');
const privHex = privateKey.export({ type: 'pkcs8', format: 'der' }).toString('hex');

const wallet = { publicKey: pubHex, privateKey: privHex };

fs.mkdirSync(path.dirname(path.resolve(outPath)), { recursive: true });
fs.writeFileSync(outPath, JSON.stringify(wallet, null, 2) + '\n', { mode: 0o600 });

console.log(`Wallet written to ${outPath}`);
console.log(`Public key: ${pubHex}`);
