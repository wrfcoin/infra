"use strict";

const express = require("express");
const path = require("path");

const app = express();
const PORT = parseInt(process.env.PORT || "8081", 10);
const NODE_API = process.env.NODE_API_URL || "http://wrfcoin-node:8556";
const BACKEND_API = process.env.BACKEND_API_URL || "http://wrfcoin-backend:4001";
const POLL_INTERVAL = parseInt(process.env.POLL_INTERVAL_MS || "5000", 10);
const BOT_UA_RE =
  /twitterbot|discordbot|slackbot|facebookexternalhit|telegrambot|linkedinbot|whatsapp/i;
const OG_IMAGE_SIZE = { width: 1200, height: 630 };
const numberFormatter = new Intl.NumberFormat("en-US");
const compactNumberFormatter = new Intl.NumberFormat("en-US", {
  notation: "compact",
  maximumFractionDigits: 1,
});
const TX_HASH_RE = /^[A-Fa-f0-9]{64}$/;
let imageResponsePromise = null;

// ---------------------------------------------------------------------------
// In-memory cache — the explorer is read-only; no DB needed
// ---------------------------------------------------------------------------
const cache = {
  chainInfo: null,
  networkInfo: null,
  latestBlocks: [],
  latestTxs: [],
  lastPoll: null,
  ogImages: new Map(),
};

// ---------------------------------------------------------------------------
// Node API proxy helpers
// ---------------------------------------------------------------------------
async function fetchJson(url) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 5000);
  try {
    const res = await fetch(url, { signal: controller.signal });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  } finally {
    clearTimeout(timeout);
  }
}

// The core4 launch_api wraps most responses in a "LawBook" envelope:
//   { ok: true, data: <payload>, error: null, meta: {...} }
// A few legacy routes (e.g. /network/info) return the payload bare. Unwrap
// transparently so callers always get the inner payload regardless of shape.
function unwrapEnvelope(body) {
  if (body == null) return null;
  if (typeof body === "object" && !Array.isArray(body)) {
    if (body.ok === false) return null;
    if ("data" in body && ("ok" in body || "meta" in body || "error" in body)) {
      return body.data ?? null;
    }
  }
  return body;
}

// Fetch a node endpoint and unwrap the LawBook envelope if present.
async function fetchNode(pathname) {
  return unwrapEnvelope(await fetchJson(`${NODE_API}${pathname}`));
}

function isValidTxHash(value) {
  return TX_HASH_RE.test(String(value || ""));
}

function encodePathSegment(value) {
  return encodeURIComponent(String(value));
}

function getCachedBlock(height) {
  return (
    cache.latestBlocks.find((block) => (block.height ?? block.index) === height) ||
    null
  );
}

function getTransactionHash(tx) {
  return tx?.hash || tx?.tx_hash || tx?.id || "";
}

function getCachedTransaction(hash) {
  const normalized = String(hash).toLowerCase();
  return (
    cache.latestTxs.find(
      (tx) => getTransactionHash(tx).toLowerCase() === normalized
    ) || null
  );
}

async function fetchBlock(height) {
  // Real node route: GET /chain/block/{height} (LawBook envelope -> data).
  return getCachedBlock(height) || fetchNode(`/chain/block/${height}`);
}

async function fetchTransaction(hash) {
  if (!isValidTxHash(hash)) return null;

  // The node exposes NO transaction-by-hash route, and /chain/block tx
  // summaries do not carry a hash. So tx lookup is best-effort: the
  // in-memory cache first, then an optional backend proxy if one is wired.
  // Never error — return null and let callers render "not found".
  const cached = getCachedTransaction(hash);
  if (cached) return cached;

  return fetchJson(`${BACKEND_API}/transactions/${encodePathSegment(hash)}`);
}

function getBlockHeight(block) {
  return block?.height ?? block?.index ?? null;
}

function getBlockHash(block) {
  return block?.hash || block?.block_hash || "";
}

function getMinerLabel(block) {
  return block?.validator || block?.miner || block?.proposer || "";
}

function getTxTypeLabel(tx) {
  const raw = String(tx?.type || tx?.tx_type || tx?.kind || "").toLowerCase();

  if (raw.includes("coinbase") || raw.includes("reward") || raw.includes("mint")) {
    return "Coinbase";
  }
  if (raw.includes("commit")) return "ContribCommit";
  if (raw.includes("reveal")) return "ContribReveal";
  if (raw.includes("transfer") || raw.includes("send")) return "Transfer";
  if (raw.includes("stake")) return "Stake";
  if (raw.includes("weather") || raw.includes("publish")) return "Weather";
  return tx?.type || tx?.tx_type || "Transaction";
}

function isContributionTx(tx) {
  const raw = String(tx?.type || tx?.tx_type || "").toLowerCase();
  return (
    raw.includes("weather") ||
    raw.includes("publish") ||
    raw.includes("commit") ||
    raw.includes("reveal") ||
    Boolean(tx?.weather_data) ||
    Boolean(tx?.station_id)
  );
}

function toFiniteNumber(value) {
  if (value == null || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function formatNumber(value) {
  const numeric = toFiniteNumber(value);
  if (numeric == null) return null;
  return numberFormatter.format(numeric);
}

function formatCompactNumber(value) {
  const numeric = toFiniteNumber(value);
  if (numeric == null) return null;
  return compactNumberFormatter.format(numeric);
}

function formatAmount(value, unit = "") {
  const numeric = toFiniteNumber(value);
  if (numeric == null) {
    return value == null || value === "" ? null : `${value}${unit ? ` ${unit}` : ""}`;
  }
  const formatted =
    Math.abs(numeric) >= 100000
      ? compactNumberFormatter.format(numeric)
      : numberFormatter.format(numeric);
  return `${formatted}${unit ? ` ${unit}` : ""}`;
}

function shortHash(value, start = 8, end = 6) {
  if (!value) return "—";
  if (value.length <= start + end + 1) return value;
  return `${value.slice(0, start)}...${value.slice(-end)}`;
}

function formatTimestamp(value) {
  if (!value) return null;

  const timestamp =
    typeof value === "number"
      ? value > 1e12
        ? value
        : value * 1000
      : Date.parse(value);

  if (Number.isNaN(timestamp)) return String(value);
  return new Date(timestamp).toLocaleString("en-US", {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function isBotRequest(req) {
  return BOT_UA_RE.test(req.get("user-agent") || "");
}

function getOrigin(req) {
  const protocolHeader = req.get("x-forwarded-proto");
  const protocol = protocolHeader ? protocolHeader.split(",")[0] : req.protocol;
  return `${protocol}://${req.get("host")}`;
}

function getTxAmount(tx) {
  return (
    tx?.amount ??
    tx?.value ??
    tx?.reward ??
    tx?.total_amount ??
    tx?.payload?.amount ??
    null
  );
}

function getTxBlockHeight(tx) {
  return tx?.block_height ?? tx?.block ?? tx?._blockHeight ?? null;
}

function getBlockStake(block) {
  const directStake =
    block?.stake ?? block?.total_stake ?? block?.validator_stake ?? null;
  if (directStake != null) return directStake;

  const stakeTxs = (block?.transactions || []).filter((tx) =>
    String(tx?.type || tx?.tx_type || "").toLowerCase().includes("stake")
  );
  if (stakeTxs.length === 0) return null;

  const total = stakeTxs.reduce((sum, tx) => sum + (toFiniteNumber(getTxAmount(tx)) || 0), 0);
  return total > 0 ? total : null;
}

function getCarbonOffsetKg(block) {
  return (
    block?.carbon_offset_kg ??
    block?.carbon_offset ??
    block?.offset_kg ??
    block?.weather_summary?.carbon_offset_kg ??
    null
  );
}

function buildBlockMeta(block, req) {
  const height = getBlockHeight(block);
  const txCount = (block?.transactions || []).length;
  const miner = getMinerLabel(block);
  const weatherTxCount = (block?.transactions || []).filter(isContributionTx).length;
  const stake = getBlockStake(block);
  const carbonOffset = getCarbonOffsetKg(block);
  const hash = getBlockHash(block);
  const origin = getOrigin(req);
  const sharePath = `/share/block/${height}`;
  const imagePath = `/og/block/${height}.png`;
  const title = `WRFCoin Block #${height} — ${txCount} tx${
    miner ? `, mined by ${shortHash(miner, 6, 4)}` : ""
  }`;

  const descriptionParts = [];
  if (weatherTxCount > 0) {
    descriptionParts.push(`Weather contributions: ${weatherTxCount}`);
  }
  if (stake != null) {
    descriptionParts.push(`Stake: ${formatAmount(stake, "WRF")}`);
  }
  if (carbonOffset != null) {
    descriptionParts.push(`Carbon offset: ${formatAmount(carbonOffset, "kg")}`);
  }
  if (descriptionParts.length === 0 && block?.timestamp) {
    descriptionParts.push(`Mined ${formatTimestamp(block.timestamp)}`);
  }
  if (descriptionParts.length === 0 && hash) {
    descriptionParts.push(`Hash ${shortHash(hash, 10, 8)}`);
  }

  return {
    kind: "block",
    title,
    description: descriptionParts.join(" · "),
    imageUrl: `${origin}${imagePath}`,
    shareUrl: `${origin}${sharePath}`,
    spaUrl: `${origin}/#/block/${height}`,
    imageAlt: `WRFCoin share card for block ${height}`,
    payload: {
      badge: "BLOCK",
      accent: "#4a9eff",
      title: `#${height}`,
      subtitle: `${txCount} transactions`,
      description: descriptionParts.join(" · ") || "WRFCoin testnet explorer",
      primary: miner ? `Miner ${shortHash(miner, 8, 6)}` : "WRFCoin testnet",
      secondary: block?.timestamp ? formatTimestamp(block.timestamp) : shortHash(hash, 10, 8),
      chips: [
        `${txCount} tx`,
        weatherTxCount > 0 ? `${weatherTxCount} weather` : null,
        stake != null ? `Stake ${formatAmount(stake, "WRF")}` : null,
      ].filter(Boolean),
      footer: hash ? `Hash ${shortHash(hash, 12, 8)}` : "WRFCoin testnet explorer",
    },
  };
}

function buildTxMeta(tx, req) {
  const hash = getTransactionHash(tx);
  const type = getTxTypeLabel(tx);
  const amount = getTxAmount(tx);
  const blockHeight = getTxBlockHeight(tx);
  const from = tx?.from || tx?.sender || tx?.signer || "";
  const to = tx?.to || tx?.recipient || tx?.receiver || "";
  const origin = getOrigin(req);
  const encodedHash = encodeURIComponent(hash);
  const sharePath = `/share/tx/${encodedHash}`;
  const imagePath = `/og/tx/${encodedHash}.png`;
  const amountLabel = formatAmount(amount, "WRF");
  const titleSegments = [`WRFCoin ${type}`];
  if (amountLabel) titleSegments.push(amountLabel);
  if (blockHeight != null) titleSegments.push(`block #${blockHeight}`);

  const descriptionParts = [`Hash ${shortHash(hash, 10, 8)}`];
  if (from) descriptionParts.push(`From ${shortHash(from, 8, 6)}`);
  if (to) descriptionParts.push(`To ${shortHash(to, 8, 6)}`);
  if (tx?.timestamp) descriptionParts.push(formatTimestamp(tx.timestamp));

  let accent = "#4a9eff";
  if (type === "ContribCommit" || type === "ContribReveal" || type === "Weather") {
    accent = "#34d399";
  } else if (type === "Coinbase") {
    accent = "#f59e0b";
  } else if (type === "Stake") {
    accent = "#fb923c";
  }

  return {
    kind: "tx",
    title: titleSegments.join(" — "),
    description: descriptionParts.join(" · "),
    imageUrl: `${origin}${imagePath}`,
    shareUrl: `${origin}${sharePath}`,
    spaUrl: `${origin}/#/tx/${encodedHash}`,
    imageAlt: `WRFCoin share card for transaction ${shortHash(hash, 12, 8)}`,
    payload: {
      badge: type.toUpperCase(),
      accent,
      title: shortHash(hash, 14, 10),
      subtitle: amountLabel || "WRFCoin transaction",
      description: descriptionParts.join(" · "),
      primary: blockHeight != null ? `Block #${blockHeight}` : "Pending / external tx",
      secondary: tx?.timestamp ? formatTimestamp(tx.timestamp) : type,
      chips: [
        amountLabel,
        from ? `From ${shortHash(from, 6, 4)}` : null,
        to ? `To ${shortHash(to, 6, 4)}` : null,
      ].filter(Boolean),
      footer: `${type}${blockHeight != null ? ` · Height ${blockHeight}` : ""}`,
    },
  };
}

function renderShareShell(meta) {
  const title = escapeHtml(meta.title);
  const description = escapeHtml(meta.description || "WRFCoin testnet explorer");
  const imageUrl = escapeHtml(meta.imageUrl);
  const shareUrl = escapeHtml(meta.shareUrl);
  const spaUrl = escapeHtml(meta.spaUrl);
  const imageAlt = escapeHtml(meta.imageAlt);

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>${title}</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="${description}">
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="WRFCoin Testnet Explorer">
  <meta property="og:title" content="${title}">
  <meta property="og:description" content="${description}">
  <meta property="og:url" content="${shareUrl}">
  <meta property="og:image" content="${imageUrl}">
  <meta property="og:image:alt" content="${imageAlt}">
  <meta property="og:image:width" content="${OG_IMAGE_SIZE.width}">
  <meta property="og:image:height" content="${OG_IMAGE_SIZE.height}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="${title}">
  <meta name="twitter:description" content="${description}">
  <meta name="twitter:image" content="${imageUrl}">
  <meta name="twitter:image:alt" content="${imageAlt}">
  <link rel="canonical" href="${spaUrl}">
</head>
<body style="margin:0;padding:24px;background:#0f1419;color:#e4e8f0;font:16px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif">
  <main>
    <h1 style="margin:0 0 12px;font-size:24px">${title}</h1>
    <p style="margin:0 0 16px;color:#b8c1d1">${description}</p>
    <p style="margin:0">
      <a href="${spaUrl}" style="color:#4a9eff">Open in explorer</a>
    </p>
  </main>
</body>
</html>`;
}

function h(type, props, ...children) {
  const flatChildren = children.flat().filter((child) => child != null && child !== false);
  return {
    type,
    props: {
      ...(props || {}),
      children:
        flatChildren.length <= 1 ? flatChildren[0] ?? null : flatChildren,
    },
  };
}

function renderChip(label, accent) {
  return h(
    "div",
    {
      style: {
        display: "flex",
        padding: "10px 16px",
        borderRadius: 999,
        border: `1px solid ${accent}`,
        color: "#e4e8f0",
        fontSize: 28,
      },
    },
    label
  );
}

function renderOgImage(payload) {
  const chips = payload.chips.map((chip) => renderChip(chip, payload.accent));

  return h(
    "div",
    {
      style: {
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        justifyContent: "space-between",
        background: "#0f1419",
        color: "#e4e8f0",
        padding: 48,
        fontFamily: "Noto Sans",
      },
    },
    h(
      "div",
      {
        style: {
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
        },
      },
      h(
        "div",
        {
          style: {
            display: "flex",
            padding: "10px 18px",
            borderRadius: 999,
            background: payload.accent,
            color: "#0f1419",
            fontSize: 24,
            fontWeight: 700,
            letterSpacing: 1.5,
          },
        },
        payload.badge
      ),
      h(
        "div",
        {
          style: {
            display: "flex",
            fontSize: 24,
            color: "#8ca2c0",
          },
        },
        "WRFCoin Testnet Explorer"
      )
    ),
    h(
      "div",
      {
        style: {
          display: "flex",
          flexDirection: "column",
          gap: 16,
        },
      },
      h(
        "div",
        {
          style: {
            display: "flex",
            fontSize: 76,
            fontWeight: 800,
            lineHeight: 1.05,
          },
        },
        payload.title
      ),
      h(
        "div",
        {
          style: {
            display: "flex",
            fontSize: 34,
            color: "#d4deef",
          },
        },
        payload.subtitle
      ),
      h(
        "div",
        {
          style: {
            display: "flex",
            fontSize: 28,
            color: "#8ca2c0",
            lineHeight: 1.35,
          },
        },
        payload.description
      )
    ),
    h(
      "div",
      {
        style: {
          display: "flex",
          flexDirection: "column",
          gap: 20,
        },
      },
      h(
        "div",
        {
          style: {
            display: "flex",
            flexWrap: "wrap",
            gap: 14,
          },
        },
        chips
      ),
      h(
        "div",
        {
          style: {
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 24,
            paddingTop: 20,
            borderTop: "1px solid #2a3040",
            fontSize: 24,
            color: "#b8c1d1",
          },
        },
        h(
          "div",
          {
            style: {
              display: "flex",
            },
          },
          payload.primary
        ),
        h(
          "div",
          {
            style: {
              display: "flex",
              color: "#8ca2c0",
            },
          },
          payload.secondary
        ),
        h(
          "div",
          {
            style: {
              display: "flex",
              color: "#8ca2c0",
            },
          },
          payload.footer
        )
      )
    )
  );
}

// `@vercel/og` 1.x ships `dist/index.node.js` as an ESM bundle with two defects
// that only surface when an image is actually rendered (infra#838). Both are
// upstream bugs in 1.0.2 -- which is the LATEST release; there is no fixed
// version to move to -- and both are repairable from here without patching the
// package or writing into node_modules.
//
//   1. esbuild emitted its `__require` shim, which reads
//      `typeof require !== "undefined"`. In an ESM module `require` is not
//      defined, so the first dynamic require throws
//      `Dynamic require of "fs" is not supported`. The bundle also references
//      `__dirname`, which ESM likewise does not define.
//
//   2. The bundled harfbuzzjs (emscripten) locates its wasm with
//      `locateFile("hb.wasm")` -> `scriptDirectory + path`, and derives
//      `scriptDirectory` from `__filename`. With `__filename` undefined,
//      `scriptDirectory` is "" and it opens `./hb.wasm` relative to the
//      process CWD. Worse, `hb.wasm` is NOT in the published @vercel/og
//      tarball at all -- `dist/` ships `yoga.wasm` and `resvg.wasm` only --
//      so no CWD would satisfy it.
//
// The repair: define the three CommonJS globals the bundle expects, pointing
// `__filename`/`__dirname` at the `harfbuzzjs` package directory, which DOES
// ship a real `hb.wasm`. That makes `scriptDirectory` resolve the one asset
// looked up that way. `yoga.wasm`, `resvg.wasm` and the bundled Geist font are
// loaded by a different mechanism and are unaffected -- verified by the render
// itself, which produces a valid PNG (og-image.test.js).
//
// Scope, stated because assigning to `globalThis` deserves it: these are set
// once, lazily, only on the first OG render, and only if not already defined,
// so a future @vercel/og that stops needing them (or a runtime that defines
// them) is left alone. harfbuzzjs is resolved THROUGH @vercel/og's own
// directory rather than ours, so this does not depend on npm hoisting and does
// not require declaring a dependency we do not import.
function prepareVercelOgRuntime() {
  const { createRequire } = require("node:module");
  const path = require("node:path");

  let hbDir;
  try {
    const ogDir = path.dirname(require.resolve("@vercel/og/package.json"));
    hbDir = path.dirname(
      require.resolve("harfbuzzjs/hb.wasm", { paths: [ogDir] })
    );
  } catch {
    // harfbuzzjs moved or vendored its wasm differently. Leave the globals
    // alone and let the import fail loudly rather than half-shimmed.
    return;
  }

  if (typeof globalThis.require === "undefined") {
    globalThis.require = createRequire(path.join(hbDir, "index.js"));
  }
  if (typeof globalThis.__filename === "undefined") {
    globalThis.__filename = path.join(hbDir, "index.js");
  }
  if (typeof globalThis.__dirname === "undefined") {
    globalThis.__dirname = hbDir;
  }
}

async function getImageResponse() {
  if (!imageResponsePromise) {
    prepareVercelOgRuntime();
    imageResponsePromise = import("@vercel/og").then(
      (module) => module.ImageResponse
    );
  }
  return imageResponsePromise;
}

async function generateOgImage(payload) {
  const ImageResponse = await getImageResponse();
  const response = new ImageResponse(renderOgImage(payload), OG_IMAGE_SIZE);
  const buffer = Buffer.from(await response.arrayBuffer());
  return {
    body: buffer,
    contentType: response.headers.get("content-type") || "image/png",
    cacheControl:
      response.headers.get("cache-control") ||
      "public, immutable, no-transform, max-age=31536000",
  };
}

async function pollNode() {
  // /network/info is the canonical status + height source (bare JSON:
  // chain_height, genesis_hash, peer_count, sync_status, ...).
  // /chain/blocks?limit=N returns the latest block summaries inside a
  // LawBook envelope: data = { blocks, chain_height, returned }.
  const [networkInfo, chainBlocks] = await Promise.all([
    fetchNode(`/network/info`),
    fetchNode(`/chain/blocks?limit=20`),
  ]);

  if (networkInfo) {
    cache.networkInfo = networkInfo;
    // Keep chainInfo populated for the overview/UI; /network/info already
    // carries chain_height so we no longer need the old /blockchain route.
    cache.chainInfo = networkInfo;
  }

  const summaries =
    (chainBlocks && Array.isArray(chainBlocks.blocks) ? chainBlocks.blocks : null) ||
    (Array.isArray(chainBlocks) ? chainBlocks : null);

  if (summaries && summaries.length > 0) {
    // /chain/blocks returns summaries in ascending height; show newest first.
    const ordered = [...summaries].sort(
      (a, b) => (getBlockHeight(b) ?? 0) - (getBlockHeight(a) ?? 0)
    );

    // Hydrate the newest blocks to detail (full tx list) so the tx feed and
    // tx-by-hash cache work. Bounded to the top 20 already returned.
    const detailed = await Promise.all(
      ordered.map(async (summary) => {
        const height = getBlockHeight(summary);
        if (height == null) return summary;
        const detail = await fetchNode(`/chain/block/${height}`);
        return detail || summary;
      })
    );

    cache.latestBlocks = detailed;
    cache.latestTxs = detailed.flatMap((block) => {
      const blockHeight = getBlockHeight(block);
      return (block.transactions || []).map((tx) => ({
        ...tx,
        _blockHeight: blockHeight,
        _blockTime: block.timestamp,
      }));
    });
  }

  cache.lastPoll = new Date().toISOString();
}

// ---------------------------------------------------------------------------
// API routes — served under /api so the static UI can fetch them
// ---------------------------------------------------------------------------
app.use((_req, res, next) => {
  res.set(
    "Content-Security-Policy",
    [
      "default-src 'self'",
      "script-src 'self'",
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data:",
      "connect-src 'self'",
      "base-uri 'none'",
      "object-src 'none'",
      "frame-ancestors 'none'",
    ].join("; ")
  );
  next();
});

app.use(express.static(path.join(__dirname, "public")));

app.get("/health", (_req, res) => {
  res.json({ status: "ok", lastPoll: cache.lastPoll });
});

app.get("/api/overview", (_req, res) => {
  res.json({
    chain: cache.chainInfo,
    network: cache.networkInfo,
    lastPoll: cache.lastPoll,
  });
});

app.get("/api/blocks", (_req, res) => {
  res.json(cache.latestBlocks);
});

app.get("/api/blocks/:height", async (req, res) => {
  const height = parseInt(req.params.height, 10);
  if (Number.isNaN(height) || height < 0) {
    return res.status(400).json({ error: "invalid height" });
  }
  const block = await fetchBlock(height);
  if (!block) return res.status(404).json({ error: "block not found" });
  res.json(block);
});

app.get("/api/transactions/:hash", async (req, res) => {
  const { hash } = req.params;
  if (!isValidTxHash(hash)) {
    return res.status(400).json({ error: "invalid transaction hash" });
  }

  const tx = await fetchTransaction(hash);
  if (tx) return res.json(tx);
  res.status(404).json({ error: "transaction not found" });
});

app.get("/api/search", async (req, res) => {
  const q = (req.query.q || "").trim();
  if (!q) return res.status(400).json({ error: "empty query" });

  // If numeric, treat as block height
  if (/^\d+$/.test(q)) {
    const block = await fetchBlock(parseInt(q, 10));
    if (block) return res.json({ type: "block", data: block });
  }

  // Otherwise treat as tx hash (best-effort: cache + optional backend proxy)
  if (!isValidTxHash(q)) {
    return res.status(400).json({ error: "invalid transaction hash" });
  }

  const tx = await fetchTransaction(q);
  if (tx) return res.json({ type: "transaction", data: tx });

  res.status(404).json({ error: "not found" });
});

app.get("/share/block/:height", async (req, res) => {
  const height = parseInt(req.params.height, 10);
  if (Number.isNaN(height) || height < 0) {
    return res.status(400).send("invalid height");
  }

  if (!isBotRequest(req)) {
    return res.redirect(302, `/#/block/${height}`);
  }

  const block = await fetchBlock(height);
  if (!block) return res.status(404).send("block not found");

  res.type("html").send(renderShareShell(buildBlockMeta(block, req)));
});

app.get("/share/tx/:hash", async (req, res) => {
  const { hash } = req.params;
  if (!isValidTxHash(hash)) {
    return res.status(400).send("invalid transaction hash");
  }

  if (!isBotRequest(req)) {
    return res.redirect(302, `/#/tx/${encodePathSegment(hash)}`);
  }

  const tx = await fetchTransaction(hash);
  if (!tx) return res.status(404).send("transaction not found");

  res.type("html").send(renderShareShell(buildTxMeta(tx, req)));
});

app.get("/og/block/:height.png", async (req, res) => {
  const height = parseInt(req.params.height, 10);
  if (Number.isNaN(height) || height < 0) {
    return res.status(400).send("invalid height");
  }

  const cacheKey = `block:${height}`;
  const cached = cache.ogImages.get(cacheKey);
  if (cached) {
    res.set("Content-Type", cached.contentType);
    res.set("Cache-Control", cached.cacheControl);
    return res.send(cached.body);
  }

  const block = await fetchBlock(height);
  if (!block) return res.status(404).send("block not found");

  try {
    const image = await generateOgImage(buildBlockMeta(block, req).payload);
    cache.ogImages.set(cacheKey, image);
    res.set("Content-Type", image.contentType);
    res.set("Cache-Control", image.cacheControl);
    res.send(image.body);
  } catch (error) {
    console.error("failed to render block OG image", error);
    res.status(500).send("image render failed");
  }
});

app.get("/og/tx/:hash.png", async (req, res) => {
  const { hash } = req.params;
  if (!isValidTxHash(hash)) {
    return res.status(400).send("invalid transaction hash");
  }

  const cacheKey = `tx:${hash.toLowerCase()}`;
  const cached = cache.ogImages.get(cacheKey);
  if (cached) {
    res.set("Content-Type", cached.contentType);
    res.set("Cache-Control", cached.cacheControl);
    return res.send(cached.body);
  }

  const tx = await fetchTransaction(hash);
  if (!tx) return res.status(404).send("transaction not found");

  try {
    const image = await generateOgImage(buildTxMeta(tx, req).payload);
    cache.ogImages.set(cacheKey, image);
    res.set("Content-Type", image.contentType);
    res.set("Cache-Control", image.cacheControl);
    res.send(image.body);
  } catch (error) {
    console.error("failed to render tx OG image", error);
    res.status(500).send("image render failed");
  }
});

// SPA fallback — all non-API GET routes serve index.html. Written as a final
// middleware rather than `app.get("*")`: express 5's path-to-regexp rejects a
// bare "*" path at registration time, and this form is valid on both 4 and 5.
// The method guard preserves the get-only semantics: non-GET requests to
// unknown paths still fall through to the default 404.
app.use((req, res, next) => {
  if (req.method !== "GET" && req.method !== "HEAD") return next();
  res.sendFile(path.join(__dirname, "public", "index.html"));
});

// ---------------------------------------------------------------------------
// Start (only when run directly; requiring the module for tests is side-effect free)
// ---------------------------------------------------------------------------
function start() {
  app.listen(PORT, "0.0.0.0", () => {
    console.log(`WRFCoin Explorer listening on :${PORT}`);
    // Initial poll + recurring
    pollNode();
    setInterval(pollNode, POLL_INTERVAL);
  });
}

if (require.main === module) {
  start();
}

// Exported for unit tests — pure normalization/unwrap helpers.
module.exports = {
  app,
  start,
  cache,
  pollNode,
  unwrapEnvelope,
  getBlockHeight,
  getBlockHash,
  getTransactionHash,
  getTxTypeLabel,
  isValidTxHash,
};
