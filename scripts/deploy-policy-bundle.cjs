#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const { loadAndValidateBundle, canonicalStringify } = require('./lib/policy-bundle-utils.cjs');

function parseArgs(argv) {
  const args = {
    environment: 'staging',
    outputDir: 'infra/policy-bundles/releases',
    dryRun: false,
    rollback: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--bundle') {
      args.bundle = argv[i + 1];
      i += 1;
    } else if (token === '--environment') {
      args.environment = argv[i + 1];
      i += 1;
    } else if (token === '--output-dir') {
      args.outputDir = argv[i + 1];
      i += 1;
    } else if (token === '--dry-run') {
      args.dryRun = true;
    } else if (token === '--rollback') {
      args.rollback = true;
    }
  }

  return args;
}

function ensureDir(absPath) {
  fs.mkdirSync(absPath, { recursive: true });
}

function readJsonIfExists(absPath) {
  if (!fs.existsSync(absPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(absPath, 'utf8'));
}

function writeJson(absPath, value) {
  fs.writeFileSync(absPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function verifyBundleIntegrity(envDir, version, expectedDigest) {
  const crypto = require('crypto');
  const canonicalPath = path.join(envDir, version, 'bundle.canonical.json');
  if (!fs.existsSync(canonicalPath)) {
    return { valid: false, reason: `Canonical bundle not found: ${canonicalPath}` };
  }
  const content = fs.readFileSync(canonicalPath, 'utf8').trim();
  const actual = crypto.createHash('sha256').update(content).digest('hex');
  if (actual !== expectedDigest) {
    return { valid: false, reason: `Digest mismatch: expected ${expectedDigest}, got ${actual}` };
  }
  return { valid: true };
}

function doRollback(args) {
  // Rollback requires deploy token for authorization
  const deployToken = process.env.POLICY_DEPLOY_TOKEN;
  if (!deployToken) {
    console.error('Rollback requires POLICY_DEPLOY_TOKEN environment variable for authorization.');
    process.exit(1);
  }

  const outputRoot = path.resolve(args.outputDir);
  const envDir = path.join(outputRoot, args.environment);
  const currentPtrPath = path.join(envDir, 'current.json');
  const current = readJsonIfExists(currentPtrPath);

  if (!current) {
    console.error(`No current deployment found for environment "${args.environment}".`);
    process.exit(1);
  }

  const currentVersion = current.policy_bundle_version;
  const deploymentRecordPath = path.join(envDir, currentVersion, 'deployment-record.json');
  const deploymentRecord = readJsonIfExists(deploymentRecordPath);

  if (!deploymentRecord || !deploymentRecord.previous_current) {
    console.error(`No previous deployment to roll back to for environment "${args.environment}".`);
    process.exit(1);
  }

  const previous = deploymentRecord.previous_current;

  // Verify integrity of the bundle we're rolling back to
  if (previous.digest_sha256) {
    const integrity = verifyBundleIntegrity(envDir, previous.policy_bundle_version, previous.digest_sha256);
    if (!integrity.valid) {
      console.error(`Rollback target integrity check failed: ${integrity.reason}`);
      process.exit(1);
    }
    console.log(`Integrity check passed for ${previous.policy_bundle_version}`);
  }

  console.log(`Rolling back from ${currentVersion} to ${previous.policy_bundle_version}...`);

  const rollbackPointer = {
    policy_bundle_version: previous.policy_bundle_version,
    schema_version: previous.schema_version,
    digest_sha256: previous.digest_sha256,
    deployed_at: new Date().toISOString(),
    dry_run: false,
    rolled_back_from: currentVersion,
  };

  writeJson(currentPtrPath, rollbackPointer);
  console.log(`Rollback complete: ${currentVersion} -> ${previous.policy_bundle_version}`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.bundle && !args.rollback) {
    console.error(
      'Usage: node scripts/deploy-policy-bundle.cjs --bundle <path> [--environment <env>] [--output-dir <path>] [--dry-run] [--rollback]'
    );
    process.exit(2);
  }

  if (args.rollback && !args.bundle) {
    doRollback(args);
    return;
  }

  const validation = loadAndValidateBundle(args.bundle);
  if (validation.errors.length > 0) {
    console.error('Pre-deploy validation failed:');
    for (const err of validation.errors) {
      console.error(`- ${err}`);
    }
    process.exit(1);
  }

  const deployedAt = new Date().toISOString();
  const outputRoot = path.resolve(args.outputDir);
  const envDir = path.join(outputRoot, args.environment);
  const versionDir = path.join(envDir, validation.bundle.policy_bundle_version);
  const currentPtrPath = path.join(envDir, 'current.json');

  ensureDir(versionDir);

  const previousCurrent = readJsonIfExists(currentPtrPath);
  const deploymentRecord = {
    environment: args.environment,
    deployed_at: deployedAt,
    dry_run: args.dryRun,
    bundle_path: validation.absBundlePath,
    policy_bundle_version: validation.bundle.policy_bundle_version,
    schema_version: validation.bundle.schema_version,
    digest_sha256: validation.digest,
    previous_current: previousCurrent,
  };

  const rollbackRecord = {
    recommended_previous_version: validation.bundle.rollback.previous_bundle_version,
    observed_previous_version: previousCurrent ? previousCurrent.policy_bundle_version : null,
    rollback_doc: validation.bundle.rollback.procedure_doc,
    max_rollback_minutes: validation.bundle.rollback.max_rollback_minutes,
    generated_at: deployedAt,
  };

  writeJson(path.join(versionDir, 'bundle.json'), validation.bundle);
  writeJson(path.join(versionDir, 'deployment-record.json'), deploymentRecord);
  writeJson(path.join(versionDir, 'rollback.json'), rollbackRecord);
  fs.writeFileSync(path.join(versionDir, 'bundle.canonical.json'), `${canonicalStringify(validation.bundle)}\n`, 'utf8');

  const currentPointer = {
    policy_bundle_version: validation.bundle.policy_bundle_version,
    schema_version: validation.bundle.schema_version,
    digest_sha256: validation.digest,
    deployed_at: deployedAt,
    dry_run: args.dryRun,
  };

  writeJson(currentPtrPath, currentPointer);

  console.log(`Policy bundle deploy ${args.dryRun ? 'dry-run' : 'apply'} complete`);
  console.log(`Environment: ${args.environment}`);
  console.log(`Version: ${validation.bundle.policy_bundle_version}`);
  console.log(`Digest: ${validation.digest}`);
  console.log(`Artifacts: ${versionDir}`);
}

main();
