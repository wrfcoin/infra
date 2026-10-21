#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

class LargeFileAnalyzer {
  constructor() {
    this.largeFiles = [];
    this.excludePatterns = [
      'node_modules',
      '.git',
      'dist',
      'build',
      '.vite',
      'coverage',
      '.next',
      'vendor',
      'target',
    ];
  }

  shouldExclude(filePath) {
    return this.excludePatterns.some(pattern => filePath.includes(pattern));
  }

  analyzeFile(filePath) {
    try {
      const stats = fs.statSync(filePath);
      const content = fs.readFileSync(filePath, 'utf8');
      const lines = content.split('\n').length;
      const sizeKB = Math.round(stats.size / 1024);

      // Criteria for "large" files that may need modularization
      const isLarge =
        (filePath.endsWith('.js') && (lines > 200 || sizeKB > 15)) ||
        (filePath.endsWith('.jsx') && (lines > 150 || sizeKB > 12)) ||
        (filePath.endsWith('.ts') && (lines > 200 || sizeKB > 15)) ||
        (filePath.endsWith('.tsx') && (lines > 150 || sizeKB > 12)) ||
        (filePath.endsWith('.rs') && (lines > 300 || sizeKB > 20)) ||
        (filePath.endsWith('.py') && (lines > 250 || sizeKB > 18));

      if (isLarge) {
        this.largeFiles.push({
          path: filePath,
          lines: lines,
          sizeKB: sizeKB,
          extension: path.extname(filePath),
        });
      }
    } catch (error) {
      // Skip files that can't be read
    }
  }

  scanDirectory(dirPath) {
    try {
      const items = fs.readdirSync(dirPath);

      for (const item of items) {
        const fullPath = path.join(dirPath, item);

        if (this.shouldExclude(fullPath)) {
          continue;
        }

        const stats = fs.statSync(fullPath);

        if (stats.isDirectory()) {
          this.scanDirectory(fullPath);
        } else if (stats.isFile()) {
          const ext = path.extname(item);
          if (['.js', '.jsx', '.ts', '.tsx', '.rs', '.py'].includes(ext)) {
            this.analyzeFile(fullPath);
          }
        }
      }
    } catch (error) {
      // Skip directories that can't be read
    }
  }

  generateReport() {
    console.log('🔍 Scanning codebase for large files...\n');

    // Scan main directories
    const dirsToScan = [
      './backend',
      './frontend',
      './src',
      './scripts',
      './contracts',
      './wrfcoin-vm',
      './testing',
      './server',
      './shared',
    ];

    for (const dir of dirsToScan) {
      if (fs.existsSync(dir)) {
        this.scanDirectory(dir);
      }
    }

    // Sort by size (largest first)
    this.largeFiles.sort((a, b) => b.sizeKB - a.sizeKB);

    console.log(
      `📊 Found ${this.largeFiles.length} files that may benefit from modularization:\n`
    );

    return this.largeFiles;
  }
}

// Run the analysis
const analyzer = new LargeFileAnalyzer();
const largeFiles = analyzer.generateReport();

// Output results
largeFiles.forEach((file, index) => {
  console.log(`${index + 1}. ${file.path}`);
  console.log(
    `   Lines: ${file.lines} | Size: ${file.sizeKB}KB | Type: ${file.extension}`
  );
  console.log('');
});

console.log(
  `\n📋 Summary: ${largeFiles.length} files identified for potential modularization`
);

// Export for use in markdown generation
module.exports = { largeFiles };
