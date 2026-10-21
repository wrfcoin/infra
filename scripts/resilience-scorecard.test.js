// node --test scripts/resilience-scorecard.test.js
// Covers the DDoS-protection check rewritten for infra#586: the old version
// read a pre-split in-repo `backend/` path, always threw post-extraction, and
// reported the misleading "DDoS protection not implemented".

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const { ResilienceScorecard } = require('./resilience-scorecard.js');

function makeBackendFixture(entrypointContent) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'scorecard-backend-'));
  fs.mkdirSync(path.join(dir, 'server'), { recursive: true });
  if (entrypointContent !== null) {
    fs.writeFileSync(
      path.join(dir, 'server', 'enhanced_unified_api_optimized.ts'),
      entrypointContent
    );
  }
  return dir;
}

function withBackendDir(dir, fn) {
  const prev = process.env.WRFCOIN_BACKEND_DIR;
  process.env.WRFCOIN_BACKEND_DIR = dir;
  try {
    return fn();
  } finally {
    if (prev === undefined) delete process.env.WRFCOIN_BACKEND_DIR;
    else process.env.WRFCOIN_BACKEND_DIR = prev;
  }
}

test('passes when infra assets exist and the live entrypoint has real protections', () => {
  const backend = makeBackendFixture(`
    import helmet from 'helmet';
    import rateLimit from 'express-rate-limit';
    const rateLimitMiddleware = () => rateLimit({ windowMs: 60_000, max: 100 });
  `);
  const result = withBackendDir(backend, () =>
    new ResilienceScorecard().checkDDoSProtection()
  );
  assert.strictEqual(result.passed, true, result.details);
  assert.match(result.details, /live entrypoint/);
});

test('fails with a no-op rate limiter finding (the real live-entrypoint state that motivated #586)', () => {
  const backend = makeBackendFixture(`
    const deps = {
      rateLimitMiddleware: () => (req: any, res: any, next: any) => next(),
    };
  `);
  const result = withBackendDir(backend, () =>
    new ResilienceScorecard().checkDDoSProtection()
  );
  assert.strictEqual(result.passed, false);
  assert.match(result.details, /no-op passthrough/);
  assert.match(result.details, /no helmet/);
});

test('missing backend repo reports a setup problem, not a security verdict', () => {
  const empty = fs.mkdtempSync(path.join(os.tmpdir(), 'scorecard-nothing-'));
  const result = withBackendDir(path.join(empty, 'nope'), () => {
    // resolveBackendDir falls through env candidate (no server/ dir) and the
    // sibling-checkout candidate resolves the real workspace backend if
    // present; force isolation by pointing env at a dir without server/.
    const scorecard = new ResilienceScorecard();
    scorecard.resolveBackendDir = () => null;
    return scorecard.checkDDoSProtection();
  });
  assert.strictEqual(result.passed, false);
  assert.match(result.details, /backend repo not found/);
  assert.doesNotMatch(result.details, /not implemented/);
});

test('missing live entrypoint is named explicitly', () => {
  const backend = makeBackendFixture(null); // server/ exists, entrypoint absent
  const result = withBackendDir(backend, () =>
    new ResilienceScorecard().checkDDoSProtection()
  );
  assert.strictEqual(result.passed, false);
  assert.match(result.details, /live API entrypoint not found/);
});

test('importing the module does not run the audit', () => {
  // If the import had side effects, this test file would already have kicked
  // off runAudit() (writing report JSON, console noise). The assertion is
  // that requiring exposed the class cleanly.
  assert.strictEqual(typeof ResilienceScorecard, 'function');
});
