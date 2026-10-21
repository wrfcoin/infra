#!/usr/bin/env node

/**
 * Wrfcoin Security Audit Tool
 * Comprehensive security assessment for blockchain infrastructure
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

class WrfcoinSecurityAudit {
  constructor() {
    this.findings = [];
    this.criticalIssues = 0;
    this.highIssues = 0;
    this.mediumIssues = 0;
    this.lowIssues = 0;
  }

  addFinding(severity, category, description, recommendation, file = null) {
    this.findings.push({
      severity,
      category,
      description,
      recommendation,
      file,
      timestamp: new Date().toISOString(),
    });

    switch (severity) {
      case 'CRITICAL':
        this.criticalIssues++;
        break;
      case 'HIGH':
        this.highIssues++;
        break;
      case 'MEDIUM':
        this.mediumIssues++;
        break;
      case 'LOW':
        this.lowIssues++;
        break;
    }
  }

  async auditEnvironmentVariables() {
    console.log('\n🔐 Auditing Environment Variables...');

    // Check for exposed secrets
    const sensitiveKeys = ['API_KEY', 'SECRET', 'PASSWORD', 'TOKEN', 'PRIVATE'];

    for (const key of Object.keys(process.env)) {
      if (sensitiveKeys.some(sensitive => key.includes(sensitive))) {
        if (process.env[key] && process.env[key].length < 10) {
          this.addFinding(
            'HIGH',
            'Secrets Management',
            `Potentially weak ${key}: value appears too short`,
            'Use strong, randomly generated secrets with minimum 32 characters'
          );
        }
      }
    }

    // Check for database URL security
    if (process.env.DATABASE_URL) {
      const dbUrl = process.env.DATABASE_URL;
      if (dbUrl.includes('localhost') || dbUrl.includes('127.0.0.1')) {
        this.addFinding(
          'LOW',
          'Database Security',
          'Database using localhost connection',
          'Consider using secure remote database for production'
        );
      }
      if (!dbUrl.includes('ssl') && !dbUrl.includes('sslmode')) {
        this.addFinding(
          'MEDIUM',
          'Database Security',
          'Database connection may not be using SSL',
          'Enable SSL for database connections in production'
        );
      }
    }
  }

  async auditFilePermissions() {
    console.log('\n📁 Auditing File Permissions...');

    const criticalFiles = [
      'package.json',
      'package-lock.json',
      '.env',
      'scripts/',
      'backend/server/',
      'contracts/',
    ];

    for (const file of criticalFiles) {
      try {
        if (fs.existsSync(file)) {
          const stats = fs.statSync(file);
          const mode = stats.mode.toString(8);

          // Check for world-writable files
          if (mode.endsWith('2') || mode.endsWith('6') || mode.endsWith('7')) {
            this.addFinding(
              'HIGH',
              'File Permissions',
              `${file} is world-writable (${mode})`,
              'Remove world-write permissions: chmod o-w ' + file,
              file
            );
          }
        }
      } catch (error) {
        // File doesn't exist or no permission to check
      }
    }
  }

  async auditDependencies() {
    console.log('\n📦 Auditing Dependencies...');

    try {
      const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
      const dependencies = {
        ...packageJson.dependencies,
        ...packageJson.devDependencies,
      };

      // Check for known vulnerable packages
      const vulnerablePackages = ['lodash', 'moment', 'request', 'node-sass'];

      for (const [pkg, version] of Object.entries(dependencies)) {
        if (vulnerablePackages.includes(pkg)) {
          this.addFinding(
            'MEDIUM',
            'Dependency Security',
            `Potentially vulnerable package: ${pkg}@${version}`,
            `Review ${pkg} for known vulnerabilities and update if needed`,
            'package.json'
          );
        }

        // Check for wildcard versions
        if (
          version.includes('*') ||
          version.includes('^') ||
          version.includes('~')
        ) {
          this.addFinding(
            'LOW',
            'Dependency Security',
            `Non-pinned dependency version: ${pkg}@${version}`,
            'Consider pinning dependency versions for reproducible builds',
            'package.json'
          );
        }
      }
    } catch (error) {
      this.addFinding(
        'LOW',
        'Dependency Security',
        'Could not read package.json for dependency audit',
        'Ensure package.json is present and readable'
      );
    }
  }

  async auditNetworkSecurity() {
    console.log('\n🌐 Auditing Network Security...');

    // Check for hardcoded IPs and URLs
    const serverFiles = this.findServerFiles();

    for (const file of serverFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for localhost bindings
        if (content.includes('localhost') || content.includes('127.0.0.1')) {
          this.addFinding(
            'LOW',
            'Network Security',
            `${file} contains localhost references`,
            'Use 0.0.0.0 for accessible services or environment variables',
            file
          );
        }

        // Check for HTTP instead of HTTPS
        const httpMatches = content.match(/http:\/\/[^\/\s]+/g);
        if (httpMatches && httpMatches.length > 0) {
          this.addFinding(
            'MEDIUM',
            'Network Security',
            `${file} contains HTTP URLs: ${httpMatches.slice(0, 3).join(', ')}`,
            'Use HTTPS for all external communications',
            file
          );
        }

        // Check for CORS configuration
        if (content.includes('cors') && content.includes('*')) {
          this.addFinding(
            'HIGH',
            'Network Security',
            `${file} may have overly permissive CORS configuration`,
            'Restrict CORS to specific domains instead of using wildcard',
            file
          );
        }
      } catch (error) {
        // Skip files that can't be read
      }
    }
  }

  async auditCryptographicSecurity() {
    console.log('\n🔒 Auditing Cryptographic Security...');

    const serverFiles = this.findServerFiles();

    for (const file of serverFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for weak hashing algorithms
        const weakHashes = ['md5', 'sha1'];
        for (const hash of weakHashes) {
          if (content.includes(hash)) {
            this.addFinding(
              'HIGH',
              'Cryptographic Security',
              `${file} uses weak hashing algorithm: ${hash}`,
              'Use SHA-256 or stronger hashing algorithms',
              file
            );
          }
        }

        // Check for hardcoded keys or salts
        const keyPatterns = [
          /['"]['"]?[a-f0-9]{32,}['"]['"]?/gi,
          /secret.*[:=]\s*['"]['"]?[a-zA-Z0-9]{8,}['"]['"]?/gi,
        ];

        for (const pattern of keyPatterns) {
          const matches = content.match(pattern);
          if (matches && matches.length > 0) {
            this.addFinding(
              'CRITICAL',
              'Cryptographic Security',
              `${file} may contain hardcoded cryptographic secrets`,
              'Move all secrets to environment variables',
              file
            );
            break;
          }
        }
      } catch (error) {
        // Skip files that can't be read
      }
    }
  }

  async auditInputValidation() {
    console.log('\n✅ Auditing Input Validation...');

    const serverFiles = this.findServerFiles();

    for (const file of serverFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for SQL injection vulnerabilities
        if (
          content.includes('query') &&
          content.includes('+') &&
          content.includes('req.')
        ) {
          this.addFinding(
            'CRITICAL',
            'Input Validation',
            `${file} may be vulnerable to SQL injection`,
            'Use parameterized queries and input sanitization',
            file
          );
        }

        // Check for missing input validation
        if (content.includes('req.body') || content.includes('req.params')) {
          if (!content.includes('validate') && !content.includes('sanitize')) {
            this.addFinding(
              'HIGH',
              'Input Validation',
              `${file} processes user input without apparent validation`,
              'Implement input validation and sanitization',
              file
            );
          }
        }
      } catch (error) {
        // Skip files that can't be read
      }
    }
  }

  async auditBlockchainSecurity() {
    console.log('\n⛓️ Auditing Blockchain Security...');

    // Check wallet security
    const walletFiles = this.findWalletFiles();
    for (const file of walletFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for private key exposure
        if (content.includes('privateKey') || content.includes('private_key')) {
          this.addFinding(
            'CRITICAL',
            'Blockchain Security',
            `${file} may contain private key references`,
            'Ensure private keys are never logged or exposed',
            file
          );
        }

        // Check for seed phrase exposure
        if (content.includes('mnemonic') || content.includes('seed')) {
          this.addFinding(
            'CRITICAL',
            'Blockchain Security',
            `${file} may contain seed phrase references`,
            'Protect seed phrases with encryption and secure storage',
            file
          );
        }
      } catch (error) {
        // Skip files that can't be read
      }
    }

    // Check smart contract security
    const contractFiles = this.findContractFiles();
    for (const file of contractFiles) {
      try {
        const content = fs.readFileSync(file, 'utf8');

        // Check for reentrancy guards
        if (content.includes('transfer') || content.includes('send')) {
          if (!content.includes('nonReentrant') && !content.includes('mutex')) {
            this.addFinding(
              'HIGH',
              'Blockchain Security',
              `${file} may be vulnerable to reentrancy attacks`,
              'Implement reentrancy guards for state-changing functions',
              file
            );
          }
        }
      } catch (error) {
        // Skip files that can't be read
      }
    }
  }

  findServerFiles() {
    const files = [];
    const serverDirs = ['backend/server', 'server', 'api'];

    for (const dir of serverDirs) {
      if (fs.existsSync(dir)) {
        const dirFiles = fs.readdirSync(dir, { recursive: true });
        for (const file of dirFiles) {
          if (file.endsWith('.js') || file.endsWith('.ts')) {
            files.push(path.join(dir, file));
          }
        }
      }
    }
    return files;
  }

  findWalletFiles() {
    const files = [];
    const walletDirs = ['wallets', 'wallet', 'keys'];

    for (const dir of walletDirs) {
      if (fs.existsSync(dir)) {
        const dirFiles = fs.readdirSync(dir, { recursive: true });
        for (const file of dirFiles) {
          if (
            file.endsWith('.js') ||
            file.endsWith('.ts') ||
            file.endsWith('.json')
          ) {
            files.push(path.join(dir, file));
          }
        }
      }
    }
    return files;
  }

  findContractFiles() {
    const files = [];
    const contractDirs = ['contracts', 'smart-contracts'];

    for (const dir of contractDirs) {
      if (fs.existsSync(dir)) {
        const dirFiles = fs.readdirSync(dir, { recursive: true });
        for (const file of dirFiles) {
          if (
            file.endsWith('.sol') ||
            file.endsWith('.rs') ||
            file.endsWith('.js')
          ) {
            files.push(path.join(dir, file));
          }
        }
      }
    }
    return files;
  }

  async runFullAudit() {
    console.log('🛡️ Starting Wrfcoin Security Audit...\n');

    await this.auditEnvironmentVariables();
    await this.auditFilePermissions();
    await this.auditDependencies();
    await this.auditNetworkSecurity();
    await this.auditCryptographicSecurity();
    await this.auditInputValidation();
    await this.auditBlockchainSecurity();

    this.generateReport();
  }

  generateReport() {
    console.log('\n' + '='.repeat(60));
    console.log('🛡️ WRFCOIN SECURITY AUDIT REPORT');
    console.log('='.repeat(60));

    console.log(`\n📊 SUMMARY:`);
    console.log(`🔴 Critical Issues: ${this.criticalIssues}`);
    console.log(`🟠 High Issues: ${this.highIssues}`);
    console.log(`🟡 Medium Issues: ${this.mediumIssues}`);
    console.log(`🟢 Low Issues: ${this.lowIssues}`);
    console.log(`📋 Total Findings: ${this.findings.length}`);

    // Risk Assessment
    let riskLevel = 'LOW';
    if (this.criticalIssues > 0) riskLevel = 'CRITICAL';
    else if (this.highIssues > 2) riskLevel = 'HIGH';
    else if (this.highIssues > 0 || this.mediumIssues > 3) riskLevel = 'MEDIUM';

    console.log(`\n🎯 OVERALL RISK LEVEL: ${riskLevel}`);

    if (this.findings.length === 0) {
      console.log('\n✅ No security issues found! Your system appears secure.');
      return;
    }

    console.log('\n📋 DETAILED FINDINGS:');
    console.log('-'.repeat(60));

    // Group findings by severity
    const grouped = {};
    for (const finding of this.findings) {
      if (!grouped[finding.severity]) grouped[finding.severity] = [];
      grouped[finding.severity].push(finding);
    }

    for (const severity of ['CRITICAL', 'HIGH', 'MEDIUM', 'LOW']) {
      if (grouped[severity]) {
        console.log(`\n${this.getSeverityIcon(severity)} ${severity} ISSUES:`);
        for (let i = 0; i < grouped[severity].length; i++) {
          const finding = grouped[severity][i];
          console.log(
            `\n${i + 1}. ${finding.category}: ${finding.description}`
          );
          console.log(`   💡 Recommendation: ${finding.recommendation}`);
          if (finding.file) {
            console.log(`   📂 File: ${finding.file}`);
          }
        }
      }
    }

    console.log('\n' + '='.repeat(60));
    console.log('🚀 NEXT STEPS:');
    console.log('1. Address CRITICAL and HIGH severity issues immediately');
    console.log('2. Plan fixes for MEDIUM severity issues');
    console.log(
      '3. Consider addressing LOW severity issues for best practices'
    );
    console.log('4. Re-run audit after implementing fixes');
    console.log('5. Set up regular security audits (monthly recommended)');
    console.log('='.repeat(60));

    // Save report to file
    const reportData = {
      timestamp: new Date().toISOString(),
      summary: {
        critical: this.criticalIssues,
        high: this.highIssues,
        medium: this.mediumIssues,
        low: this.lowIssues,
        total: this.findings.length,
        riskLevel,
      },
      findings: this.findings,
    };

    fs.writeFileSync(
      'security-audit-report.json',
      JSON.stringify(reportData, null, 2)
    );
    console.log('\n📄 Detailed report saved to: security-audit-report.json');
  }

  getSeverityIcon(severity) {
    const icons = {
      CRITICAL: '🔴',
      HIGH: '🟠',
      MEDIUM: '🟡',
      LOW: '🟢',
    };
    return icons[severity] || '⚪';
  }
}

// Run audit if called directly
if (require.main === module) {
  const audit = new WrfcoinSecurityAudit();
  audit.runFullAudit().catch(console.error);
}

module.exports = WrfcoinSecurityAudit;
