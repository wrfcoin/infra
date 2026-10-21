#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const dashboardPath = path.join(
  repoRoot,
  'infra/monitoring/dashboards/wrfcoin-sanctions-parity-phase2.json'
);
const alertPath = path.join(
  repoRoot,
  'infra/monitoring/alert-rules-sanctions-parity-phase2.yml'
);
const runbookPath = path.join(
  repoRoot,
  'infra/monitoring/runbooks/sanctions-parity-drift-response.md'
);

function fail(message) {
  console.error(`Validation failed: ${message}`);
  process.exit(1);
}

function slugifyHeading(heading) {
  return heading
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-');
}

for (const filePath of [dashboardPath, alertPath, runbookPath]) {
  if (!fs.existsSync(filePath)) {
    fail(`Required file missing: ${filePath}`);
  }
}

let dashboard;
try {
  dashboard = JSON.parse(fs.readFileSync(dashboardPath, 'utf8'));
} catch (error) {
  fail(`Dashboard JSON is invalid: ${error instanceof Error ? error.message : String(error)}`);
}

if (!Array.isArray(dashboard.panels) || dashboard.panels.length < 9) {
  fail('Dashboard must define at least 9 panels');
}

const requiredPanelTitles = [
  'Sanction Parity Drift Score (Max Spread)',
  'Sanction Rate by Actor Class (All Severities)',
  'Sanction Rate by Offense Severity (All Actors)',
  'Parity SLO Compliance (24h)',
  'Sanction Rate by Actor Class and Severity',
  'Sanction Outcome Mix by Actor Class and Severity',
  'Appeal Overturn Rate by Actor Class and Severity',
  'Remediation Latency (p95)',
  'Telemetry Coverage for Actor Class + Severity Labels',
];
const panelTitleSet = new Set(dashboard.panels.map(panel => panel.title));
for (const title of requiredPanelTitles) {
  if (!panelTitleSet.has(title)) {
    fail(`Dashboard missing required panel title: ${title}`);
  }
}

const expressions = dashboard.panels.flatMap(panel =>
  Array.isArray(panel.targets) ? panel.targets.map(target => target.expr || '') : []
);
const hasActorClassDimension = expressions.some(expr => expr.includes('actor_class'));
const hasSeverityDimension = expressions.some(expr => expr.includes('offense_severity'));
if (!hasActorClassDimension || !hasSeverityDimension) {
  fail('Dashboard expressions must include actor_class and offense_severity dimensions');
}

const alertYaml = fs.readFileSync(alertPath, 'utf8');
const alertNames = [
  'AlignmentSanctionParityActorClassDriftCritical',
  'AlignmentSanctionParitySeverityDriftCritical',
  'AlignmentSanctionParityOutcomeBiasWarning',
  'AlignmentSanctionParityTelemetryCoverageDrop',
  'AlignmentSanctionParityRemediationLatencyHigh',
];
for (const alertName of alertNames) {
  if (!alertYaml.includes(`- alert: ${alertName}`)) {
    fail(`Alert rule not found: ${alertName}`);
  }
}

const runbookUrlMatches = Array.from(
  alertYaml.matchAll(/runbook_url:\s*'([^']+)'/g)
).map(match => match[1]);
if (runbookUrlMatches.length !== alertNames.length) {
  fail(`Expected ${alertNames.length} runbook_url entries, found ${runbookUrlMatches.length}`);
}

const runbookBody = fs.readFileSync(runbookPath, 'utf8');
if (!runbookBody.toLowerCase().includes('equal-liability')) {
  fail('Runbook must explicitly mention equal-liability treatment');
}

const headingMatches = Array.from(runbookBody.matchAll(/^##\s+(.+)$/gm)).map(match => match[1]);
const headingAnchors = new Set(headingMatches.map(slugifyHeading));

for (const url of runbookUrlMatches) {
  const anchor = url.includes('#') ? url.split('#')[1] : '';
  if (!anchor) {
    fail(`runbook_url missing anchor: ${url}`);
  }
  if (!headingAnchors.has(anchor)) {
    fail(`runbook_url anchor not found in runbook headings: ${anchor}`);
  }
}

console.log('Sanctions parity observability assets validation passed.');
