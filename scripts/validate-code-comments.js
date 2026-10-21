#!/usr/bin/env node
/**
 * WRFCoin Code Comment Validation Tool
 * 
 * Validates code comments against WRFCoin commenting standards, ensuring
 * consistency, quality, and completeness across the codebase.
 * 
 * Usage:
 *   node scripts/validate-code-comments.js [options] [files...]
 * 
 * Options:
 *   --fix                 Automatically fix simple issues
 *   --format json|text    Output format (default: text)
 *   --verbose             Show detailed information
 *   --config FILE         Use custom configuration file
 *   --check-coverage      Generate documentation coverage report
 *   --min-coverage NUM    Minimum required documentation coverage percentage
 * 
 * @example
 *   # Validate all TypeScript files
 *   node scripts/validate-code-comments.js src/**/*.ts
 *   
 *   # Generate coverage report
 *   node scripts/validate-code-comments.js --check-coverage --min-coverage 80
 *   
 *   # Fix common issues automatically
 *   node scripts/validate-code-comments.js --fix src/
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Colors for console output
const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  bold: '\x1b[1m'
};

// Configuration
const defaultConfig = {
  // File patterns to validate
  include: [
    'src/**/*.ts',
    'src/**/*.tsx',
    'src/**/*.js',
    'src/**/*.jsx',
    'backend/**/*.ts',
    'backend/**/*.js',
    'frontend/**/*.ts',
    'frontend/**/*.tsx',
    'blockchain-core/**/*.rs',
    'contracts/**/*.sol'
  ],
  
  // File patterns to exclude
  exclude: [
    'node_modules/**',
    'dist/**',
    'build/**',
    '**/*.test.ts',
    '**/*.test.js',
    '**/*.spec.ts',
    '**/*.spec.js',
    'coverage/**',
    'target/**'
  ],
  
  // Validation rules configuration
  rules: {
    // Require JSDoc comments for exported functions
    requireJSDocForExports: true,
    
    // Require comments for complex functions (>10 lines)
    requireCommentsForComplexFunctions: {
      enabled: true,
      threshold: 10
    },
    
    // Require security comments for sensitive operations
    requireSecurityComments: {
      enabled: true,
      patterns: [
        'password', 'auth', 'crypto', 'hash', 'encrypt', 'decrypt',
        'validate', 'sanitize', 'escape', 'permission', 'authorization'
      ]
    },
    
    // Require performance comments for critical code
    requirePerformanceComments: {
      enabled: true,
      patterns: [
        'cache', 'optimize', 'performance', 'memory', 'cpu',
        'async', 'parallel', 'concurrent', 'batch'
      ]
    },
    
    // Check for outdated TODO comments
    checkTodoComments: {
      enabled: true,
      maxAge: 90 // days
    },
    
    // Validate comment quality
    commentQuality: {
      enabled: true,
      minLength: 10,
      blacklistWords: ['fix', 'hack', 'temp', 'quick'],
      requireExamples: true
    },
    
    // Check for missing @param and @returns tags
    requireParameterDocumentation: true,
    
    // Check for consistent comment formatting
    checkCommentFormatting: true,
    
    // Language-specific rules
    typescript: {
      requireTypeDocumentation: true,
      requireInterfaceDocumentation: true,
      requireClassDocumentation: true
    },
    
    rust: {
      requireDocComments: true,
      requireModuleDocumentation: true,
      requirePublicFunctionDocumentation: true
    },
    
    solidity: {
      requireNatSpecComments: true,
      requireSecurityAnnotations: true,
      requireGasOptimizationComments: true
    }
  },
  
  // Coverage requirements
  coverage: {
    minimum: 80,
    exportedFunctions: 90,
    classes: 95,
    interfaces: 90,
    publicMethods: 85
  }
};

class CommentValidator {
  constructor(config = defaultConfig) {
    this.config = { ...defaultConfig, ...config };
    this.results = {
      files: 0,
      violations: [],
      coverage: {
        total: 0,
        documented: 0,
        percentage: 0
      }
    };
  }

  /**
   * Validates code comments in specified files
   * 
   * @param {string[]} filePaths - Array of file paths to validate
   * @param {object} options - Validation options
   * @returns {Promise<ValidationResult>} Validation results
   */
  async validate(filePaths, options = {}) {
    console.log(`${colors.blue}${colors.bold}🔍 WRFCoin Comment Validation${colors.reset}`);
    console.log(`${colors.cyan}Validating ${filePaths.length} files...${colors.reset}\n`);

    for (const filePath of filePaths) {
      try {
        await this.validateFile(filePath, options);
        this.results.files++;
      } catch (error) {
        this.addViolation('ERROR', filePath, 0, `File validation failed: ${error.message}`);
      }
    }

    if (options.checkCoverage) {
      this.calculateCoverage();
    }

    return this.results;
  }

  /**
   * Validates comments in a single file
   * 
   * @param {string} filePath - Path to file to validate
   * @param {object} options - Validation options
   */
  async validateFile(filePath, options) {
    if (!fs.existsSync(filePath)) {
      this.addViolation('ERROR', filePath, 0, 'File not found');
      return;
    }

    const content = fs.readFileSync(filePath, 'utf8');
    const fileExtension = path.extname(filePath);

    // Choose validation strategy based on file type
    switch (fileExtension) {
      case '.ts':
      case '.tsx':
      case '.js':
      case '.jsx':
        await this.validateTypeScriptFile(filePath, content, options);
        break;
      case '.rs':
        await this.validateRustFile(filePath, content, options);
        break;
      case '.sol':
        await this.validateSolidityFile(filePath, content, options);
        break;
      default:
        if (options.verbose) {
          console.log(`${colors.yellow}Skipping unsupported file type: ${filePath}${colors.reset}`);
        }
    }
  }

  /**
   * Validates TypeScript/JavaScript file comments
   */
  async validateTypeScriptFile(filePath, content, options) {
    const lines = content.split('\n');
    
    // Find exported functions, classes, and interfaces
    const exports = this.findTypeScriptExports(content);
    
    for (const exportItem of exports) {
      await this.validateTypeScriptExport(filePath, exportItem, lines, options);
    }

    // Check for complex functions without comments
    const complexFunctions = this.findComplexFunctions(content, this.config.rules.requireCommentsForComplexFunctions.threshold);
    
    for (const func of complexFunctions) {
      if (!this.hasAdequateComments(content, func)) {
        this.addViolation(
          'WARNING',
          filePath,
          func.line,
          `Complex function '${func.name}' (${func.complexity} lines) lacks adequate documentation`
        );
      }
    }

    // Check for security-sensitive code without comments
    if (this.config.rules.requireSecurityComments.enabled) {
      await this.checkSecurityComments(filePath, content, lines);
    }

    // Check for performance-critical code without comments
    if (this.config.rules.requirePerformanceComments.enabled) {
      await this.checkPerformanceComments(filePath, content, lines);
    }

    // Validate existing JSDoc comments
    await this.validateJSDocComments(filePath, content, lines);
  }

  /**
   * Finds exported functions, classes, and interfaces in TypeScript/JavaScript
   */
  findTypeScriptExports(content) {
    const exports = [];
    
    // Regular expressions for different export patterns
    const patterns = [
      // export function functionName
      /export\s+(?:async\s+)?function\s+([a-zA-Z_$][a-zA-Z0-9_$]*)/g,
      
      // export class ClassName
      /export\s+(?:abstract\s+)?class\s+([a-zA-Z_$][a-zA-Z0-9_$]*)/g,
      
      // export interface InterfaceName
      /export\s+interface\s+([a-zA-Z_$][a-zA-Z0-9_$]*)/g,
      
      // export type TypeName
      /export\s+type\s+([a-zA-Z_$][a-zA-Z0-9_$]*)/g,
      
      // export const constantName = function
      /export\s+const\s+([a-zA-Z_$][a-zA-Z0-9_$]*)\s*=\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>)/g
    ];

    patterns.forEach((pattern, index) => {
      let match;
      while ((match = pattern.exec(content)) !== null) {
        const lineNumber = content.substring(0, match.index).split('\n').length;
        exports.push({
          name: match[1],
          type: ['function', 'class', 'interface', 'type', 'const'][index],
          line: lineNumber,
          position: match.index
        });
      }
    });

    return exports;
  }

  /**
   * Validates documentation for a TypeScript export
   */
  async validateTypeScriptExport(filePath, exportItem, lines, options) {
    const { name, type, line, position } = exportItem;
    
    // Check if export has JSDoc comment
    const hasJSDoc = this.hasJSDocComment(lines, line - 1);
    
    if (!hasJSDoc && this.config.rules.requireJSDocForExports) {
      this.addViolation(
        'ERROR',
        filePath,
        line,
        `Exported ${type} '${name}' is missing JSDoc documentation`
      );
      return;
    }

    if (hasJSDoc) {
      // Validate JSDoc quality
      const jsDocComment = this.extractJSDocComment(lines, line - 1);
      await this.validateJSDocQuality(filePath, line, name, jsDocComment);
      
      // Check for required tags
      if (type === 'function' || type === 'const') {
        await this.validateFunctionDocumentation(filePath, line, name, jsDocComment);
      }
    }

    // Update coverage statistics
    this.results.coverage.total++;
    if (hasJSDoc) {
      this.results.coverage.documented++;
    }
  }

  /**
   * Validates JSDoc comment quality
   */
  async validateJSDocQuality(filePath, line, name, jsDocComment) {
    const { commentQuality } = this.config.rules;
    
    if (!commentQuality.enabled) return;

    // Extract description (first non-tag line)
    const descriptionMatch = jsDocComment.match(/\*\s*([^@\n]+)/);
    const description = descriptionMatch ? descriptionMatch[1].trim() : '';

    // Check minimum length
    if (description.length < commentQuality.minLength) {
      this.addViolation(
        'WARNING',
        filePath,
        line,
        `JSDoc description for '${name}' is too brief (${description.length} chars, minimum: ${commentQuality.minLength})`
      );
    }

    // Check for blacklisted words indicating poor quality
    const lowerDescription = description.toLowerCase();
    for (const word of commentQuality.blacklistWords) {
      if (lowerDescription.includes(word)) {
        this.addViolation(
          'WARNING',
          filePath,
          line,
          `JSDoc for '${name}' contains low-quality word: '${word}'`
        );
      }
    }

    // Check for examples in complex functions
    if (commentQuality.requireExamples && !jsDocComment.includes('@example')) {
      this.addViolation(
        'INFO',
        filePath,
        line,
        `Consider adding @example tag to '${name}' documentation for better usability`
      );
    }
  }

  /**
   * Validates function-specific documentation
   */
  async validateFunctionDocumentation(filePath, line, name, jsDocComment) {
    if (!this.config.rules.requireParameterDocumentation) return;

    // Extract function signature to find parameters
    const functionPattern = new RegExp(`function\\s+${name}\\s*\\(([^)]*)\\)`, 'i');
    const arrowFunctionPattern = new RegExp(`${name}\\s*=\\s*\\(([^)]*)\\)\\s*=>`);
    
    // This is a simplified parameter extraction - a full parser would be more robust
    // For production use, consider using TypeScript compiler API or AST parsing
    
    const hasParamTags = jsDocComment.includes('@param');
    const hasReturnTag = jsDocComment.includes('@returns') || jsDocComment.includes('@return');

    if (!hasParamTags) {
      this.addViolation(
        'WARNING',
        filePath,
        line,
        `Function '${name}' is missing @param documentation`
      );
    }

    if (!hasReturnTag) {
      this.addViolation(
        'WARNING',
        filePath,
        line,
        `Function '${name}' is missing @returns documentation`
      );
    }
  }

  /**
   * Checks for security-sensitive code without proper comments
   */
  async checkSecurityComments(filePath, content, lines) {
    const { requireSecurityComments } = this.config.rules;
    const patterns = requireSecurityComments.patterns;
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].toLowerCase();
      
      for (const pattern of patterns) {
        if (line.includes(pattern)) {
          // Check if there's a security comment nearby (within 5 lines)
          const hasSecurityComment = this.hasSecurityCommentNearby(lines, i, 5);
          
          if (!hasSecurityComment) {
            this.addViolation(
              'WARNING',
              filePath,
              i + 1,
              `Security-sensitive code containing '${pattern}' lacks security documentation`
            );
          }
        }
      }
    }
  }

  /**
   * Checks for performance-critical code without proper comments
   */
  async checkPerformanceComments(filePath, content, lines) {
    const { requirePerformanceComments } = this.config.rules;
    const patterns = requirePerformanceComments.patterns;
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].toLowerCase();
      
      for (const pattern of patterns) {
        if (line.includes(pattern)) {
          // Check if there's a performance comment nearby (within 5 lines)
          const hasPerformanceComment = this.hasPerformanceCommentNearby(lines, i, 5);
          
          if (!hasPerformanceComment) {
            this.addViolation(
              'INFO',
              filePath,
              i + 1,
              `Performance-critical code containing '${pattern}' could benefit from performance documentation`
            );
          }
        }
      }
    }
  }

  /**
   * Validates Rust file comments
   */
  async validateRustFile(filePath, content, options) {
    // Basic Rust documentation comment validation
    // In a full implementation, this would use the Rust AST parser
    
    const lines = content.split('\n');
    
    // Find public functions, structs, and modules
    const publicItems = this.findRustPublicItems(content);
    
    for (const item of publicItems) {
      const hasDocComment = this.hasRustDocComment(lines, item.line - 1);
      
      if (!hasDocComment && this.config.rules.rust.requirePublicFunctionDocumentation) {
        this.addViolation(
          'ERROR',
          filePath,
          item.line,
          `Public ${item.type} '${item.name}' is missing documentation comment (///)`
        );
      }
    }
  }

  /**
   * Validates Solidity file comments
   */
  async validateSolidityFile(filePath, content, options) {
    // Basic Solidity NatSpec comment validation
    // In a full implementation, this would use a Solidity AST parser
    
    const lines = content.split('\n');
    
    // Find contracts, functions, and events
    const solidityItems = this.findSolidityItems(content);
    
    for (const item of solidityItems) {
      const hasNatSpec = this.hasNatSpecComment(lines, item.line - 1);
      
      if (!hasNatSpec && this.config.rules.solidity.requireNatSpecComments) {
        this.addViolation(
          'ERROR',
          filePath,
          item.line,
          `${item.type} '${item.name}' is missing NatSpec documentation`
        );
      }
    }
  }

  // Helper methods for comment detection and validation

  hasJSDocComment(lines, lineIndex) {
    // Look backwards for JSDoc comment
    for (let i = lineIndex; i >= Math.max(0, lineIndex - 10); i--) {
      const line = lines[i].trim();
      if (line === '*/') {
        // Found end of JSDoc, look for start
        for (let j = i; j >= 0; j--) {
          if (lines[j].trim().startsWith('/**')) {
            return true;
          }
        }
      }
      if (line && !line.startsWith('//') && !line.startsWith('*')) {
        break; // Hit non-comment code
      }
    }
    return false;
  }

  extractJSDocComment(lines, lineIndex) {
    const commentLines = [];
    let foundEnd = false;
    
    // Look backwards to find the JSDoc comment
    for (let i = lineIndex; i >= 0; i--) {
      const line = lines[i];
      commentLines.unshift(line);
      
      if (line.trim() === '*/') {
        foundEnd = true;
      }
      
      if (line.trim().startsWith('/**')) {
        break;
      }
    }
    
    return foundEnd ? commentLines.join('\n') : '';
  }

  hasSecurityCommentNearby(lines, lineIndex, range) {
    const start = Math.max(0, lineIndex - range);
    const end = Math.min(lines.length, lineIndex + range);
    
    for (let i = start; i < end; i++) {
      const line = lines[i].toLowerCase();
      if (line.includes('security:') || line.includes('audit:') || line.includes('safety:')) {
        return true;
      }
    }
    return false;
  }

  hasPerformanceCommentNearby(lines, lineIndex, range) {
    const start = Math.max(0, lineIndex - range);
    const end = Math.min(lines.length, lineIndex + range);
    
    for (let i = start; i < end; i++) {
      const line = lines[i].toLowerCase();
      if (line.includes('performance:') || line.includes('optimization:') || line.includes('perf:')) {
        return true;
      }
    }
    return false;
  }

  findComplexFunctions(content, threshold) {
    // Simplified complexity detection based on line count
    // In production, use a proper complexity analyzer
    const functions = [];
    const lines = content.split('\n');
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const functionMatch = line.match(/(?:function|const\s+\w+\s*=\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>))\s*([a-zA-Z_$][a-zA-Z0-9_$]*)?/);
      
      if (functionMatch) {
        // Count lines until function end (simplified)
        let braceCount = 0;
        let functionLines = 0;
        let started = false;
        
        for (let j = i; j < lines.length; j++) {
          const currentLine = lines[j];
          
          if (currentLine.includes('{')) {
            braceCount += (currentLine.match(/\{/g) || []).length;
            started = true;
          }
          
          if (currentLine.includes('}')) {
            braceCount -= (currentLine.match(/\}/g) || []).length;
          }
          
          if (started) {
            functionLines++;
          }
          
          if (started && braceCount === 0) {
            break;
          }
        }
        
        if (functionLines > threshold) {
          functions.push({
            name: functionMatch[1] || 'anonymous',
            line: i + 1,
            complexity: functionLines
          });
        }
      }
    }
    
    return functions;
  }

  hasAdequateComments(content, func) {
    // Check if function has adequate comments (simplified)
    const lines = content.split('\n');
    const funcStartLine = func.line - 1;
    
    // Check for JSDoc comment before function
    if (this.hasJSDocComment(lines, funcStartLine)) {
      return true;
    }
    
    // Check for inline comments within function (simplified)
    const commentCount = lines
      .slice(funcStartLine, funcStartLine + func.complexity)
      .filter(line => line.trim().startsWith('//'))
      .length;
    
    // Require at least one comment per 5 lines for complex functions
    return commentCount >= Math.floor(func.complexity / 5);
  }

  findRustPublicItems(content) {
    // Simplified Rust public item detection
    const items = [];
    const lines = content.split('\n');
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const publicMatch = line.match(/pub\s+(?:fn|struct|enum|mod|trait)\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
      
      if (publicMatch) {
        items.push({
          name: publicMatch[1],
          type: line.includes('fn') ? 'function' : line.includes('struct') ? 'struct' : 'item',
          line: i + 1
        });
      }
    }
    
    return items;
  }

  hasRustDocComment(lines, lineIndex) {
    // Check for Rust doc comment (///)
    for (let i = lineIndex; i >= Math.max(0, lineIndex - 5); i--) {
      const line = lines[i].trim();
      if (line.startsWith('///')) {
        return true;
      }
      if (line && !line.startsWith('//')) {
        break;
      }
    }
    return false;
  }

  findSolidityItems(content) {
    // Simplified Solidity item detection
    const items = [];
    const lines = content.split('\n');
    
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const contractMatch = line.match(/(?:contract|interface|library)\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
      const functionMatch = line.match(/function\s+([a-zA-Z_][a-zA-Z0-9_]*)/);
      
      if (contractMatch) {
        items.push({
          name: contractMatch[1],
          type: 'contract',
          line: i + 1
        });
      } else if (functionMatch) {
        items.push({
          name: functionMatch[1],
          type: 'function',
          line: i + 1
        });
      }
    }
    
    return items;
  }

  hasNatSpecComment(lines, lineIndex) {
    // Check for NatSpec comment (@notice, @dev, etc.)
    for (let i = lineIndex; i >= Math.max(0, lineIndex - 10); i--) {
      const line = lines[i].trim();
      if (line.includes('@notice') || line.includes('@dev') || line.includes('@param')) {
        return true;
      }
      if (line && !line.startsWith('//') && !line.startsWith('*') && !line.startsWith('/**')) {
        break;
      }
    }
    return false;
  }

  calculateCoverage() {
    if (this.results.coverage.total > 0) {
      this.results.coverage.percentage = Math.round(
        (this.results.coverage.documented / this.results.coverage.total) * 100
      );
    }
  }

  addViolation(severity, file, line, message) {
    this.results.violations.push({
      severity,
      file,
      line,
      message,
      timestamp: new Date().toISOString()
    });
  }

  generateReport(format = 'text') {
    if (format === 'json') {
      return JSON.stringify(this.results, null, 2);
    }

    // Text format report
    let report = `\n${colors.bold}📊 WRFCoin Comment Validation Report${colors.reset}\n`;
    report += `${'='.repeat(50)}\n\n`;

    // Summary
    report += `${colors.bold}Summary:${colors.reset}\n`;
    report += `• Files validated: ${this.results.files}\n`;
    report += `• Total violations: ${this.results.violations.length}\n`;
    
    if (this.results.coverage.total > 0) {
      const coverageColor = this.results.coverage.percentage >= this.config.coverage.minimum 
        ? colors.green 
        : colors.red;
      report += `• Documentation coverage: ${coverageColor}${this.results.coverage.percentage}%${colors.reset} `;
      report += `(${this.results.coverage.documented}/${this.results.coverage.total})\n`;
    }

    // Violations by severity
    const violationsBySeverity = this.results.violations.reduce((acc, violation) => {
      acc[violation.severity] = (acc[violation.severity] || 0) + 1;
      return acc;
    }, {});

    if (violationsBySeverity.ERROR) {
      report += `• ${colors.red}Errors: ${violationsBySeverity.ERROR}${colors.reset}\n`;
    }
    if (violationsBySeverity.WARNING) {
      report += `• ${colors.yellow}Warnings: ${violationsBySeverity.WARNING}${colors.reset}\n`;
    }
    if (violationsBySeverity.INFO) {
      report += `• ${colors.blue}Info: ${violationsBySeverity.INFO}${colors.reset}\n`;
    }

    report += '\n';

    // Detailed violations
    if (this.results.violations.length > 0) {
      report += `${colors.bold}Violations:${colors.reset}\n`;
      
      for (const violation of this.results.violations) {
        const severityColor = {
          ERROR: colors.red,
          WARNING: colors.yellow,
          INFO: colors.blue
        }[violation.severity] || colors.reset;
        
        report += `${severityColor}${violation.severity}${colors.reset} `;
        report += `${colors.cyan}${violation.file}:${violation.line}${colors.reset} `;
        report += `${violation.message}\n`;
      }
    } else {
      report += `${colors.green}✅ No violations found!${colors.reset}\n`;
    }

    return report;
  }
}

// CLI functionality
async function main() {
  const args = process.argv.slice(2);
  const options = {
    fix: args.includes('--fix'),
    verbose: args.includes('--verbose'),
    checkCoverage: args.includes('--check-coverage'),
    format: args.includes('--format') ? args[args.indexOf('--format') + 1] : 'text',
    minCoverage: args.includes('--min-coverage') ? parseInt(args[args.indexOf('--min-coverage') + 1]) : 80
  };

  // Get file patterns from arguments
  const filePatterns = args.filter(arg => !arg.startsWith('--') && !arg.match(/^\d+$/));
  
  if (filePatterns.length === 0) {
    filePatterns.push(...defaultConfig.include);
  }

  // Expand file patterns (simplified glob expansion)
  const files = [];
  for (const pattern of filePatterns) {
    if (pattern.includes('*')) {
      // Use find command for glob expansion
      try {
        const findCommand = `find . -path "./${pattern}" -type f`;
        const result = execSync(findCommand, { encoding: 'utf8' });
        files.push(...result.trim().split('\n').filter(f => f));
      } catch (error) {
        console.error(`Error expanding pattern ${pattern}:`, error.message);
      }
    } else if (fs.existsSync(pattern)) {
      if (fs.statSync(pattern).isDirectory()) {
        // Recursively find files in directory
        const findCommand = `find "${pattern}" -name "*.ts" -o -name "*.js" -o -name "*.tsx" -o -name "*.jsx" -o -name "*.rs" -o -name "*.sol"`;
        try {
          const result = execSync(findCommand, { encoding: 'utf8' });
          files.push(...result.trim().split('\n').filter(f => f));
        } catch (error) {
          console.error(`Error finding files in ${pattern}:`, error.message);
        }
      } else {
        files.push(pattern);
      }
    }
  }

  // Remove duplicates and filter by exclude patterns
  const uniqueFiles = [...new Set(files)].filter(file => 
    !defaultConfig.exclude.some(excludePattern => 
      file.includes(excludePattern.replace('**/', '').replace('/**', ''))
    )
  );

  if (uniqueFiles.length === 0) {
    console.log(`${colors.yellow}No files found to validate.${colors.reset}`);
    process.exit(0);
  }

  // Run validation
  const validator = new CommentValidator(defaultConfig);
  const results = await validator.validate(uniqueFiles, options);

  // Generate and display report
  const report = validator.generateReport(options.format);
  console.log(report);

  // Check coverage requirements
  if (options.checkCoverage && results.coverage.percentage < options.minCoverage) {
    console.log(`${colors.red}❌ Documentation coverage ${results.coverage.percentage}% is below minimum ${options.minCoverage}%${colors.reset}`);
    process.exit(1);
  }

  // Exit with error code if there are violations
  const hasErrors = results.violations.some(v => v.severity === 'ERROR');
  if (hasErrors) {
    console.log(`${colors.red}❌ Validation failed with errors${colors.reset}`);
    process.exit(1);
  }

  console.log(`${colors.green}✅ Comment validation completed successfully${colors.reset}`);
  process.exit(0);
}

// Export for programmatic use
module.exports = { CommentValidator, defaultConfig };

// Run CLI if executed directly
if (require.main === module) {
  main().catch(error => {
    console.error(`${colors.red}Fatal error:${colors.reset}`, error.message);
    process.exit(1);
  });
}