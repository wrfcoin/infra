const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = Number.parseInt(process.env.PORT || '8080', 10);
const BACKEND_API_URL = process.env.BACKEND_API_URL || 'http://wrfcoin-backend:4001';
// FAUCET_NODE_URL is what the compose stack sets (docker-compose.testnet.yml);
// CORE4_API_URL remains as a legacy fallback (#602).
const CORE4_API_URL =
  process.env.FAUCET_NODE_URL ||
  process.env.CORE4_API_URL ||
  'http://wrfcoin-node:8556';
const REDIS_URL = process.env.REDIS_URL || '';
const DISCORD_OAUTH_URL = process.env.DISCORD_OAUTH_URL || '';
const DISCORD_CLIENT_ID = process.env.DISCORD_CLIENT_ID || '';
const DISCORD_INVITE_URL = process.env.DISCORD_INVITE_URL || 'https://discord.gg/wrfcoin-testnet';
const EXPLORER_URL = process.env.EXPLORER_URL || 'http://localhost:8081';
const FAUCET_LABEL = process.env.FAUCET_LABEL || 'WRFCoin Faucet';

const STATIC_DIR = __dirname;
const MIME_TYPES = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.svg': 'image/svg+xml; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
};

const CONFIG = {
  backendApiUrl: BACKEND_API_URL,
  core4ApiUrl: CORE4_API_URL,
  discordOauthUrl: DISCORD_OAUTH_URL,
  discordClientId: DISCORD_CLIENT_ID,
  discordInviteUrl: DISCORD_INVITE_URL,
  explorerUrl: EXPLORER_URL,
  faucetLabel: FAUCET_LABEL,
  faucetPath: '/faucet',
  redisConfigured: Boolean(REDIS_URL),
};

function sendJson(res, status, payload) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(payload));
}

function sendText(res, status, text, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store',
  });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk)));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function proxyApi(req, res, targetUrl) {
  const body = req.method === 'GET' || req.method === 'HEAD' ? undefined : await readBody(req);
  const upstreamHeaders = new Headers();

  for (const [key, value] of Object.entries(req.headers)) {
    if (value == null) {
      continue;
    }
    if (Array.isArray(value)) {
      upstreamHeaders.set(key, value.join(', '));
    } else {
      upstreamHeaders.set(key, value);
    }
  }

  upstreamHeaders.delete('host');
  upstreamHeaders.delete('content-length');
  upstreamHeaders.set('x-forwarded-host', req.headers.host || `localhost:${PORT}`);
  upstreamHeaders.set('x-forwarded-proto', 'http');

  const upstream = await fetch(targetUrl, {
    method: req.method,
    headers: upstreamHeaders,
    body,
    redirect: 'manual',
  });

  const responseHeaders = {};
  upstream.headers.forEach((value, key) => {
    responseHeaders[key] = value;
  });

  res.writeHead(upstream.status, responseHeaders);
  if (upstream.body) {
    const buffer = Buffer.from(await upstream.arrayBuffer());
    res.end(buffer);
  } else {
    res.end();
  }
}

function renderIndex() {
  const templatePath = path.join(STATIC_DIR, 'index.html');
  const html = fs.readFileSync(templatePath, 'utf8');
  return html.replace('__FAUCET_CONFIG__', JSON.stringify(CONFIG));
}

async function serveStatic(req, res, pathname) {
  const cleanPath = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.normalize(path.join(STATIC_DIR, cleanPath));

  if (!filePath.startsWith(STATIC_DIR)) {
    sendText(res, 403, 'Forbidden');
    return;
  }

  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    sendText(res, 404, 'Not found');
    return;
  }

  const ext = path.extname(filePath).toLowerCase();
  res.writeHead(200, {
    'Content-Type': MIME_TYPES[ext] || 'application/octet-stream',
    'Cache-Control': ext === '.html' ? 'no-store' : 'public, max-age=3600',
  });
  fs.createReadStream(filePath).pipe(res);
}

const server = http.createServer(async (req, res) => {
  const requestUrl = new URL(req.url || '/', 'http://localhost');
  const { pathname } = requestUrl;

  try {
    if (pathname === '/health') {
      sendJson(res, 200, {
        status: 'ok',
        service: 'wrfcoin-faucet',
        backendApiUrl: BACKEND_API_URL,
        core4ApiUrl: CORE4_API_URL,
        redisConfigured: Boolean(REDIS_URL),
        discordConfigured: Boolean(DISCORD_CLIENT_ID),
      });
      return;
    }

    if (pathname === '/' || pathname === '/faucet') {
      res.writeHead(200, {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-store',
      });
      res.end(renderIndex());
      return;
    }

    if (pathname === '/faucet/') {
      res.writeHead(302, { Location: '/faucet' });
      res.end();
      return;
    }

    if (pathname.startsWith('/api/')) {
      const upstreamUrl = new URL(req.url || '/', BACKEND_API_URL);
      await proxyApi(req, res, upstreamUrl);
      return;
    }

    await serveStatic(req, res, pathname);
  } catch (error) {
    sendJson(res, 502, {
      error: 'BAD_GATEWAY',
      message: error instanceof Error ? error.message : 'Faucet proxy error',
    });
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`wrfcoin-faucet listening on ${PORT}`);
});
