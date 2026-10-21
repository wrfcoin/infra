#!/usr/bin/env node
const { loadAndValidateBundle } = require('./lib/policy-bundle-utils.cjs');

function parseArgs(argv) {
  const args = { json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--bundle') {
      args.bundle = argv[i + 1];
      i += 1;
    } else if (token === '--json') {
      args.json = true;
    }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.bundle) {
    console.error('Usage: node scripts/validate-policy-bundle.cjs --bundle <path> [--json]');
    process.exit(2);
  }

  const result = loadAndValidateBundle(args.bundle);
  const summary = {
    bundle: result.absBundlePath,
    policy_bundle_version: result.bundle.policy_bundle_version,
    schema_version: result.bundle.schema_version,
    digest_sha256: result.digest,
    error_count: result.errors.length,
    errors: result.errors,
  };

  if (args.json) {
    console.log(JSON.stringify(summary, null, 2));
  } else {
    console.log(`Bundle: ${summary.bundle}`);
    console.log(`Version: ${summary.policy_bundle_version}`);
    console.log(`Schema: ${summary.schema_version}`);
    console.log(`Digest: ${summary.digest_sha256}`);
    if (summary.errors.length > 0) {
      console.log('Validation errors:');
      for (const err of summary.errors) {
        console.log(`- ${err}`);
      }
    } else {
      console.log('Validation errors: none');
    }
  }

  if (summary.errors.length > 0) {
    process.exit(1);
  }
}

main();
