"use strict";

// Smoke tests for the explorer's normalization of REAL core4 launch_api
// payloads. Uses node's built-in test runner (no extra deps). Run:
//   node --test
//
// These assert the explorer correctly handles:
//   - the LawBook envelope ({ ok, data, error, meta }) used by /chain/*
//   - the bare JSON used by /network/info
//   - the real field names (height, hash, prev_block_hash, tx_count, ...)

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const {
  app,
  unwrapEnvelope,
  getBlockHeight,
  getBlockHash,
  getTxTypeLabel,
  isValidTxHash,
} = require("./server");

function request(pathname, headers = {}) {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      const req = http.request(
        { host: "127.0.0.1", port, path: pathname, headers },
        (res) => {
          let body = "";
          res.setEncoding("utf8");
          res.on("data", (chunk) => {
            body += chunk;
          });
          res.on("end", () => {
            server.close(() =>
              resolve({ statusCode: res.statusCode, headers: res.headers, body })
            );
          });
        }
      );
      req.on("error", (error) => {
        server.close(() => reject(error));
      });
      req.end();
    });
  });
}

// Representative payloads copied from core4 native-chain route handlers
// (routes/chain.rs chain_block_summary/detail, routes/network.rs get_network_info).
const CHAIN_BLOCKS_ENVELOPE = {
  ok: true,
  data: {
    blocks: [
      {
        height: 4186,
        timestamp: "2026-06-13T00:00:00+00:00",
        hash: "abc123",
        prev_block_hash: "def456",
        tx_count: 3,
      },
      {
        height: 4187,
        timestamp: "2026-06-13T00:00:05+00:00",
        hash: "ghi789",
        prev_block_hash: "abc123",
        tx_count: 2,
      },
    ],
    chain_height: 4187,
    returned: 2,
  },
  error: null,
  meta: { request_id: "r-1" },
};

const CHAIN_BLOCK_DETAIL_ENVELOPE = {
  ok: true,
  data: {
    height: 4187,
    timestamp: "2026-06-13T00:00:05+00:00",
    hash: "ghi789",
    prev_block_hash: "abc123",
    tx_count: 2,
    difficulty: 1,
    version: 1,
    nonce: 42,
    metadata: {},
    transactions: [
      { type: "Coinbase", sender: "0xminer" },
      { type: "DataAnalysis", sender: "0xuser" },
    ],
  },
  error: null,
  meta: { request_id: "r-2" },
};

const NETWORK_INFO_BARE = {
  network_id: "testnet",
  chain_id: "777",
  node_version: "0.1.0",
  genesis_hash: "0xgenesis",
  peer_count: 1,
  sync_status: "synced",
  chain_height: 4187,
  local_peer_id: "peer-1",
};

test("unwraps the LawBook envelope from /chain/blocks", () => {
  const data = unwrapEnvelope(CHAIN_BLOCKS_ENVELOPE);
  assert.ok(data, "envelope should unwrap to data");
  assert.equal(data.chain_height, 4187);
  assert.equal(data.blocks.length, 2);
});

test("unwraps the LawBook envelope from /chain/block/{height}", () => {
  const block = unwrapEnvelope(CHAIN_BLOCK_DETAIL_ENVELOPE);
  assert.equal(getBlockHeight(block), 4187);
  assert.equal(getBlockHash(block), "ghi789");
  assert.equal(block.transactions.length, 2);
});

test("passes through bare /network/info JSON unchanged", () => {
  const info = unwrapEnvelope(NETWORK_INFO_BARE);
  assert.equal(info.chain_height, 4187);
  assert.equal(info.genesis_hash, "0xgenesis");
  // No `data` key on a bare body — must not be swallowed.
  assert.equal(info, NETWORK_INFO_BARE);
});

test("returns null for an error envelope", () => {
  assert.equal(unwrapEnvelope({ ok: false, data: null, error: { code: "X" } }), null);
});

test("normalizes real block summary field names", () => {
  const data = unwrapEnvelope(CHAIN_BLOCKS_ENVELOPE);
  const [b0] = data.blocks;
  assert.equal(getBlockHeight(b0), 4186);
  assert.equal(getBlockHash(b0), "abc123");
});

test("labels real transaction types from /chain/block detail", () => {
  const block = unwrapEnvelope(CHAIN_BLOCK_DETAIL_ENVELOPE);
  const labels = block.transactions.map(getTxTypeLabel);
  assert.deepEqual(labels, ["Coinbase", "DataAnalysis"]);
});

test("serves explorer assets with a self-only script CSP", async () => {
  const res = await request("/");
  assert.equal(res.statusCode, 200);
  assert.match(res.headers["content-security-policy"], /default-src 'self'/);
  assert.match(res.headers["content-security-policy"], /script-src 'self'/);
  assert.match(res.body, /<script src="\/app\.js"><\/script>/);
  assert.doesNotMatch(res.body, /<script>\s*\/\//);
});

test("validates transaction hashes before backend proxy fetches", async () => {
  const originalFetch = global.fetch;
  let fetchCalled = false;
  global.fetch = async () => {
    fetchCalled = true;
    return { ok: false, json: async () => ({}) };
  };

  try {
    const txRes = await request("/api/transactions/..%2Fsigning_keys%2Flist");
    assert.equal(txRes.statusCode, 400);
    assert.match(txRes.body, /invalid transaction hash/);

    const searchRes = await request("/api/search?q=..%2Fsigning_keys%2Flist");
    assert.equal(searchRes.statusCode, 400);
    assert.match(searchRes.body, /invalid transaction hash/);

    assert.equal(fetchCalled, false);
  } finally {
    global.fetch = originalFetch;
  }
});

test("accepts only 64-character hex transaction hashes", () => {
  assert.equal(isValidTxHash("a".repeat(64)), true);
  assert.equal(isValidTxHash("A".repeat(64)), true);
  assert.equal(isValidTxHash("g".repeat(64)), false);
  assert.equal(isValidTxHash("../signing_keys/list"), false);
  assert.equal(isValidTxHash("a".repeat(63)), false);
});
