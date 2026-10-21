#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {
    target: 'production',
    auditOutput: 'artifacts/alignment-release-gate/release-gate-audit.json',
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--kpis') {
      args.kpis = argv[i + 1];
      i += 1;
    } else if (token === '--thresholds') {
      args.thresholds = argv[i + 1];
      i += 1;
    } else if (token === '--target') {
      args.target = argv[i + 1];
      i += 1;
    } else if (token === '--override-ticket') {
      args.overrideTicket = argv[i + 1];
      i += 1;
    } else if (token === '--override-reason') {
      args.overrideReason = argv[i + 1];
      i += 1;
    } else if (token === '--override-approver') {
      args.overrideApprover = argv[i + 1];
      i += 1;
    } else if (token === '--audit-output') {
      args.auditOutput = argv[i + 1];
      i += 1;
    }
  }

  return args;
}

function fail(message, exitCode = 1) {
  console.error(message);
  process.exit(exitCode);
}

function readJson(absPath, label) {
  if (!fs.existsSync(absPath)) {
    fail(`${label} not found: ${absPath}`);
  }
  try {
    return JSON.parse(fs.readFileSync(absPath, 'utf8'));
  } catch (error) {
    fail(`${label} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function getByPath(obj, dottedPath) {
  return dottedPath.split('.').reduce((acc, key) => {
    if (acc == null || typeof acc !== 'object' || !(key in acc)) {
      return undefined;
    }
    return acc[key];
  }, obj);
}

function ensureDirForFile(absPath) {
  const dir = path.dirname(absPath);
  fs.mkdirSync(dir, { recursive: true });
}

function evaluateMetric(metricName, rule, kpis) {
  const value = getByPath(kpis, rule.path);
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return {
      metric: metricName,
      path: rule.path,
      comparator: rule.min != null ? '>=' : '<=',
      threshold: rule.min != null ? rule.min : rule.max,
      value,
      pass: false,
      reason: `metric missing or non-numeric at path ${rule.path}`,
    };
  }

  if (rule.min != null && rule.max != null) {
    return {
      metric: metricName,
      path: rule.path,
      comparator: 'range',
      threshold: { min: rule.min, max: rule.max },
      value,
      pass: value >= rule.min && value <= rule.max,
      reason: null,
    };
  }

  if (rule.min != null) {
    return {
      metric: metricName,
      path: rule.path,
      comparator: '>=',
      threshold: rule.min,
      value,
      pass: value >= rule.min,
      reason: null,
    };
  }

  if (rule.max != null) {
    return {
      metric: metricName,
      path: rule.path,
      comparator: '<=',
      threshold: rule.max,
      value,
      pass: value <= rule.max,
      reason: null,
    };
  }

  return {
    metric: metricName,
    path: rule.path,
    comparator: 'unknown',
    threshold: null,
    value,
    pass: false,
    reason: 'metric rule must define min or max threshold',
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.kpis || !args.thresholds) {
    fail(
      'Usage: node scripts/evaluate-alignment-release-gate.cjs --kpis <kpi-json> --thresholds <thresholds-json> [--target production] [--override-ticket <issue-or-incident>] [--override-reason <reason>] [--override-approver <approver>] [--audit-output <path>]',
      2
    );
  }

  const absKpis = path.resolve(args.kpis);
  const absThresholds = path.resolve(args.thresholds);
  const absAudit = path.resolve(args.auditOutput);

  const kpis = readJson(absKpis, 'KPI payload');
  const thresholds = readJson(absThresholds, 'Threshold config');

  if (!thresholds.metrics || typeof thresholds.metrics !== 'object') {
    fail('Threshold config must include a metrics object');
  }

  const metricResults = Object.entries(thresholds.metrics).map(([metricName, rule]) =>
    evaluateMetric(metricName, rule, kpis)
  );

  const failedMetrics = metricResults.filter(result => !result.pass);
  const hasFailures = failedMetrics.length > 0;

  const overrideRequested = Boolean(args.overrideTicket || args.overrideReason || args.overrideApprover);
  const overrideFullySpecified = Boolean(args.overrideTicket && args.overrideReason && args.overrideApprover);

  if (overrideRequested && !overrideFullySpecified) {
    fail('Override requires --override-ticket, --override-reason, and --override-approver');
  }

  let decision = 'pass';
  let blocked = false;

  if (hasFailures) {
    if (overrideFullySpecified) {
      decision = 'override-pass';
    } else {
      decision = 'blocked';
      blocked = true;
    }
  }

  const audit = {
    generated_at: new Date().toISOString(),
    target: args.target,
    decision,
    thresholds_version: thresholds.gate_version || 'unknown',
    thresholds_path: absThresholds,
    kpis_path: absKpis,
    context: {
      github_sha: process.env.GITHUB_SHA || null,
      github_ref: process.env.GITHUB_REF || null,
      github_actor: process.env.GITHUB_ACTOR || null,
      github_run_id: process.env.GITHUB_RUN_ID || null,
    },
    metrics: metricResults,
    failed_metrics: failedMetrics.map(result => result.metric),
    override: overrideFullySpecified
      ? {
          ticket: args.overrideTicket,
          reason: args.overrideReason,
          approver: args.overrideApprover,
        }
      : null,
  };

  ensureDirForFile(absAudit);
  fs.writeFileSync(absAudit, `${JSON.stringify(audit, null, 2)}\n`, 'utf8');

  console.log(`Alignment release gate decision: ${decision}`);
  console.log(`Threshold version: ${audit.thresholds_version}`);
  for (const result of metricResults) {
    const status = result.pass ? 'PASS' : 'FAIL';
    const thresholdText =
      typeof result.threshold === 'object'
        ? `${JSON.stringify(result.threshold)}`
        : `${result.comparator} ${result.threshold}`;
    console.log(
      `- ${status} ${result.metric}: value=${result.value} threshold=${thresholdText}` +
        (result.reason ? ` reason=${result.reason}` : '')
    );
  }
  console.log(`Audit record: ${absAudit}`);

  if (blocked) {
    fail('Alignment release gate blocked promotion due to failing KPI thresholds.', 1);
  }
}

main();
