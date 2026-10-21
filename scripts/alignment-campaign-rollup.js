#!/usr/bin/env node
/**
 * Cross-repo alignment campaign rollup generator.
 *
 * Outputs:
 * - artifacts/alignment/alignment-campaign-board.md
 * - artifacts/alignment/alignment-rubric-rollup.md
 * - artifacts/alignment/alignment-rubric-rollup.json
 */

const fs = require('fs');
const path = require('path');

const OWNER = process.env.ALIGNMENT_OWNER || 'wrfcoin';
const DEFAULT_REPOS = [
  'core4',
  'backend',
  'frontend',
  'defi-protocols',
  'storage-providers',
  'smart-contracts',
  'infra',
  'security-testing',
];
const REPOS = (process.env.ALIGNMENT_REPOS || DEFAULT_REPOS.join(','))
  .split(',')
  .map(v => v.trim())
  .filter(Boolean);

const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
if (!TOKEN) {
  throw new Error('GITHUB_TOKEN (or GH_TOKEN) is required');
}

const DIMENSIONS = [
  'Useful-work consensus + role economics',
  'Privacy goals (financial + contributor)',
  'Permissionless/borderless participation',
  'Data market + storage architecture',
  'Environmental forecast breadth',
  'Governance / AI-DAO trajectory',
  'Product coherence vs scope drift',
  'Human-legible integrity + bot governance',
];

function unique(values) {
  return Array.from(new Set(values));
}

function mapIssueToDimensions(issue) {
  const labels = (issue.labels || []).map(label =>
    typeof label === 'string' ? label.toLowerCase() : String(label.name || '').toLowerCase()
  );
  const haystack = `${issue.title || ''} ${issue.body || ''}`.toLowerCase();
  const mapped = [];

  if (labels.includes('bot-governance') || /(integrity|sybil|sanction|appeal|abuse|parity)/.test(haystack)) {
    mapped.push('Human-legible integrity + bot governance');
  }
  if (labels.includes('forecast-breadth') || /(forecast|environment|soil|ocean|hydrology)/.test(haystack)) {
    mapped.push('Environmental forecast breadth');
  }
  if (/(privacy|confidential|shielded)/.test(haystack)) {
    mapped.push('Privacy goals (financial + contributor)');
  }
  if (/(permissionless|borderless|censorship|geoblock|participation)/.test(haystack)) {
    mapped.push('Permissionless/borderless participation');
  }
  if (/(storage|data market|provenance|schema|replication)/.test(haystack)) {
    mapped.push('Data market + storage architecture');
  }
  if (/(governance|policy|dao|constitution|law)/.test(haystack)) {
    mapped.push('Governance / AI-DAO trajectory');
  }
  if (/(useful-work|pop|consensus|role economics|task assign)/.test(haystack)) {
    mapped.push('Useful-work consensus + role economics');
  }
  if (/(coherence|scope drift|campaign board|aggregation|release gate)/.test(haystack)) {
    mapped.push('Product coherence vs scope drift');
  }

  if (mapped.length === 0) {
    mapped.push('Product coherence vs scope drift');
  }

  return unique(mapped);
}

async function requestJson(url) {
  const response = await fetch(url, {
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'wrfcoin-alignment-rollup-bot',
    },
  });

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`GitHub API ${response.status} for ${url}: ${text.slice(0, 400)}`);
  }

  return response.json();
}

async function fetchRepoIssues(repo) {
  const all = [];
  let page = 1;
  const labels = [
    'alignment-90',
    'alignment-wave-2',
    'alignment-wave-3',
  ].join(',');

  while (true) {
    const url = `https://api.github.com/repos/${OWNER}/${repo}/issues?state=all&labels=${encodeURIComponent(labels)}&per_page=100&page=${page}`;
    const batch = await requestJson(url);
    if (!Array.isArray(batch) || batch.length === 0) break;
    const issuesOnly = batch.filter(item => !item.pull_request);
    all.push(...issuesOnly);
    if (batch.length < 100) break;
    page += 1;
  }

  return all;
}

function summarizeIssues(issuesWithRepo) {
  const repoSummary = {};
  const dimensionSummary = Object.fromEntries(
    DIMENSIONS.map(dimension => [dimension, { total: 0, open: 0, closed: 0 }])
  );

  for (const item of issuesWithRepo) {
    const repo = item.repo;
    if (!repoSummary[repo]) {
      repoSummary[repo] = { total: 0, open: 0, closed: 0 };
    }

    repoSummary[repo].total += 1;
    repoSummary[repo][item.state] += 1;

    for (const dimension of item.dimensions) {
      dimensionSummary[dimension].total += 1;
      dimensionSummary[dimension][item.state] += 1;
    }
  }

  return { repoSummary, dimensionSummary };
}

function renderBoardMarkdown(generatedAtIso, issuesWithRepo, summaries) {
  const open = issuesWithRepo.filter(item => item.state === 'open');
  const closed = issuesWithRepo.filter(item => item.state === 'closed');

  const repoRows = Object.entries(summaries.repoSummary)
    .sort((a, b) => a[0].localeCompare(b[0]))
    .map(([repo, stats]) => `| ${repo} | ${stats.total} | ${stats.open} | ${stats.closed} |`)
    .join('\n');

  const openRows = open
    .sort((a, b) => a.repo.localeCompare(b.repo) || a.number - b.number)
    .map(item => {
      const dimension = item.dimensions.join('; ');
      return `| ${item.repo} | [#${item.number}](${item.html_url}) | ${item.title.replace(/\|/g, '\\|')} | ${dimension} | ${item.updated_at.slice(0, 10)} |`;
    })
    .join('\n');

  return [
    '# Alignment Campaign Board',
    '',
    `Generated: ${generatedAtIso}`,
    '',
    '## Repo Rollup',
    '',
    '| Repo | Total Issues | Open | Closed |',
    '|---|---:|---:|---:|',
    repoRows || '| _none_ | 0 | 0 | 0 |',
    '',
    '## Open Alignment Issues',
    '',
    '| Repo | Issue | Title | Rubric Dimension(s) | Updated |',
    '|---|---|---|---|---|',
    openRows || '| _none_ | - | - | - | - |',
    '',
    '## Totals',
    '',
    `- Open: ${open.length}`,
    `- Closed: ${closed.length}`,
    `- Total: ${issuesWithRepo.length}`,
    '',
  ].join('\n');
}

function renderRubricMarkdown(generatedAtIso, dimensionSummary) {
  const rows = Object.entries(dimensionSummary)
    .map(([dimension, stats]) => `| ${dimension} | ${stats.total} | ${stats.open} | ${stats.closed} |`)
    .join('\n');

  return [
    '# Alignment Rubric Rollup',
    '',
    `Generated: ${generatedAtIso}`,
    '',
    '| Rubric Dimension | Total | Open | Closed |',
    '|---|---:|---:|---:|',
    rows || '| _none_ | 0 | 0 | 0 |',
    '',
  ].join('\n');
}

async function main() {
  const generatedAtIso = new Date().toISOString();
  const issuesWithRepo = [];

  for (const repo of REPOS) {
    const issues = await fetchRepoIssues(repo);
    for (const issue of issues) {
      issuesWithRepo.push({
        repo,
        number: issue.number,
        title: issue.title || '',
        state: issue.state === 'open' ? 'open' : 'closed',
        html_url: issue.html_url,
        updated_at: issue.updated_at || generatedAtIso,
        dimensions: mapIssueToDimensions(issue),
        labels: (issue.labels || []).map(label =>
          typeof label === 'string' ? label : label.name
        ),
      });
    }
  }

  const summaries = summarizeIssues(issuesWithRepo);
  const boardMarkdown = renderBoardMarkdown(generatedAtIso, issuesWithRepo, summaries);
  const rubricMarkdown = renderRubricMarkdown(generatedAtIso, summaries.dimensionSummary);

  const outDir = path.join(process.cwd(), 'artifacts', 'alignment');
  fs.mkdirSync(outDir, { recursive: true });

  fs.writeFileSync(path.join(outDir, 'alignment-campaign-board.md'), boardMarkdown);
  fs.writeFileSync(path.join(outDir, 'alignment-rubric-rollup.md'), rubricMarkdown);
  fs.writeFileSync(
    path.join(outDir, 'alignment-rubric-rollup.json'),
    JSON.stringify(
      {
        generatedAt: generatedAtIso,
        owner: OWNER,
        repos: REPOS,
        repoSummary: summaries.repoSummary,
        rubricSummary: summaries.dimensionSummary,
        issues: issuesWithRepo,
      },
      null,
      2
    )
  );

  console.log(`Generated alignment artifacts in ${outDir}`);
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
