/**
 * update-gap-report.ts
 *
 * Reads PR metadata from environment variables (set by GitHub Actions)
 * and updates the gap analysis report when a merged PR addresses known gap areas.
 *
 * Environment variables consumed:
 *   PR_NUMBER  - Pull request number
 *   PR_TITLE   - Pull request title
 *   PR_BODY    - Pull request body/description
 *   PR_LABELS  - Comma-separated label names
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const REPORT_PATH = resolve(
  process.cwd(),
  "reports/frontend-interaction-mapping-summary.md"
);

const RUST_REPORT_PATH = resolve(
  process.cwd(),
  "reports/wrfcoin-rust-blockchain-feature-gap-analysis-2026-02-15.md"
);

// Gap area keyword mappings
const GAP_AREA_PATTERNS: Record<string, RegExp> = {
  "Bridge trust": /bridge|trust|attestation|finality|simulated.*production/i,
  Identity: /identity|credential|governance.?policy|did|verifiable/i,
  "State sync": /state.?sync|p2p|orchestration|snapshot/i,
  "Durable store": /durable.?store|concurrency|locking|optimistic/i,
  "Feature visibility":
    /capabilities|feature.?visibility|feature.?toggle|features\.ts/i,
  "Explorer consolidation":
    /explorer|dag.?explorer|consolidat|canonical.?entry/i,
  "Design system": /bootstrap|mui|design.?system|style.?migration/i,
  "Route ownership": /route.?ownership|route.?map/i,
  "Release automation": /release|automation|ci\/cd|gap.?report/i,
  Documentation: /documentation|audit.?report|contradiction|doc.?drift/i,
  "Rust core": /cargo|blockchain.?core|native.?chain|shared.?protocol|rust/i,
};

interface PrMetadata {
  number: string;
  title: string;
  body: string;
  labels: string[];
}

interface ReadinessReport {
  layers?: {
    backend?: { status: string; details?: string };
    frontend?: { status: string; details?: string };
    core?: { status: string; details?: string };
    contracts?: { status: string; details?: string };
  };
  gates?: {
    security_scan?: { status: string; details?: string };
    lockfile_integrity?: { status: string; details?: string };
    cross_layer_consistency?: { status: string; details?: string };
  };
}

function getPrMetadata(): PrMetadata {
  const number = process.env.PR_NUMBER ?? "";
  const title = process.env.PR_TITLE ?? "";
  const body = process.env.PR_BODY ?? "";
  const labelsRaw = process.env.PR_LABELS ?? "";
  const labels = labelsRaw
    .split(",")
    .map((l) => l.trim())
    .filter(Boolean);

  if (!number) {
    console.log("No PR_NUMBER set. Nothing to do.");
    process.exit(0);
  }

  return { number, title, body, labels };
}

function matchGapAreas(pr: PrMetadata): string[] {
  const searchText = `${pr.title} ${pr.body} ${pr.labels.join(" ")}`;
  const matched: string[] = [];

  for (const [area, pattern] of Object.entries(GAP_AREA_PATTERNS)) {
    if (pattern.test(searchText)) {
      matched.push(area);
    }
  }

  return matched;
}

/**
 * Auto-resolve gaps in the "Remaining open items" table when a PR's
 * title or body indicates it resolves/fixes/closes a gap area.
 */
function autoResolveGaps(
  content: string,
  matchedAreas: string[],
  prMeta: PrMetadata
): string {
  const resolvePattern = /resolves|fixes|closes|resolved|fixed|closed/i;
  const combinedText = `${prMeta.title} ${prMeta.body}`;

  if (!resolvePattern.test(combinedText)) {
    return content;
  }

  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const lines = content.split(lineEnding);
  const result: string[] = [];

  // Find the "Remaining open items" section and its table
  let inRemainingTable = false;
  let pastHeader = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Detect the start of "Remaining open items" section
    if (/^#+\s+Remaining open items/i.test(line)) {
      inRemainingTable = true;
      pastHeader = false;
      result.push(line);
      continue;
    }

    // Detect the header separator row (|---|---|)
    if (inRemainingTable && !pastHeader && /^\|---/.test(line)) {
      pastHeader = true;
      result.push(line);
      continue;
    }

    // Process table rows after header
    if (inRemainingTable && pastHeader && line.startsWith("|")) {
      const cells = line.split("|").map((c) => c.trim());
      // cells[0] is empty (before first |), cells[1] is Area, cells[2] is Residual gap
      const area = cells[1] ?? "";
      const residualGap = cells[2] ?? "";

      // Skip rows already containing strikethrough
      if (residualGap.includes("~~")) {
        result.push(line);
        continue;
      }

      // Check if this row's area matches any of the matched gap areas
      const areaMatches = matchedAreas.some(
        (matched) => area.toLowerCase() === matched.toLowerCase()
      );

      if (areaMatches) {
        const resolvedGap = `~~${residualGap}~~ **RESOLVED (PR #${prMeta.number})**`;
        const newLine = `| ${area} | ${resolvedGap} |`;
        result.push(newLine);
        console.log(`Auto-resolved gap area: ${area}`);
        continue;
      }
    }

    // Detect end of remaining open items table (blank line or new heading)
    if (inRemainingTable && pastHeader && !line.startsWith("|") && line.trim() !== "") {
      if (line.startsWith("#")) {
        inRemainingTable = false;
      }
    }

    result.push(line);
  }

  return result.join(lineEnding);
}

/**
 * Count and display residual (unresolved) gaps in the "Remaining open items" table.
 * Inserts or updates a summary blockquote line after the table.
 */
function updateResidualCount(content: string): string {
  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const lines = content.split(lineEnding);
  const result: string[] = [];

  let inRemainingTable = false;
  let pastHeader = false;
  let totalRows = 0;
  let openRows = 0;
  let tableEndIndex = -1;

  // First pass: count rows
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    if (/^#+\s+Remaining open items/i.test(line)) {
      inRemainingTable = true;
      pastHeader = false;
      continue;
    }

    if (inRemainingTable && !pastHeader && /^\|---/.test(line)) {
      pastHeader = true;
      continue;
    }

    if (inRemainingTable && pastHeader && line.startsWith("|")) {
      totalRows++;
      const cells = line.split("|").map((c) => c.trim());
      const residualGap = cells[2] ?? "";
      if (!residualGap.includes("~~")) {
        openRows++;
      }
      tableEndIndex = i;
      continue;
    }

    if (inRemainingTable && pastHeader && !line.startsWith("|")) {
      inRemainingTable = false;
    }
  }

  if (totalRows === 0) {
    return content;
  }

  const date = new Date().toISOString().slice(0, 10);
  const summaryLine = `> **Residual gaps: ${openRows} of ${totalRows} items remain open** (updated ${date})`;

  // Second pass: rebuild with summary line
  inRemainingTable = false;
  pastHeader = false;
  let currentTableRow = -1;
  let summaryInserted = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Remove any existing residual gap summary line
    if (line.startsWith("> **Residual gaps:")) {
      continue;
    }

    if (/^#+\s+Remaining open items/i.test(line)) {
      inRemainingTable = true;
      pastHeader = false;
      result.push(line);
      continue;
    }

    if (inRemainingTable && !pastHeader && /^\|---/.test(line)) {
      pastHeader = true;
      result.push(line);
      continue;
    }

    if (inRemainingTable && pastHeader && line.startsWith("|")) {
      currentTableRow = i;
      result.push(line);

      // After the last table row, insert the summary
      if (i === tableEndIndex && !summaryInserted) {
        result.push(summaryLine);
        summaryInserted = true;
      }
      continue;
    }

    if (inRemainingTable && pastHeader && !line.startsWith("|")) {
      inRemainingTable = false;
    }

    result.push(line);
  }

  return result.join(lineEnding);
}

/**
 * Read readiness-report.json and insert/update a "CI Readiness Status" section.
 * Gracefully no-ops if the file is missing.
 */
function updateCIReadinessSection(content: string): string {
  const readinessPath = resolve(process.cwd(), "readiness-report.json");

  if (!existsSync(readinessPath)) {
    return content;
  }

  let report: ReadinessReport;
  try {
    const raw = readFileSync(readinessPath, "utf-8");
    report = JSON.parse(raw) as ReadinessReport;
  } catch (err) {
    console.log("Could not parse readiness-report.json. Skipping CI readiness update.");
    return content;
  }

  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const rows: string[] = [];

  rows.push("| Layer | Status | Details |");
  rows.push("|---|---|---|");

  // Layer statuses
  if (report.layers) {
    const layerEntries: Array<[string, { status: string; details?: string } | undefined]> = [
      ["Backend", report.layers.backend],
      ["Frontend", report.layers.frontend],
      ["Core", report.layers.core],
      ["Contracts", report.layers.contracts],
    ];
    for (const [name, layer] of layerEntries) {
      if (layer) {
        rows.push(`| ${name} | ${sanitize(layer.status)} | ${sanitize(layer.details ?? "")} |`);
      }
    }
  }

  // Gate statuses
  if (report.gates) {
    const gateEntries: Array<[string, { status: string; details?: string } | undefined]> = [
      ["Security Scan", report.gates.security_scan],
      ["Lockfile Integrity", report.gates.lockfile_integrity],
      ["Cross-Layer Consistency", report.gates.cross_layer_consistency],
    ];
    for (const [name, gate] of gateEntries) {
      if (gate) {
        rows.push(`| ${name} | ${sanitize(gate.status)} | ${sanitize(gate.details ?? "")} |`);
      }
    }
  }

  const sectionHeader = "## CI Readiness Status";
  const sectionContent = rows.join(lineEnding);
  const fullSection = `${sectionHeader}${lineEnding}${lineEnding}${sectionContent}`;

  // Check if section already exists and replace it
  const sectionPattern = /## CI Readiness Status[\s\S]*?(?=\n## |\n# |$)/;
  if (sectionPattern.test(content)) {
    return content.replace(sectionPattern, fullSection);
  }

  // Insert before Changelog if it exists, otherwise append
  const changelogIdx = content.indexOf("## Changelog");
  if (changelogIdx !== -1) {
    return (
      content.substring(0, changelogIdx) +
      fullSection +
      lineEnding +
      lineEnding +
      content.substring(changelogIdx)
    );
  }

  return content.trimEnd() + lineEnding + lineEnding + fullSection + lineEnding;
}

function updateImplementationProgress(
  content: string,
  pr: PrMetadata,
  areas: string[]
): string {
  // Handle both \r\n and \n line endings
  const tableHeaderPattern =
    /(\| PR \| Branch \| Status \| Tasks \|\r?\n\|---\|---\|---\|---\|)/;
  const match = content.match(tableHeaderPattern);
  if (!match) {
    console.log(
      "Could not find Implementation progress table header. Skipping table update."
    );
    return content;
  }

  // Detect line ending style used in the file
  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";

  // Find the end of the existing table rows after the header
  const headerEnd = content.indexOf(match[0]) + match[0].length;
  const afterHeader = content.substring(headerEnd);

  // Find where table rows end (next blank line or next heading)
  const tableEndPattern = lineEnding === "\r\n"
    ? /\r\n\r\n|\r\n##/
    : /\n\n|\n##/;
  const tableEndMatch = afterHeader.match(tableEndPattern);
  const tableEnd = tableEndMatch
    ? headerEnd + (tableEndMatch.index ?? afterHeader.length)
    : headerEnd + afterHeader.length;

  const existingRows = content.substring(headerEnd, tableEnd);

  // Check if this PR is already listed
  if (existingRows.includes(`#${pr.number}`)) {
    console.log(
      `PR #${pr.number} already listed in Implementation progress table.`
    );
    return content;
  }

  const areasStr = areas.join(", ");
  const newRow = `${lineEnding}| [#${pr.number}](https://github.com/wrfcoin/core4/pull/${pr.number}) | \`${getBranchName()}\` | Merged | ${areasStr} |`;

  // Insert new row after existing rows
  return (
    content.substring(0, tableEnd) + newRow + content.substring(tableEnd)
  );
}

function appendChangelog(
  content: string,
  pr: PrMetadata,
  areas: string[]
): string {
  const changelogHeader = "## Changelog";
  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const date = new Date().toISOString().slice(0, 10);
  const entry = `- **${date}** PR [#${pr.number}](https://github.com/wrfcoin/core4/pull/${pr.number}): ${sanitize(pr.title)} (areas: ${areas.join(", ")})`;

  if (content.includes(changelogHeader)) {
    // Append after the changelog header line
    const idx = content.indexOf(changelogHeader);
    const afterHeader = idx + changelogHeader.length;
    // Find end of the heading line
    const lineEnd = content.indexOf(lineEnding, afterHeader);
    const insertPoint = lineEnd === -1 ? content.length : lineEnd;
    return (
      content.substring(0, insertPoint) +
      lineEnding +
      entry +
      content.substring(insertPoint)
    );
  }

  // Create the Changelog section at the end
  return content.trimEnd() + lineEnding + lineEnding + changelogHeader + lineEnding + lineEnding + entry + lineEnding;
}

/**
 * If the "Rust core" gap area was matched, also append a changelog entry
 * to the Rust blockchain feature gap analysis report.
 */
function updateRustGapReport(pr: PrMetadata, areas: string[]): void {
  if (!areas.includes("Rust core")) {
    return;
  }

  if (!existsSync(RUST_REPORT_PATH)) {
    console.log(`Rust gap report not found at ${RUST_REPORT_PATH}. Skipping Rust report update.`);
    return;
  }

  let content: string;
  try {
    content = readFileSync(RUST_REPORT_PATH, "utf-8");
  } catch (err) {
    console.error(`Failed to read Rust gap report at ${RUST_REPORT_PATH}:`, err);
    return;
  }

  content = appendChangelog(content, pr, areas);
  writeFileSync(RUST_REPORT_PATH, content, "utf-8");
  console.log(`Rust gap report updated at ${RUST_REPORT_PATH}`);
}

/**
 * Sanitize user-provided text for safe inclusion in markdown.
 * Strips characters that could break table formatting or inject markdown.
 */
function sanitize(text: string): string {
  return text
    .replace(/\|/g, "-")
    .replace(/[`<>]/g, "")
    .replace(/\n/g, " ")
    .trim()
    .substring(0, 200);
}

function getBranchName(): string {
  return (
    process.env.GITHUB_HEAD_REF ??
    process.env.GITHUB_REF_NAME ??
    process.env.GITHUB_SHA?.substring(0, 7) ??
    "unknown"
  );
}

function main(): void {
  const pr = getPrMetadata();
  const areas = matchGapAreas(pr);

  if (areas.length === 0) {
    console.log(
      `PR #${pr.number} ("${pr.title}") does not match any gap area keywords. No update needed.`
    );
    return;
  }

  console.log(
    `PR #${pr.number} matches gap areas: ${areas.join(", ")}`
  );

  let content: string;
  try {
    content = readFileSync(REPORT_PATH, "utf-8");
  } catch (err) {
    console.error(`Failed to read report at ${REPORT_PATH}:`, err);
    process.exit(1);
  }

  content = updateImplementationProgress(content, pr, areas);
  content = autoResolveGaps(content, areas, pr);
  content = updateResidualCount(content);
  content = updateCIReadinessSection(content);
  content = appendChangelog(content, pr, areas);

  writeFileSync(REPORT_PATH, content, "utf-8");
  console.log(`Gap report updated at ${REPORT_PATH}`);

  // Also update Rust gap report if applicable
  updateRustGapReport(pr, areas);
}

// Export functions for testing
export {
  autoResolveGaps,
  updateResidualCount,
  updateCIReadinessSection,
  updateImplementationProgress,
  appendChangelog,
  matchGapAreas,
  sanitize,
  getBranchName,
  getPrMetadata,
  updateRustGapReport,
  GAP_AREA_PATTERNS,
  REPORT_PATH,
  RUST_REPORT_PATH,
};
export type { PrMetadata, ReadinessReport };

main();
