/**
 * validate-gap-report.ts
 *
 * Validates gap report integrity for CI. Checks that:
 * - Items marked as RESOLVED reference PRs that actually exist and are merged
 * - Open items have not been silently fixed by merged PRs
 *
 * Outputs a DriftReport JSON to stdout and exits with code 1 if drift is detected.
 *
 * Environment variables consumed:
 *   GH_TOKEN - GitHub token for PR verification (optional, uses gh CLI auth)
 */

import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const REPORT_PATH = resolve(
  process.cwd(),
  "reports/frontend-interaction-mapping-summary.md"
);

interface DriftIssue {
  type: "unverified_resolution" | "missed_resolution";
  area: string;
  description: string;
  prNumber?: string;
}

interface DriftReport {
  timestamp: string;
  reportPath: string;
  totalItems: number;
  resolvedItems: number;
  openItems: number;
  driftIssues: DriftIssue[];
  exitCode: number;
}

interface GapItem {
  area: string;
  residualGap: string;
  isResolved: boolean;
  prNumber?: string;
}

interface ProgressEntry {
  prNumber: string;
  areas: string;
  status: string;
}

/**
 * Parse the gap report and extract resolved/open items from the
 * "Remaining open items" table, plus PR entries from the Implementation progress table.
 */
function parseGapReport(filePath: string): {
  items: GapItem[];
  progressEntries: ProgressEntry[];
} {
  const content = readFileSync(filePath, "utf-8");
  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const lines = content.split(lineEnding);

  const items: GapItem[] = [];
  const progressEntries: ProgressEntry[] = [];

  let inRemainingTable = false;
  let inProgressTable = false;
  let pastHeader = false;

  for (const line of lines) {
    // Detect "Remaining open items" section
    if (/^#+\s+Remaining open items/i.test(line)) {
      inRemainingTable = true;
      inProgressTable = false;
      pastHeader = false;
      continue;
    }

    // Detect "Implementation progress" section
    if (/^#+\s+Implementation progress/i.test(line)) {
      inProgressTable = true;
      inRemainingTable = false;
      pastHeader = false;
      continue;
    }

    // Detect new sections (end current table)
    if (/^#+\s/.test(line) && !(/^#+\s+Remaining open items/i.test(line)) && !(/^#+\s+Implementation progress/i.test(line))) {
      inRemainingTable = false;
      inProgressTable = false;
      pastHeader = false;
      continue;
    }

    // Detect header separator
    if ((inRemainingTable || inProgressTable) && !pastHeader && /^\|---/.test(line)) {
      pastHeader = true;
      continue;
    }

    // Skip header row
    if ((inRemainingTable || inProgressTable) && !pastHeader && line.startsWith("|")) {
      continue;
    }

    // Parse remaining open items table rows
    if (inRemainingTable && pastHeader && line.startsWith("|")) {
      const cells = line.split("|").map((c) => c.trim());
      const area = cells[1] ?? "";
      const residualGap = cells[2] ?? "";

      if (!area) continue;

      const isResolved = residualGap.includes("~~");
      let prNumber: string | undefined;

      // Extract PR number from RESOLVED markers like "RESOLVED (PR #123)"
      const prMatch = residualGap.match(/RESOLVED\s*\(PR\s*#(\d+)\)/i);
      if (prMatch) {
        prNumber = prMatch[1];
      }

      items.push({ area, residualGap, isResolved, prNumber });
      continue;
    }

    // Parse implementation progress table rows
    if (inProgressTable && pastHeader && line.startsWith("|")) {
      const cells = line.split("|").map((c) => c.trim());
      // cells: ['', PR link, branch, status, tasks/areas, '']
      const prCell = cells[1] ?? "";
      const status = cells[3] ?? "";
      const areas = cells[4] ?? "";

      const prMatch = prCell.match(/#(\d+)/);
      if (prMatch) {
        progressEntries.push({
          prNumber: prMatch[1],
          areas,
          status,
        });
      }
      continue;
    }

    // Non-table line while in a table section ends the table
    if ((inRemainingTable || inProgressTable) && pastHeader && !line.startsWith("|") && line.trim() !== "" && !line.startsWith(">")) {
      if (line.startsWith("#")) {
        inRemainingTable = false;
        inProgressTable = false;
      }
      pastHeader = false;
    }
  }

  return { items, progressEntries };
}

/**
 * Execute a command safely, returning null on failure instead of throwing.
 */
function execFileNoThrow(
  file: string,
  args: string[]
): { stdout: string; exitCode: number } | null {
  try {
    const stdout = execFileSync(file, args, {
      encoding: "utf-8",
      timeout: 30_000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { stdout, exitCode: 0 };
  } catch (err: unknown) {
    const error = err as { status?: number; stdout?: string };
    if (error.status !== undefined) {
      return { stdout: error.stdout ?? "", exitCode: error.status };
    }
    return null;
  }
}

/**
 * For each RESOLVED item that references a PR#, verify the PR exists and is merged.
 */
function validateResolvedItems(items: GapItem[]): DriftIssue[] {
  const issues: DriftIssue[] = [];

  for (const item of items) {
    if (!item.isResolved || !item.prNumber) continue;

    const result = execFileNoThrow("gh", [
      "pr",
      "view",
      item.prNumber,
      "--json",
      "state,merged",
    ]);

    if (!result) {
      issues.push({
        type: "unverified_resolution",
        area: item.area,
        description: `Could not verify PR #${item.prNumber} (gh CLI unavailable or timed out)`,
        prNumber: item.prNumber,
      });
      continue;
    }

    if (result.exitCode !== 0) {
      issues.push({
        type: "unverified_resolution",
        area: item.area,
        description: `PR #${item.prNumber} does not exist or is not accessible`,
        prNumber: item.prNumber,
      });
      continue;
    }

    try {
      const prData = JSON.parse(result.stdout) as {
        state?: string;
        merged?: boolean;
      };

      if (prData.state !== "MERGED" && prData.merged !== true) {
        issues.push({
          type: "unverified_resolution",
          area: item.area,
          description: `PR #${item.prNumber} is marked as RESOLVED but PR state is "${prData.state ?? "unknown"}" (not merged)`,
          prNumber: item.prNumber,
        });
      }
    } catch {
      issues.push({
        type: "unverified_resolution",
        area: item.area,
        description: `Could not parse gh output for PR #${item.prNumber}`,
        prNumber: item.prNumber,
      });
    }
  }

  return issues;
}

/**
 * For each open item, check if there is a merged PR in the Implementation progress table
 * whose gap areas match the open item's Area column. This indicates a potentially missed resolution.
 */
function detectUnresolvedMatches(
  items: GapItem[],
  progressEntries: ProgressEntry[]
): DriftIssue[] {
  const issues: DriftIssue[] = [];

  // Get merged PRs from progress table
  const mergedPRs = progressEntries.filter(
    (entry) => entry.status.toLowerCase().includes("merged")
  );

  for (const item of items) {
    if (item.isResolved) continue;

    for (const pr of mergedPRs) {
      const prAreas = pr.areas.toLowerCase();
      const itemArea = item.area.toLowerCase();

      if (prAreas.includes(itemArea)) {
        issues.push({
          type: "missed_resolution",
          area: item.area,
          description: `Open item "${item.area}" may have been addressed by merged PR #${pr.prNumber} (listed areas: ${pr.areas})`,
          prNumber: pr.prNumber,
        });
      }
    }
  }

  return issues;
}

function main(): void {
  let reportContent: string;
  try {
    reportContent = readFileSync(REPORT_PATH, "utf-8");
  } catch (err) {
    console.error(`Failed to read report at ${REPORT_PATH}:`, err);
    process.exit(1);
  }

  const { items, progressEntries } = parseGapReport(REPORT_PATH);

  const resolvedItems = items.filter((i) => i.isResolved);
  const openItems = items.filter((i) => !i.isResolved);

  // Validate resolved items against actual PR state
  const resolutionIssues = validateResolvedItems(resolvedItems);

  // Detect open items that might have been missed
  const missedIssues = detectUnresolvedMatches(items, progressEntries);

  const allIssues = [...resolutionIssues, ...missedIssues];

  const report: DriftReport = {
    timestamp: new Date().toISOString(),
    reportPath: REPORT_PATH,
    totalItems: items.length,
    resolvedItems: resolvedItems.length,
    openItems: openItems.length,
    driftIssues: allIssues,
    exitCode: allIssues.length > 0 ? 1 : 0,
  };

  console.log(JSON.stringify(report, null, 2));

  if (report.exitCode !== 0) {
    console.error(
      `\nDrift detected: ${allIssues.length} issue(s) found in gap report.`
    );
    for (const issue of allIssues) {
      console.error(`  [${issue.type}] ${issue.area}: ${issue.description}`);
    }
  } else {
    console.error("\nGap report validation passed. No drift detected.");
  }

  process.exit(report.exitCode);
}

// Export functions for testing
export {
  parseGapReport,
  validateResolvedItems,
  detectUnresolvedMatches,
  execFileNoThrow,
  REPORT_PATH,
};
export type { DriftReport, DriftIssue, GapItem, ProgressEntry };

main();
