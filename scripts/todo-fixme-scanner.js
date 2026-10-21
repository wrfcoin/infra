#!/usr/bin/env node

/**
 * TODO/FIXME Scanner
 * Scans the repository for TODO or FIXME comments and outputs a report.
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function listFiles() {
  const output = execSync('git ls-files', { encoding: 'utf8' });
  return output.split(/\r?\n/).filter(Boolean);
}

function scanFile(file) {
  const content = fs.readFileSync(file, 'utf8');
  const lines = content.split(/\r?\n/);
  const matches = [];
  lines.forEach((line, idx) => {
    if (/TODO|FIXME/i.test(line)) {
      matches.push({ file, line: idx + 1, text: line.trim() });
    }
  });
  return matches;
}

function scanRepository() {
  const files = listFiles();
  const results = [];
  for (const file of files) {
    try {
      results.push(...scanFile(file));
    } catch (err) {
      // Ignore binary files or read errors
    }
  }
  return results;
}

function generateReport(items) {
  console.log('📝 TODO/FIXME REPORT');
  console.log('='.repeat(70));
  console.log(`Found ${items.length} items\n`);

  items.forEach(item => {
    console.log(`${item.file}:${item.line}  ${item.text}`);
  });

  const reportDir = path.join('reports');
  if (!fs.existsSync(reportDir)) {
    fs.mkdirSync(reportDir, { recursive: true });
  }
  const reportPath = path.join(reportDir, 'todo_report.txt');
  const header = `TODO/FIXME Report\nGenerated: ${new Date().toISOString()}\n\n`;
  const body = items.map(i => `${i.file}:${i.line} ${i.text}`).join('\n');
  fs.writeFileSync(reportPath, header + body + '\n');
  console.log(`\n📄 Report written to ${reportPath}`);
}

const items = scanRepository();
generateReport(items);
