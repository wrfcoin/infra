#!/usr/bin/env node

/**
 * Dependency Pinning Tool
 * Pins flexible dependency versions for enhanced security
 */

const fs = require('fs');
const { execSync } = require('child_process');

class DependencyPinner {
  constructor() {
    this.pinnedPackages = [];
    this.errors = [];
  }

  async pinDependencies() {
    console.log('📌 Pinning dependency versions for security...\n');

    await this.loadCurrentVersions();
    await this.updatePackageJson();

    this.generateReport();
  }

  async loadCurrentVersions() {
    console.log('📦 Reading current package.json...');

    if (!fs.existsSync('package.json')) {
      throw new Error('package.json not found');
    }

    const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));
    this.originalDeps = { ...packageJson.dependencies };
    this.originalDevDeps = { ...packageJson.devDependencies };
  }

  async updatePackageJson() {
    console.log('🔧 Getting exact versions from package-lock.json...');

    try {
      // Read package-lock.json to get exact versions
      const lockContent = fs.readFileSync('package-lock.json', 'utf8');
      const lockData = JSON.parse(lockContent);

      const packageJson = JSON.parse(fs.readFileSync('package.json', 'utf8'));

      // Pin dependencies
      if (packageJson.dependencies) {
        for (const [pkg, version] of Object.entries(packageJson.dependencies)) {
          if (this.isFlexibleVersion(version)) {
            const exactVersion = this.getExactVersion(lockData, pkg);
            if (exactVersion) {
              packageJson.dependencies[pkg] = exactVersion;
              this.pinnedPackages.push({
                package: pkg,
                from: version,
                to: exactVersion,
              });
              console.log(`📌 Pinned ${pkg}: ${version} → ${exactVersion}`);
            }
          }
        }
      }

      // Pin devDependencies
      if (packageJson.devDependencies) {
        for (const [pkg, version] of Object.entries(
          packageJson.devDependencies
        )) {
          if (this.isFlexibleVersion(version)) {
            const exactVersion = this.getExactVersion(lockData, pkg);
            if (exactVersion) {
              packageJson.devDependencies[pkg] = exactVersion;
              this.pinnedPackages.push({
                package: pkg,
                from: version,
                to: exactVersion,
              });
              console.log(`📌 Pinned ${pkg}: ${version} → ${exactVersion}`);
            }
          }
        }
      }

      // Write updated package.json
      fs.writeFileSync('package.json', JSON.stringify(packageJson, null, 2));
      console.log('✅ Updated package.json with pinned versions');
    } catch (error) {
      this.errors.push(`Error pinning dependencies: ${error.message}`);
    }
  }

  isFlexibleVersion(version) {
    return (
      version.startsWith('^') ||
      version.startsWith('~') ||
      version.includes('*') ||
      version.includes('x') ||
      version.includes('>=') ||
      version.includes('>')
    );
  }

  getExactVersion(lockData, packageName) {
    // Check top-level packages in package-lock.json
    if (lockData.packages && lockData.packages[`node_modules/${packageName}`]) {
      return lockData.packages[`node_modules/${packageName}`].version;
    }

    // Check dependencies section (older format)
    if (lockData.dependencies && lockData.dependencies[packageName]) {
      return lockData.dependencies[packageName].version;
    }

    return null;
  }

  generateReport() {
    console.log('\n' + '='.repeat(60));
    console.log('📌 DEPENDENCY PINNING REPORT');
    console.log('='.repeat(60));

    console.log(`\n📊 SUMMARY:`);
    console.log(`📌 Packages Pinned: ${this.pinnedPackages.length}`);
    console.log(`❌ Errors: ${this.errors.length}`);

    if (this.pinnedPackages.length > 0) {
      console.log('\n📌 PINNED PACKAGES:');

      // Group by type of change
      const caret = this.pinnedPackages.filter(p => p.from.startsWith('^'));
      const tilde = this.pinnedPackages.filter(p => p.from.startsWith('~'));
      const other = this.pinnedPackages.filter(
        p => !p.from.startsWith('^') && !p.from.startsWith('~')
      );

      if (caret.length > 0) {
        console.log('\n  🔸 Caret (^) versions pinned:');
        caret.forEach(p =>
          console.log(`     ${p.package}: ${p.from} → ${p.to}`)
        );
      }

      if (tilde.length > 0) {
        console.log('\n  🔸 Tilde (~) versions pinned:');
        tilde.forEach(p =>
          console.log(`     ${p.package}: ${p.from} → ${p.to}`)
        );
      }

      if (other.length > 0) {
        console.log('\n  🔸 Other flexible versions pinned:');
        other.forEach(p =>
          console.log(`     ${p.package}: ${p.from} → ${p.to}`)
        );
      }
    }

    if (this.errors.length > 0) {
      console.log('\n❌ ERRORS:');
      for (const error of this.errors) {
        console.log(`   • ${error}`);
      }
    }

    console.log('\n🔒 SECURITY BENEFITS:');
    console.log('• Prevents unexpected dependency updates');
    console.log('• Eliminates supply chain attack risks from version ranges');
    console.log('• Ensures reproducible builds across environments');
    console.log('• Provides better control over security updates');

    console.log('\n🚀 NEXT STEPS:');
    console.log('1. Run npm install to verify pinned versions work');
    console.log('2. Test the application to ensure compatibility');
    console.log('3. Commit the updated package.json');
    console.log('4. Set up automated dependency monitoring');
    console.log('5. Review and update pinned versions periodically');

    console.log('='.repeat(60));
  }
}

// Run pinning if called directly
if (require.main === module) {
  const pinner = new DependencyPinner();
  pinner.pinDependencies().catch(console.error);
}

module.exports = DependencyPinner;
