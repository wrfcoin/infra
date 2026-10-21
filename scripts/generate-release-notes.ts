/**
 * generate-release-notes.ts
 *
 * Generates release notes from gap report diffs by comparing the current
 * state of gap analysis reports against the previous commit.
 *
 * Output: reports/release-notes/YYYY-MM-DD-release-notes.md
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const REPORT_PATH = resolve(
  process.cwd(),
  "reports/frontend-interaction-mapping-summary.md"
);

const RELEASE_NOTES_DIR = resolve(process.cwd(), "reports/release-notes");

const READINESS_REPORT_PATH = resolve(process.cwd(), "readiness-report.json");

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
 * Get the diff of the gap report between HEAD~1 and HEAD.
 * Returns null if there is no previous commit or the diff fails.
 */
function getReportDiff(): string | null {
  // First check if there is a previous commit to diff against
  const logResult = execFileNoThrow("git", ["rev-parse", "HEAD~1"]);
  if (!logResult || logResult.exitCode !== 0) {
    console.log("No previous commit to diff against. Generating initial release notes.");
    return null;
  }

  const result = execFileNoThrow("git", [
    "diff",
    "HEAD~1",
    "--",
    REPORT_PATH,
  ]);

  if (!result || result.exitCode !== 0) {
    return null;
  }

  return result.stdout;
}

interface ResolvedGap {
  text: string;
  prNumber?: string;
}

interface ReleaseNotesData {
  resolvedGaps: ResolvedGap[];
  residualGapCount: { open: number; total: number } | null;
  readinessChanges: string[];
}

/**
 * Parse the diff output for newly resolved gaps and changes.
 */
function parseDiff(diff: string): ReleaseNotesData {
  const resolvedGaps: ResolvedGap[] = [];
  const readinessChanges: string[] = [];
  let residualGapCount: { open: number; total: number } | null = null;

  const lines = diff.split("\n");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Lines starting with + that contain ~~ (newly resolved gaps)
    // Exclude +++ (diff header)
    if (line.startsWith("+") && !line.startsWith("+++") && line.includes("~~")) {
      const text = line.substring(1).trim();
      const prMatch = text.match(/PR\s*#(\d+)/i);
      resolvedGaps.push({
        text,
        prNumber: prMatch?.[1],
      });
      continue;
    }

    // Detect items that changed from unresolved to resolved
    // Look for - line without ~~ followed by + line with ~~
    if (line.startsWith("-") && !line.startsWith("---") && !line.includes("~~")) {
      const nextLine = lines[i + 1];
      if (nextLine?.startsWith("+") && !nextLine.startsWith("+++") && nextLine.includes("~~")) {
        const text = nextLine.substring(1).trim();
        const prMatch = text.match(/PR\s*#(\d+)/i);
        if (!resolvedGaps.some((g) => g.text === text)) {
          resolvedGaps.push({
            text,
            prNumber: prMatch?.[1],
          });
        }
      }
    }

    // Detect residual gap count changes
    if (line.startsWith("+") && !line.startsWith("+++") && line.includes("Residual gaps:")) {
      const countMatch = line.match(/(\d+)\s+of\s+(\d+)\s+items/);
      if (countMatch) {
        residualGapCount = {
          open: parseInt(countMatch[1], 10),
          total: parseInt(countMatch[2], 10),
        };
      }
    }

    // Detect CI readiness changes
    if (line.startsWith("+") && !line.startsWith("+++") && line.includes("CI Readiness")) {
      readinessChanges.push(line.substring(1).trim());
    }

    // Detect layer/gate status changes in readiness table
    if (line.startsWith("+") && !line.startsWith("+++") && /^\+\|.+\|.+\|.+\|$/.test(line)) {
      const cells = line.substring(1).split("|").map((c) => c.trim());
      const layer = cells[1] ?? "";
      const status = cells[2] ?? "";
      if (layer && status && !layer.startsWith("---") && layer !== "Layer") {
        readinessChanges.push(`${layer}: ${status}`);
      }
    }
  }

  return { resolvedGaps, residualGapCount, readinessChanges };
}

/**
 * Count current residual gaps from the report file directly (fallback when no diff).
 */
function countCurrentResidualGaps(): { open: number; total: number } | null {
  if (!existsSync(REPORT_PATH)) {
    return null;
  }

  const content = readFileSync(REPORT_PATH, "utf-8");
  const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
  const lines = content.split(lineEnding);

  let inRemainingTable = false;
  let pastHeader = false;
  let total = 0;
  let open = 0;

  for (const line of lines) {
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
      total++;
      const cells = line.split("|").map((c) => c.trim());
      const residualGap = cells[2] ?? "";
      if (!residualGap.includes("~~")) {
        open++;
      }
      continue;
    }

    if (inRemainingTable && pastHeader && !line.startsWith("|")) {
      break;
    }
  }

  if (total === 0) return null;
  return { open, total };
}

/**
 * Generate the release notes markdown content.
 */
function generateReleaseNotesContent(data: ReleaseNotesData): string {
  const date = new Date().toISOString().slice(0, 10);
  const lines: string[] = [];

  lines.push(`# Release Notes - ${date}`);
  lines.push("");
  lines.push(`Generated from gap report analysis.`);
  lines.push("");

  // Resolved Gaps
  lines.push("## Resolved Gaps");
  lines.push("");
  if (data.resolvedGaps.length === 0) {
    lines.push("No new gaps resolved in this release.");
  } else {
    for (const gap of data.resolvedGaps) {
      const prRef = gap.prNumber ? ` (PR #${gap.prNumber})` : "";
      // Clean up table formatting for display
      const cleanText = gap.text
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .replace(/\|/g, " - ")
        .replace(/~~/g, "")
        .replace(/\*\*RESOLVED.*?\*\*/i, "")
        .trim();
      lines.push(`- ${cleanText}${prRef}`);
    }
  }
  lines.push("");

  // Residual Gaps
  lines.push("## Residual Gaps");
  lines.push("");
  if (data.residualGapCount) {
    lines.push(
      `**${data.residualGapCount.open} of ${data.residualGapCount.total}** items remain open.`
    );
  } else {
    lines.push("Residual gap count not available.");
  }
  lines.push("");

  // Changed Risk/Readiness
  lines.push("## Changed Risk/Readiness");
  lines.push("");
  if (data.readinessChanges.length === 0) {
    lines.push("No CI readiness changes detected in this release.");
  } else {
    for (const change of data.readinessChanges) {
      lines.push(`- ${change}`);
    }
  }
  lines.push("");

  return lines.join("\n");
}

function main(): void {
  // Ensure the release-notes directory exists
  mkdirSync(RELEASE_NOTES_DIR, { recursive: true });

  const diff = getReportDiff();

  let data: ReleaseNotesData;

  if (diff && diff.trim().length > 0) {
    data = parseDiff(diff);
    // If we didn't get residual count from diff, try reading the file directly
    if (!data.residualGapCount) {
      data.residualGapCount = countCurrentResidualGaps();
    }
  } else {
    // No diff available - generate from current state
    data = {
      resolvedGaps: [],
      residualGapCount: countCurrentResidualGaps(),
      readinessChanges: [],
    };
  }

  const content = generateReleaseNotesContent(data);

  const date = new Date().toISOString().slice(0, 10);
  const outputPath = resolve(RELEASE_NOTES_DIR, `${date}-release-notes.md`);

  writeFileSync(outputPath, content, "utf-8");
  console.log(`Release notes generated at ${outputPath}`);
}

// Export functions for testing
export {
  getReportDiff,
  parseDiff,
  countCurrentResidualGaps,
  generateReleaseNotesContent,
  execFileNoThrow,
  REPORT_PATH,
  RELEASE_NOTES_DIR,
};
export type { ResolvedGap, ReleaseNotesData };

main();
