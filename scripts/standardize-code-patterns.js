#!/usr/bin/env node

/**
 * Code Standardization Tool for Wrfcoin Platform
 * Addresses mixed CommonJS/ES6 patterns and large file modularization
 */

const fs = require('fs');
const path = require('path');
const { promisify } = require('util');

class CodeStandardizer {
  constructor() {
    this.fixes = [];
    this.errors = [];
    this.stats = {
      filesAnalyzed: 0,
      filesFixed: 0,
      patternsStandardized: 0,
      filesModularized: 0,
    };
  }

  async standardizeCodebase() {
    console.log('🔧 Starting Code Standardization Process...');
    console.log('📅 Timestamp:', new Date().toISOString());

    await this.analyzeAndFixImportPatterns();
    await this.modularizeLargeFiles();
    await this.standardizeBackendModules();
    await this.optimizeFrontendPatterns();

    this.generateReport();
  }

  async analyzeAndFixImportPatterns() {
    console.log('\n📦 Standardizing Import/Export Patterns...');

    const backendFiles = this.findJSFiles('./backend');
    const frontendFiles = this.findJSFiles('./frontend/src');

    for (const file of backendFiles) {
      await this.standardizeBackendFile(file);
    }

    for (const file of frontendFiles) {
      await this.standardizeFrontendFile(file);
    }
  }

  async standardizeBackendFile(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      this.stats.filesAnalyzed++;

      // Skip if already standardized or has mixed patterns intentionally
      if (this.shouldSkipFile(content, filePath)) {
        return;
      }

      let updatedContent = content;
      let hasChanges = false;

      // Fix mixed require/import patterns in Node.js files
      if (this.hasMixedPatterns(content)) {
        updatedContent = this.standardizeToCommonJS(updatedContent);
        hasChanges = true;
        this.stats.patternsStandardized++;
      }

      // Improve module organization
      if (this.needsModuleReorganization(content)) {
        updatedContent = this.reorganizeModules(updatedContent);
        hasChanges = true;
      }

      if (hasChanges) {
        fs.writeFileSync(filePath, updatedContent);
        this.fixes.push(`Standardized patterns in ${filePath}`);
        this.stats.filesFixed++;
      }
    } catch (error) {
      this.errors.push(`Backend file ${filePath}: ${error.message}`);
    }
  }

  async standardizeFrontendFile(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      this.stats.filesAnalyzed++;

      if (this.shouldSkipFile(content, filePath)) {
        return;
      }

      let updatedContent = content;
      let hasChanges = false;

      // Ensure React files use ES6 imports consistently
      if (filePath.includes('.jsx') || filePath.includes('.js')) {
        const standardized = this.standardizeToES6(updatedContent);
        if (standardized !== updatedContent) {
          updatedContent = standardized;
          hasChanges = true;
          this.stats.patternsStandardized++;
        }
      }

      // Clean up import order and grouping
      if (this.needsImportReorganization(content)) {
        updatedContent = this.reorganizeImports(updatedContent);
        hasChanges = true;
      }

      if (hasChanges) {
        fs.writeFileSync(filePath, updatedContent);
        this.fixes.push(`Standardized frontend patterns in ${filePath}`);
        this.stats.filesFixed++;
      }
    } catch (error) {
      this.errors.push(`Frontend file ${filePath}: ${error.message}`);
    }
  }

  hasMixedPatterns(content) {
    const hasRequire = /const\s+.+\s*=\s*require\s*\(/m.test(content);
    const hasImport = /import\s+.+\s+from\s+['"]/m.test(content);
    const hasExports = /module\.exports\s*=/m.test(content);
    const hasExportDefault = /export\s+(default\s+)?/m.test(content);

    return (hasRequire && hasImport) || (hasExports && hasExportDefault);
  }

  standardizeToCommonJS(content) {
    // Convert ES6 imports to CommonJS requires for Node.js backend
    content = content.replace(
      /import\s+(\w+)\s+from\s+['"](.+)['"];?/g,
      "const $1 = require('$2');"
    );

    content = content.replace(
      /import\s+\{\s*([^}]+)\s*\}\s+from\s+['"](.+)['"];?/g,
      "const { $1 } = require('$2');"
    );

    content = content.replace(
      /export\s+default\s+(.+);?$/gm,
      'module.exports = $1;'
    );

    content = content.replace(
      /export\s+\{\s*([^}]+)\s*\};?/g,
      'module.exports = { $1 };'
    );

    return content;
  }

  standardizeToES6(content) {
    // Only convert if file is clearly a React component or modern JS module
    if (!content.includes('React') && !content.includes('import')) {
      return content;
    }

    // Keep ES6 imports in frontend files
    // Just ensure consistency in import style
    content = content.replace(
      /const\s+(\w+)\s*=\s*require\s*\(\s*['"](.+)['"]\s*\);?/g,
      "import $1 from '$2';"
    );

    return content;
  }

  reorganizeImports(content) {
    const lines = content.split('\n');
    const imports = [];
    const otherLines = [];

    for (const line of lines) {
      if (line.trim().startsWith('import ')) {
        imports.push(line);
      } else {
        otherLines.push(line);
      }
    }

    // Group imports: React, external libraries, internal modules
    const reactImports = imports.filter(imp => imp.includes('react'));
    const libraryImports = imports.filter(
      imp =>
        !imp.includes('react') && !imp.includes('./') && !imp.includes('../')
    );
    const localImports = imports.filter(
      imp => imp.includes('./') || imp.includes('../')
    );

    const organizedImports = [
      ...reactImports,
      ...(reactImports.length > 0 && libraryImports.length > 0 ? [''] : []),
      ...libraryImports,
      ...(libraryImports.length > 0 && localImports.length > 0 ? [''] : []),
      ...localImports,
      ...(imports.length > 0 ? [''] : []),
    ];

    return [...organizedImports, ...otherLines].join('\n');
  }

  reorganizeModules(content) {
    // Organize require statements at the top
    const lines = content.split('\n');
    const requires = [];
    const otherLines = [];

    for (const line of lines) {
      if (line.trim().startsWith('const ') && line.includes('require(')) {
        requires.push(line);
      } else {
        otherLines.push(line);
      }
    }

    // Group requires: Node.js built-in, external packages, local modules
    const builtinRequires = requires.filter(req =>
      /require\s*\(\s*['"](?:fs|path|crypto|http|https|util|url|querystring|os)['"]\s*\)/.test(
        req
      )
    );
    const packageRequires = requires.filter(
      req =>
        !builtinRequires.includes(req) &&
        !req.includes('./') &&
        !req.includes('../')
    );
    const localRequires = requires.filter(
      req => req.includes('./') || req.includes('../')
    );

    const organizedRequires = [
      ...builtinRequires,
      ...(builtinRequires.length > 0 && packageRequires.length > 0 ? [''] : []),
      ...packageRequires,
      ...(packageRequires.length > 0 && localRequires.length > 0 ? [''] : []),
      ...localRequires,
      ...(requires.length > 0 ? [''] : []),
    ];

    return [...organizedRequires, ...otherLines].join('\n');
  }

  async modularizeLargeFiles() {
    console.log('\n📂 Analyzing Large Files for Modularization...');

    const largeFiles = this.findLargeFiles();

    for (const file of largeFiles) {
      await this.analyzeLargeFile(file);
    }
  }

  findLargeFiles() {
    const files = [];
    const checkDirectory = dir => {
      if (!fs.existsSync(dir)) return;

      const items = fs.readdirSync(dir);
      for (const item of items) {
        const fullPath = path.join(dir, item);
        const stat = fs.statSync(fullPath);

        if (stat.isDirectory() && !item.includes('node_modules')) {
          checkDirectory(fullPath);
        } else if (stat.isFile() && item.endsWith('.js') && stat.size > 5000) {
          files.push({ path: fullPath, size: stat.size });
        }
      }
    };

    checkDirectory('./backend');
    checkDirectory('./frontend/src');

    return files.filter(f => f.size > 10000); // Files larger than 10KB
  }

  async analyzeLargeFile(file) {
    try {
      const content = fs.readFileSync(file.path, 'utf8');
      const lines = content.split('\n').length;

      if (lines > 200) {
        console.log(
          `📋 Large file detected: ${file.path} (${lines} lines, ${(file.size / 1024).toFixed(1)}KB)`
        );

        const suggestions = this.generateModularizationSuggestions(
          content,
          file.path
        );
        if (suggestions.length > 0) {
          this.fixes.push(
            `Modularization suggestions for ${file.path}: ${suggestions.join(', ')}`
          );
        }
      }
    } catch (error) {
      this.errors.push(`Large file analysis ${file.path}: ${error.message}`);
    }
  }

  generateModularizationSuggestions(content, filePath) {
    const suggestions = [];

    // Detect multiple class definitions
    const classMatches = content.match(/class\s+\w+/g);
    if (classMatches && classMatches.length > 2) {
      suggestions.push('Extract classes into separate modules');
    }

    // Detect multiple function groups
    const functionMatches = content.match(
      /(?:function\s+\w+|const\s+\w+\s*=\s*(?:async\s+)?\()/g
    );
    if (functionMatches && functionMatches.length > 15) {
      suggestions.push('Group related functions into utility modules');
    }

    // Detect large middleware sections
    if (content.includes('app.use') || content.includes('router.')) {
      const middlewareCount = (content.match(/app\.use|router\./g) || [])
        .length;
      if (middlewareCount > 10) {
        suggestions.push('Extract middleware into separate router modules');
      }
    }

    // Detect multiple API endpoint groups
    const routeMatches = content.match(/app\.(get|post|put|delete|patch)/g);
    if (routeMatches && routeMatches.length > 20) {
      suggestions.push('Split API routes into domain-specific router modules');
    }

    return suggestions;
  }

  async standardizeBackendModules() {
    console.log('\n⚙️  Standardizing Backend Module Patterns...');

    // Ensure consistent error handling patterns
    const serverFiles = this.findJSFiles('./backend/server');
    for (const file of serverFiles) {
      await this.standardizeErrorHandling(file);
    }
  }

  async standardizeErrorHandling(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      let updatedContent = content;
      let hasChanges = false;

      // Standardize error handling patterns
      if (content.includes('try {') && !content.includes('catch (error)')) {
        updatedContent = updatedContent.replace(
          /catch\s*\(\s*(\w+)\s*\)/g,
          'catch (error)'
        );
        hasChanges = true;
      }

      // Ensure consistent async/await patterns
      if (content.includes('async ') && content.includes('.then(')) {
        console.log(
          `⚠️  Mixed async/await and Promise patterns in ${filePath}`
        );
        this.fixes.push(`Consider standardizing to async/await in ${filePath}`);
      }

      if (hasChanges) {
        fs.writeFileSync(filePath, updatedContent);
        this.fixes.push(`Standardized error handling in ${filePath}`);
        this.stats.filesFixed++;
      }
    } catch (error) {
      this.errors.push(
        `Error handling standardization ${filePath}: ${error.message}`
      );
    }
  }

  async optimizeFrontendPatterns() {
    console.log('\n⚛️  Optimizing Frontend Code Patterns...');

    const componentFiles = this.findJSFiles('./frontend/src/components');
    for (const file of componentFiles) {
      await this.optimizeReactComponent(file);
    }
  }

  async optimizeReactComponent(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      let updatedContent = content;
      let hasChanges = false;

      // Ensure proper React import
      if (content.includes('React.') && !content.includes('import React')) {
        updatedContent = `import React from 'react';\n${updatedContent}`;
        hasChanges = true;
      }

      // Standardize component export
      if (
        content.includes('export default ') &&
        content.includes('function ')
      ) {
        // Component is properly structured
      } else if (content.includes('const ') && content.includes('= () =>')) {
        // Arrow function component - acceptable pattern
      }

      if (hasChanges) {
        fs.writeFileSync(filePath, updatedContent);
        this.fixes.push(`Optimized React patterns in ${filePath}`);
        this.stats.filesFixed++;
      }
    } catch (error) {
      this.errors.push(`React optimization ${filePath}: ${error.message}`);
    }
  }

  shouldSkipFile(content, filePath) {
    // Skip test files, configuration files, and generated files
    if (
      filePath.includes('.test.') ||
      filePath.includes('.spec.') ||
      filePath.includes('node_modules') ||
      filePath.includes('.config.') ||
      content.includes('// @generated') ||
      content.includes('/* eslint-disable */')
    ) {
      return true;
    }

    // Skip files that are already well-structured
    if (
      content.includes('// Standardized') ||
      content.includes('/* Standardized */')
    ) {
      return true;
    }

    return false;
  }

  needsModuleReorganization(content) {
    const requireLines = content
      .split('\n')
      .filter(
        line => line.trim().startsWith('const ') && line.includes('require(')
      );

    // Check if requires are scattered throughout the file
    const contentLines = content.split('\n');
    const firstRequireIndex = contentLines.findIndex(
      line => line.trim().startsWith('const ') && line.includes('require(')
    );
    const lastRequireIndex = contentLines
      .map((line, index) =>
        line.trim().startsWith('const ') && line.includes('require(')
          ? index
          : -1
      )
      .filter(index => index !== -1)
      .pop();

    return (
      requireLines.length > 3 &&
      lastRequireIndex - firstRequireIndex > requireLines.length + 5
    );
  }

  needsImportReorganization(content) {
    const importLines = content
      .split('\n')
      .filter(line => line.trim().startsWith('import '));

    if (importLines.length < 3) return false;

    // Check if imports are not grouped properly
    let hasReactImport = false;
    let hasLibraryImport = false;
    let hasLocalImport = false;

    for (const line of importLines) {
      if (line.includes('react')) hasReactImport = true;
      else if (line.includes('./') || line.includes('../'))
        hasLocalImport = true;
      else hasLibraryImport = true;
    }

    return hasReactImport && hasLibraryImport && hasLocalImport;
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
        } else if (
          stat.isFile() &&
          (item.endsWith('.js') || item.endsWith('.jsx'))
        ) {
          files.push(fullPath);
        }
      }
    };

    search(directory);
    return files;
  }

  generateReport() {
    console.log('\n📊 Code Standardization Report');
    console.log('=====================================');
    console.log(`📁 Files Analyzed: ${this.stats.filesAnalyzed}`);
    console.log(`✅ Files Fixed: ${this.stats.filesFixed}`);
    console.log(`🔄 Patterns Standardized: ${this.stats.patternsStandardized}`);
    console.log(
      `📦 Files Analyzed for Modularization: ${this.stats.filesModularized}`
    );

    if (this.fixes.length > 0) {
      console.log('\n✅ Successful Fixes:');
      this.fixes.forEach(fix => console.log(`  • ${fix}`));
    }

    if (this.errors.length > 0) {
      console.log('\n❌ Errors Encountered:');
      this.errors.forEach(error => console.log(`  • ${error}`));
    }

    // Generate detailed report file
    const report = {
      timestamp: new Date().toISOString(),
      statistics: this.stats,
      fixes: this.fixes,
      errors: this.errors,
      summary: {
        success_rate:
          (
            (this.stats.filesFixed / Math.max(this.stats.filesAnalyzed, 1)) *
            100
          ).toFixed(1) + '%',
        recommendation: this.generateRecommendations(),
      },
    };

    const reportPath = `logs/code-standardization-report-${new Date().toISOString().slice(0, 10)}.json`;
    if (!fs.existsSync('logs')) fs.mkdirSync('logs', { recursive: true });
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    console.log(`\n📄 Detailed report saved: ${reportPath}`);
    console.log('✅ Code standardization completed successfully!');
  }

  generateRecommendations() {
    const recommendations = [];

    if (this.stats.patternsStandardized > 0) {
      recommendations.push(
        'Consider adding ESLint rules to prevent mixed import patterns'
      );
    }

    if (this.errors.length > 0) {
      recommendations.push(
        'Review error logs for files that need manual attention'
      );
    }

    if (this.stats.filesFixed < this.stats.filesAnalyzed * 0.1) {
      recommendations.push(
        'Codebase is already well-standardized - maintain current patterns'
      );
    }

    return recommendations;
  }
}

// Execute if run directly
if (require.main === module) {
  const standardizer = new CodeStandardizer();
  standardizer.standardizeCodebase().catch(console.error);
}

module.exports = CodeStandardizer;
