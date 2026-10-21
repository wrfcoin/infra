export interface StorageClient {
  uploadResult(
    data: Buffer,
    metadata: Record<string, string>,
  ): Promise<string>;
  downloadInput(url: string): Promise<Buffer>;
}

export class HttpStorageClient implements StorageClient {
  private baseUrl: string;

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
  }

  async uploadResult(
    data: Buffer,
    metadata: Record<string, string>,
  ): Promise<string> {
    const url = `${this.baseUrl}/api/storage/upload`;

    // Build multipart form data manually since we're not using any deps
    const boundary = `----FormBoundary${Date.now().toString(36)}`;
    const parts: Buffer[] = [];

    // Add metadata fields
    for (const [key, value] of Object.entries(metadata)) {
      parts.push(
        Buffer.from(
          `--${boundary}\r\nContent-Disposition: form-data; name="${key}"\r\n\r\n${value}\r\n`,
        ),
      );
    }

    // Add file data
    parts.push(
      Buffer.from(
        `--${boundary}\r\nContent-Disposition: form-data; name="file"; filename="result.nc"\r\nContent-Type: application/octet-stream\r\n\r\n`,
      ),
    );
    parts.push(data);
    parts.push(Buffer.from(`\r\n--${boundary}--\r\n`));

    const body = Buffer.concat(parts);

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': `multipart/form-data; boundary=${boundary}`,
          'Content-Length': body.length.toString(),
        },
        body,
        signal: AbortSignal.timeout(120_000), // 2 minute timeout for uploads
      });

      if (!res.ok) {
        const text = await res.text().catch(() => '');
        throw new Error(`Upload failed: ${res.status} ${text}`);
      }

      const result = (await res.json()) as { cid: string };
      console.log(`[storage-client] Uploaded result, CID: ${result.cid}`);
      return result.cid;
    } catch (err) {
      console.error(
        `[storage-client] Upload failed: ${(err as Error).message}`,
      );
      throw err;
    }
  }

  async downloadInput(url: string): Promise<Buffer> {
    try {
      const res = await fetch(url, {
        signal: AbortSignal.timeout(60_000), // 1 minute timeout for downloads
      });

      if (!res.ok) {
        throw new Error(`Download failed: ${res.status}`);
      }

      const arrayBuf = await res.arrayBuffer();
      console.log(
        `[storage-client] Downloaded ${arrayBuf.byteLength} bytes from ${url}`,
      );
      return Buffer.from(arrayBuf);
    } catch (err) {
      console.error(
        `[storage-client] Download failed for ${url}: ${(err as Error).message}`,
      );
      throw err;
    }
  }
}
