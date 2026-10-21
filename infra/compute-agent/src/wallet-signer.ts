import * as crypto from 'node:crypto';
import * as fs from 'node:fs/promises';

export interface TaskAttestation {
  taskId: string;
  outputHash: string;
  nodeId: string;
  timestamp: number;
}

export interface SignedAttestation extends TaskAttestation {
  signature: string;
  publicKey: string;
}

export class WalletSigner {
  private privateKey: crypto.KeyObject;
  private publicKey: crypto.KeyObject;
  readonly publicKeyHex: string;

  private constructor(
    privateKey: crypto.KeyObject,
    publicKey: crypto.KeyObject,
    publicKeyHex: string,
  ) {
    this.privateKey = privateKey;
    this.publicKey = publicKey;
    this.publicKeyHex = publicKeyHex;
  }

  static async fromFile(filePath: string): Promise<WalletSigner> {
    let raw: string;
    try {
      raw = await fs.readFile(filePath, 'utf-8');
    } catch (err) {
      throw new Error(
        `Wallet file not found: ${filePath} (${(err as Error).message})`,
      );
    }

    let parsed: { publicKey?: string; privateKey?: string };
    try {
      parsed = JSON.parse(raw);
    } catch {
      throw new Error(`Invalid wallet file: ${filePath} is not valid JSON`);
    }

    if (!parsed.publicKey || !parsed.privateKey) {
      throw new Error(
        `Invalid wallet file: ${filePath} must contain publicKey and privateKey fields`,
      );
    }

    let privateKey: crypto.KeyObject;
    let publicKey: crypto.KeyObject;
    try {
      privateKey = crypto.createPrivateKey({
        key: Buffer.from(parsed.privateKey, 'hex'),
        format: 'der',
        type: 'pkcs8',
      });
      publicKey = crypto.createPublicKey({
        key: Buffer.from(parsed.publicKey, 'hex'),
        format: 'der',
        type: 'spki',
      });
    } catch (err) {
      throw new Error(
        `Invalid wallet file: ${filePath} contains invalid keys (${(err as Error).message})`,
      );
    }

    return new WalletSigner(privateKey, publicKey, parsed.publicKey);
  }

  signAttestation(attestation: TaskAttestation): SignedAttestation {
    const message = JSON.stringify({
      taskId: attestation.taskId,
      outputHash: attestation.outputHash,
      nodeId: attestation.nodeId,
      timestamp: attestation.timestamp,
    });

    const signature = crypto.sign(null, Buffer.from(message), this.privateKey);

    return {
      ...attestation,
      signature: signature.toString('hex'),
      publicKey: this.publicKeyHex,
    };
  }
}
