"use strict";

// Smoke test for the explorer's OG image routes (infra#838 coverage gap).
//
// Before this file, nothing exercised `generateOgImage`/`ImageResponse`.
// `@vercel/og` 0.11.1 -> 1.0.2 (dependabot infra#838) installed cleanly,
// built cleanly, and the boot probe in build-boot-gate.yml passed, because
// `require("./server")` only registers routes — it never calls
// `getImageResponse()`, which is invoked lazily inside `generateOgImage`
// only when a request actually hits /og/block or /og/tx. Under 1.0.2,
// `new ImageResponse(...)` throws `Dynamic require of "fs" is not
// supported` from the bundled harfbuzzjs, so every such request 500s —
// a total feature outage that passed build, install, boot, /health, and
// Docker's own HEALTHCHECK. Confirmed by a manual control: the identical
// probe against 0.11.1 in the same environment renders a working PNG.
//
// This test seeds `cache.latestBlocks`/`cache.latestTxs` directly (both
// exported for tests) so it never needs a live core4 node, boots a real
// ephemeral instance of the real exported `app`, and makes a real HTTP
// request through the real route — the same
// getImageResponse -> generateOgImage -> ImageResponse -> arrayBuffer/headers
// pattern server.js uses in production, exercised end to end rather than
// re-implemented, so a regression anywhere in that chain is caught the
// same way infra#838 was: by actually rendering an image and checking the
// bytes that come back.
//
// Run: node --test

const test = require("node:test");
const assert = require("node:assert/strict");
const http = require("node:http");

const { app, cache } = require("./server");

// PNG magic bytes (first 8 bytes of every valid PNG file).
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// Binary-safe request helper — server.test.js's `request()` decodes the body
// as utf8, which corrupts PNG bytes. This collects raw Buffer chunks.
function requestBinary(pathname) {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      const req = http.request(
        { host: "127.0.0.1", port, path: pathname },
        (res) => {
          const chunks = [];
          res.on("data", (chunk) => chunks.push(chunk));
          res.on("end", () => {
            server.close(() =>
              resolve({
                statusCode: res.statusCode,
                headers: res.headers,
                body: Buffer.concat(chunks),
              })
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

test("GET /og/block/:height.png renders a real PNG", async () => {
  const height = 999999;
  cache.latestBlocks = [
    {
      height,
      timestamp: "2026-08-31T00:00:00+00:00",
      hash: "og-smoke-block-hash",
      prev_block_hash: "og-smoke-prev-hash",
      tx_count: 2,
      transactions: [
        { type: "Coinbase", sender: "0xminer" },
        { type: "Transfer", sender: "0xa", recipient: "0xb", amount: 12.5 },
      ],
    },
  ];
  cache.ogImages.delete(`block:${height}`);

  const res = await requestBinary(`/og/block/${height}.png`);

  assert.equal(res.statusCode, 200, `expected 200, got ${res.statusCode} (body: ${res.body.toString("utf8").slice(0, 300)})`);
  assert.match(res.headers["content-type"] || "", /^image\/png/);
  // A blank/near-blank render is itself a defect signature — assert a
  // plausible non-trivial size, not just "some bytes came back".
  assert.ok(
    res.body.length > 1000,
    `rendered PNG is suspiciously small (${res.body.length} bytes) — likely a broken render`
  );
  assert.ok(
    res.body.subarray(0, 8).equals(PNG_MAGIC),
    "response body does not start with PNG magic bytes"
  );
});

test("GET /og/tx/:hash.png renders a real PNG", async () => {
  const hash = "a".repeat(64);
  cache.latestTxs = [
    {
      hash,
      type: "Transfer",
      amount: 42,
      sender: "0xa",
      recipient: "0xb",
      block_height: 999998,
    },
  ];
  cache.ogImages.delete(`tx:${hash.toLowerCase()}`);

  const res = await requestBinary(`/og/tx/${hash}.png`);

  assert.equal(res.statusCode, 200, `expected 200, got ${res.statusCode} (body: ${res.body.toString("utf8").slice(0, 300)})`);
  assert.match(res.headers["content-type"] || "", /^image\/png/);
  assert.ok(
    res.body.length > 1000,
    `rendered PNG is suspiciously small (${res.body.length} bytes) — likely a broken render`
  );
  assert.ok(
    res.body.subarray(0, 8).equals(PNG_MAGIC),
    "response body does not start with PNG magic bytes"
  );
});
