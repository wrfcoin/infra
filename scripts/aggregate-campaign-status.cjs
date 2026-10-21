#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const REPOS = [
  'core4',
  'frontend',
  'backend',
  'smart-contracts',
  'infra',
  'security-testing',
  'defi-protocols',
  'storage-providers',
];

const LABELS = ['alignment-90', 'bot-governance', 'next-sprint'];
const ORG = 'wrfcoin';

function parseArgs(argv) {
  const args = { output: null, json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--output') {
      args.output = argv[i + 1];
      i += 1;
    } else if (token === '--json') {
      args.json = true;
    }
  }
  return args;
}

function ghIssueList(repo, label, state) {
  try {
    const cmd = `gh issue list --repo ${ORG}/${repo} --label "${label}" --state ${state} --json number,title,state,labels --limit 200`;
    const raw = execSync(cmd, { encoding: 'utf8', timeout: 30000 });
    return JSON.parse(raw);
  } catch (_err) {
    return [];
  }
}

function checkCLAUDEmd(repo) {
  try {
    execSync(`gh api repos/${ORG}/${repo}/contents/CLAUDE.md --silent`, {
      encoding: 'utf8',
      timeout: 15000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    return true;
  } catch (_err) {
    return false;
  }
}

function checkCIWorkflows(repo) {
  try {
    const raw = execSync(
      `gh api repos/${ORG}/${repo}/contents/.github/workflows --jq 'length'`,
      { encoding: 'utf8', timeout: 15000, stdio: ['pipe', 'pipe', 'pipe'] }
    );
    return parseInt(raw.trim(), 10) || 0;
  } catch (_err) {
    return 0;
  }
}

function aggregateRepo(repo) {
  const result = {
    repo,
    labels: {},
    totals: { open: 0, closed: 0 },
    blockers: [],
    rubric: {
      has_claude_md: false,
      ci_workflow_count: 0,
    },
  };

  for (const label of LABELS) {
    const open = ghIssueList(repo, label, 'open');
    const closed = ghIssueList(repo, label, 'closed');
    result.labels[label] = {
      open: open.length,
      closed: closed.length,
    };
    result.totals.open += open.length;
    result.totals.closed += closed.length;

    // Issues labeled as blockers (title contains "blocker" case-insensitive)
    for (const issue of open) {
      if (/blocker/i.test(issue.title)) {
        result.blockers.push({
          number: issue.number,
          title: issue.title,
          label,
        });
      }
    }
  }

  result.rubric.has_claude_md = checkCLAUDEmd(repo);
  result.rubric.ci_workflow_count = checkCIWorkflows(repo);

  return result;
}

function computeRubricScore(rubric) {
  let score = 0;
  if (rubric.has_claude_md) score += 50;
  if (rubric.ci_workflow_count > 0) score += 30;
  if (rubric.ci_workflow_count >= 3) score += 20;
  return score;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  const generatedAt = new Date().toISOString();
  const repos = [];
  let totalOpen = 0;
  let totalClosed = 0;
  const allBlockers = [];

  for (const repo of REPOS) {
    process.stderr.write(`Querying ${ORG}/${repo}...\n`);
    const data = aggregateRepo(repo);
    data.rubric.score = computeRubricScore(data.rubric);
    repos.push(data);
    totalOpen += data.totals.open;
    totalClosed += data.totals.closed;
    for (const b of data.blockers) {
      allBlockers.push({ repo, ...b });
    }
  }

  const report = {
    generated_at: generatedAt,
    org: ORG,
    labels_queried: LABELS,
    summary: {
      total_open: totalOpen,
      total_closed: totalClosed,
      blocker_count: allBlockers.length,
    },
    blockers: allBlockers,
    repos,
  };

  const output = JSON.stringify(report, null, 2);

  if (args.output) {
    const absPath = path.resolve(args.output);
    fs.mkdirSync(path.dirname(absPath), { recursive: true });
    fs.writeFileSync(absPath, `${output}\n`, 'utf8');
    process.stderr.write(`Report written to ${absPath}\n`);
  } else {
    console.log(output);
  }
}

main();
