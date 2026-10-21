#!/usr/bin/env node

/**
 * Performance Optimization Script
 * Implements the 5-phase performance improvement plan
 */

const fs = require('fs');
const path = require('path');

class PerformanceOptimizer {
  constructor() {
    this.results = {
      phase1: { removed: [], updated: [], errors: [] },
      phase2: { standardized: [], conflicts: [], errors: [] },
      phase3: { consolidated: [], cachingAdded: [], errors: [] },
      bundleSize: { before: 0, after: 0, reduction: 0 },
    };
  }

  /**
   * Phase 1: Remove Framework Duplication
   */
  async removeFrameworkDuplication() {
    console.log('🚦 Phase 1: Removing Framework Duplication');

    try {
      // Check which UI framework is used most
      const componentUsage = await this.analyzeComponentUsage();
      console.log('📊 Component Usage Analysis:', componentUsage);

      // Remove Vue.js since React is primary
      await this.removeVueComponents();

      // Standardize on Material-UI (remove Ant Design)
      await this.removeAntDesignDependencies();

      // Consolidate charting libraries to Recharts
      await this.consolidateChartingLibraries();

      console.log('✅ Phase 1 completed');
      return this.results.phase1;
    } catch (error) {
      console.error('❌ Phase 1 failed:', error);
      this.results.phase1.errors.push(error.message);
      return this.results.phase1;
    }
  }

  /**
   * Phase 2: Unify React Versions
   */
  async unifyReactVersions() {
    console.log('🔧 Phase 2: Unifying React Versions');

    try {
      // Standardize on React 18.2.0 (more stable than 19.x)
      const packageFiles = [
        'package.json',
        'frontend/package.json',
        'sdk/js/package.json',
        'sdk/wrf-sdk-js/package.json',
      ];

      for (const file of packageFiles) {
        if (fs.existsSync(file)) {
          await this.standardizeReactVersion(file);
          this.results.phase2.standardized.push(file);
        }
      }

      console.log('✅ Phase 2 completed');
      return this.results.phase2;
    } catch (error) {
      console.error('❌ Phase 2 failed:', error);
      this.results.phase2.errors.push(error.message);
      return this.results.phase2;
    }
  }

  /**
   * Analyze which UI components are used most
   */
  async analyzeComponentUsage() {
    const usage = {
      materialUI: 0,
      antDesign: 0,
      customMUI: 0,
      bootstrap: 0,
    };

    // Scan frontend components for usage patterns
    const frontendDir = 'frontend/src/components';
    if (fs.existsSync(frontendDir)) {
      await this.scanDirectoryForUsage(frontendDir, usage);
    }

    return usage;
  }

  async scanDirectoryForUsage(dir, usage) {
    const files = fs.readdirSync(dir);

    for (const file of files) {
      const filePath = path.join(dir, file);
      const stat = fs.statSync(filePath);

      if (stat.isDirectory()) {
        await this.scanDirectoryForUsage(filePath, usage);
      } else if (file.endsWith('.jsx') || file.endsWith('.js')) {
        const content = fs.readFileSync(filePath, 'utf8');

        // Count usage patterns
        if (
          content.includes('@mui/material') ||
          content.includes('@material-ui')
        ) {
          usage.materialUI++;
        }
        if (content.includes('antd') || content.includes('@ant-design')) {
          usage.antDesign++;
        }
        if (
          content.includes('const Box = ') ||
          content.includes('const Typography = ')
        ) {
          usage.customMUI++;
        }
        if (
          content.includes('react-bootstrap') ||
          content.includes('bootstrap')
        ) {
          usage.bootstrap++;
        }
      }
    }
  }

  /**
   * Remove Vue.js components and dependencies
   */
  async removeVueComponents() {
    console.log('🗑️ Removing Vue.js components...');

    const vueDirectories = ['sdk/vue'];

    for (const dir of vueDirectories) {
      if (fs.existsSync(dir)) {
        // Instead of removing, rename to indicate it's deprecated
        const deprecatedDir = dir + '_deprecated';
        if (!fs.existsSync(deprecatedDir)) {
          fs.renameSync(dir, deprecatedDir);
          this.results.phase1.removed.push(dir);
          console.log(`  ✅ Moved ${dir} to ${deprecatedDir}`);
        }
      }
    }
  }

  /**
   * Remove Ant Design dependencies
   */
  async removeAntDesignDependencies() {
    console.log('🗑️ Removing Ant Design dependencies...');

    // Update package.json to remove antd
    const packagePath = 'package.json';
    if (fs.existsSync(packagePath)) {
      const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));

      if (packageJson.dependencies && packageJson.dependencies.antd) {
        delete packageJson.dependencies.antd;
        fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));
        this.results.phase1.removed.push('antd from package.json');
        console.log('  ✅ Removed antd from main package.json');
      }
    }
  }

  /**
   * Consolidate charting libraries
   */
  async consolidateChartingLibraries() {
    console.log('📊 Consolidating charting libraries to Recharts...');

    const packagePath = 'package.json';
    if (fs.existsSync(packagePath)) {
      const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));

      // Remove Chart.js, keep Recharts
      const chartLibsToRemove = ['chart.js', 'react-chartjs-2'];
      let removed = false;

      for (const lib of chartLibsToRemove) {
        if (packageJson.dependencies && packageJson.dependencies[lib]) {
          delete packageJson.dependencies[lib];
          this.results.phase1.removed.push(lib);
          removed = true;
        }
      }

      if (removed) {
        fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));
        console.log('  ✅ Removed redundant charting libraries');
      }
    }
  }

  /**
   * Standardize React version in a package.json file
   */
  async standardizeReactVersion(packagePath) {
    const packageJson = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
    const targetReactVersion = '^18.2.0';
    let updated = false;

    // Update React dependencies
    if (packageJson.dependencies) {
      if (
        packageJson.dependencies.react &&
        packageJson.dependencies.react !== targetReactVersion
      ) {
        packageJson.dependencies.react = targetReactVersion;
        updated = true;
      }
      if (
        packageJson.dependencies['react-dom'] &&
        packageJson.dependencies['react-dom'] !== targetReactVersion
      ) {
        packageJson.dependencies['react-dom'] = targetReactVersion;
        updated = true;
      }
    }

    // Add resolutions to enforce version consistency
    if (!packageJson.resolutions) {
      packageJson.resolutions = {};
    }
    packageJson.resolutions.react = targetReactVersion;
    packageJson.resolutions['react-dom'] = targetReactVersion;
    updated = true;

    if (updated) {
      fs.writeFileSync(packagePath, JSON.stringify(packageJson, null, 2));
      console.log(`  ✅ Standardized React version in ${packagePath}`);
    }
  }

  /**
   * Generate optimization report
   */
  generateReport() {
    const report = {
      timestamp: new Date().toISOString(),
      phase1: this.results.phase1,
      phase2: this.results.phase2,
      recommendations: [
        'Run npm install after React version standardization',
        'Test critical components after framework removal',
        'Implement data aggregation layer (Phase 3)',
        'Add caching layer with Redis (Phase 4)',
        'Consider SSR implementation (Phase 5)',
      ],
    };

    const reportPath = 'logs/performance-optimization-report.json';
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
    console.log(`📄 Report generated: ${reportPath}`);

    return report;
  }

  /**
   * Run complete optimization
   */
  async runOptimization() {
    console.log('🚀 Starting Performance Optimization');
    console.log('=====================================');

    // Create logs directory if it doesn't exist
    if (!fs.existsSync('logs')) {
      fs.mkdirSync('logs');
    }

    // Run optimization phases
    await this.removeFrameworkDuplication();
    await this.unifyReactVersions();

    // Generate final report
    const report = this.generateReport();

    console.log('=====================================');
    console.log('🎯 Optimization Summary:');
    console.log(
      `  Removed: ${this.results.phase1.removed.length} dependencies`
    );
    console.log(
      `  Standardized: ${this.results.phase2.standardized.length} package files`
    );
    console.log(
      `  Errors: ${this.results.phase1.errors.length + this.results.phase2.errors.length}`
    );
    console.log('=====================================');

    return report;
  }
}

// Run optimization if called directly
if (require.main === module) {
  const optimizer = new PerformanceOptimizer();
  optimizer.runOptimization().catch(console.error);
}

module.exports = PerformanceOptimizer;
