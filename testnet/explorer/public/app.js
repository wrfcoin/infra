// ---------------------------------------------------------------------------
// Client-side router — hash-based for deep links
// ---------------------------------------------------------------------------
const $ = (sel) => document.querySelector(sel);
const app = $("#app");

function navigate(hash) {
  window.location.hash = hash;
}

function route() {
  const hash = window.location.hash.slice(1) || "/";
  const parts = hash.split("/").filter(Boolean);

  if (parts[0] === "block" && parts[1]) {
    renderBlockDetail(decodeRoutePart(parts[1]));
  } else if (parts[0] === "tx" && parts[1]) {
    renderTxDetail(decodeRoutePart(parts[1]));
  } else {
    renderHome();
  }
}

window.addEventListener("hashchange", route);

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------
async function api(path) {
  const res = await fetch(path);
  if (!res.ok) throw new Error(res.statusText);
  return res.json();
}

function short(hash) {
  const value = hash == null ? "" : String(hash);
  if (!value || value.length < 16) return value || "—";
  return value.slice(0, 8) + "..." + value.slice(-6);
}

function escapeHtml(value) {
  return String(value ?? "—").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}

function display(value, fallback = "—") {
  return escapeHtml(value == null || value === "" ? fallback : value);
}

function shortDisplay(value) {
  return escapeHtml(short(value));
}

function pathSegment(value) {
  return encodeURIComponent(value == null ? "" : String(value)).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

function decodeRoutePart(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function txBadge(tx) {
  const t = String(tx.type || tx.tx_type || "").toLowerCase();
  if (t.includes("weather") || t.includes("publish")) return '<span class="badge badge-weather">weather</span>';
  if (t.includes("transfer") || t.includes("send")) return '<span class="badge badge-transfer">transfer</span>';
  if (t.includes("stake")) return '<span class="badge badge-stake">stake</span>';
  return `<span class="badge badge-other">${display(t || "tx")}</span>`;
}

function timeAgo(ts) {
  if (!ts) return "—";
  const d = typeof ts === "number" ? (ts > 1e12 ? ts : ts * 1000) : Date.parse(ts);
  if (Number.isNaN(d)) return "—";
  const s = Math.floor((Date.now() - d) / 1000);
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  return Math.floor(s / 86400) + "d ago";
}

function fmtNumber(n) {
  if (n == null || n === "") return "—";
  const value = Number(n);
  return Number.isFinite(value) ? value.toLocaleString() : display(n);
}

function explorerShareUrl(kind, value) {
  return new URL(`/share/${kind}/${pathSegment(value)}`, window.location.origin).toString();
}

async function copyToClipboard(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return true;
  }
  return false;
}

async function shareExplorerLink(kind, value, label) {
  const url = explorerShareUrl(kind, value);
  try {
    if (navigator.share) {
      await navigator.share({ title: label, url });
      return;
    }
    const copied = await copyToClipboard(url);
    alert(copied ? `Share link copied:\n${url}` : `Share this link:\n${url}`);
  } catch (err) {
    if (err && err.name === "AbortError") return;
    alert(`Share failed. Link:\n${url}`);
  }
}

async function copyExplorerLink(kind, value) {
  const url = explorerShareUrl(kind, value);
  const copied = await copyToClipboard(url);
  alert(copied ? `Copied:\n${url}` : `Copy this link:\n${url}`);
}

function bindDetailActions(kind, value, label) {
  const shareButton = $("#shareAction");
  const copyButton = $("#copyShareAction");
  if (shareButton) {
    shareButton.addEventListener("click", () => shareExplorerLink(kind, value, label));
  }
  if (copyButton) {
    copyButton.addEventListener("click", () => copyExplorerLink(kind, value));
  }
}

// ---------------------------------------------------------------------------
// Home view
// ---------------------------------------------------------------------------
let pollTimer = null;

async function renderHome() {
  try {
    const [overview, blocks] = await Promise.all([
      api("/api/overview"),
      api("/api/blocks"),
    ]);

    const chain = overview.chain || {};
    const net = overview.network || {};
    const height = chain.height ?? chain.chain_height ?? chain.block_height ?? "—";
    const peers = net.peer_count ?? net.peers ?? net.connected_peers ?? "—";
    const pending = chain.pending_transactions ?? chain.pending_txs ?? chain.mempool_size ?? "—";

    // Update header status
    const dot = $("#statusDot");
    const txt = $("#statusText");
    if (overview.lastPoll) {
      dot.className = "status-dot";
      txt.textContent = "synced " + timeAgo(overview.lastPoll);
    } else {
      dot.className = "status-dot offline";
      txt.textContent = "offline";
    }

    // Collect all txs from blocks for the tx table
    const allTxs = [];
    for (const b of blocks) {
      const bh = b.height ?? b.index;
      for (const tx of (b.transactions || [])) {
        allTxs.push({ ...tx, _blockHeight: bh, _blockTime: b.timestamp });
      }
    }

    app.innerHTML = `
      <div class="overview">
        <div class="card"><div class="label">Block Height</div><div class="value">${fmtNumber(height)}</div></div>
        <div class="card"><div class="label">Peers</div><div class="value">${fmtNumber(peers)}</div></div>
        <div class="card"><div class="label">Pending Txs</div><div class="value">${fmtNumber(pending)}</div></div>
        <div class="card"><div class="label">Blocks Cached</div><div class="value">${blocks.length}</div></div>
      </div>

      <div class="section">
        <h2>Latest Blocks</h2>
        <table>
          <thead><tr><th>Height</th><th>Hash</th><th>Txs</th><th>Time</th></tr></thead>
          <tbody>
            ${blocks.slice(0, 20).map(b => {
              const h = b.height ?? b.index;
              const hash = b.hash || b.block_hash || "";
              const txCount = (b.transactions || []).length;
              return `<tr>
                <td><a href="#/block/${pathSegment(h)}">${fmtNumber(h)}</a></td>
                <td class="mono"><a href="#/block/${pathSegment(h)}" class="hash">${shortDisplay(hash)}</a></td>
                <td>${txCount}</td>
                <td>${timeAgo(b.timestamp)}</td>
              </tr>`;
            }).join("")}
          </tbody>
        </table>
      </div>

      <div class="section">
        <h2>Recent Transactions</h2>
        ${allTxs.length === 0
          ? '<div class="card" style="text-align:center;color:var(--muted)">No transactions in recent blocks</div>'
          : `<table>
          <thead><tr><th>Hash</th><th>Type</th><th>Block</th><th>From</th><th>To</th></tr></thead>
          <tbody>
            ${allTxs.slice(0, 30).map(tx => {
              const hash = tx.hash || tx.tx_hash || tx.id || "";
              return `<tr>
                <td class="mono"><a href="#/tx/${pathSegment(hash)}" class="hash">${shortDisplay(hash)}</a></td>
                <td>${txBadge(tx)}</td>
                <td><a href="#/block/${pathSegment(tx._blockHeight)}">${fmtNumber(tx._blockHeight)}</a></td>
                <td class="mono hash">${shortDisplay(tx.from || tx.sender || "")}</td>
                <td class="mono hash">${shortDisplay(tx.to || tx.recipient || "")}</td>
              </tr>`;
            }).join("")}
          </tbody>
        </table>`}
      </div>
    `;
  } catch (err) {
    app.innerHTML = `<div class="loading">
      <p>Unable to connect to node</p>
      <p style="font-size:0.8rem;color:var(--muted);margin-top:0.5rem">${display(err.message)}</p>
    </div>`;
  }

  // Auto-refresh every 10s on home page
  clearInterval(pollTimer);
  pollTimer = setInterval(() => {
    if ((window.location.hash || "#/") === "#/" || window.location.hash === "") {
      renderHome();
    }
  }, 10000);
}

// ---------------------------------------------------------------------------
// Block detail
// ---------------------------------------------------------------------------
async function renderBlockDetail(height) {
  clearInterval(pollTimer);
  app.innerHTML = '<div class="loading">Loading block...</div>';

  try {
    const block = await api(`/api/blocks/${pathSegment(height)}`);
    const h = block.height ?? block.index;
    const hash = block.hash || block.block_hash || "—";
    const prevHash = block.previous_hash || block.prev_hash || "—";
    const txs = block.transactions || [];

    app.innerHTML = `
      <div class="detail">
        <div class="detail-header">
          <div>
            <a class="back-link" href="#/">&larr; Back to overview</a>
            <h2>Block #${fmtNumber(h)}</h2>
          </div>
          <div class="detail-actions">
            <button id="shareAction" class="action-button" type="button">Share card</button>
            <button id="copyShareAction" class="action-button secondary" type="button">Copy share URL</button>
          </div>
        </div>
        <div class="detail-grid">
          <div class="label">Height</div><div class="val">${fmtNumber(h)}</div>
          <div class="label">Hash</div><div class="val mono">${display(hash)}</div>
          <div class="label">Previous Hash</div><div class="val mono">${display(prevHash)}</div>
          <div class="label">Timestamp</div><div class="val">${display(block.timestamp)} (${timeAgo(block.timestamp)})</div>
          <div class="label">Transactions</div><div class="val">${txs.length}</div>
          <div class="label">Nonce</div><div class="val mono">${display(block.nonce)}</div>
          <div class="label">Difficulty</div><div class="val">${display(block.difficulty)}</div>
          <div class="label">Validator</div><div class="val mono">${display(block.validator || block.miner)}</div>
        </div>
        <p class="action-note">Shared links use <span class="mono">/share/block/${display(h)}</span> so bots receive OG metadata and browsers bounce back into the SPA.</p>

        ${txs.length > 0 ? `
        <h2 style="margin-top:1.5rem">Transactions in Block</h2>
        <table>
          <thead><tr><th>Hash</th><th>Type</th><th>From</th><th>To</th><th>Amount</th></tr></thead>
          <tbody>
            ${txs.map(tx => {
              const txHash = tx.hash || tx.tx_hash || tx.id || "";
              return `<tr>
                <td class="mono"><a href="#/tx/${pathSegment(txHash)}" class="hash">${shortDisplay(txHash)}</a></td>
                <td>${txBadge(tx)}</td>
                <td class="mono hash">${shortDisplay(tx.from || tx.sender || "")}</td>
                <td class="mono hash">${shortDisplay(tx.to || tx.recipient || "")}</td>
                <td>${display(tx.amount ?? tx.value)}</td>
              </tr>`;
            }).join("")}
          </tbody>
        </table>` : ""}
      </div>
    `;
    bindDetailActions("block", h, `WRFCoin Block #${h}`);
  } catch {
    app.innerHTML = '<div class="loading">Block not found</div>';
  }
}

// ---------------------------------------------------------------------------
// Transaction detail — with weather-native view
// ---------------------------------------------------------------------------
async function renderTxDetail(hash) {
  clearInterval(pollTimer);
  app.innerHTML = '<div class="loading">Loading transaction...</div>';

  try {
    const tx = await api(`/api/transactions/${pathSegment(hash)}`);
    const txHash = tx.hash || tx.tx_hash || tx.id || hash;
    const type = String(tx.type || tx.tx_type || "").toLowerCase();
    const isWeather = type.includes("weather") || type.includes("publish") || tx.weather_data || tx.station_id;

    let weatherHtml = "";
    if (isWeather) {
      const wd = tx.weather_data || tx.data || tx;
      weatherHtml = `
        <div class="weather-card">
          <h3>Weather Data Submission</h3>
          <div class="weather-grid">
            <div class="weather-metric"><div class="wlabel">Station ID</div><div class="wval">${display(wd.station_id || tx.station_id)}</div></div>
            <div class="weather-metric"><div class="wlabel">Temperature</div><div class="wval">${wd.temperature != null ? `${display(wd.temperature)} °C` : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Humidity</div><div class="wval">${wd.humidity != null ? `${display(wd.humidity)} %` : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Pressure</div><div class="wval">${wd.pressure != null ? `${display(wd.pressure)} hPa` : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Wind Speed</div><div class="wval">${wd.wind_speed != null ? `${display(wd.wind_speed)} m/s` : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Wind Direction</div><div class="wval">${wd.wind_direction != null ? `${display(wd.wind_direction)}°` : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Data Quality</div><div class="wval">${display(wd.quality_score ?? wd.data_quality)}</div></div>
            <div class="weather-metric"><div class="wlabel">PoP Verified</div><div class="wval">${tx.pop_verified != null ? (tx.pop_verified ? "Yes" : "No") : "—"}</div></div>
            <div class="weather-metric"><div class="wlabel">Location</div><div class="wval">${wd.latitude != null ? `${display(wd.latitude)}, ${display(wd.longitude)}` : display(wd.location)}</div></div>
          </div>
        </div>`;
    }

    app.innerHTML = `
      <div class="detail">
        <div class="detail-header">
          <div>
            <a class="back-link" href="#/">&larr; Back to overview</a>
            <h2>Transaction ${txBadge(tx)}</h2>
          </div>
          <div class="detail-actions">
            <button id="shareAction" class="action-button" type="button">Share card</button>
            <button id="copyShareAction" class="action-button secondary" type="button">Copy share URL</button>
          </div>
        </div>
        <div class="detail-grid">
          <div class="label">Hash</div><div class="val mono">${display(txHash)}</div>
          <div class="label">Type</div><div class="val">${display(tx.type || tx.tx_type)}</div>
          <div class="label">Block</div><div class="val"><a href="#/block/${pathSegment(tx.block_height ?? tx.block ?? "")}">${fmtNumber(tx.block_height ?? tx.block ?? "—")}</a></div>
          <div class="label">From</div><div class="val mono">${display(tx.from || tx.sender)}</div>
          <div class="label">To</div><div class="val mono">${display(tx.to || tx.recipient)}</div>
          <div class="label">Amount</div><div class="val">${display(tx.amount ?? tx.value)} WRF</div>
          <div class="label">Fee</div><div class="val">${display(tx.fee)}</div>
          <div class="label">Timestamp</div><div class="val">${display(tx.timestamp)} (${timeAgo(tx.timestamp)})</div>
          <div class="label">Signature</div><div class="val mono" style="font-size:0.75rem">${display(tx.signature)}</div>
        </div>
        <p class="action-note">Shared links use <span class="mono">/share/tx/${display(txHash)}</span> so crawlers see rich metadata while human visitors return to <span class="mono">/#/tx/...</span>.</p>
        ${weatherHtml}
      </div>
    `;
    bindDetailActions("tx", txHash, `WRFCoin Transaction ${txHash}`);
  } catch {
    app.innerHTML = '<div class="loading">Transaction not found</div>';
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------
async function doSearch() {
  const q = $("#searchInput").value.trim();
  if (!q) return;

  try {
    const result = await api(`/api/search?q=${encodeURIComponent(q)}`);
    if (result.type === "block") {
      const h = result.data.height ?? result.data.index;
      navigate(`/block/${h}`);
    } else if (result.type === "transaction") {
      const hash = result.data.hash || result.data.tx_hash || result.data.id;
      navigate(`/tx/${hash}`);
    }
  } catch {
    alert("Not found: " + q);
  }
}

$("#searchInput").addEventListener("keydown", (e) => {
  if (e.key === "Enter") doSearch();
});
$("#searchButton").addEventListener("click", doSearch);

// Initial route
route();
