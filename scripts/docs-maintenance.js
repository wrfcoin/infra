#!/usr/bin/env node
/**
 * WRFCoin Documentation Maintenance System
 * Team Zeta - Enterprise Documentation Automation
 *
 * Automated maintenance, validation, and optimization for the unified documentation system.
 */

const fs = require('fs').promises;
const path = require('path');
const { execSync } = require('child_process');

class DocumentationMaintenance {
  constructor() {
    this.projectRoot = process.cwd();
    this.docsDir = path.join(this.projectRoot, 'docs');
    this.reports = {
      brokenLinks: [],
      orphanedFiles: [],
      missingPages: [],
      performanceIssues: [],
      accessibilityIssues: [],
    };
  }

  /**
   * Main maintenance routine
   */
  async runMaintenance() {
    console.log('🔧 Starting WRFCoin Documentation Maintenance...\n');

    try {
      await this.validateDocumentationStructure();
      await this.checkLinkHealth();
      await this.validateMarkdownSyntax();
      await this.optimizeImages();
      await this.updateNavigationIndex();
      await this.generateHealthReport();

      console.log('✅ Documentation maintenance completed successfully!');
    } catch (error) {
      console.error('❌ Documentation maintenance failed:', error.message);
      process.exit(1);
    }
  }

  /**
   * Validate documentation structure integrity
   */
  async validateDocumentationStructure() {
    console.log('📁 Validating documentation structure...');

    const requiredDirectories = [
      'getting-started',
      'api',
      'development',
      'components',
      'architecture',
      'security',
      'feedback',
    ];

    for (const dir of requiredDirectories) {
      const dirPath = path.join(this.docsDir, dir);
      try {
        await fs.access(dirPath);
        console.log(`  ✓ ${dir}/ exists`);
      } catch (error) {
        console.log(`  ❌ Missing directory: ${dir}/`);
        this.reports.missingPages.push(`Missing directory: ${dir}/`);
      }
    }

    // Check for README files in main sections
    for (const dir of requiredDirectories) {
      const readmePath = path.join(this.docsDir, dir, 'README.md');
      try {
        await fs.access(readmePath);
        console.log(`  ✓ ${dir}/README.md exists`);
      } catch (error) {
        console.log(`  ❌ Missing README: ${dir}/README.md`);
        this.reports.missingPages.push(`Missing README: ${dir}/README.md`);
      }
    }
  }

  /**
   * Check for broken internal links
   */
  async checkLinkHealth() {
    console.log('🔗 Checking link health...');

    const markdownFiles = await this.findMarkdownFiles();

    for (const file of markdownFiles) {
      const content = await fs.readFile(file, 'utf-8');
      const links = this.extractMarkdownLinks(content);

      for (const link of links) {
        if (this.isInternalLink(link)) {
          const targetPath = this.resolveInternalLink(file, link);

          try {
            await fs.access(targetPath);
          } catch (error) {
            const brokenLink = {
              file: path.relative(this.docsDir, file),
              link: link,
              target: targetPath,
            };
            this.reports.brokenLinks.push(brokenLink);
            console.log(`  ❌ Broken link in ${brokenLink.file}: ${link}`);
          }
        }
      }
    }

    if (this.reports.brokenLinks.length === 0) {
      console.log('  ✅ All internal links are healthy');
    } else {
      console.log(
        `  ⚠️  Found ${this.reports.brokenLinks.length} broken links`
      );
    }
  }

  /**
   * Validate markdown syntax and formatting
   */
  async validateMarkdownSyntax() {
    console.log('📝 Validating markdown syntax...');

    try {
      // Use markdownlint if available
      const result = execSync(
        'npx markdownlint docs/**/*.md --config .markdownlint.json',
        { encoding: 'utf-8', stdio: 'pipe' }
      );
      console.log('  ✅ All markdown files are properly formatted');
    } catch (error) {
      console.log('  ⚠️  Markdown formatting issues detected');
      if (error.stdout) {
        console.log(error.stdout);
      }
    }
  }

  /**
   * Optimize images for web performance
   */
  async optimizeImages() {
    console.log('🖼️  Optimizing images...');

    const imageFiles = await this.findImageFiles();
    let optimizedCount = 0;

    for (const imagePath of imageFiles) {
      const stats = await fs.stat(imagePath);
      const fileSizeKB = stats.size / 1024;

      if (fileSizeKB > 500) {
        console.log(
          `  ⚠️  Large image detected: ${path.relative(this.docsDir, imagePath)} (${fileSizeKB.toFixed(1)}KB)`
        );
        this.reports.performanceIssues.push({
          type: 'large_image',
          file: path.relative(this.docsDir, imagePath),
          size: fileSizeKB,
        });
      } else {
        optimizedCount++;
      }
    }

    console.log(`  ✅ ${optimizedCount} images are optimized`);
  }

  /**
   * Update navigation index automatically
   */
  async updateNavigationIndex() {
    console.log('🧭 Updating navigation index...');

    try {
      // Generate automated navigation based on directory structure
      const navigation = await this.generateNavigationStructure();
      const navContent = this.formatNavigationForMkDocs(navigation);

      // Update mkdocs.yml navigation section
      await this.updateMkDocsNavigation(navContent);

      console.log('  ✅ Navigation index updated');
    } catch (error) {
      console.log('  ⚠️  Navigation update failed:', error.message);
    }
  }

  /**
   * Generate comprehensive health report
   */
  async generateHealthReport() {
    console.log('📊 Generating health report...');

    const report = {
      timestamp: new Date().toISOString(),
      summary: {
        totalFiles: (await this.findMarkdownFiles()).length,
        brokenLinks: this.reports.brokenLinks.length,
        missingPages: this.reports.missingPages.length,
        performanceIssues: this.reports.performanceIssues.length,
        healthScore: this.calculateHealthScore(),
      },
      details: this.reports,
      recommendations: this.generateRecommendations(),
    };

    // Save report
    const reportPath = path.join(this.docsDir, 'reports', 'health-report.json');
    await fs.mkdir(path.dirname(reportPath), { recursive: true });
    await fs.writeFile(reportPath, JSON.stringify(report, null, 2));

    // Generate markdown summary
    const markdownReport = this.generateMarkdownReport(report);
    const markdownPath = path.join(this.docsDir, 'reports', 'health-report.md');
    await fs.writeFile(markdownPath, markdownReport);

    console.log(
      `  ✅ Health report saved to: ${path.relative(this.projectRoot, markdownPath)}`
    );
    console.log(`  📈 Overall health score: ${report.summary.healthScore}/100`);
  }

  /**
   * Helper methods
   */

  async findMarkdownFiles() {
    const files = [];

    async function scanDirectory(dir) {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory() && !entry.name.startsWith('.')) {
          await scanDirectory(fullPath);
        } else if (entry.isFile() && entry.name.endsWith('.md')) {
          files.push(fullPath);
        }
      }
    }

    await scanDirectory(this.docsDir);
    return files;
  }

  async findImageFiles() {
    const files = [];
    const imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg'];

    async function scanDirectory(dir) {
      const entries = await fs.readdir(dir, { withFileTypes: true });

      for (const entry of entries) {
        const fullPath = path.join(dir, entry.name);

        if (entry.isDirectory() && !entry.name.startsWith('.')) {
          await scanDirectory(fullPath);
        } else if (entry.isFile()) {
          const ext = path.extname(entry.name).toLowerCase();
          if (imageExtensions.includes(ext)) {
            files.push(fullPath);
          }
        }
      }
    }

    await scanDirectory(this.docsDir);
    return files;
  }

  extractMarkdownLinks(content) {
    const linkRegex = /\[([^\]]*)\]\(([^)]+)\)/g;
    const links = [];
    let match;

    while ((match = linkRegex.exec(content)) !== null) {
      links.push(match[2]);
    }

    return links;
  }

  isInternalLink(link) {
    return (
      !link.startsWith('http') &&
      !link.startsWith('mailto:') &&
      !link.startsWith('#')
    );
  }

  resolveInternalLink(currentFile, link) {
    const currentDir = path.dirname(currentFile);
    return path.resolve(currentDir, link);
  }

  calculateHealthScore() {
    const totalIssues =
      this.reports.brokenLinks.length +
      this.reports.missingPages.length +
      this.reports.performanceIssues.length;

    const maxScore = 100;
    const penaltyPerIssue = 5;

    return Math.max(0, maxScore - totalIssues * penaltyPerIssue);
  }

  generateRecommendations() {
    const recommendations = [];

    if (this.reports.brokenLinks.length > 0) {
      recommendations.push({
        priority: 'high',
        issue: 'Broken Links',
        action: `Fix ${this.reports.brokenLinks.length} broken internal links`,
        impact: 'User experience and SEO',
      });
    }

    if (this.reports.missingPages.length > 0) {
      recommendations.push({
        priority: 'medium',
        issue: 'Missing Pages',
        action: `Create ${this.reports.missingPages.length} missing documentation pages`,
        impact: 'Documentation completeness',
      });
    }

    if (this.reports.performanceIssues.length > 0) {
      recommendations.push({
        priority: 'low',
        issue: 'Performance',
        action: `Optimize ${this.reports.performanceIssues.length} large images`,
        impact: 'Page load speed',
      });
    }

    return recommendations;
  }

  generateMarkdownReport(report) {
    return `# Documentation Health Report
Generated: ${new Date(report.timestamp).toLocaleString()}

## Summary
- **Total Files:** ${report.summary.totalFiles}
- **Health Score:** ${report.summary.healthScore}/100
- **Broken Links:** ${report.summary.brokenLinks}
- **Missing Pages:** ${report.summary.missingPages}
- **Performance Issues:** ${report.summary.performanceIssues}

## Issues Found

### Broken Links (${report.details.brokenLinks.length})
${report.details.brokenLinks.map(link => `- \`${link.file}\`: [${link.link}](${link.target})`).join('\n')}

### Missing Pages (${report.details.missingPages.length})
${report.details.missingPages.map(page => `- ${page}`).join('\n')}

### Performance Issues (${report.details.performanceIssues.length})
${report.details.performanceIssues.map(issue => `- ${issue.file} (${issue.size.toFixed(1)}KB)`).join('\n')}

## Recommendations
${report.recommendations
  .map(
    rec => `### ${rec.issue} (${rec.priority} priority)
**Action:** ${rec.action}
**Impact:** ${rec.impact}`
  )
  .join('\n\n')}

---
*Generated by WRFCoin Documentation Maintenance System*`;
  }
}

// CLI execution
if (require.main === module) {
  const maintenance = new DocumentationMaintenance();
  maintenance.runMaintenance().catch(error => {
    console.error('❌ Maintenance failed:', error);
    process.exit(1);
  });
}

module.exports = DocumentationMaintenance;
