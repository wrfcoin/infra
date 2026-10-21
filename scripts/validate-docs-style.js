#!/usr/bin/env node

/**
 * WRFCoin Documentation Style Guide Validator
 *
 * This script validates markdown files against the WRFCoin documentation style guide.
 * It checks for common style issues, formatting problems, and consistency violations.
 */

const fs = require('fs');
const path = require('path');

// Try to use glob, fallback to fs.readdir if not available
let glob;
try {
  glob = require('glob');
} catch (error) {
  console.warn('Glob not available, using fallback directory scanning');
}

// ANSI color codes for console output
const colors = {
  red: '\x1b[31m',
  yellow: '\x1b[33m',
  green: '\x1b[32m',
  blue: '\x1b[34m',
  reset: '\x1b[0m',
  bold: '\x1b[1m',
};

// Style guide rules configuration
const rules = {
  // Heading rules
  singleH1: true, // Only one H1 per document
  properHeadingHierarchy: true, // No skipped heading levels
  noTrailingPunctuation: true, // No periods in headings

  // Code block rules
  specifyLanguage: true, // Code blocks should specify language
  completeExamples: true, // Code examples should be complete

  // Link rules
  relativeInternalLinks: true, // Use relative paths for internal links
  descriptiveLinkText: true, // Avoid "click here", "here", etc.

  // Terminology rules
  consistentTerms: true, // Use standardized terminology

  // Structure rules
  hasOverview: true, // Documents should have overview section
  hasPrerequisites: true, // Tutorials should have prerequisites

  // Language rules
  activeVoice: true, // Prefer active voice
  presentTense: true, // Use present tense for functionality
  secondPerson: true, // Address reader directly

  // Formatting rules
  properListFormatting: true, // Consistent list formatting
  tableHeaders: true, // Tables should have headers

  // Accessibility rules
  altTextForImages: true, // Images should have alt text
  properHeadingStructure: true, // Semantic heading structure
};

// Terminology standards
const terminologyStandards = {
  'wrfcoin platform': ['WRF', 'Wrfcoin', 'WRF-Coin', 'wrfcoin', 'WRFCOIN'],
  'computational NFT': [
    'Comp-NFT',
    'cNFT',
    'computational nft',
    'Computational Nft',
  ],
  'weather oracle': ['Weather API', 'Data Feed', 'weather api', 'data feed'],
  'cross-chain bridge': [
    'Bridge',
    'X-chain',
    'cross chain bridge',
    'crosschain bridge',
  ],
  'DAO governance': ['Governance', 'DAO', 'dao governance', 'Dao Governance'],
  'HSM integration': [
    'HSM',
    'Security module',
    'hsm integration',
    'Hsm Integration',
  ],
  API: ['A.P.I.', 'api', 'Api'],
  JSON: ['json', 'Json'],
  URL: ['url', 'Url'],
  HTTP: ['http', 'Http'],
  HTTPS: ['https', 'Https'],
  SDK: ['sdk', 'Sdk'],
  CLI: ['cli', 'Cli'],
  npm: ['NPM', 'Npm'],
  'Node.js': ['NodeJS', 'nodejs', 'node.js', 'Node.JS'],
};

// Problematic phrases to avoid
const problematicPhrases = [
  'click here',
  'click on',
  'simply',
  'just',
  'easy',
  'obviously',
  'clearly',
  'of course',
  'as you can see',
  'please note that',
  'it should be noted',
  'it is important to note',
];

// Required sections for different document types
const requiredSections = {
  'quick-start': ['overview', 'prerequisites', 'step', 'verify', 'next steps'],
  tutorial: ['overview', "what you'll learn", 'prerequisites', 'step'],
  'api-reference': ['base url', 'authentication', 'endpoints'],
  adr: ['status', 'context', 'decision', 'rationale', 'consequences'],
};

class StyleValidator {
  constructor() {
    this.errors = [];
    this.warnings = [];
    this.suggestions = [];
  }

  validateFile(filePath) {
    console.log(`${colors.blue}Validating:${colors.reset} ${filePath}`);

    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split('\n');

    this.errors = [];
    this.warnings = [];
    this.suggestions = [];

    this.validateHeadings(lines);
    this.validateCodeBlocks(content, lines);
    this.validateLinks(content, lines);
    this.validateTerminology(content);
    this.validateStructure(content, filePath);
    this.validateLanguage(content, lines);
    this.validateFormatting(lines);
    this.validateAccessibility(content, lines);

    return {
      errors: this.errors,
      warnings: this.warnings,
      suggestions: this.suggestions,
    };
  }

  validateHeadings(lines) {
    const headings = lines.filter(line => line.startsWith('#'));
    const h1Count = headings.filter(line => line.match(/^# [^#]/)).length;

    // Rule: Only one H1 per document
    if (rules.singleH1 && h1Count > 1) {
      this.errors.push(
        'Multiple H1 headings found. Use only one H1 per document.'
      );
    }

    if (h1Count === 0) {
      this.errors.push(
        'No H1 heading found. Documents should start with an H1.'
      );
    }

    // Rule: Proper heading hierarchy
    if (rules.properHeadingHierarchy) {
      let currentLevel = 0;
      headings.forEach((heading, index) => {
        const level = heading.match(/^#+/)[0].length;
        if (level > currentLevel + 1) {
          this.errors.push(
            `Heading hierarchy skip detected: H${currentLevel} to H${level} at line with "${heading}"`
          );
        }
        currentLevel = level;
      });
    }

    // Rule: No trailing punctuation in headings
    if (rules.noTrailingPunctuation) {
      headings.forEach(heading => {
        if (heading.match(/[.!?]$/)) {
          this.warnings.push(`Heading ends with punctuation: "${heading}"`);
        }
      });
    }
  }

  validateCodeBlocks(content, lines) {
    const codeBlockPattern = /```(\w*)\n/g;
    let match;

    // Rule: Specify language for code blocks
    if (rules.specifyLanguage) {
      while ((match = codeBlockPattern.exec(content)) !== null) {
        if (!match[1]) {
          this.warnings.push(`Code block without language specification found`);
        }
      }
    }

    // Rule: Complete examples
    if (rules.completeExamples) {
      const incompletePatterns = [/\/\/ \.\.\.$/m, /# \.\.\.$/m, /\.\.\./m];

      incompletePatterns.forEach(pattern => {
        if (content.match(pattern)) {
          this.suggestions.push(
            'Consider providing complete code examples instead of using "..."'
          );
        }
      });
    }
  }

  validateLinks(content, lines) {
    const linkPattern = /\[([^\]]+)\]\(([^)]+)\)/g;
    let match;

    while ((match = linkPattern.exec(content)) !== null) {
      const linkText = match[1].toLowerCase();
      const linkUrl = match[2];

      // Rule: Descriptive link text
      if (rules.descriptiveLinkText) {
        if (
          linkText.includes('click here') ||
          linkText.includes('here') ||
          linkText.includes('this link') ||
          linkText === 'link'
        ) {
          this.warnings.push(`Non-descriptive link text: "${match[1]}"`);
        }
      }

      // Rule: Relative internal links
      if (rules.relativeInternalLinks) {
        if (
          linkUrl.includes('docs.wrfcoin.com') ||
          linkUrl.includes('localhost')
        ) {
          this.warnings.push(`Use relative path for internal link: ${linkUrl}`);
        }
      }
    }
  }

  validateTerminology(content) {
    if (!rules.consistentTerms) return;

    Object.entries(terminologyStandards).forEach(([correct, variations]) => {
      variations.forEach(variation => {
        const regex = new RegExp(`\\b${this.escapeRegex(variation)}\\b`, 'g');
        if (content.match(regex)) {
          this.warnings.push(`Use "${correct}" instead of "${variation}"`);
        }
      });
    });
  }

  validateStructure(content, filePath) {
    const fileName = path.basename(filePath, '.md').toLowerCase();
    const contentLower = content.toLowerCase();

    // Determine document type and check required sections
    let docType = null;
    if (fileName.includes('quick-start') || fileName.includes('quickstart')) {
      docType = 'quick-start';
    } else if (fileName.includes('tutorial')) {
      docType = 'tutorial';
    } else if (fileName.includes('api') || fileName.includes('reference')) {
      docType = 'api-reference';
    } else if (fileName.includes('adr-') || fileName.startsWith('adr')) {
      docType = 'adr';
    }

    if (docType && requiredSections[docType]) {
      requiredSections[docType].forEach(section => {
        if (!contentLower.includes(section)) {
          this.warnings.push(
            `Missing recommended section for ${docType}: "${section}"`
          );
        }
      });
    }

    // Rule: Has overview
    if (
      rules.hasOverview &&
      !contentLower.includes('overview') &&
      !contentLower.includes('introduction')
    ) {
      this.suggestions.push(
        'Consider adding an overview or introduction section'
      );
    }
  }

  validateLanguage(content, lines) {
    // Rule: Avoid problematic phrases
    problematicPhrases.forEach(phrase => {
      const regex = new RegExp(`\\b${this.escapeRegex(phrase)}\\b`, 'gi');
      if (content.match(regex)) {
        this.suggestions.push(`Consider avoiding the phrase "${phrase}"`);
      }
    });

    // Rule: Active voice (basic check)
    if (rules.activeVoice) {
      const passivePatterns = [
        /\bis\s+\w+ed\b/g,
        /\bare\s+\w+ed\b/g,
        /\bwas\s+\w+ed\b/g,
        /\bwere\s+\w+ed\b/g,
        /\bshould\s+be\s+\w+ed\b/g,
      ];

      passivePatterns.forEach(pattern => {
        if (content.match(pattern)) {
          this.suggestions.push(
            'Consider using active voice instead of passive voice'
          );
        }
      });
    }
  }

  validateFormatting(lines) {
    // Rule: Proper list formatting
    if (rules.properListFormatting) {
      let inList = false;
      let listType = null;

      lines.forEach((line, index) => {
        const trimmed = line.trim();

        if (trimmed.match(/^[\-\+\*]\s/)) {
          if (inList && listType === 'ordered') {
            this.warnings.push(`Mixed list types at line ${index + 1}`);
          }
          inList = true;
          listType = 'unordered';
        } else if (trimmed.match(/^\d+\.\s/)) {
          if (inList && listType === 'unordered') {
            this.warnings.push(`Mixed list types at line ${index + 1}`);
          }
          inList = true;
          listType = 'ordered';
        } else if (trimmed === '') {
          // Empty line might end list
        } else {
          inList = false;
          listType = null;
        }
      });
    }
  }

  validateAccessibility(content, lines) {
    // Rule: Alt text for images
    if (rules.altTextForImages) {
      const imagePattern = /!\[([^\]]*)\]\([^)]+\)/g;
      let match;

      while ((match = imagePattern.exec(content)) !== null) {
        if (!match[1] || match[1].trim() === '') {
          this.warnings.push('Image missing alt text for accessibility');
        }
      }
    }
  }

  escapeRegex(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
}

function findMarkdownFiles(dirPath) {
  if (glob) {
    return glob.sync('**/*.md', {
      cwd: dirPath,
      ignore: ['node_modules/**', '.git/**', 'dist/**', 'build/**'],
    });
  } else {
    // Fallback to manual directory scanning
    const files = [];

    function scanDir(currentPath, relativePath = '') {
      const entries = fs.readdirSync(currentPath, { withFileTypes: true });

      for (const entry of entries) {
        if (
          entry.name.startsWith('.') ||
          entry.name === 'node_modules' ||
          entry.name === 'dist' ||
          entry.name === 'build'
        ) {
          continue;
        }

        const fullPath = path.join(currentPath, entry.name);
        const relativeFilePath = path.join(relativePath, entry.name);

        if (entry.isDirectory()) {
          scanDir(fullPath, relativeFilePath);
        } else if (entry.name.endsWith('.md')) {
          files.push(relativeFilePath);
        }
      }
    }

    scanDir(dirPath);
    return files;
  }
}

function validateDirectory(dirPath) {
  const validator = new StyleValidator();
  const markdownFiles = findMarkdownFiles(dirPath);

  let totalErrors = 0;
  let totalWarnings = 0;
  let totalSuggestions = 0;

  console.log(
    `${colors.bold}WRFCoin Documentation Style Validator${colors.reset}\n`
  );
  console.log(`Found ${markdownFiles.length} markdown files to validate\n`);

  markdownFiles.forEach(file => {
    const filePath = path.join(dirPath, file);
    const result = validator.validateFile(filePath);

    if (result.errors.length > 0) {
      console.log(`${colors.red}✗ Errors:${colors.reset}`);
      result.errors.forEach(error => {
        console.log(`  ${colors.red}•${colors.reset} ${error}`);
      });
      totalErrors += result.errors.length;
    }

    if (result.warnings.length > 0) {
      console.log(`${colors.yellow}⚠ Warnings:${colors.reset}`);
      result.warnings.forEach(warning => {
        console.log(`  ${colors.yellow}•${colors.reset} ${warning}`);
      });
      totalWarnings += result.warnings.length;
    }

    if (result.suggestions.length > 0) {
      console.log(`${colors.blue}💡 Suggestions:${colors.reset}`);
      result.suggestions.forEach(suggestion => {
        console.log(`  ${colors.blue}•${colors.reset} ${suggestion}`);
      });
      totalSuggestions += result.suggestions.length;
    }

    if (
      result.errors.length === 0 &&
      result.warnings.length === 0 &&
      result.suggestions.length === 0
    ) {
      console.log(`${colors.green}✓ No issues found${colors.reset}`);
    }

    console.log('');
  });

  // Summary
  console.log(`${colors.bold}Summary:${colors.reset}`);
  console.log(`Files checked: ${markdownFiles.length}`);
  console.log(`${colors.red}Errors: ${totalErrors}${colors.reset}`);
  console.log(`${colors.yellow}Warnings: ${totalWarnings}${colors.reset}`);
  console.log(`${colors.blue}Suggestions: ${totalSuggestions}${colors.reset}`);

  if (totalErrors > 0) {
    console.log(
      `\n${colors.red}❌ Style validation failed. Please fix errors before proceeding.${colors.reset}`
    );
    process.exit(1);
  } else if (totalWarnings > 0) {
    console.log(
      `\n${colors.yellow}⚠️ Style validation completed with warnings.${colors.reset}`
    );
    process.exit(0);
  } else {
    console.log(`\n${colors.green}✅ Style validation passed!${colors.reset}`);
    process.exit(0);
  }
}

// CLI interface
function main() {
  const args = process.argv.slice(2);
  const targetPath = args[0] || 'docs';

  if (args.includes('--help') || args.includes('-h')) {
    console.log(`
WRFCoin Documentation Style Validator

Usage: node validate-docs-style.js [directory]

Options:
  --help, -h    Show this help message
  --version     Show version information

Examples:
  node validate-docs-style.js                    # Validate docs/ directory
  node validate-docs-style.js docs/api          # Validate specific directory
  node validate-docs-style.js docs/tutorial.md  # Validate single file

For more information, see docs/STYLE_GUIDE.md
    `);
    process.exit(0);
  }

  if (args.includes('--version')) {
    console.log('WRFCoin Documentation Style Validator v1.0.0');
    process.exit(0);
  }

  if (!fs.existsSync(targetPath)) {
    console.error(
      `${colors.red}Error: Path "${targetPath}" does not exist${colors.reset}`
    );
    process.exit(1);
  }

  const stat = fs.statSync(targetPath);
  if (stat.isFile()) {
    // Validate single file
    const validator = new StyleValidator();
    const result = validator.validateFile(targetPath);

    console.log(
      `${colors.bold}WRFCoin Documentation Style Validator${colors.reset}\n`
    );

    // Output results similar to directory validation
    if (result.errors.length > 0) {
      console.log(`${colors.red}✗ Errors:${colors.reset}`);
      result.errors.forEach(error =>
        console.log(`  ${colors.red}•${colors.reset} ${error}`)
      );
    }

    if (result.warnings.length > 0) {
      console.log(`${colors.yellow}⚠ Warnings:${colors.reset}`);
      result.warnings.forEach(warning =>
        console.log(`  ${colors.yellow}•${colors.reset} ${warning}`)
      );
    }

    if (result.suggestions.length > 0) {
      console.log(`${colors.blue}💡 Suggestions:${colors.reset}`);
      result.suggestions.forEach(suggestion =>
        console.log(`  ${colors.blue}•${colors.reset} ${suggestion}`)
      );
    }

    if (
      result.errors.length === 0 &&
      result.warnings.length === 0 &&
      result.suggestions.length === 0
    ) {
      console.log(`${colors.green}✓ No issues found${colors.reset}`);
    }

    process.exit(result.errors.length > 0 ? 1 : 0);
  } else {
    // Validate directory
    validateDirectory(targetPath);
  }
}

if (require.main === module) {
  main();
}

module.exports = { StyleValidator, validateDirectory };
