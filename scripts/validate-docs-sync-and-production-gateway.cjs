#!/usr/bin/env node

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const DEFAULT_MODE = 'all';
const VALID_MODES = new Set(['all', 'docs-sync', 'gateway-check']);
const DEFAULT_ARTIFACT_DIR = 'artifacts/docs-gateway-check';
const DEFAULT_MANIFEST_PATH = 'infra/docs/docs-sync-manifest.json';

const FORBIDDEN_TOKEN_RULES = [
  { token: 'localhost', regex: /localhost/i },
  { token: '127.0.0.1', regex: /127\.0\.0\.1/ },
  { token: 'mock', regex: /(^|[^a-z])mock([^a-z]|$)/i },
  { token: 'stub', regex: /(^|[^a-z])stub([^a-z]|$)/i },
  { token: 'test', regex: /(^|[^a-z])test([^a-z]|$)/i },
];

const GATEWAY_TARGETS = [
  {
    key: 'main_api_http',
    aliases: ['MAIN_API_BASE_URL', 'WRFCOIN_API_BASE_URL'],
    protocols: ['https:'],
    safeValue: 'https://prod-gateway-main-api.wrfcoin.invalid',
  },
  {
    key: 'main_api_ws',
    aliases: ['MAIN_API_WS_URL', 'WRFCOIN_WS_URL'],
    protocols: ['wss:'],
    safeValue: 'wss://prod-gateway-main-api.wrfcoin.invalid/ws',
  },
  {
    key: 'compute_api_http',
    aliases: ['COMPUTE_API_BASE_URL', 'WRFCOIN_COMPUTE_BASE_URL'],
    protocols: ['https:'],
    safeValue: 'https://prod-gateway-compute-api.wrfcoin.invalid',
  },
];

function printUsage() {
  console.log(
    [
      'Usage: node scripts/validate-docs-sync-and-production-gateway.cjs [options]',
      '',
      'Options:',
      '  --mode <all|docs-sync|gateway-check>   Validation mode (default: all)',
      '  --safe-mode                             Inject deterministic production-like URLs when unset',
      '  --repo-root <path>                      Root directory containing repo checkouts (default: cwd)',
      '  --manifest <path>                       Docs manifest file (default: infra/docs/docs-sync-manifest.json)',
      '  --artifact-dir <path>                   Artifact output directory (default: artifacts/docs-gateway-check)',
      '  --help                                  Show usage',
    ].join('\n')
  );
}

function parseArgs(argv) {
  const options = {
    mode: DEFAULT_MODE,
    safeMode: false,
    repoRoot: process.cwd(),
    manifestPath: DEFAULT_MANIFEST_PATH,
    artifactDir: DEFAULT_ARTIFACT_DIR,
  };

  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === '--help' || arg === '-h') {
      options.help = true;
      return options;
    }

    if (arg === '--safe-mode') {
      options.safeMode = true;
      continue;
    }

    if (arg === '--mode') {
      options.mode = argv[i + 1];
      i += 1;
      continue;
    }

    if (arg === '--repo-root') {
      options.repoRoot = argv[i + 1];
      i += 1;
      continue;
    }

    if (arg === '--manifest') {
      options.manifestPath = argv[i + 1];
      i += 1;
      continue;
    }

    if (arg === '--artifact-dir') {
      options.artifactDir = argv[i + 1];
      i += 1;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }

  if (!VALID_MODES.has(options.mode)) {
    throw new Error(`Invalid --mode \"${options.mode}\". Expected one of: ${Array.from(VALID_MODES).join(', ')}`);
  }

  if (!options.repoRoot) {
    throw new Error('--repo-root cannot be empty');
  }

  if (!options.manifestPath) {
    throw new Error('--manifest cannot be empty');
  }

  if (!options.artifactDir) {
    throw new Error('--artifact-dir cannot be empty');
  }

  options.repoRoot = path.resolve(options.repoRoot);
  options.manifestPath = path.resolve(options.manifestPath);
  options.artifactDir = path.resolve(options.artifactDir);

  return options;
}

function sha256OfFile(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function safeRelative(root, target) {
  try {
    return path.relative(root, target);
  } catch (_error) {
    return target;
  }
}

function renderStatus(ok) {
  return ok ? 'PASS' : 'FAIL';
}

function checkForbiddenTokens(rawValue) {
  const matches = [];
  for (const rule of FORBIDDEN_TOKEN_RULES) {
    if (rule.regex.test(rawValue)) {
      matches.push(rule.token);
    }
  }
  return matches;
}

function truncate(str, maxLen) {
  if (typeof str !== 'string') {
    return '';
  }
  if (str.length <= maxLen) {
    return str;
  }
  return `${str.slice(0, Math.max(0, maxLen - 3))}...`;
}

function maskUrl(rawValue) {
  try {
    const parsed = new URL(rawValue);
    const pathFragment = parsed.pathname === '/' ? '' : parsed.pathname;
    return `${parsed.protocol}//${parsed.host}${pathFragment}`;
  } catch (_error) {
    return truncate(rawValue, 60);
  }
}

function loadManifest(manifestPath) {
  if (!fs.existsSync(manifestPath)) {
    throw new Error(`docs manifest not found: ${manifestPath}`);
  }

  const raw = fs.readFileSync(manifestPath, 'utf8');
  let manifest;
  try {
    manifest = JSON.parse(raw);
  } catch (error) {
    throw new Error(`docs manifest is invalid JSON: ${error.message}`);
  }

  if (!manifest || typeof manifest !== 'object' || typeof manifest.repos !== 'object') {
    throw new Error('docs manifest must be an object with a "repos" key');
  }

  return manifest;
}

function resolveRepoPath(repoRoot, repoName, repoConfig, requiredFiles) {
  const candidates = Array.isArray(repoConfig.path_candidates) && repoConfig.path_candidates.length > 0
    ? repoConfig.path_candidates
    : [repoConfig.path || repoName];

  let selected = null;
  let selectedScore = -1;

  for (const candidate of candidates) {
    const resolved = path.resolve(repoRoot, candidate);
    if (!fs.existsSync(resolved)) {
      continue;
    }

    let score = 0;
    for (const requiredFile of requiredFiles) {
      if (fs.existsSync(path.join(resolved, requiredFile))) {
        score += 1;
      }
    }

    if (score > selectedScore) {
      selected = { candidate, resolved, score };
      selectedScore = score;
    }

    if (requiredFiles.length > 0 && score === requiredFiles.length) {
      break;
    }
  }

  if (!selected) {
    return {
      resolvedPath: path.resolve(repoRoot, candidates[0]),
      selectedCandidate: candidates[0],
      exists: false,
    };
  }

  return {
    resolvedPath: selected.resolved,
    selectedCandidate: selected.candidate,
    exists: true,
  };
}

function runDocsSyncCheck(options) {
  const manifest = loadManifest(options.manifestPath);
  const repoEntries = Object.entries(manifest.repos);

  if (repoEntries.length === 0) {
    throw new Error('docs manifest contains zero repositories');
  }

  const results = [];
  const fingerprintRows = [];
  let failed = false;

  for (const [repoName, repoConfig] of repoEntries) {
    const requiredFiles = Array.isArray(repoConfig.required_files) ? repoConfig.required_files : [];
    const requiredAnyOf = Array.isArray(repoConfig.required_any_of) ? repoConfig.required_any_of : [];
    const repoPathResolution = resolveRepoPath(options.repoRoot, repoName, repoConfig, requiredFiles);
    const repoPath = repoPathResolution.resolvedPath;

    const result = {
      repo: repoName,
      path: repoPath,
      selectedPathCandidate: repoPathResolution.selectedCandidate,
      exists: repoPathResolution.exists && fs.existsSync(repoPath),
      requiredFiles,
      requiredAnyOf,
      checkedFiles: [],
      missingFiles: [],
      missingAnyOfGroups: [],
      fileFingerprints: [],
      status: 'PASS',
      failureReason: null,
    };

    if (!result.exists || !fs.statSync(repoPath).isDirectory()) {
      result.status = 'FAIL';
      result.failureReason = 'repository checkout missing';
      failed = true;
      results.push(result);
      continue;
    }

    for (const relativeFile of requiredFiles) {
      const absoluteFile = path.join(repoPath, relativeFile);
      const exists = fs.existsSync(absoluteFile);
      result.checkedFiles.push(relativeFile);

      if (!exists) {
        result.missingFiles.push(relativeFile);
        continue;
      }

      if (fs.statSync(absoluteFile).isFile()) {
        const fileHash = sha256OfFile(absoluteFile);
        result.fileFingerprints.push({
          file: relativeFile,
          sha256: fileHash,
          short: fileHash.slice(0, 12),
        });
        fingerprintRows.push(`${repoName}:${relativeFile}:${fileHash}`);
      }
    }

    for (const anyOfGroup of requiredAnyOf) {
      if (!Array.isArray(anyOfGroup) || anyOfGroup.length === 0) {
        continue;
      }

      const found = anyOfGroup.some(relativePath => fs.existsSync(path.join(repoPath, relativePath)));
      if (!found) {
        result.missingAnyOfGroups.push(anyOfGroup);
      }
    }

    if (result.missingFiles.length > 0 || result.missingAnyOfGroups.length > 0) {
      result.status = 'FAIL';
      if (result.missingFiles.length > 0) {
        result.failureReason = 'missing required documentation files';
      } else {
        result.failureReason = 'missing required any-of documentation group';
      }
      failed = true;
    }

    results.push(result);
  }

  fingerprintRows.sort();
  const syncFingerprint = crypto
    .createHash('sha256')
    .update(fingerprintRows.join('\n'))
    .digest('hex');

  return {
    status: failed ? 'FAIL' : 'PASS',
    manifestPath: options.manifestPath,
    repoRoot: options.repoRoot,
    repoCount: results.length,
    syncFingerprint,
    repos: results,
  };
}

function resolveGatewayValue(target, safeMode, injectedDefaults) {
  for (const alias of target.aliases) {
    const value = process.env[alias];
    if (typeof value === 'string' && value.trim().length > 0) {
      return { envName: alias, value: value.trim(), injected: false };
    }
  }

  if (safeMode) {
    const primaryAlias = target.aliases[0];
    process.env[primaryAlias] = target.safeValue;
    injectedDefaults.push({ envName: primaryAlias, value: target.safeValue });
    return { envName: primaryAlias, value: target.safeValue, injected: true };
  }

  return null;
}

function validateGatewayTarget(target, resolvedValue) {
  if (!resolvedValue) {
    return {
      status: 'FAIL',
      reason: `missing required env var (${target.aliases.join(' or ')})`,
      valuePreview: null,
    };
  }

  const { value } = resolvedValue;
  let parsed;
  try {
    parsed = new URL(value);
  } catch (error) {
    return {
      status: 'FAIL',
      reason: `invalid URL: ${error.message}`,
      valuePreview: maskUrl(value),
    };
  }

  if (!target.protocols.includes(parsed.protocol)) {
    return {
      status: 'FAIL',
      reason: `invalid protocol ${parsed.protocol}; expected ${target.protocols.join(' or ')}`,
      valuePreview: maskUrl(value),
    };
  }

  if (parsed.username || parsed.password) {
    return {
      status: 'FAIL',
      reason: 'URL must not embed credentials',
      valuePreview: maskUrl(value),
    };
  }

  const forbiddenMatches = checkForbiddenTokens(value);
  if (forbiddenMatches.length > 0) {
    return {
      status: 'FAIL',
      reason: `forbidden token(s) detected: ${forbiddenMatches.join(', ')}`,
      valuePreview: maskUrl(value),
    };
  }

  return {
    status: 'PASS',
    reason: 'value passed strict production gateway policy',
    valuePreview: maskUrl(value),
  };
}

function runGatewayCheck(options) {
  const injectedDefaults = [];
  const targetResults = [];
  let failed = false;

  for (const target of GATEWAY_TARGETS) {
    const resolved = resolveGatewayValue(target, options.safeMode, injectedDefaults);
    const validation = validateGatewayTarget(target, resolved);

    const result = {
      target: target.key,
      aliases: target.aliases,
      protocols: target.protocols,
      envName: resolved ? resolved.envName : null,
      injectedBySafeMode: Boolean(resolved && resolved.injected),
      status: validation.status,
      reason: validation.reason,
      valuePreview: validation.valuePreview,
    };

    if (result.status !== 'PASS') {
      failed = true;
    }

    targetResults.push(result);
  }

  return {
    status: failed ? 'FAIL' : 'PASS',
    safeMode: options.safeMode,
    injectedDefaults,
    targets: targetResults,
  };
}

function renderDocsConsole(docsResult, workspaceRoot) {
  console.log('');
  console.log('=== docs-sync ===');
  console.log(`status: ${docsResult.status}`);
  console.log(`manifest: ${safeRelative(workspaceRoot, docsResult.manifestPath)}`);
  console.log(`repo-root: ${docsResult.repoRoot}`);
  console.log(`sync-fingerprint: ${docsResult.syncFingerprint.slice(0, 16)}...`);

  for (const repoResult of docsResult.repos) {
    const repoLine = `${renderStatus(repoResult.status === 'PASS')} ${repoResult.repo}`;
    const pathLine = safeRelative(workspaceRoot, repoResult.path);

    if (repoResult.status === 'PASS') {
      console.log(`  ${repoLine} (${pathLine})`);
      continue;
    }

    console.log(`  ${repoLine} (${pathLine})`);
    if (!repoResult.exists) {
      console.log('    reason: repository checkout missing');
      continue;
    }
    if (repoResult.missingFiles.length > 0) {
      console.log(`    missing files: ${repoResult.missingFiles.join(', ')}`);
    }
    if (repoResult.missingAnyOfGroups.length > 0) {
      for (const group of repoResult.missingAnyOfGroups) {
        console.log(`    missing any-of group: [${group.join(' | ')}]`);
      }
    }
  }
}

function renderGatewayConsole(gatewayResult) {
  console.log('');
  console.log('=== gateway-check ===');
  console.log(`status: ${gatewayResult.status}`);
  console.log(`safe-mode: ${gatewayResult.safeMode ? 'enabled' : 'disabled'}`);

  for (const targetResult of gatewayResult.targets) {
    const line = `${renderStatus(targetResult.status === 'PASS')} ${targetResult.target}`;
    const source = targetResult.envName ? ` via ${targetResult.envName}` : '';
    const injected = targetResult.injectedBySafeMode ? ' (safe-mode default)' : '';
    console.log(`  ${line}${source}${injected}`);
    console.log(`    reason: ${targetResult.reason}`);
    if (targetResult.valuePreview) {
      console.log(`    value: ${targetResult.valuePreview}`);
    }
  }
}

function buildMarkdownSummary(summary, workspaceRoot) {
  const lines = [];

  lines.push('# Docs Sync + Production Gateway Check');
  lines.push('');
  lines.push(`- Status: **${summary.status}**`);
  lines.push(`- Mode: \`${summary.mode}\``);
  lines.push(`- Safe mode: \`${summary.safeMode}\``);
  lines.push(`- Started: ${summary.startedAt}`);
  lines.push(`- Finished: ${summary.finishedAt}`);

  if (summary.docsSync) {
    lines.push('');
    lines.push('## Docs Sync');
    lines.push(`- Status: **${summary.docsSync.status}**`);
    lines.push(`- Manifest: \`${safeRelative(workspaceRoot, summary.docsSync.manifestPath)}\``);
    lines.push(`- Sync fingerprint: \`${summary.docsSync.syncFingerprint.slice(0, 24)}\`...`);

    for (const repoResult of summary.docsSync.repos) {
      lines.push(
        `- ${repoResult.status === 'PASS' ? 'PASS' : 'FAIL'} ${repoResult.repo} (${safeRelative(
          workspaceRoot,
          repoResult.path
        )})`
      );
      if (repoResult.missingFiles.length > 0) {
        lines.push(`  - Missing files: ${repoResult.missingFiles.join(', ')}`);
      }
      if (repoResult.missingAnyOfGroups.length > 0) {
        lines.push(
          `  - Missing any-of groups: ${repoResult.missingAnyOfGroups
            .map(group => `[${group.join(' | ')}]`)
            .join(', ')}`
        );
      }
      if (!repoResult.exists) {
        lines.push('  - Reason: repository checkout missing');
      }
    }
  }

  if (summary.gatewayCheck) {
    lines.push('');
    lines.push('## Production Gateway Check');
    lines.push(`- Status: **${summary.gatewayCheck.status}**`);
    lines.push(`- Safe mode: \`${summary.gatewayCheck.safeMode}\``);

    for (const targetResult of summary.gatewayCheck.targets) {
      const source = targetResult.envName ? ` via ${targetResult.envName}` : '';
      const injected = targetResult.injectedBySafeMode ? ' (safe-mode default)' : '';
      lines.push(`- ${targetResult.status === 'PASS' ? 'PASS' : 'FAIL'} ${targetResult.target}${source}${injected}`);
      lines.push(`  - Reason: ${targetResult.reason}`);
      if (targetResult.valuePreview) {
        lines.push(`  - Value: ${targetResult.valuePreview}`);
      }
    }
  }

  return `${lines.join('\n')}\n`;
}

function persistArtifacts(summary, options) {
  ensureDir(options.artifactDir);
  const summaryJsonPath = path.join(options.artifactDir, 'summary.json');
  const summaryMarkdownPath = path.join(options.artifactDir, 'summary.md');

  writeJson(summaryJsonPath, summary);
  fs.writeFileSync(summaryMarkdownPath, buildMarkdownSummary(summary, options.repoRoot));

  if (summary.docsSync) {
    writeJson(path.join(options.artifactDir, 'docs-sync.json'), summary.docsSync);
  }

  if (summary.gatewayCheck) {
    writeJson(path.join(options.artifactDir, 'gateway-check.json'), summary.gatewayCheck);
  }

  return {
    summaryJsonPath,
    summaryMarkdownPath,
  };
}

function main() {
  let options;
  try {
    options = parseArgs(process.argv);
  } catch (error) {
    console.error(`error: ${error.message}`);
    printUsage();
    process.exit(1);
  }

  if (options.help) {
    printUsage();
    return;
  }

  ensureDir(options.artifactDir);

  const startedAt = new Date().toISOString();
  const summary = {
    status: 'PASS',
    mode: options.mode,
    safeMode: options.safeMode,
    startedAt,
    finishedAt: null,
    docsSync: null,
    gatewayCheck: null,
  };

  try {
    if (options.mode === 'all' || options.mode === 'docs-sync') {
      summary.docsSync = runDocsSyncCheck(options);
      renderDocsConsole(summary.docsSync, options.repoRoot);
      if (summary.docsSync.status !== 'PASS') {
        summary.status = 'FAIL';
      }
    }

    if (options.mode === 'all' || options.mode === 'gateway-check') {
      summary.gatewayCheck = runGatewayCheck(options);
      renderGatewayConsole(summary.gatewayCheck);
      if (summary.gatewayCheck.status !== 'PASS') {
        summary.status = 'FAIL';
      }
    }
  } catch (error) {
    summary.status = 'FAIL';
    summary.error = error instanceof Error ? error.message : String(error);
    console.error('');
    console.error(`fatal: ${summary.error}`);
  }

  summary.finishedAt = new Date().toISOString();
  const artifactPaths = persistArtifacts(summary, options);

  console.log('');
  console.log('=== final ===');
  console.log(`status: ${summary.status}`);
  console.log(`summary.json: ${artifactPaths.summaryJsonPath}`);
  console.log(`summary.md: ${artifactPaths.summaryMarkdownPath}`);

  if (summary.status !== 'PASS') {
    process.exitCode = 1;
  }
}

main();
