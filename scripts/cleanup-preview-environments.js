#!/usr/bin/env node

/**
 * Preview Environment Cleanup Automation
 * Automatically cleans up preview environments based on PR status and age
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

class PreviewEnvironmentCleaner {
  constructor(options = {}) {
    this.dryRun = options.dryRun || false;
    this.maxAge = options.maxAge || 7; // days
    this.batchSize = options.batchSize || 10;
    this.github = options.github || false;
    this.vercel = options.vercel || false;
    this.fly = options.fly || false;
    this.cleanupResults = {
      github: [],
      vercel: [],
      fly: [],
      errors: [],
    };
  }

  async cleanup() {
    console.log('🧹 Starting preview environment cleanup...');
    console.log(`Mode: ${this.dryRun ? 'DRY RUN' : 'LIVE'}`);
    console.log(`Max age: ${this.maxAge} days`);

    try {
      // Get list of closed PRs
      const closedPRs = await this.getClosedPRs();
      console.log(`📋 Found ${closedPRs.length} closed PRs to evaluate`);

      // Get old preview environments
      const oldEnvironments = await this.getOldEnvironments();
      console.log(
        `🕒 Found ${oldEnvironments.length} old environments to cleanup`
      );

      // Cleanup GitHub packages
      if (this.github) {
        await this.cleanupGitHubPackages(closedPRs, oldEnvironments);
      }

      // Cleanup Vercel deployments
      if (this.vercel) {
        await this.cleanupVercelDeployments(closedPRs, oldEnvironments);
      }

      // Cleanup Fly.io apps
      if (this.fly) {
        await this.cleanupFlyApps(closedPRs, oldEnvironments);
      }

      // Generate cleanup report
      this.generateCleanupReport();

      console.log('✅ Preview environment cleanup completed');
    } catch (error) {
      console.error('❌ Cleanup failed:', error.message);
      this.cleanupResults.errors.push({
        stage: 'general',
        error: error.message,
        timestamp: new Date().toISOString(),
      });
      throw error;
    }
  }

  async getClosedPRs() {
    console.log('🔍 Fetching closed PRs from GitHub...');

    try {
      const result = execSync(
        `gh pr list --state closed --limit 100 --json number,title,closedAt,headRefName`,
        {
          encoding: 'utf-8',
        }
      );

      const prs = JSON.parse(result);
      const cutoffDate = new Date();
      cutoffDate.setDate(cutoffDate.getDate() - this.maxAge);

      return prs.filter(pr => {
        const closedDate = new Date(pr.closedAt);
        return closedDate < cutoffDate;
      });
    } catch (error) {
      console.error('❌ Failed to fetch closed PRs:', error.message);
      return [];
    }
  }

  async getOldEnvironments() {
    console.log('📅 Identifying old preview environments...');

    const oldEnvironments = [];
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - this.maxAge);

    // Check deployment history
    const deploymentsDir = path.join(__dirname, '..', 'deployments', 'preview');

    if (fs.existsSync(deploymentsDir)) {
      const deploymentFiles = fs
        .readdirSync(deploymentsDir)
        .filter(file => file.startsWith('pr-') && file.endsWith('.json'));

      for (const file of deploymentFiles) {
        try {
          const deploymentPath = path.join(deploymentsDir, file);
          const stats = fs.statSync(deploymentPath);

          if (stats.mtime < cutoffDate) {
            const deployment = JSON.parse(
              fs.readFileSync(deploymentPath, 'utf-8')
            );
            oldEnvironments.push({
              prNumber: deployment.prNumber,
              file: deploymentPath,
              age: Math.floor(
                (Date.now() - stats.mtime.getTime()) / (1000 * 60 * 60 * 24)
              ),
            });
          }
        } catch (error) {
          console.warn(
            `⚠️ Failed to process deployment file ${file}:`,
            error.message
          );
        }
      }
    }

    return oldEnvironments;
  }

  async cleanupGitHubPackages(closedPRs, oldEnvironments) {
    console.log('📦 Cleaning up GitHub container packages...');

    const prNumbers = [
      ...closedPRs.map(pr => pr.number),
      ...oldEnvironments.map(env => env.prNumber),
    ];

    const components = ['frontend', 'backend', 'api'];

    for (const component of components) {
      try {
        if (!this.dryRun) {
          // Get packages for this component
          const packagesResult = execSync(
            `gh api orgs/wrfcoin/packages/container/${component}/versions`,
            {
              encoding: 'utf-8',
            }
          );

          const packages = JSON.parse(packagesResult);

          for (const pkg of packages) {
            if (
              pkg.metadata &&
              pkg.metadata.container &&
              pkg.metadata.container.tags
            ) {
              const tags = pkg.metadata.container.tags;

              // Check if this package is for a closed PR
              for (const prNumber of prNumbers) {
                if (tags.some(tag => tag.includes(`pr-${prNumber}`))) {
                  console.log(
                    `🗑️ Deleting ${component} package for PR #${prNumber}`
                  );

                  try {
                    execSync(
                      `gh api -X DELETE orgs/wrfcoin/packages/container/${component}/versions/${pkg.id}`
                    );
                    this.cleanupResults.github.push({
                      component,
                      prNumber,
                      packageId: pkg.id,
                      status: 'deleted',
                    });
                  } catch (deleteError) {
                    console.error(
                      `❌ Failed to delete package ${pkg.id}:`,
                      deleteError.message
                    );
                    this.cleanupResults.errors.push({
                      stage: 'github-packages',
                      component,
                      prNumber,
                      error: deleteError.message,
                    });
                  }
                  break;
                }
              }
            }
          }
        } else {
          console.log(
            `🔍 Would cleanup GitHub packages for component: ${component}`
          );
          prNumbers.forEach(prNumber => {
            this.cleanupResults.github.push({
              component,
              prNumber,
              status: 'would-delete',
            });
          });
        }
      } catch (error) {
        console.error(
          `❌ Failed to cleanup ${component} packages:`,
          error.message
        );
        this.cleanupResults.errors.push({
          stage: 'github-packages',
          component,
          error: error.message,
        });
      }
    }
  }

  async cleanupVercelDeployments(closedPRs, oldEnvironments) {
    console.log('▲ Cleaning up Vercel preview deployments...');

    const prNumbers = [
      ...closedPRs.map(pr => pr.number),
      ...oldEnvironments.map(env => env.prNumber),
    ];

    for (const prNumber of prNumbers) {
      try {
        const domain = `pr-${prNumber}-wrfcoin.vercel.app`;

        if (!this.dryRun) {
          // Get deployment ID for this domain
          const deploymentsResult = execSync(
            `vercel list --meta prNumber=${prNumber}`,
            {
              encoding: 'utf-8',
            }
          );

          if (deploymentsResult.includes(domain)) {
            console.log(`🗑️ Removing Vercel deployment for PR #${prNumber}`);

            try {
              execSync(`vercel remove ${domain} --yes`);
              this.cleanupResults.vercel.push({
                prNumber,
                domain,
                status: 'removed',
              });
            } catch (removeError) {
              console.error(
                `❌ Failed to remove Vercel deployment for PR #${prNumber}:`,
                removeError.message
              );
              this.cleanupResults.errors.push({
                stage: 'vercel',
                prNumber,
                error: removeError.message,
              });
            }
          }
        } else {
          console.log(
            `🔍 Would remove Vercel deployment for PR #${prNumber}: ${domain}`
          );
          this.cleanupResults.vercel.push({
            prNumber,
            domain,
            status: 'would-remove',
          });
        }
      } catch (error) {
        console.error(
          `❌ Failed to process Vercel deployment for PR #${prNumber}:`,
          error.message
        );
        this.cleanupResults.errors.push({
          stage: 'vercel',
          prNumber,
          error: error.message,
        });
      }
    }
  }

  async cleanupFlyApps(closedPRs, oldEnvironments) {
    console.log('🪰 Cleaning up Fly.io preview apps...');

    const prNumbers = [
      ...closedPRs.map(pr => pr.number),
      ...oldEnvironments.map(env => env.prNumber),
    ];

    for (const prNumber of prNumbers) {
      try {
        const appName = `wrfcoin-api-pr-${prNumber}`;

        if (!this.dryRun) {
          // Check if app exists
          const appsResult = execSync('flyctl apps list', {
            encoding: 'utf-8',
          });

          if (appsResult.includes(appName)) {
            console.log(`🗑️ Destroying Fly.io app for PR #${prNumber}`);

            try {
              execSync(`flyctl apps destroy ${appName} --yes`);
              this.cleanupResults.fly.push({
                prNumber,
                appName,
                status: 'destroyed',
              });
            } catch (destroyError) {
              console.error(
                `❌ Failed to destroy Fly.io app for PR #${prNumber}:`,
                destroyError.message
              );
              this.cleanupResults.errors.push({
                stage: 'fly',
                prNumber,
                error: destroyError.message,
              });
            }
          }
        } else {
          console.log(
            `🔍 Would destroy Fly.io app for PR #${prNumber}: ${appName}`
          );
          this.cleanupResults.fly.push({
            prNumber,
            appName,
            status: 'would-destroy',
          });
        }
      } catch (error) {
        console.error(
          `❌ Failed to process Fly.io app for PR #${prNumber}:`,
          error.message
        );
        this.cleanupResults.errors.push({
          stage: 'fly',
          prNumber,
          error: error.message,
        });
      }
    }
  }

  generateCleanupReport() {
    console.log('\n📊 Cleanup Report:');

    const totalGithub = this.cleanupResults.github.length;
    const totalVercel = this.cleanupResults.vercel.length;
    const totalFly = this.cleanupResults.fly.length;
    const totalErrors = this.cleanupResults.errors.length;

    console.log(`GitHub Packages: ${totalGithub} processed`);
    console.log(`Vercel Deployments: ${totalVercel} processed`);
    console.log(`Fly.io Apps: ${totalFly} processed`);
    console.log(`Errors: ${totalErrors}`);

    if (totalErrors > 0) {
      console.log('\n❌ Errors encountered:');
      this.cleanupResults.errors.forEach((error, index) => {
        console.log(`${index + 1}. [${error.stage}] ${error.error}`);
      });
    }

    // Save detailed report
    const reportDir = path.join(__dirname, '..', 'reports');
    if (!fs.existsSync(reportDir)) {
      fs.mkdirSync(reportDir, { recursive: true });
    }

    const reportFile = path.join(
      reportDir,
      `cleanup-report-${new Date().toISOString().split('T')[0]}.json`
    );
    fs.writeFileSync(
      reportFile,
      JSON.stringify(
        {
          timestamp: new Date().toISOString(),
          dryRun: this.dryRun,
          maxAge: this.maxAge,
          results: this.cleanupResults,
          summary: {
            totalProcessed: totalGithub + totalVercel + totalFly,
            totalErrors,
            success: totalErrors === 0,
          },
        },
        null,
        2
      )
    );

    console.log(`📝 Detailed report saved to: ${reportFile}`);
  }
}

// CLI interface
async function main() {
  const args = process.argv.slice(2);

  const options = {
    dryRun: args.includes('--dry-run'),
    maxAge:
      parseInt(args.find(arg => arg.startsWith('--max-age='))?.split('=')[1]) ||
      7,
    batchSize:
      parseInt(
        args.find(arg => arg.startsWith('--batch-size='))?.split('=')[1]
      ) || 10,
    github: args.includes('--github') || args.includes('--all'),
    vercel: args.includes('--vercel') || args.includes('--all'),
    fly: args.includes('--fly') || args.includes('--all'),
  };

  // If no specific platforms selected, cleanup all
  if (!options.github && !options.vercel && !options.fly) {
    options.github = true;
    options.vercel = true;
    options.fly = true;
  }

  const cleaner = new PreviewEnvironmentCleaner(options);
  await cleaner.cleanup();
}

// Scheduled cleanup function for cron jobs
async function scheduledCleanup() {
  console.log('⏰ Running scheduled preview environment cleanup...');

  const cleaner = new PreviewEnvironmentCleaner({
    dryRun: false,
    maxAge: 7,
    github: true,
    vercel: true,
    fly: true,
  });

  try {
    await cleaner.cleanup();

    // Send notification if configured
    if (process.env.SLACK_WEBHOOK_URL) {
      const { cleanupResults } = cleaner;
      const total =
        cleanupResults.github.length +
        cleanupResults.vercel.length +
        cleanupResults.fly.length;
      const errors = cleanupResults.errors.length;

      const payload = {
        text: `🧹 Preview Environment Cleanup Complete`,
        attachments: [
          {
            color: errors > 0 ? 'warning' : 'good',
            fields: [
              {
                title: 'Environments Cleaned',
                value: total.toString(),
                short: true,
              },
              { title: 'Errors', value: errors.toString(), short: true },
            ],
          },
        ],
      };

      const fetch = require('node-fetch');
      await fetch(process.env.SLACK_WEBHOOK_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    }
  } catch (error) {
    console.error('❌ Scheduled cleanup failed:', error.message);
    process.exit(1);
  }
}

// Handle different execution modes
if (require.main === module) {
  const isScheduled = process.argv.includes('--scheduled');

  if (isScheduled) {
    scheduledCleanup().catch(error => {
      console.error('❌ Scheduled cleanup failed:', error);
      process.exit(1);
    });
  } else {
    main().catch(error => {
      console.error('❌ Cleanup failed:', error);
      process.exit(1);
    });
  }
}

module.exports = {
  PreviewEnvironmentCleaner,
  main,
  scheduledCleanup,
};
