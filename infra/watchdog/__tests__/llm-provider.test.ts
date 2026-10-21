import * as http from 'node:http';
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import {
  OpenAICompatibleProvider,
  RetryProvider,
  RateLimitedProvider,
  FallbackProvider,
} from '../src/llm/provider.js';

// Mock OpenAI-compatible server
let mockServer: http.Server;
let mockPort: number;
let requestCount: number;
let respondWith: (
  req: http.IncomingMessage,
  res: http.ServerResponse,
) => void;

beforeAll(async () => {
  requestCount = 0;
  respondWith = (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(
      JSON.stringify({
        choices: [{ message: { content: 'test response' } }],
        model: 'test-model',
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      }),
    );
  };

  mockServer = http.createServer((req, res) => {
    requestCount++;
    respondWith(req, res);
  });

  await new Promise<void>((resolve) => {
    mockServer.listen(0, () => {
      const addr = mockServer.address();
      mockPort = (addr as { port: number }).port;
      resolve();
    });
  });
});

afterAll(async () => {
  await new Promise<void>((resolve, reject) => {
    mockServer.close((err) => (err ? reject(err) : resolve()));
  });
});

describe('OpenAICompatibleProvider', () => {
  it('sends chat request and parses response', async () => {
    const provider = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test-model',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const result = await provider.chat([
      { role: 'user', content: 'hello' },
    ]);

    expect(result.content).toBe('test response');
    expect(result.model).toBe('test-model');
    expect(result.prompt_tokens).toBe(10);
    expect(result.completion_tokens).toBe(5);
  });

  it('throws on non-OK response', async () => {
    respondWith = (_req, res) => {
      res.writeHead(500);
      res.end('Internal Server Error');
    };

    const provider = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test-model',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    await expect(
      provider.chat([{ role: 'user', content: 'hello' }]),
    ).rejects.toThrow('LLM request failed: 500');

    // Reset
    respondWith = (_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          choices: [{ message: { content: 'ok' } }],
          model: 'test-model',
          usage: { prompt_tokens: 1, completion_tokens: 1 },
        }),
      );
    };
  });

  it('isAvailable returns true when /models endpoint responds', async () => {
    respondWith = (_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ data: [] }));
    };

    const provider = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    expect(await provider.isAvailable()).toBe(true);
  });

  it('isAvailable returns false when endpoint is unreachable', async () => {
    const provider = new OpenAICompatibleProvider({
      endpoint: 'http://localhost:1/v1',
      model: 'test',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 1000,
    });

    expect(await provider.isAvailable()).toBe(false);
  });
});

describe('RetryProvider', () => {
  it('retries on failure then succeeds', async () => {
    let callCount = 0;
    respondWith = (_req, res) => {
      callCount++;
      if (callCount <= 2) {
        res.writeHead(500);
        res.end('error');
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            choices: [{ message: { content: 'success after retry' } }],
            model: 'test',
            usage: { prompt_tokens: 1, completion_tokens: 1 },
          }),
        );
      }
    };

    const inner = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const provider = new RetryProvider(inner, 3, 10); // 10ms base delay for tests

    const result = await provider.chat([
      { role: 'user', content: 'hello' },
    ]);
    expect(result.content).toBe('success after retry');
  });
});

describe('RateLimitedProvider', () => {
  it('allows requests within rate limit', async () => {
    respondWith = (_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          choices: [{ message: { content: 'ok' } }],
          model: 'test',
          usage: { prompt_tokens: 1, completion_tokens: 1 },
        }),
      );
    };

    const inner = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const provider = new RateLimitedProvider(inner, 100);
    const result = await provider.chat([
      { role: 'user', content: 'hello' },
    ]);
    expect(result.content).toBe('ok');
  });

  it('rejects when rate limit exceeded', async () => {
    respondWith = (_req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          choices: [{ message: { content: 'ok' } }],
          model: 'test',
          usage: { prompt_tokens: 1, completion_tokens: 1 },
        }),
      );
    };

    const inner = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'test',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const provider = new RateLimitedProvider(inner, 2);

    // First two should work
    await provider.chat([{ role: 'user', content: '1' }]);
    await provider.chat([{ role: 'user', content: '2' }]);

    // Third should fail
    await expect(
      provider.chat([{ role: 'user', content: '3' }]),
    ).rejects.toThrow('rate limit exceeded');
  });
});

describe('FallbackProvider', () => {
  it('falls back to secondary when primary fails', async () => {
    let callIndex = 0;
    respondWith = (_req, res) => {
      callIndex++;
      if (callIndex === 1) {
        // Primary fails
        res.writeHead(500);
        res.end('primary down');
      } else {
        // Secondary succeeds
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(
          JSON.stringify({
            choices: [{ message: { content: 'from secondary' } }],
            model: 'secondary-model',
            usage: { prompt_tokens: 1, completion_tokens: 1 },
          }),
        );
      }
    };

    const primary = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'primary',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const secondary = new OpenAICompatibleProvider({
      endpoint: `http://localhost:${mockPort}/v1`,
      model: 'secondary',
      max_tokens: 100,
      temperature: 0.5,
      timeout_ms: 5000,
    });

    const provider = new FallbackProvider(primary, secondary);
    const result = await provider.chat([
      { role: 'user', content: 'hello' },
    ]);

    expect(result.content).toBe('from secondary');
  });
});
