#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const REQUIRED_ACTOR_CLASSES = ['human', 'ai_agent', 'robot'];
const REQUIRED_SANCTION_FIELDS = [
  'temporary_ban_blocks',
  'slash_bps',
  'cooldown_blocks',
  'appeal_window_blocks',
];
const REQUIRED_OFFENSE_LEVELS = ['low', 'medium', 'high', 'critical'];

function isObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isSemver(value) {
  return typeof value === 'string' && /^\d+\.\d+\.\d+$/.test(value);
}

function isIsoUtc(value) {
  if (typeof value !== 'string') {
    return false;
  }
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) && value.endsWith('Z');
}

function normalize(value) {
  if (Array.isArray(value)) {
    return value.map(normalize);
  }
  if (isObject(value)) {
    const sorted = Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = normalize(value[key]);
        return acc;
      }, {});
    return sorted;
  }
  return value;
}

function canonicalStringify(value) {
  return JSON.stringify(normalize(value));
}

function digestHex(value) {
  return crypto.createHash('sha256').update(canonicalStringify(value)).digest('hex');
}

function parseJsonFile(absPath) {
  const raw = fs.readFileSync(absPath, 'utf8');
  return JSON.parse(raw);
}

function assertNumber(name, value, errors, minimum = 0, maximum = Number.MAX_SAFE_INTEGER) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < minimum || value > maximum) {
    errors.push(`${name} must be an integer in [${minimum}, ${maximum}]`);
  }
}

function validateSanctionProfile(pathPrefix, profile, errors) {
  if (!isObject(profile)) {
    errors.push(`${pathPrefix} must be an object`);
    return;
  }
  for (const field of REQUIRED_SANCTION_FIELDS) {
    assertNumber(`${pathPrefix}.${field}`, profile[field], errors, 0, 1_000_000);
  }
}

function validateBundle(bundle, bundlePath) {
  const errors = [];

  if (!isObject(bundle)) {
    return { errors: ['bundle root must be an object'] };
  }

  if (bundle.schema_id !== 'wrfcoin.actor_governance_policy_bundle') {
    errors.push('schema_id must equal "wrfcoin.actor_governance_policy_bundle"');
  }

  assertNumber('schema_version', bundle.schema_version, errors, 1, 100);

  if (!isSemver(bundle.policy_bundle_version)) {
    errors.push('policy_bundle_version must be semver (x.y.z)');
  }

  if (!isIsoUtc(bundle.created_at)) {
    errors.push('created_at must be an ISO-8601 UTC timestamp ending in Z');
  }

  if (!isObject(bundle.actor_classes)) {
    errors.push('actor_classes must be an object');
  } else {
    for (const actorClass of REQUIRED_ACTOR_CLASSES) {
      const actorEntry = bundle.actor_classes[actorClass];
      if (!isObject(actorEntry)) {
        errors.push(`actor_classes.${actorClass} must be present and be an object`);
        continue;
      }
      if (!isObject(actorEntry.default_sanction_profile)) {
        errors.push(`actor_classes.${actorClass}.default_sanction_profile must be an object`);
      } else {
        validateSanctionProfile(
          `actor_classes.${actorClass}.default_sanction_profile`,
          actorEntry.default_sanction_profile,
          errors
        );
      }
    }
  }

  if (!isObject(bundle.sanction_profiles)) {
    errors.push('sanction_profiles must be an object');
  } else {
    const names = Object.keys(bundle.sanction_profiles);
    if (names.length === 0) {
      errors.push('sanction_profiles must define at least one profile');
    }
    for (const name of names) {
      validateSanctionProfile(`sanction_profiles.${name}`, bundle.sanction_profiles[name], errors);
    }
  }

  if (!isObject(bundle.equal_liability_matrix)) {
    errors.push('equal_liability_matrix must be an object');
  } else {
    for (const offense of REQUIRED_OFFENSE_LEVELS) {
      const row = bundle.equal_liability_matrix[offense];
      if (!isObject(row)) {
        errors.push(`equal_liability_matrix.${offense} must be an object`);
        continue;
      }
      const firstProfile = row[REQUIRED_ACTOR_CLASSES[0]];
      for (const actorClass of REQUIRED_ACTOR_CLASSES) {
        const profileName = row[actorClass];
        if (typeof profileName !== 'string' || !profileName.trim()) {
          errors.push(`equal_liability_matrix.${offense}.${actorClass} must be a non-empty string`);
          continue;
        }
        if (!isObject(bundle.sanction_profiles) || !bundle.sanction_profiles[profileName]) {
          errors.push(
            `equal_liability_matrix.${offense}.${actorClass} references missing sanction profile "${profileName}"`
          );
        }
      }
      if (typeof firstProfile === 'string') {
        for (const actorClass of REQUIRED_ACTOR_CLASSES.slice(1)) {
          if (row[actorClass] !== firstProfile) {
            errors.push(
              `equal_liability_matrix.${offense} violates equal-liability: all actor classes must map to the same profile`
            );
          }
        }
      }
    }
  }

  if (!isObject(bundle.rollout)) {
    errors.push('rollout must be an object');
  } else {
    assertNumber('rollout.canary_percent', bundle.rollout.canary_percent, errors, 1, 100);
    assertNumber('rollout.max_blast_radius_percent', bundle.rollout.max_blast_radius_percent, errors, 1, 100);
    if (typeof bundle.rollout.target_environment !== 'string' || !bundle.rollout.target_environment.trim()) {
      errors.push('rollout.target_environment must be a non-empty string');
    }
    if (!Array.isArray(bundle.rollout.pre_deploy_checks) || bundle.rollout.pre_deploy_checks.length < 1) {
      errors.push('rollout.pre_deploy_checks must contain at least one check id');
    }
  }

  if (!isObject(bundle.rollback)) {
    errors.push('rollback must be an object');
  } else {
    if (!isSemver(bundle.rollback.previous_bundle_version)) {
      errors.push('rollback.previous_bundle_version must be semver (x.y.z)');
    }
    assertNumber('rollback.max_rollback_minutes', bundle.rollback.max_rollback_minutes, errors, 1, 10_080);
    if (typeof bundle.rollback.procedure_doc !== 'string' || !bundle.rollback.procedure_doc.trim()) {
      errors.push('rollback.procedure_doc must be a non-empty string path');
    } else {
      const rollbackDocFromCwd = path.resolve(process.cwd(), bundle.rollback.procedure_doc);
      const rollbackDocFromBundle = path.resolve(path.dirname(bundlePath), bundle.rollback.procedure_doc);
      if (!fs.existsSync(rollbackDocFromCwd) && !fs.existsSync(rollbackDocFromBundle)) {
        errors.push(`rollback.procedure_doc does not exist: ${bundle.rollback.procedure_doc}`);
      }
    }
  }

  if (Array.isArray(bundle.change_log)) {
    if (bundle.change_log.length === 0) {
      errors.push('change_log must not be empty when present');
    }
  }

  return { errors };
}

function loadAndValidateBundle(bundlePath) {
  const absBundlePath = path.resolve(bundlePath);
  const bundle = parseJsonFile(absBundlePath);
  const { errors } = validateBundle(bundle, absBundlePath);
  const digest = digestHex(bundle);

  return {
    bundle,
    absBundlePath,
    digest,
    errors,
  };
}

module.exports = {
  canonicalStringify,
  digestHex,
  loadAndValidateBundle,
};
