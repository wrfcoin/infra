#!/usr/bin/env node

/**
 * CORS Security Fix Tool
 * Automatically fixes wildcard CORS configurations across all servers
 */

const fs = require('fs');
const path = require('path');

class CORSSecurityFix {
  constructor() {
    this.fixedFiles = [];
    this.errors = [];

    // Secure CORS configuration
    this.secureCorsConfig = `app.use(cors({
    origin: [
        'https://wrfcoin.replit.app',
        'https://78d83de6-3c2e-4513-8977-f64d83a9e3cb-00-33g6fqpn548lr.worf.replit.dev',
        'http://localhost:5000',
        'http://0.0.0.0:5000'
    ],
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With']
}));`;
  }

  async fixCORSConfigurations() {
    console.log('🔒 Fixing CORS Security Configurations...\n');

    const serverFiles = this.findServerFiles();

    for (const file of serverFiles) {
      try {
        await this.fixCORSInFile(file);
      } catch (error) {
        this.errors.push(`${file}: ${error.message}`);
      }
    }

    this.generateReport();
  }

  async fixCORSInFile(filePath) {
    const content = fs.readFileSync(filePath, 'utf8');

    // Check if file has CORS configuration
    if (!content.includes('cors') && !content.includes('CORS')) {
      return; // No CORS configuration found
    }

    let updatedContent = content;
    let hasChanges = false;

    // Pattern 1: app.use(cors())
    if (content.match(/app\.use\(cors\(\)\)/g)) {
      updatedContent = updatedContent.replace(
        /app\.use\(cors\(\)\)/g,
        this.secureCorsConfig
      );
      hasChanges = true;
    }

    // Pattern 2: app.use(cors({ origin: '*' }))
    if (content.match(/app\.use\(cors\(\{[^}]*origin:\s*['"]\*['"]/g)) {
      updatedContent = updatedContent.replace(
        /app\.use\(cors\(\{[^}]*origin:\s*['"]\*['"][^}]*\}\)\)/g,
        this.secureCorsConfig
      );
      hasChanges = true;
    }

    // Pattern 3: origin: '*'
    if (content.match(/origin:\s*['"]\*['"]/g)) {
      updatedContent = updatedContent.replace(
        /origin:\s*['"]\*['"]/g,
        `origin: [
        'https://wrfcoin.replit.app',
        'https://78d83de6-3c2e-4513-8977-f64d83a9e3cb-00-33g6fqpn548lr.worf.replit.dev',
        'http://localhost:5000',
        'http://0.0.0.0:5000'
    ]`
      );
      hasChanges = true;
    }

    // Pattern 4: Access-Control-Allow-Origin: *
    if (content.match(/['"]Access-Control-Allow-Origin['"]:\s*['"]\*['"]/g)) {
      updatedContent = updatedContent.replace(
        /['"]Access-Control-Allow-Origin['"]:\s*['"]\*['"]/g,
        '"Access-Control-Allow-Origin": req.headers.origin'
      );
      hasChanges = true;
    }

    // Pattern 5: setHeader('Access-Control-Allow-Origin', '*')
    if (
      content.match(
        /setHeader\(['"]Access-Control-Allow-Origin['"],\s*['"]\*['"]\)/g
      )
    ) {
      updatedContent = updatedContent.replace(
        /setHeader\(['"]Access-Control-Allow-Origin['"],\s*['"]\*['"]\)/g,
        `setHeader('Access-Control-Allow-Origin', req.headers.origin || 'https://wrfcoin.replit.app')`
      );
      hasChanges = true;
    }

    if (hasChanges) {
      // Add required imports if not present
      if (!updatedContent.includes("const cors = require('cors')")) {
        const requireStatements =
          updatedContent.match(/const .* = require\(['"][^'"]*['"]\);?/g) || [];
        if (requireStatements.length > 0) {
          const lastRequire = requireStatements[requireStatements.length - 1];
          updatedContent = updatedContent.replace(
            lastRequire,
            lastRequire + "\nconst cors = require('cors');"
          );
        } else {
          updatedContent = "const cors = require('cors');\n" + updatedContent;
        }
      }

      fs.writeFileSync(filePath, updatedContent);
      this.fixedFiles.push(filePath);
      console.log(`✅ Fixed CORS configuration: ${filePath}`);
    }
  }

  findServerFiles() {
    const files = [];
    const serverDirs = ['backend/server', 'server', 'api'];

    for (const dir of serverDirs) {
      if (fs.existsSync(dir)) {
        this.findJSFiles(dir, files);
      }
    }
    return files;
  }

  findJSFiles(dir, files) {
    const items = fs.readdirSync(dir);

    for (const item of items) {
      const fullPath = path.join(dir, item);
      const stat = fs.statSync(fullPath);

      if (stat.isDirectory()) {
        this.findJSFiles(fullPath, files);
      } else if (item.endsWith('.js') || item.endsWith('.ts')) {
        files.push(fullPath);
      }
    }
  }

  generateReport() {
    console.log('\n' + '='.repeat(50));
    console.log('🔒 CORS SECURITY FIX REPORT');
    console.log('='.repeat(50));

    console.log(`\n📊 SUMMARY:`);
    console.log(`✅ Files Fixed: ${this.fixedFiles.length}`);
    console.log(`❌ Errors: ${this.errors.length}`);

    if (this.fixedFiles.length > 0) {
      console.log('\n✅ FIXED FILES:');
      for (const file of this.fixedFiles) {
        console.log(`   • ${file}`);
      }
    }

    if (this.errors.length > 0) {
      console.log('\n❌ ERRORS:');
      for (const error of this.errors) {
        console.log(`   • ${error}`);
      }
    }

    console.log('\n🔒 SECURITY IMPROVEMENTS:');
    console.log(
      '• Replaced wildcard (*) origins with specific allowed domains'
    );
    console.log('• Added credentials: true for secure cookie handling');
    console.log('• Restricted HTTP methods to essential ones only');
    console.log('• Limited allowed headers to prevent injection attacks');

    console.log('\n🚀 NEXT STEPS:');
    console.log('1. Restart affected servers to apply changes');
    console.log('2. Test frontend connectivity with new CORS settings');
    console.log('3. Add additional domains as needed for production');
    console.log('4. Monitor for any blocked legitimate requests');

    console.log('='.repeat(50));
  }
}

// Run fix if called directly
if (require.main === module) {
  const fix = new CORSSecurityFix();
  fix.fixCORSConfigurations().catch(console.error);
}

module.exports = CORSSecurityFix;
