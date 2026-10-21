import { describe, it, before } from 'node:test';
import * as assert from 'node:assert/strict';
import * as crypto from 'node:crypto';
import * as fs from 'node:fs/promises';
import * as path from 'node:path';
import * as os from 'node:os';
import { WalletSigner, type TaskAttestation } from './wallet-signer.js';

describe('WalletSigner', () => {
  let tmpDir: string;
  let validKeyPath: string;

  before(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'wallet-test-'));

    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    const pubHex = publicKey
      .export({ type: 'spki', format: 'der' })
      .toString('hex');
    const privHex = privateKey
      .export({ type: 'pkcs8', format: 'der' })
      .toString('hex');

    validKeyPath = path.join(tmpDir, 'wallet.json');
    await fs.writeFile(
      validKeyPath,
      JSON.stringify({ publicKey: pubHex, privateKey: privHex }),
    );
  });

  it('loads a valid wallet file', async () => {
    const signer = await WalletSigner.fromFile(validKeyPath);
    assert.ok(signer.publicKeyHex.length > 0);
  });

  it('throws on missing wallet file', async () => {
    await assert.rejects(
      () => WalletSigner.fromFile('/nonexistent/wallet.json'),
      { message: /wallet file not found/i },
    );
  });

  it('throws on invalid wallet JSON', async () => {
    const badPath = path.join(tmpDir, 'bad.json');
    await fs.writeFile(badPath, 'not json');
    await assert.rejects(() => WalletSigner.fromFile(badPath), {
      message: /invalid wallet/i,
    });
  });

  it('throws on missing privateKey field', async () => {
    const incompletePath = path.join(tmpDir, 'incomplete.json');
    await fs.writeFile(incompletePath, JSON.stringify({ publicKey: 'abc' }));
    await assert.rejects(() => WalletSigner.fromFile(incompletePath), {
      message: /invalid wallet/i,
    });
  });

  it('signs and verifies a task attestation', async () => {
    const signer = await WalletSigner.fromFile(validKeyPath);
    const attestation: TaskAttestation = {
      taskId: 'task-001',
      outputHash: 'abc123',
      nodeId: 'node-1',
      timestamp: 1709856000000,
    };

    const signed = signer.signAttestation(attestation);

    assert.equal(signed.taskId, 'task-001');
    assert.equal(signed.outputHash, 'abc123');
    assert.equal(signed.nodeId, 'node-1');
    assert.equal(signed.timestamp, 1709856000000);
    assert.equal(signed.publicKey, signer.publicKeyHex);
    assert.ok(signed.signature.length > 0, 'signature should be non-empty');

    const message = JSON.stringify({
      taskId: attestation.taskId,
      outputHash: attestation.outputHash,
      nodeId: attestation.nodeId,
      timestamp: attestation.timestamp,
    });
    const pubKeyObj = crypto.createPublicKey({
      key: Buffer.from(signed.publicKey, 'hex'),
      format: 'der',
      type: 'spki',
    });
    const isValid = crypto.verify(
      null,
      Buffer.from(message),
      pubKeyObj,
      Buffer.from(signed.signature, 'hex'),
    );
    assert.ok(isValid, 'signature should verify');
  });

  it('produces deterministic signatures for same input', async () => {
    const signer = await WalletSigner.fromFile(validKeyPath);
    const attestation: TaskAttestation = {
      taskId: 'task-002',
      outputHash: 'def456',
      nodeId: 'node-1',
      timestamp: 1709856000000,
    };

    const sig1 = signer.signAttestation(attestation).signature;
    const sig2 = signer.signAttestation(attestation).signature;
    assert.equal(sig1, sig2, 'same input should produce same signature');
  });
});
