#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const infraRepoDir = path.resolve(process.env.INFRA_REPO_DIR || path.join(__dirname, '..'));

function resolveRepoDir(repoName, explicitValue) {
  if (explicitValue) {
    return path.resolve(explicitValue);
  }

  const candidates = [
    path.join(infraRepoDir, repoName),
    path.join(process.cwd(), repoName),
    path.join(process.cwd(), '..', repoName),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      return path.resolve(candidate);
    }
  }

  return path.resolve(path.join(infraRepoDir, repoName));
}

process.env.INFRA_REPO_DIR = infraRepoDir;
process.env.MAIN_API_BASE_URL =
  process.env.MAIN_API_BASE_URL ||
  process.env.WRFCOIN_API_BASE_URL ||
  'http://127.0.0.1:4001';
process.env.MAIN_API_WS_URL =
  process.env.MAIN_API_WS_URL ||
  process.env.WRFCOIN_WS_URL ||
  'ws://127.0.0.1:4001/ws';
process.env.COMPUTE_API_BASE_URL =
  process.env.COMPUTE_API_BASE_URL ||
  process.env.WRFCOIN_COMPUTE_BASE_URL ||
  'http://127.0.0.1:6003';
process.env.BACKEND_REPO_DIR = resolveRepoDir('backend', process.env.BACKEND_REPO_DIR);
process.env.MOBILE_REPO_DIR = resolveRepoDir('mobile', process.env.MOBILE_REPO_DIR);
process.env.CORE4_REPO_DIR = resolveRepoDir('core4', process.env.CORE4_REPO_DIR);
process.env.REPORT_DIR =
  process.env.REPORT_DIR || path.join(infraRepoDir, 'artifacts', 'launch-contract-suite');

require('./run-launch-contract-suite.cjs');
