#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { createRequire } = require('module');

const startedAt = new Date();

const config = {
  mainApiBaseUrl: process.env.MAIN_API_BASE_URL || 'http://127.0.0.1:4001',
  mainApiWsUrl: process.env.MAIN_API_WS_URL || 'ws://127.0.0.1:4001/ws',
  computeApiBaseUrl: process.env.COMPUTE_API_BASE_URL || 'http://127.0.0.1:6003',
  core4ApiBaseUrl:
    process.env.CORE4_API_BASE_URL || process.env.CORE4_API_URL || 'http://127.0.0.1:8556',
  backendRepoDir: path.resolve(
    process.env.BACKEND_REPO_DIR || path.join(process.cwd(), 'backend')
  ),
  mobileRepoDir: path.resolve(
    process.env.MOBILE_REPO_DIR || path.join(process.cwd(), 'mobile')
  ),
  core4RepoDir: path.resolve(
    process.env.CORE4_REPO_DIR || path.join(process.cwd(), 'core4')
  ),
  infraRepoDir: path.resolve(
    process.env.INFRA_REPO_DIR || path.join(__dirname, '..')
  ),
  reportDir: path.resolve(
    process.env.REPORT_DIR || path.join(process.cwd(), 'artifacts', 'launch-contract-suite')
  ),
  requestTimeoutMs: Number.parseInt(process.env.CONTRACT_REQUEST_TIMEOUT_MS || '10000', 10),
  wsTimeoutMs: Number.parseInt(process.env.CONTRACT_WS_TIMEOUT_MS || '20000', 10),
  taskStatusPollIntervalMs: Number.parseInt(
    process.env.CONTRACT_TASK_STATUS_POLL_INTERVAL_MS || '1000',
    10
  ),
  taskStatusTimeoutMs: Number.parseInt(
    process.env.CONTRACT_TASK_STATUS_TIMEOUT_MS || '12000',
    10
  ),
};

const fixturePaths = {
  mobileWalletAuth: path.join(
    config.mobileRepoDir,
    'contract-fixtures',
    'launch-wallet-auth.json'
  ),
  backendAuthWebsocket: path.join(
    config.backendRepoDir,
    'contract-fixtures',
    'launch-auth-websocket.json'
  ),
  core4Realtime: path.join(
    config.core4RepoDir,
    'contract-fixtures',
    'launch-realtime-event-source.json'
  ),
  computeAgent: path.join(
    config.infraRepoDir,
    'infra',
    'compute-agent',
    'contract-fixtures',
    'launch-task-client.json'
  ),
};

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function formatError(error) {
  if (error instanceof Error) {
    let message = error.message;
    if (error.cause) {
      const causeMessage =
        error.cause instanceof Error ? error.cause.message : String(error.cause);
      if (causeMessage && !message.includes(causeMessage)) {
        message = `${message}: ${causeMessage}`;
      }
    }
    return message;
  }

  return String(error);
}

function loadBackendDependency(moduleName) {
  const backendPackagePath = path.join(config.backendRepoDir, 'package.json');
  if (!fs.existsSync(backendPackagePath)) {
    throw new Error(
      `backend repo not found at ${config.backendRepoDir}; set BACKEND_REPO_DIR to a checkout of wrfcoin/backend`
    );
  }

  const backendRequire = createRequire(backendPackagePath);

  try {
    return backendRequire(moduleName);
  } catch (error) {
    const message = formatError(error);
    throw new Error(
      `backend dependency "${moduleName}" is unavailable from ${config.backendRepoDir}; run "npm ci" in the backend repo. Original error: ${message}`
    );
  }
}

function loadFixture(label, fixturePath) {
  if (!fs.existsSync(fixturePath)) {
    throw new Error(`fixture "${label}" not found at ${fixturePath}`);
  }

  try {
    return JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
  } catch (error) {
    throw new Error(`fixture "${label}" is invalid JSON: ${formatError(error)}`);
  }
}

function redactToken(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return value;
  }

  if (value.length <= 10) {
    return `${value.slice(0, 3)}...`;
  }

  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function safeJson(value) {
  try {
    return JSON.stringify(value, null, 2);
  } catch (error) {
    return JSON.stringify({
      serializationError: error instanceof Error ? error.message : String(error),
    });
  }
}

function expect(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

function describeHttpFailure(method, url, status, body) {
  return `${method} ${url} returned ${status}; body=${safeJson(body)}`;
}

function requireFields(value, fields, label) {
  expect(value && typeof value === 'object', `${label} missing object body`);

  for (const field of fields) {
    expect(field in value, `${label} missing field "${field}": ${safeJson(value)}`);
  }
}

function normalizeBaseUrl(baseUrl) {
  return baseUrl.replace(/\/$/, '');
}

function usesFixtureCore4Stub() {
  const baseUrl = normalizeBaseUrl(config.core4ApiBaseUrl);
  return baseUrl === 'http://127.0.0.1:18556';
}

function core4Headers() {
  const headers = {};
  if (process.env.WRFCOIN_OPERATOR_TOKEN) {
    headers.authorization = `Bearer ${process.env.WRFCOIN_OPERATOR_TOKEN}`;
  }
  return headers;
}

async function httpJson(method, url, body, headers = {}) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.requestTimeoutMs);

  try {
    const response = await fetch(url, {
      method,
      headers: {
        'content-type': 'application/json',
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: controller.signal,
    });

    const text = await response.text();
    let json = null;

    if (text.length > 0) {
      try {
        json = JSON.parse(text);
      } catch (error) {
        throw new Error(`${method} ${url} returned non-JSON body: ${text.slice(0, 400)}`);
      }
    }

    return { response, json, text };
  } catch (error) {
    if (error && error.name === 'AbortError') {
      throw new Error(`${method} ${url} timed out after ${config.requestTimeoutMs}ms`);
    }
    throw new Error(`${method} ${url} failed: ${formatError(error)}`);
  } finally {
    clearTimeout(timeout);
  }
}

function withTimeout(promise, ms, label) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);

    promise
      .then(value => {
        clearTimeout(timer);
        resolve(value);
      })
      .catch(error => {
        clearTimeout(timer);
        reject(error);
      });
  });
}

function writeArtifact(relativePath, content) {
  const outputPath = path.join(config.reportDir, relativePath);
  ensureDir(path.dirname(outputPath));
  fs.writeFileSync(outputPath, content);
}

function writeJsonArtifact(relativePath, value) {
  writeArtifact(relativePath, `${safeJson(value)}\n`);
}

function maskAuthPayload(payload) {
  if (!payload || typeof payload !== 'object') {
    return payload;
  }

  const copy = { ...payload };
  if (typeof copy.jwt === 'string') {
    copy.jwt = redactToken(copy.jwt);
  }
  if (typeof copy.refreshToken === 'string') {
    copy.refreshToken = redactToken(copy.refreshToken);
  }
  return copy;
}

function decodeJwtClaims(token) {
  const jsonwebtoken = loadBackendDependency('jsonwebtoken');
  const decoded = jsonwebtoken.decode(token);
  expect(decoded && typeof decoded === 'object', 'jwt could not be decoded');
  return decoded;
}

function buildWalletLoginMessage(fixture, nonce) {
  return fixture.walletLogin.messageTemplate.replace('{nonce}', nonce);
}

async function createWalletSession(fixtures) {
  const { Wallet } = loadBackendDependency('ethers');
  const wallet = Wallet.createRandom();
  const address = wallet.address.toLowerCase();

  const addressRegex = new RegExp(fixtures.mobile.walletLogin.request.addressFormat);
  expect(addressRegex.test(address), `generated wallet does not match fixture regex: ${address}`);

  const nonce = `${Date.now()}`;
  const message = buildWalletLoginMessage(fixtures.mobile, nonce);
  const signature = await wallet.signMessage(message);

  expect(
    signature.startsWith(fixtures.mobile.walletLogin.request.signaturePrefix),
    `signature missing expected prefix ${fixtures.mobile.walletLogin.request.signaturePrefix}`
  );

  const loginUrl = `${normalizeBaseUrl(config.mainApiBaseUrl)}${fixtures.mobile.walletLogin.endpoint}`;
  const loginBody = { address, signature, nonce };
  const login = await httpJson('POST', loginUrl, loginBody);

  expect(
    login.response.status === 200,
    describeHttpFailure('POST', loginUrl, login.response.status, login.json)
  );
  expect(login.json && login.json.success === true, `wallet-login missing success=true: ${safeJson(login.json)}`);
  requireFields(login.json, ['success', 'data', 'timestamp'], 'wallet-login response');
  requireFields(
    login.json.data,
    fixtures.mobile.walletLogin.successResponse.requiredDataFields,
    'wallet-login data'
  );
  expect(
    typeof login.json.data.expiresIn === 'number' &&
      login.json.data.expiresIn >= fixtures.mobile.walletLogin.successResponse.minimumExpiresInSeconds,
    `wallet-login expiresIn invalid: ${safeJson(maskAuthPayload(login.json.data))}`
  );

  const claims = decodeJwtClaims(login.json.data.jwt);
  for (const claim of fixtures.backend.jwt.requiredClaims) {
    expect(claims[claim] !== undefined, `jwt missing claim "${claim}": ${safeJson(claims)}`);
  }
  expect(claims.iss === fixtures.backend.jwt.issuer, `jwt issuer mismatch: ${safeJson(claims)}`);
  expect(claims.aud === fixtures.backend.jwt.audience, `jwt audience mismatch: ${safeJson(claims)}`);

  const refreshUrl = `${normalizeBaseUrl(config.mainApiBaseUrl)}${fixtures.mobile.refresh.endpoint}`;
  const refresh = await httpJson('POST', refreshUrl, {
    refreshToken: login.json.data.refreshToken,
  });

  expect(
    refresh.response.status === 200,
    describeHttpFailure('POST', refreshUrl, refresh.response.status, refresh.json)
  );
  expect(refresh.json && refresh.json.success === true, `refresh missing success=true: ${safeJson(refresh.json)}`);
  requireFields(
    refresh.json.data,
    fixtures.mobile.refresh.successResponse.requiredDataFields,
    'refresh data'
  );
  expect(
    refresh.json.data.refreshToken !== login.json.data.refreshToken,
    'refresh token did not rotate on /api/auth/refresh'
  );

  const reusedRefresh = await httpJson('POST', refreshUrl, {
    refreshToken: login.json.data.refreshToken,
  });
  expect(reusedRefresh.response.status === 401, `reused refresh token should fail with 401, got ${reusedRefresh.response.status}`);

  const tamperedLogin = await httpJson('POST', loginUrl, {
    address,
    signature,
    nonce: `${nonce}-tampered`,
  });
  expect(tamperedLogin.response.status === 401, `tampered wallet-login should fail with 401, got ${tamperedLogin.response.status}`);

  return {
    address,
    loginRequest: loginBody,
    loginResponse: maskAuthPayload(login.json),
    refreshResponse: maskAuthPayload(refresh.json),
    reusedRefreshResponse: reusedRefresh.json,
    tamperedLoginResponse: tamperedLogin.json,
    jwt: login.json.data.jwt,
  };
}

async function openWebSocket(url, options = {}) {
  const WebSocket = loadBackendDependency('ws');
  const ws = new WebSocket(url, options);

  await withTimeout(
    new Promise((resolve, reject) => {
      ws.once('open', resolve);
      ws.once('error', reject);
    }),
    config.wsTimeoutMs,
    `websocket open ${url}`
  );

  return ws;
}

async function waitForSocketEvent(ws, matcher, label, transcript) {
  return await withTimeout(
    new Promise((resolve, reject) => {
      const onMessage = raw => {
        let message;
        try {
          message = JSON.parse(raw.toString());
        } catch (error) {
          cleanup();
          reject(new Error(`websocket returned non-JSON payload: ${raw.toString()}`));
          return;
        }

        transcript.push(message);
        if (matcher(message)) {
          cleanup();
          resolve(message);
        }
      };

      const onClose = (code, reason) => {
        cleanup();
        reject(
          new Error(
            `${label} closed before expected event; code=${code}; reason=${reason.toString()}`
          )
        );
      };

      const onError = error => {
        cleanup();
        reject(error);
      };

      function cleanup() {
        ws.off('message', onMessage);
        ws.off('close', onClose);
        ws.off('error', onError);
      }

      ws.on('message', onMessage);
      ws.on('close', onClose);
      ws.on('error', onError);
    }),
    config.wsTimeoutMs,
    label
  );
}

async function checkAuthenticatedWebSocketContract(fixtures) {
  const session = await createWalletSession(fixtures);
  const transcript = [];
  const wsPath = fixtures.backend.websocket.path;

  const publicSocket = await openWebSocket(`${normalizeBaseUrl(config.mainApiWsUrl)}`);
  try {
    const connected = await waitForSocketEvent(
      publicSocket,
      message => message.event === 'connected',
      'public websocket connected event',
      transcript
    );
    expect(
      connected.payload?.authenticated === false,
      `public websocket should be unauthenticated: ${safeJson(connected)}`
    );

    publicSocket.send(JSON.stringify({ action: 'subscribe', channel: 'blocks' }));
    await waitForSocketEvent(
      publicSocket,
      message => message.event === 'subscribed' && message.payload?.channel === 'blocks',
      'public blocks subscription',
      transcript
    );
  } finally {
    publicSocket.terminate();
  }

  const invalidSocketUrl = `${normalizeBaseUrl(config.mainApiWsUrl)}?token=invalid-token`;
  const invalidSocket = loadBackendDependency('ws');
  const invalidResult = await withTimeout(
    new Promise(resolve => {
      const ws = new invalidSocket(invalidSocketUrl);
      ws.on('close', (code, reason) => {
        resolve({ code, reason: reason.toString() });
      });
      ws.on('error', () => {
        // A close should follow; ignore error noise from ws.
      });
    }),
    config.wsTimeoutMs,
    'invalid websocket close'
  );
  expect(
    invalidResult.code === fixtures.backend.websocket.invalidTokenCloseCode,
    `invalid token close code mismatch: ${safeJson(invalidResult)}`
  );

  const authenticatedChannel = fixtures.backend.websocket.authenticatedChannelTemplate.replace(
    '{address}',
    session.address
  );
  const mismatchedChannel = fixtures.backend.websocket.authenticatedChannelTemplate.replace(
    '{address}',
    '0x3333333333333333333333333333333333333333'
  );
  const authenticatedSocket = await openWebSocket(
    `${normalizeBaseUrl(config.mainApiWsUrl)}?token=${encodeURIComponent(session.jwt)}`
  );

  try {
    const connected = await waitForSocketEvent(
      authenticatedSocket,
      message => message.event === 'connected',
      'authenticated websocket connected event',
      transcript
    );
    expect(
      connected.payload?.authenticated === fixtures.backend.websocket.expectedConnectedAuthenticated,
      `authenticated websocket did not set connected.authenticated=true: ${safeJson(connected)}`
    );

    authenticatedSocket.send(
      JSON.stringify({
        action: 'subscribe',
        channels: [authenticatedChannel, mismatchedChannel],
      })
    );

    const [, denied] = await Promise.all([
      waitForSocketEvent(
        authenticatedSocket,
        message =>
          message.event === 'subscribed' &&
          message.payload?.channel === authenticatedChannel,
        'authenticated wallet subscription',
        transcript
      ),
      waitForSocketEvent(
        authenticatedSocket,
        message =>
          message.event === fixtures.backend.websocket.unauthorizedEvent &&
          message.payload?.channel === mismatchedChannel,
        'mismatched wallet denial',
        transcript
      ),
    ]);

    expect(
      denied.payload?.reason === fixtures.backend.websocket.unauthorizedReason,
      `unexpected wallet denial payload: ${safeJson(denied)}`
    );
  } finally {
    authenticatedSocket.terminate();
  }

  return {
    wsPath,
    address: session.address,
    invalidClose: invalidResult,
    transcript,
  };
}

async function checkCore4RealtimeCompatibility(fixtures) {
  const transcript = [];
  const ws = await openWebSocket(normalizeBaseUrl(config.mainApiWsUrl));

  try {
    await waitForSocketEvent(
      ws,
      message => message.event === 'connected',
      'core4 websocket connected event',
      transcript
    );

    ws.send(JSON.stringify({ action: 'subscribe', channel: fixtures.core4.expectedWebSocket.channel }));

    await waitForSocketEvent(
      ws,
      message =>
        message.event === 'subscribed' &&
        message.payload?.channel === fixtures.core4.expectedWebSocket.channel,
      'core4 blocks subscription',
      transcript
    );

    const baselineChainState = await fetchCore4ChainState();
    const baselineHeight = baselineChainState.height;
    if (!usesFixtureCore4Stub()) {
      expect(
        process.env.WRFCOIN_OPERATOR_TOKEN,
        `WRFCOIN_OPERATOR_TOKEN is required to validate live Core4 websocket events against ${config.core4ApiBaseUrl}`
      );
    }

    const mineAttempt = process.env.WRFCOIN_OPERATOR_TOKEN ? await mineCore4Block() : null;

    let blockEvent;
    try {
      blockEvent = await waitForSocketEvent(
        ws,
        message =>
          message.channel === fixtures.core4.expectedWebSocket.channel &&
          message.event === fixtures.core4.expectedWebSocket.event &&
          typeof message.payload?.height === 'number' &&
          (!mineAttempt || message.payload.height > baselineHeight),
        'core4 block event',
        transcript
      );
    } catch (error) {
      if (mineAttempt) {
        throw new Error(
          `core4 block event timed out after live mine; baselineHeight=${baselineHeight}; mineAttempt=${safeJson(mineAttempt)}; ${formatError(error)}`
        );
      }
      throw error;
    }

    const eventHeight = blockEvent.payload?.height;
    expect(
      typeof eventHeight === 'number' && Number.isFinite(eventHeight),
      `core4 block event missing numeric height: ${safeJson(blockEvent)}`
    );

    const upstreamBlock = await fetchCanonicalCore4Block(eventHeight, mineAttempt);
    expect(
      blockEvent.payload?.height === upstreamBlock.height,
      `core4 block height mismatch: event=${safeJson(blockEvent)} upstream=${safeJson(upstreamBlock)}`
    );
    if (typeof blockEvent.payload?.hash === 'string' && blockEvent.payload.hash.length > 0) {
      expect(
        blockEvent.payload.hash === upstreamBlock.hash,
        `core4 block hash mismatch: event=${safeJson(blockEvent)} upstream=${safeJson(upstreamBlock)}`
      );
    }

    return {
      wsUrl: config.mainApiWsUrl,
      core4ApiBaseUrl: config.core4ApiBaseUrl,
      baselineChainState,
      baselineHeight,
      mineAttempt,
      transcript,
      blockEvent,
      upstreamBlock,
    };
  } finally {
    ws.terminate();
  }
}

async function mineCore4Block() {
  const url = `${normalizeBaseUrl(config.core4ApiBaseUrl)}/blocks/mine`;
  const response = await httpJson(
    'POST',
    url,
    {
      miner_address: '0x0000000000000000000000000000000000000001',
    },
    core4Headers()
  );

  expect(
    response.response.status === 200 || response.response.status === 201,
    describeHttpFailure('POST', url, response.response.status, response.json)
  );

  return {
    url,
    status: response.response.status,
    height: extractNumericField(unwrapCore4Block(response.json), ['height', 'blockHeight']),
    hash: extractStringField(unwrapCore4Block(response.json), ['hash', 'tip']),
    body: response.json,
  };
}

async function fetchCore4ChainState() {
  const endpoints = [
    '/blockchain',
    '/chain/height',
    '/api/blockchain/status',
    '/status',
    '/transactions/contributions/status',
  ];

  for (const endpoint of endpoints) {
    const url = `${normalizeBaseUrl(config.core4ApiBaseUrl)}${endpoint}`;
    try {
      const response = await httpJson('GET', url, undefined, core4Headers());
      if (!response.response.ok) {
        continue;
      }

      const unwrapped = unwrapCore4Block(response.json);
      const height = extractNumericField(unwrapped, ['height', 'blockHeight', 'currentHeight']);
      if (height !== null) {
        return {
          height,
          hash: extractStringField(unwrapped, ['hash', 'tip']),
          raw: response.json,
          url,
        };
      }
    } catch {
      // try next endpoint
    }
  }

  throw new Error(`unable to fetch latest core4 height from ${config.core4ApiBaseUrl}`);
}

async function fetchCanonicalCore4Block(height, minedBlock = null) {
  if (minedBlock && minedBlock.height === height && minedBlock.hash) {
    return {
      height: minedBlock.height,
      hash: minedBlock.hash,
      raw: minedBlock.body,
      url: minedBlock.url,
      source: 'blocks/mine',
    };
  }

  const endpoints = [
    `/blocks/${height}`,
    `/api/blockchain/blocks/${height}`,
    `/api/blockchain/block/${height}`,
  ];

  for (const endpoint of endpoints) {
    const url = `${normalizeBaseUrl(config.core4ApiBaseUrl)}${endpoint}`;
    try {
      const response = await httpJson('GET', url);
      if (!response.response.ok) {
        continue;
      }

      const block = unwrapCore4Block(response.json);
      const normalizedHeight = extractNumericField(block, ['height', 'blockHeight']);
      const normalizedHash = extractStringField(block, ['hash']);

      expect(
        normalizedHeight !== null,
        `core4 block response missing numeric height: ${safeJson(response.json)}`
      );
      expect(
        normalizedHash,
        `core4 block response missing hash: ${safeJson(response.json)}`
      );

      return {
        height: normalizedHeight,
        hash: normalizedHash,
        raw: response.json,
        url,
        source: endpoint,
      };
    } catch {
      // try next endpoint
    }
  }

  const chainState = await fetchCore4ChainState();
  if (chainState.height === height && chainState.hash) {
    return {
      height: chainState.height,
      hash: chainState.hash,
      raw: chainState.raw,
      url: chainState.url,
      source: 'blockchain-tip',
    };
  }

  throw new Error(
    `unable to fetch canonical core4 block ${height} from ${config.core4ApiBaseUrl}`
  );
}

function unwrapCore4Block(value) {
  if (!value || typeof value !== 'object') {
    return {};
  }

  if (value.data && typeof value.data === 'object') {
    return value.data;
  }

  return value;
}

function extractNumericField(value, keys) {
  if (!value || typeof value !== 'object') {
    return null;
  }

  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === 'number' && Number.isFinite(candidate)) {
      return candidate;
    }
    if (typeof candidate === 'string' && candidate.length > 0) {
      const parsed = Number(candidate);
      if (Number.isFinite(parsed)) {
        return parsed;
      }
    }
  }

  return null;
}

function extractStringField(value, keys) {
  if (!value || typeof value !== 'object') {
    return null;
  }

  for (const key of keys) {
    const candidate = value[key];
    if (typeof candidate === 'string' && candidate.length > 0) {
      return candidate;
    }
  }

  return null;
}

async function pollTaskStatus(taskId) {
  const deadline = Date.now() + config.taskStatusTimeoutMs;
  let lastStatus = null;

  while (Date.now() < deadline) {
    const statusUrl = `${normalizeBaseUrl(config.computeApiBaseUrl)}/api/compute/tasks/${encodeURIComponent(taskId)}/status`;
    const status = await httpJson('GET', statusUrl);
    if (status.response.status === 200 && status.json?.success === true) {
      lastStatus = status.json;
      if (status.json.status === 'running' || status.json.status === 'completed') {
        return { statusUrl, status };
      }
    }
    await new Promise(resolve => setTimeout(resolve, config.taskStatusPollIntervalMs));
  }

  throw new Error(`task status for ${taskId} did not reach running/completed within timeout: ${safeJson(lastStatus)}`);
}

async function checkComputeLifecycle(fixtures) {
  const submissionFixture = fixtures.compute.mainApiSubmission;
  const submitUrl = `${normalizeBaseUrl(config.mainApiBaseUrl)}${submissionFixture.endpoint}`;
  const submittedTask = await httpJson('POST', submitUrl, {
    taskType: submissionFixture.taskType,
    payload: submissionFixture.payload,
    priority: 5,
  });

  expect(
    submittedTask.response.status === 200,
    describeHttpFailure('POST', submitUrl, submittedTask.response.status, submittedTask.json)
  );
  expect(
    submittedTask.json?.success === true,
    `main_api compute submission missing success=true: ${safeJson(submittedTask.json)}`
  );
  expect(
    submittedTask.json?.data?.status === submissionFixture.expectedQueuedStatus,
    `main_api compute status mismatch: ${safeJson(submittedTask.json)}`
  );
  expect(
    typeof submittedTask.json?.data?.taskId === 'string',
    `main_api compute taskId missing: ${safeJson(submittedTask.json)}`
  );

  const registerUrl = `${normalizeBaseUrl(config.computeApiBaseUrl)}${fixtures.compute.register.endpoint}`;
  const register = await httpJson('POST', registerUrl, {
    walletAddress: '0x1111111111111111111111111111111111111111',
    preferences: fixtures.compute.register.preferences,
  });
  expect(
    register.response.status === 200,
    describeHttpFailure('POST', registerUrl, register.response.status, register.json)
  );
  requireFields(register.json, fixtures.compute.register.requiredResponseFields, 'compute register response');

  const nodeId = register.json.nodeId;
  const heartbeatUrl = `${normalizeBaseUrl(config.computeApiBaseUrl)}${fixtures.compute.heartbeat.endpoint}`;
  const heartbeat = await httpJson('POST', heartbeatUrl, {
    nodeId,
    status: fixtures.compute.heartbeat.status,
  });
  expect(
    heartbeat.response.status === 200,
    describeHttpFailure('POST', heartbeatUrl, heartbeat.response.status, heartbeat.json)
  );
  requireFields(heartbeat.json, fixtures.compute.heartbeat.requiredResponseFields, 'compute heartbeat response');

  const pollUrl = `${normalizeBaseUrl(config.computeApiBaseUrl)}${fixtures.compute.poll.endpointTemplate.replace('{nodeId}', encodeURIComponent(nodeId))}`;
  const poll = await httpJson('GET', pollUrl);
  expect(
    poll.response.status === 200,
    describeHttpFailure('GET', pollUrl, poll.response.status, poll.json)
  );
  requireFields(poll.json, fixtures.compute.poll.requiredResponseFields, 'compute poll response');
  expect(
    Array.isArray(poll.json.availableTasks) &&
      poll.json.availableTasks.some(task => task.taskId === submissionFixture.taskType),
    `compute available tasks do not include canonical task type ${submissionFixture.taskType}: ${safeJson(poll.json)}`
  );

  const startUrl = `${normalizeBaseUrl(config.computeApiBaseUrl)}${fixtures.compute.start.endpoint}`;
  const start = await httpJson('POST', startUrl, {
    nodeId,
    taskType: fixtures.compute.start.taskType,
  });
  expect(
    start.response.status === 200,
    describeHttpFailure('POST', startUrl, start.response.status, start.json)
  );
  requireFields(start.json, fixtures.compute.start.requiredResponseFields, 'compute start response');

  const statusResult = await pollTaskStatus(start.json.taskId);
  expect(
    fixtures.compute.status.requiredStates.includes(statusResult.status.json.status),
    `compute task status outside fixture-required states: ${safeJson(statusResult.status.json)}`
  );

  return {
    submittedTaskId: submittedTask.json.data.taskId,
    queuedStatus: submittedTask.json.data.status,
    nodeId,
    availableTaskCount: poll.json.availableTasks.length,
    sharedTaskType: submissionFixture.taskType,
    startedTaskId: start.json.taskId,
    taskStatus: statusResult.status.json,
    note: 'Main API submission and compute-agent lifecycle share the same canonical task type, but production services are still separate surfaces.',
  };
}

async function runCheck(name, fn) {
  const checkStartedAt = Date.now();
  try {
    const details = await fn();
    writeJsonArtifact(
      path.join('checks', `${name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}.json`),
      details
    );
    return {
      name,
      status: 'passed',
      durationMs: Date.now() - checkStartedAt,
      details,
    };
  } catch (error) {
    const failure = {
      error: formatError(error),
    };
    writeJsonArtifact(
      path.join('checks', `${name.replace(/[^a-z0-9]+/gi, '-').toLowerCase()}.json`),
      failure
    );
    return {
      name,
      status: 'failed',
      durationMs: Date.now() - checkStartedAt,
      error: failure.error,
    };
  }
}

function formatPassDetails(name, details) {
  if (name === 'wallet login + refresh fixture contract') {
    return `wallet=${details.address} refresh-rotated=true`;
  }

  if (name === 'websocket auth fixture contract') {
    return `wallet=${details.address} invalid-close=${details.invalidClose.code}`;
  }

  if (name === 'core4 realtime fixture contract') {
    const trigger = details.mineAttempt ? ` mined-status=${details.mineAttempt.status}` : '';
    const source = details.upstreamBlock?.source ? ` source=${details.upstreamBlock.source}` : '';
    return `height=${details.blockEvent.payload.height} hash=${details.blockEvent.payload.hash || 'n/a'}${trigger}${source}`;
  }

  if (name === 'compute task vocabulary + lifecycle contract') {
    return `queued=${details.queuedStatus} taskType=${details.sharedTaskType} nodeId=${details.nodeId} state=${details.taskStatus.status}`;
  }

  return safeJson(details);
}

function buildSummary(results) {
  const passed = results.filter(result => result.status === 'passed');
  const failed = results.filter(result => result.status === 'failed');

  const lines = [
    `Launch Contract Suite: ${failed.length === 0 ? 'PASS' : 'FAIL'}`,
    `Started: ${startedAt.toISOString()}`,
    `Main API HTTP: ${config.mainApiBaseUrl}`,
    `Main API WS: ${config.mainApiWsUrl}`,
    `Compute API: ${config.computeApiBaseUrl}`,
    `Core4 API: ${config.core4ApiBaseUrl}`,
    `Backend repo: ${config.backendRepoDir}`,
    `Mobile repo: ${config.mobileRepoDir}`,
    `Core4 repo: ${config.core4RepoDir}`,
    '',
  ];

  for (const result of results) {
    if (result.status === 'passed') {
      lines.push(
        `[PASS] ${result.name} (${result.durationMs}ms) ${formatPassDetails(result.name, result.details)}`
      );
    } else {
      lines.push(`[FAIL] ${result.name} (${result.durationMs}ms) ${result.error}`);
    }
  }

  lines.push('');
  lines.push(`Summary: ${passed.length} passed, ${failed.length} failed`);
  lines.push(`Artifacts: ${path.join(config.reportDir, 'summary.json')}`);
  return lines.join('\n');
}

function writeArtifacts(fixtures, results, summaryText) {
  ensureDir(config.reportDir);

  writeJsonArtifact('fixtures.json', {
    paths: fixturePaths,
    fixtures,
  });

  const payload = {
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    config: {
      mainApiBaseUrl: config.mainApiBaseUrl,
      mainApiWsUrl: config.mainApiWsUrl,
      computeApiBaseUrl: config.computeApiBaseUrl,
      core4ApiBaseUrl: config.core4ApiBaseUrl,
      backendRepoDir: config.backendRepoDir,
      mobileRepoDir: config.mobileRepoDir,
      core4RepoDir: config.core4RepoDir,
      infraRepoDir: config.infraRepoDir,
      reportDir: config.reportDir,
    },
    fixturePaths,
    results,
    pass: results.every(result => result.status === 'passed'),
  };

  writeJsonArtifact('summary.json', payload);
  writeArtifact('summary.md', `${summaryText}\n`);
}

async function main() {
  const fixtures = {
    mobile: loadFixture('mobile-wallet-auth', fixturePaths.mobileWalletAuth),
    backend: loadFixture('backend-auth-websocket', fixturePaths.backendAuthWebsocket),
    core4: loadFixture('core4-realtime-event-source', fixturePaths.core4Realtime),
    compute: loadFixture('compute-agent-task-client', fixturePaths.computeAgent),
  };

  const results = [];
  results.push(
    await runCheck('wallet login + refresh fixture contract', () =>
      createWalletSession(fixtures)
    )
  );
  results.push(
    await runCheck('websocket auth fixture contract', () =>
      checkAuthenticatedWebSocketContract(fixtures)
    )
  );
  results.push(
    await runCheck('core4 realtime fixture contract', () =>
      checkCore4RealtimeCompatibility(fixtures)
    )
  );
  results.push(
    await runCheck('compute task vocabulary + lifecycle contract', () =>
      checkComputeLifecycle(fixtures)
    )
  );

  const summaryText = buildSummary(results);
  writeArtifacts(fixtures, results, summaryText);
  process.stdout.write(`${summaryText}\n`);
  process.exitCode = results.some(result => result.status === 'failed') ? 1 : 0;
}

main().catch(error => {
  ensureDir(config.reportDir);
  writeJsonArtifact('summary.json', {
    startedAt: startedAt.toISOString(),
    finishedAt: new Date().toISOString(),
    config: {
      mainApiBaseUrl: config.mainApiBaseUrl,
      mainApiWsUrl: config.mainApiWsUrl,
      computeApiBaseUrl: config.computeApiBaseUrl,
      core4ApiBaseUrl: config.core4ApiBaseUrl,
      backendRepoDir: config.backendRepoDir,
      mobileRepoDir: config.mobileRepoDir,
      core4RepoDir: config.core4RepoDir,
      infraRepoDir: config.infraRepoDir,
      reportDir: config.reportDir,
    },
    error: formatError(error),
    pass: false,
  });
  process.stderr.write(`Launch Contract Suite failed: ${formatError(error)}\n`);
  process.exitCode = 1;
});
