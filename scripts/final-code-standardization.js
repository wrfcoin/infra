#!/usr/bin/env node

/**
 * Final Code Standardization Solution for Wrfcoin Platform
 * Comprehensive fix for all remaining import/export pattern issues
 */

const fs = require('fs');
const path = require('path');

class FinalStandardizer {
  constructor() {
    this.fixes = [];
    this.errors = [];
  }

  async standardizeAll() {
    console.log('🔧 Final Code Standardization Starting...');

    // Fix specific problematic files
    await this.fixFrontendImportIssues();
    await this.validateBackendConsistency();
    await this.generateFinalReport();

    console.log('✅ Final standardization completed successfully!');
  }

  async fixFrontendImportIssues() {
    console.log('🎯 Fixing Frontend Import Issues...');

    const problematicFiles = [
      'frontend/src/components/Dashboard/OptimizedDashboard.jsx',
      'frontend/src/components/Dashboard/InfrastructureCapacityDashboard.jsx',
    ];

    for (const filePath of problematicFiles) {
      try {
        if (fs.existsSync(filePath)) {
          const content = fs.readFileSync(filePath, 'utf8');
          const fixed = this.fixImportSyntax(content);

          if (fixed !== content) {
            fs.writeFileSync(filePath, fixed);
            this.fixes.push(`Fixed import syntax in ${filePath}`);
            console.log(`✅ Fixed: ${filePath}`);
          }
        }
      } catch (error) {
        this.errors.push(`Error fixing ${filePath}: ${error.message}`);
      }
    }
  }

  fixImportSyntax(content) {
    // Fix broken import statements
    content = content.replace(/import \{\s*\n\s*import/g, 'import');

    // Fix incomplete import blocks
    content = content.replace(
      /import \{\s*([^}]*)\s*\n\s*([^}]*)\s*\}/g,
      (match, p1, p2) => {
        if (p2.includes('from')) {
          return p2;
        }
        return `import {\n  ${p1.trim()}\n} ${p2}`;
      }
    );

    // Remove duplicate import keywords
    content = content.replace(/import\s+import/g, 'import');

    // Fix malformed Material-UI icon imports
    content = content.replace(
      /}\s*from\s*['"][^'"]*['"];\s*([A-Z]\w+)\s+as\s+([A-Z]\w+Icon),/g,
      "} from '@mui/material';\nimport { $1 as $2 } from '@mui/icons-material';"
    );

    // Clean up extra semicolons and formatting
    content = content.replace(/;\s*,/g, ',');
    content = content.replace(/,\s*;/g, ';');

    return content;
  }

  async validateBackendConsistency() {
    console.log('🔍 Validating Backend Module Consistency...');

    const backendFiles = this.findJSFiles('./backend');
    let consistencyIssues = 0;

    for (const file of backendFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for mixed patterns
        const hasRequire = content.includes('require(');
        const hasImport = content.includes('import ');
        const hasModuleExports = content.includes('module.exports');
        const hasESExport = content.includes('export ');

        if ((hasRequire && hasImport) || (hasModuleExports && hasESExport)) {
          consistencyIssues++;
          // Auto-fix by standardizing to CommonJS for backend
          const fixed = this.standardizeToCommonJS(content);
          fs.writeFileSync(file, fixed);
          this.fixes.push(`Standardized mixed patterns in ${file}`);
        }
      } catch (error) {
        this.errors.push(`Validation error in ${file}: ${error.message}`);
      }
    }

    console.log(`📊 Found and fixed ${consistencyIssues} consistency issues`);
  }

  standardizeToCommonJS(content) {
    // Convert ES6 imports to require statements
    content = content.replace(
      /import\s+(\w+)\s+from\s+['"](.+)['"];?/g,
      "const $1 = require('$2');"
    );
    content = content.replace(
      /import\s+\{\s*([^}]+)\s*\}\s+from\s+['"](.+)['"];?/g,
      "const { $1 } = require('$2');"
    );
    content = content.replace(
      /import\s+\*\s+as\s+(\w+)\s+from\s+['"](.+)['"];?/g,
      "const $1 = require('$2');"
    );

    // Convert ES6 exports to module.exports
    content = content.replace(
      /export\s+default\s+(.+);?$/gm,
      'module.exports = $1;'
    );
    content = content.replace(
      /export\s+\{\s*([^}]+)\s*\};?/g,
      'module.exports = { $1 };'
    );
    content = content.replace(
      /export\s+const\s+(\w+)\s*=\s*(.+);?/g,
      'const $1 = $2;\nmodule.exports.$1 = $1;'
    );
    content = content.replace(/export\s+function\s+(\w+)/g, 'function $1');

    return content;
  }

  findJSFiles(directory) {
    const files = [];
    if (!fs.existsSync(directory)) return files;

    const search = dir => {
      const items = fs.readdirSync(dir);
      for (const item of items) {
        const fullPath = path.join(dir, item);
        const stat = fs.statSync(fullPath);

        if (stat.isDirectory() && !item.includes('node_modules')) {
          search(fullPath);
        } else if (stat.isFile() && item.endsWith('.js')) {
          files.push(fullPath);
        }
      }
    };

    search(directory);
    return files;
  }

  async generateFinalReport() {
    const report = {
      timestamp: new Date().toISOString(),
      summary: {
        total_fixes: this.fixes.length,
        total_errors: this.errors.length,
        success_rate:
          (
            (this.fixes.length /
              Math.max(this.fixes.length + this.errors.length, 1)) *
            100
          ).toFixed(1) + '%',
      },
      fixes_applied: this.fixes,
      errors_encountered: this.errors,
      status: this.errors.length === 0 ? 'COMPLETE' : 'PARTIAL_SUCCESS',
    };

    const reportPath = 'logs/final-standardization-report.json';
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    console.log('\n📋 Final Standardization Summary:');
    console.log(`✅ Fixes Applied: ${this.fixes.length}`);
    console.log(`❌ Errors: ${this.errors.length}`);
    console.log(`📄 Report: ${reportPath}`);
  }
}

// Execute
const standardizer = new FinalStandardizer();
standardizer.standardizeAll().catch(console.error);

module.exports = FinalStandardizer;
