#!/usr/bin/env node
const fs = require('fs');
const path = require('path');

const repoRoot = process.cwd();
const dashboardPath = path.join(
  repoRoot,
  'infra/monitoring/dashboards/wrfcoin-alignment-integrity-observability.json'
);
const alertPath = path.join(
  repoRoot,
  'infra/monitoring/alert-rules-alignment-integrity.yml'
);
const runbookPath = path.join(
  repoRoot,
  'infra/monitoring/runbooks/alignment-integrity-incident-response.md'
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

if (!Array.isArray(dashboard.panels) || dashboard.panels.length < 8) {
  fail('Dashboard must define at least 8 panels');
}

const requiredPanelTitles = [
  'Sybil Detection Coverage',
  'Appeal Overturn Rate',
  'Forecast Coverage (Soil/Ocean/Hydrology)',
  'Participation Accessibility Score',
  'Abuse + Sybil Signal Rate',
  'Sanctions by Actor Class',
  'Incident MTTD / MTTR (p95)',
  'Alert Throughput and Acknowledgement',
];
const panelTitleSet = new Set(dashboard.panels.map(panel => panel.title));
for (const title of requiredPanelTitles) {
  if (!panelTitleSet.has(title)) {
    fail(`Dashboard missing required panel title: ${title}`);
  }
}

const alertYaml = fs.readFileSync(alertPath, 'utf8');
const alertNames = [
  'AlignmentIntegrityAbuseSpike',
  'AlignmentSybilCoverageDrop',
  'AlignmentSanctionParityDrift',
  'AlignmentAppealOverturnRateHigh',
  'AlignmentParticipationAccessibilityDegraded',
  'AlignmentForecastCoverageRegression',
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

console.log('Alignment integrity observability assets validation passed.');
