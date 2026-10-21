#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {
    bundle: null,
    env: 'staging',
    dryRun: false,
    rollback: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--bundle') {
      args.bundle = argv[i + 1];
      i += 1;
    } else if (token === '--env') {
      args.env = argv[i + 1];
      i += 1;
    } else if (token === '--dry-run') {
      args.dryRun = true;
    } else if (token === '--rollback') {
      args.rollback = true;
    }
  }

  return args;
}

function run(cmd, label) {
  console.log(`\n==> [${label}] ${cmd}`);
  try {
    const output = execSync(cmd, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] });
    if (output.trim()) {
      console.log(output.trim());
    }
    return { ok: true, output: output.trim() };
  } catch (err) {
    console.error(`FAILED: ${err.stderr || err.message}`);
    return { ok: false, output: err.stderr || err.message };
  }
}

function readJsonIfExists(absPath) {
  if (!fs.existsSync(absPath)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(absPath, 'utf8'));
}

function writeJson(absPath, value) {
  fs.mkdirSync(path.dirname(absPath), { recursive: true });
  fs.writeFileSync(absPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function doRollback(env) {
  const releasesDir = path.resolve('infra/policy-bundles/releases', env);
  const currentPath = path.join(releasesDir, 'current.json');
  const current = readJsonIfExists(currentPath);

  if (!current) {
    console.error(`No current deployment found for environment "${env}".`);
    process.exit(1);
  }

  const currentVersion = current.policy_bundle_version;
  const deploymentRecordPath = path.join(releasesDir, currentVersion, 'deployment-record.json');
  const deploymentRecord = readJsonIfExists(deploymentRecordPath);

  if (!deploymentRecord || !deploymentRecord.previous_current) {
    console.error(`No previous deployment to roll back to for environment "${env}".`);
    process.exit(1);
  }

  const previousVersion = deploymentRecord.previous_current.policy_bundle_version;
  const previousBundlePath = path.join(releasesDir, previousVersion, 'bundle.json');

  if (!fs.existsSync(previousBundlePath)) {
    console.error(`Previous bundle not found at ${previousBundlePath}.`);
    process.exit(1);
  }

  console.log(`Rolling back from ${currentVersion} to ${previousVersion}...`);

  // Restore previous bundle as current
  const result = run(
    `node scripts/deploy-policy-bundle.cjs --bundle "${previousBundlePath}" --environment "${env}" --rollback`,
    'rollback-deploy'
  );

  if (!result.ok) {
    console.error('Rollback deployment failed.');
    process.exit(1);
  }

  console.log(`\nRollback complete: ${currentVersion} -> ${previousVersion}`);
}

function doPipeline(args) {
  const steps = [];
  let failed = false;

  // Step 1: Validate
  const validateResult = run(
    `node scripts/validate-policy-bundle.cjs --bundle "${args.bundle}" --json`,
    'validate'
  );
  steps.push({ step: 'validate', ...validateResult });
  if (!validateResult.ok) {
    console.error('\nPipeline aborted: validation failed.');
    failed = true;
  }

  if (!failed) {
    // Parse validation output to get version
    let bundleVersion = 'unknown';
    try {
      const parsed = JSON.parse(validateResult.output);
      bundleVersion = parsed.policy_bundle_version;
    } catch (_e) {
      // ignore
    }

    // Step 2: Dry-run deploy
    const dryRunResult = run(
      `node scripts/deploy-policy-bundle.cjs --bundle "${args.bundle}" --environment "${args.env}" --output-dir /tmp/wrfcoin-policy-dry-run --dry-run`,
      'dry-run'
    );
    steps.push({ step: 'dry-run', ...dryRunResult });
    if (!dryRunResult.ok) {
      console.error('\nPipeline aborted: dry-run failed.');
      failed = true;
    }

    if (!failed && !args.dryRun) {
      // Step 3: Deploy
      const deployResult = run(
        `node scripts/deploy-policy-bundle.cjs --bundle "${args.bundle}" --environment "${args.env}"`,
        'deploy'
      );
      steps.push({ step: 'deploy', ...deployResult });
      if (!deployResult.ok) {
        console.error('\nPipeline aborted: deploy failed.');
        failed = true;
      }

      if (!failed) {
        // Step 4: Smoke test — verify current.json was written and matches
        const currentPath = path.resolve('infra/policy-bundles/releases', args.env, 'current.json');
        const current = readJsonIfExists(currentPath);
        const smokeOk = current && current.policy_bundle_version === bundleVersion;
        steps.push({
          step: 'smoke-test',
          ok: smokeOk,
          output: smokeOk
            ? `Verified current.json points to ${bundleVersion}`
            : `Smoke test failed: current.json version mismatch`,
        });
        if (!smokeOk) {
          console.error('\nPipeline warning: smoke test failed.');
          failed = true;
        }

        // Step 5: Record release manifest
        const releasesDir = path.resolve('infra/policy-bundles/releases');
        const manifestPath = path.join(releasesDir, `${bundleVersion}.json`);
        const manifest = {
          pipeline_version: '1.0.0',
          bundle_version: bundleVersion,
          environment: args.env,
          deployed_at: new Date().toISOString(),
          steps: steps.map((s) => ({ step: s.step, ok: s.ok })),
          dry_run: args.dryRun,
        };
        writeJson(manifestPath, manifest);
        steps.push({
          step: 'record-manifest',
          ok: true,
          output: `Release manifest written to ${manifestPath}`,
        });
        console.log(`\nRelease manifest: ${manifestPath}`);
      }
    }
  }

  // Summary
  console.log('\n--- Pipeline Summary ---');
  for (const s of steps) {
    console.log(`  ${s.ok ? 'PASS' : 'FAIL'}  ${s.step}`);
  }

  if (failed) {
    process.exit(1);
  }

  console.log('\nPipeline completed successfully.');
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (args.rollback) {
    doRollback(args.env);
    return;
  }

  if (!args.bundle) {
    console.error(
      'Usage: node scripts/pipeline-deploy-policy-bundle.cjs --bundle <path> --env <environment> [--dry-run] [--rollback]'
    );
    process.exit(2);
  }

  doPipeline(args);
}

main();
