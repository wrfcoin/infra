#!/usr/bin/env node

const fs = require('fs');
const http = require('http');
const path = require('path');

const port = Number.parseInt(process.env.CORE4_STUB_PORT || '18556', 10);
const host = process.env.CORE4_STUB_HOST || '127.0.0.1';
const fixturePath = path.resolve(
  process.env.CORE4_FIXTURE_PATH ||
    path.join(process.cwd(), 'core4', 'contract-fixtures', 'launch-realtime-event-source.json')
);

function loadFixture() {
  const fallback = {
    chainHeightSequence: [1000, 1001],
    block: {
      height: 1001,
      hash: `0x${(1001).toString(16).padStart(64, '0')}`,
      timestamp: new Date().toISOString(),
      transactions: [
        {
          hash: '0xtx1001',
          from: '0x1111111111111111111111111111111111111111',
          to: '0x2222222222222222222222222222222222222222',
          type: 'transfer',
        },
      ],
    },
  };

  if (!fs.existsSync(fixturePath)) {
    return fallback;
  }

  const parsed = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  return {
    chainHeightSequence:
      Array.isArray(parsed.chainHeightSequence) && parsed.chainHeightSequence.length > 0
        ? parsed.chainHeightSequence
        : fallback.chainHeightSequence,
    block: parsed.block && typeof parsed.block === 'object' ? parsed.block : fallback.block,
  };
}

const fixture = loadFixture();
let chainHeightCalls = 0;

function buildDeterministicHash(height) {
  return `0x${height.toString(16).padStart(64, '0')}`;
}

function buildDeterministicTimestamp(height) {
  const baseTimestamp = Date.parse(fixture.block.timestamp || new Date().toISOString());
  const baseHeight = Number.isFinite(fixture.block.height)
    ? fixture.block.height
    : fixture.chainHeightSequence[fixture.chainHeightSequence.length - 1];
  const offsetMs = Math.max(0, height - baseHeight) * 1000;
  return new Date(baseTimestamp + offsetMs).toISOString();
}

function json(res, status, payload) {
  res.statusCode = status;
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(payload));
}

function resolveHeight() {
  const sequence = fixture.chainHeightSequence;
  if (chainHeightCalls < sequence.length) {
    return sequence[chainHeightCalls];
  }

  const tailHeight = sequence[sequence.length - 1];
  return tailHeight + (chainHeightCalls - sequence.length + 1);
}

function resolveBlock(requestedHeight) {
  const blockHeight = Number.isFinite(requestedHeight) ? requestedHeight : fixture.block.height;
  const transactions = Array.isArray(fixture.block.transactions)
    ? fixture.block.transactions.map((tx, index) => {
        if (!tx || typeof tx !== 'object') {
          return tx;
        }

        return {
          ...tx,
          hash:
            typeof tx.hash === 'string' && blockHeight === fixture.block.height
              ? tx.hash
              : `0xtx${blockHeight.toString(16)}${index}`,
        };
      })
    : [];

  return {
    ...fixture.block,
    height: blockHeight,
    hash:
      blockHeight === fixture.block.height && typeof fixture.block.hash === 'string'
        ? fixture.block.hash
        : buildDeterministicHash(blockHeight),
    timestamp: buildDeterministicTimestamp(blockHeight),
    transactions,
  };
}

const server = http.createServer((req, res) => {
  if (!req.url) {
    json(res, 400, { error: 'missing url' });
    return;
  }

  if (req.url === '/health') {
    json(res, 200, {
      ok: true,
      currentHeight: resolveHeight(),
      chainHeightCalls,
      fixturePath,
    });
    return;
  }

  if (req.url === '/chain/height') {
    const height = resolveHeight();
    chainHeightCalls += 1;
    json(res, 200, { height });
    return;
  }

  if (req.url.startsWith('/blocks/')) {
    const rawHeight = req.url.slice('/blocks/'.length);
    const height = Number.parseInt(rawHeight, 10);
    if (!Number.isFinite(height)) {
      json(res, 400, { error: 'invalid block height' });
      return;
    }
    json(res, 200, resolveBlock(height));
    return;
  }

  json(res, 404, { error: `unknown endpoint ${req.url}` });
});

server.listen(port, host, () => {
  process.stdout.write(
    `core4 stub listening on http://${host}:${port} using fixture=${fixturePath}\n`
  );
});

function shutdown(signal) {
  process.stdout.write(`core4 stub shutting down on ${signal}\n`);
  server.close(() => process.exit(0));
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
