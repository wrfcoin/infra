#!/usr/bin/env node

/**
 * Project File Organization Script
 * Organizes loose files from the top-level directory into appropriate folders
 */

const fs = require('fs');
const path = require('path');

// File organization mapping
const fileOrganization = {
  // Testing scripts - move to testing/scripts/
  'test-acurite-connection.js': 'testing/scripts/',
  'test-ai-ml-networks.js': 'testing/scripts/',
  'test-bridge-assets.js': 'testing/scripts/',
  'test-cross-chain-protocols.js': 'testing/scripts/',
  'test-nas-integration.js': 'testing/scripts/',
  'test-security-patch.js': 'testing/scripts/',
  'test-storage-networks.js': 'testing/scripts/',
  'validate-security-fix.js': 'testing/scripts/',

  // Demo scripts - move to testing/scripts/demos/
  'demo-data-decentralization.js': 'testing/scripts/demos/',
  'demo-database-cleanup.js': 'testing/scripts/demos/',
  'demo-nas-storage-integration.js': 'testing/scripts/demos/',

  // Auto-collector scripts - move to scripts/collectors/
  'acurite-auto-collector.js': 'scripts/collectors/',
  'acurite-enhanced-collector.js': 'scripts/collectors/',
  'acurite-working-collector.js': 'scripts/collectors/',
  'compute-auto-collector.js': 'scripts/collectors/',
  'nas-auto-collector.js': 'scripts/collectors/',

  // Temporary files - move to scripts/temp/
  'temp_compute_7000.js': 'scripts/temp/',

  // Configuration files (keep in root but organize)
  'jest.config.js': './', // Keep in root
  'docker-compose.yml': './', // Keep in root

  // Documentation files (already in good location)
  'CODEBASE_INDEX.md': './', // Keep in root
  'FRIEND_SETUP_GUIDE.md': './', // Keep in root
  'PROJECT_STRUCTURE.md': './', // Keep in root

  // Analysis/report files - move to docs/reports/
  'blockchain-messaging-research.md': 'docs/reports/',
  'database-consolidation-progress-report.md': 'docs/reports/',
  'database-consolidation-report.json': 'docs/reports/',
  'database-structure-analysis.json': 'docs/reports/',
  'database_migrations.md': 'docs/reports/',
  'error-handling-analysis-report.json': 'docs/reports/',
  'error-handling-improvements-complete.json': 'docs/reports/',
  'hierarchical-performance-report.md': 'docs/reports/',
  'layer2-breakthrough-report.json': 'docs/reports/',
  'layer2-maximum-tps-report.json': 'docs/reports/',

  // Backup files - move to backup/
  'blockchain-core-fixes.rs': 'backup/',
};

// Directories to create if they don't exist
const dirsToCreate = [
  'testing/scripts/demos',
  'scripts/collectors',
  'scripts/temp',
  'docs/reports',
];

function createDirectories() {
  console.log('📁 Creating necessary directories...');

  dirsToCreate.forEach(dir => {
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
      console.log(`   ✅ Created: ${dir}`);
    } else {
      console.log(`   📂 Exists: ${dir}`);
    }
  });
}

function organizeFiles() {
  console.log('\n📋 Organizing files...');

  let movedCount = 0;
  let skippedCount = 0;

  Object.entries(fileOrganization).forEach(([fileName, targetDir]) => {
    const sourcePath = fileName;
    const targetPath = path.join(targetDir, fileName);

    // Skip if source file doesn't exist
    if (!fs.existsSync(sourcePath)) {
      console.log(`   ⚠️  Skipped: ${fileName} (not found)`);
      skippedCount++;
      return;
    }

    // Skip if target is same as source (keeping in root)
    if (targetDir === './') {
      console.log(`   📌 Keeping in root: ${fileName}`);
      return;
    }

    // Skip if file already exists in target location
    if (fs.existsSync(targetPath)) {
      console.log(
        `   ⚠️  Skipped: ${fileName} (already exists in ${targetDir})`
      );
      skippedCount++;
      return;
    }

    try {
      // Move the file
      fs.renameSync(sourcePath, targetPath);
      console.log(`   ✅ Moved: ${fileName} → ${targetDir}`);
      movedCount++;
    } catch (error) {
      console.log(`   ❌ Failed to move ${fileName}: ${error.message}`);
      skippedCount++;
    }
  });

  return { movedCount, skippedCount };
}

function updateDocumentation() {
  console.log('\n📝 Updating PROJECT_STRUCTURE.md...');

  const newSection = `
## File Organization (Updated)

### Collectors (\`scripts/collectors/\`)
Auto-collector scripts for different data sources:
- \`acurite-auto-collector.js\` - Weather station auto-collection
- \`acurite-enhanced-collector.js\` - Enhanced weather collection with IPFS
- \`acurite-working-collector.js\` - Working weather station collector
- \`compute-auto-collector.js\` - Computational power contribution
- \`nas-auto-collector.js\` - NAS storage auto-discovery and management

### Testing Scripts (\`testing/scripts/\`)
Organized testing and validation scripts:
- \`test-*.js\` - Various system integration tests
- \`demos/\` - Demonstration scripts for features
- \`validate-*.js\` - Security and system validation

### Reports (\`docs/reports/\`)
Analysis reports and documentation:
- Database structure and migration reports
- Performance analysis reports
- Security analysis reports
- System optimization reports

### Temporary Files (\`scripts/temp/\`)
Temporary development files and work-in-progress scripts.
`;

  try {
    if (fs.existsSync('PROJECT_STRUCTURE.md')) {
      let content = fs.readFileSync('PROJECT_STRUCTURE.md', 'utf8');

      // Add the new section if it doesn't exist
      if (!content.includes('## File Organization (Updated)')) {
        content += newSection;
        fs.writeFileSync('PROJECT_STRUCTURE.md', content);
        console.log('   ✅ Updated PROJECT_STRUCTURE.md');
      } else {
        console.log(
          '   📌 PROJECT_STRUCTURE.md already contains organization info'
        );
      }
    }
  } catch (error) {
    console.log(
      `   ⚠️  Could not update PROJECT_STRUCTURE.md: ${error.message}`
    );
  }
}

function createReadmeFiles() {
  console.log('\n📖 Creating README files for organized directories...');

  const readmeContents = {
    'scripts/collectors/README.md': `# Auto-Collectors

This directory contains "set it and forget it" auto-collector scripts that continuously earn WRF tokens by contributing various resources to the network.

## Available Collectors

### Weather Data Collectors
- \`acurite-working-collector.js\` - Basic authenticated AcuRite weather station collector
- \`acurite-enhanced-collector.js\` - Enhanced collector with IPFS and data-aware blocks
- \`acurite-auto-collector.js\` - Fully automated multi-source weather collection

### Compute Collectors
- \`compute-auto-collector.js\` - One-click computational power contribution

### Storage Collectors
- \`nas-auto-collector.js\` - Automatic NAS device discovery and storage contribution

## Usage

Each collector can be run independently:
\`\`\`bash
node scripts/collectors/acurite-working-collector.js
node scripts/collectors/compute-auto-collector.js
node scripts/collectors/nas-auto-collector.js
\`\`\`

All collectors follow the "weather station model" - simple setup with continuous automated earning.
`,

    'testing/scripts/demos/README.md': `# Demo Scripts

This directory contains demonstration scripts that showcase specific features and capabilities of the Wrfcoin platform.

## Available Demos

- \`demo-data-decentralization.js\` - Demonstrates IPFS integration and data-aware blocks
- \`demo-database-cleanup.js\` - Shows PostgreSQL to IPFS migration workflow
- \`demo-nas-storage-integration.js\` - Demonstrates NAS storage provider integration

## Usage

Run demos individually to see specific features:
\`\`\`bash
node testing/scripts/demos/demo-data-decentralization.js
node testing/scripts/demos/demo-nas-storage-integration.js
\`\`\`

These scripts are designed to showcase the platform's capabilities to developers and stakeholders.
`,

    'docs/reports/README.md': `# System Reports

This directory contains analysis reports, migration documentation, and system optimization reports generated during development.

## Categories

### Database Reports
- Migration and consolidation reports
- Structure analysis reports
- Optimization reports

### Performance Reports
- TPS breakthrough analysis
- Layer2 performance reports
- Hierarchical performance analysis

### Security Reports
- Error handling improvements
- Security patch validation
- System hardening analysis

These reports provide historical context and documentation for system improvements and optimizations.
`,
  };

  Object.entries(readmeContents).forEach(([filePath, content]) => {
    if (!fs.existsSync(filePath)) {
      try {
        fs.writeFileSync(filePath, content);
        console.log(`   ✅ Created: ${filePath}`);
      } catch (error) {
        console.log(`   ❌ Failed to create ${filePath}: ${error.message}`);
      }
    } else {
      console.log(`   📂 Exists: ${filePath}`);
    }
  });
}

function main() {
  console.log('🗂️  Wrfcoin Project File Organization');
  console.log('=====================================');

  createDirectories();

  const { movedCount, skippedCount } = organizeFiles();

  updateDocumentation();

  createReadmeFiles();

  console.log('\n📊 Organization Summary:');
  console.log(`   ✅ Files moved: ${movedCount}`);
  console.log(`   ⚠️  Files skipped: ${skippedCount}`);
  console.log('   📁 Directories created as needed');
  console.log('   📖 Documentation updated');

  console.log('\n🎯 Next Steps:');
  console.log('   1. Verify all files are in their correct locations');
  console.log(
    '   2. Update any import paths in code that reference moved files'
  );
  console.log('   3. Test that all collectors and scripts still work');
  console.log('   4. Consider updating workflow configurations if needed');

  console.log('\n✨ Project structure is now better organized!');
}

if (require.main === module) {
  main();
}

module.exports = { fileOrganization, dirsToCreate };
