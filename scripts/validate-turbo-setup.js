#!/usr/bin/env node

/**
 * Turborepo Setup Validation Script
 * Validates caching configuration and measures performance improvements
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

class TurboValidator {
  constructor() {
    this.results = {
      configValid: false,
      dependencyGraph: false,
      cachePerformance: {},
      recommendations: [],
    };
  }

  log(message) {
    console.log(`[Turbo Validator] ${message}`);
  }

  error(message) {
    console.error(`[Turbo Validator] ERROR: ${message}`);
  }

  success(message) {
    console.log(`[Turbo Validator] ✅ ${message}`);
  }

  warning(message) {
    console.log(`[Turbo Validator] ⚠️ ${message}`);
  }

  validateTurboConfig() {
    this.log('Validating Turborepo configuration...');

    try {
      // Check if turbo.json exists
      const turboConfigPath = path.join(process.cwd(), 'turbo.json');
      if (!fs.existsSync(turboConfigPath)) {
        this.error('turbo.json not found');
        return false;
      }

      const turboConfig = JSON.parse(fs.readFileSync(turboConfigPath, 'utf8'));

      // Validate required fields
      if (!turboConfig.tasks && !turboConfig.pipeline) {
        this.error('turbo.json missing tasks/pipeline configuration');
        return false;
      }

      // Check for essential tasks
      const requiredTasks = ['build', 'test', 'lint'];
      const configuredTasks = Object.keys(
        turboConfig.tasks || turboConfig.pipeline || {}
      );

      for (const task of requiredTasks) {
        const hasTask = configuredTasks.some(t => t.includes(task));
        if (!hasTask) {
          this.warning(`No ${task} task configured in pipeline`);
        }
      }

      // Validate cache configuration
      const tasks = turboConfig.tasks || turboConfig.pipeline || {};
      const tasksWithOutputs = configuredTasks.filter(
        task => tasks[task].outputs && tasks[task].outputs.length > 0
      );

      if (tasksWithOutputs.length === 0) {
        this.warning('No tasks configured with cache outputs');
      }

      this.results.configValid = true;
      this.success('Turborepo configuration is valid');
      return true;
    } catch (error) {
      this.error(`Failed to validate turbo.json: ${error.message}`);
      return false;
    }
  }

  validateDependencyGraph() {
    this.log('Validating dependency graph...');

    try {
      // Generate dependency graph
      execSync('npx turbo run build --dry-run --graph', {
        stdio: 'pipe',
        cwd: process.cwd(),
      });

      this.results.dependencyGraph = true;
      this.success('Dependency graph is valid');
      return true;
    } catch (error) {
      this.error(`Dependency graph validation failed: ${error.message}`);
      return false;
    }
  }

  async measureCachePerformance() {
    this.log('Measuring cache performance...');

    try {
      // Clean build (no cache)
      this.log('Running clean build (no cache)...');
      const cleanStart = Date.now();

      try {
        execSync('npx turbo run build --force', {
          stdio: 'pipe',
          cwd: process.cwd(),
          timeout: 300000, // 5 minute timeout
        });
      } catch (error) {
        this.warning('Clean build failed, using estimated times');
        this.results.cachePerformance = {
          cleanBuildTime: 'N/A (build failed)',
          cachedBuildTime: 'N/A',
          improvement: 'Cannot measure',
          estimated: true,
        };
        return;
      }

      const cleanTime = (Date.now() - cleanStart) / 1000;

      // Cached build
      this.log('Running cached build...');
      const cachedStart = Date.now();

      execSync('npx turbo run build', {
        stdio: 'pipe',
        cwd: process.cwd(),
        timeout: 300000,
      });

      const cachedTime = (Date.now() - cachedStart) / 1000;

      // Calculate improvement
      const improvement = ((cleanTime - cachedTime) / cleanTime) * 100;

      this.results.cachePerformance = {
        cleanBuildTime: `${cleanTime.toFixed(1)}s`,
        cachedBuildTime: `${cachedTime.toFixed(1)}s`,
        improvement: `${improvement.toFixed(1)}%`,
        estimated: false,
      };

      if (improvement > 50) {
        this.success(
          `Excellent cache performance: ${improvement.toFixed(1)}% improvement`
        );
      } else if (improvement > 20) {
        this.success(
          `Good cache performance: ${improvement.toFixed(1)}% improvement`
        );
      } else {
        this.warning(
          `Cache performance could be improved: ${improvement.toFixed(1)}% improvement`
        );
        this.results.recommendations.push(
          'Consider optimizing cache inputs and outputs'
        );
      }
    } catch (error) {
      this.error(`Cache performance measurement failed: ${error.message}`);
      this.results.cachePerformance = {
        cleanBuildTime: 'Failed',
        cachedBuildTime: 'Failed',
        improvement: 'Cannot measure',
        estimated: false,
      };
    }
  }

  validateWorkspaceStructure() {
    this.log('Validating workspace structure...');

    const expectedProjects = [
      'frontend',
      'backend',
      'blockchain-core',
      'contracts',
    ];

    const foundProjects = [];

    for (const project of expectedProjects) {
      const projectPath = path.join(process.cwd(), project);
      if (fs.existsSync(projectPath)) {
        foundProjects.push(project);

        // Check for package.json
        const packageJsonPath = path.join(projectPath, 'package.json');
        if (fs.existsSync(packageJsonPath)) {
          this.success(`${project} workspace configured`);
        } else {
          this.warning(`${project} missing package.json`);
        }
      }
    }

    if (foundProjects.length < expectedProjects.length) {
      this.warning(
        `Found ${foundProjects.length}/${expectedProjects.length} expected projects`
      );
      this.results.recommendations.push(
        'Ensure all project workspaces have package.json files'
      );
    }
  }

  generateReport() {
    this.log('Generating validation report...');

    const report = {
      timestamp: new Date().toISOString(),
      validation: {
        configValid: this.results.configValid,
        dependencyGraph: this.results.dependencyGraph,
        cachePerformance: this.results.cachePerformance,
      },
      recommendations: this.results.recommendations,
      nextSteps: [
        'Monitor CI/CD cache hit rates',
        'Set up cache analytics dashboard',
        'Optimize cache invalidation strategies',
        'Configure remote caching for team collaboration',
      ],
    };

    // Write report to file
    const reportPath = path.join(process.cwd(), 'turbo-validation-report.json');
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    // Generate markdown report
    const markdownReport = this.generateMarkdownReport(report);
    const markdownPath = path.join(process.cwd(), 'TURBO_VALIDATION_REPORT.md');
    fs.writeFileSync(markdownPath, markdownReport);

    this.success(`Validation report generated: ${reportPath}`);
    this.success(`Markdown report generated: ${markdownPath}`);

    return report;
  }

  generateMarkdownReport(report) {
    return `# Turborepo Setup Validation Report

## Summary
- **Validation Date**: ${new Date(report.timestamp).toLocaleString()}
- **Configuration Valid**: ${report.validation.configValid ? '✅' : '❌'}
- **Dependency Graph**: ${report.validation.dependencyGraph ? '✅' : '❌'}

## Cache Performance
- **Clean Build Time**: ${report.validation.cachePerformance.cleanBuildTime || 'N/A'}
- **Cached Build Time**: ${report.validation.cachePerformance.cachedBuildTime || 'N/A'}
- **Performance Improvement**: ${report.validation.cachePerformance.improvement || 'N/A'}

## Recommendations
${
  report.recommendations.length > 0
    ? report.recommendations.map(rec => `- ${rec}`).join('\n')
    : '- No recommendations at this time'
}

## Next Steps
${report.nextSteps.map(step => `- ${step}`).join('\n')}

## Commands Reference
\`\`\`bash
# Build with cache
npm run build

# Build without cache (force rebuild)
npm run turbo:cache:clear

# Show dependency graph
npm run turbo:graph

# Dry run to see what would be cached
npm run turbo:dry-run
\`\`\`

## Cache Configuration
Turborepo is configured to cache:
- Build outputs (dist/, build/, target/)
- Test results and coverage
- Lint and type-check results
- Smart contract compilation artifacts

Cache invalidation is based on:
- Source file changes
- Dependency changes
- Environment variable changes
- Configuration file changes
`;
  }

  async run() {
    this.log('Starting Turborepo setup validation...');

    console.log('🔍 Validating Turborepo Setup for WRFCoin');
    console.log('=' * 50);

    // Run validations
    this.validateTurboConfig();
    this.validateDependencyGraph();
    this.validateWorkspaceStructure();
    await this.measureCachePerformance();

    // Generate report
    const report = this.generateReport();

    console.log('\n📊 Validation Complete!');
    console.log(`Config Valid: ${report.validation.configValid ? '✅' : '❌'}`);
    console.log(
      `Cache Performance: ${report.validation.cachePerformance.improvement || 'N/A'}`
    );

    if (this.results.recommendations.length > 0) {
      console.log('\n💡 Recommendations:');
      this.results.recommendations.forEach(rec => console.log(`  - ${rec}`));
    }

    return report.validation.configValid && report.validation.dependencyGraph;
  }
}

// Run validation if called directly
if (require.main === module) {
  const validator = new TurboValidator();
  validator
    .run()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('Validation failed:', error);
      process.exit(1);
    });
}

module.exports = TurboValidator;
