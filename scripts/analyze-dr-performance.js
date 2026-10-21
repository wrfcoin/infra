#!/usr/bin/env node

/**
 * WRFCoin Disaster Recovery Performance Analysis
 * Integrates with existing DR infrastructure to provide comprehensive performance insights
 */

const path = require('path');
const fs = require('fs').promises;
const { spawn } = require('child_process');

// Import the performance benchmarker
const DRPerformanceBenchmarker = require('../infra/monitoring/disaster-recovery-performance-benchmarker');

class DRPerformanceAnalyzer {
  constructor() {
    this.projectRoot = path.resolve(__dirname, '..');
    this.drScriptPath = path.join(
      this.projectRoot,
      'infra/deployment/disaster-recovery/test-failover.sh'
    );
    this.terraformPath = path.join(
      this.projectRoot,
      'infra/terraform/disaster-recovery-monitoring.tf'
    );
    this.workflowPath = path.join(
      this.projectRoot,
      '.github/workflows/disaster-recovery-test.yml'
    );

    this.config = {
      rtoTarget: 900, // 15 minutes from monitoring config
      rpoTarget: 300, // 5 minutes from monitoring config
      primaryRegion: 'us-east-1',
      secondaryRegion: 'us-west-2',
    };
  }

  async runCompleteAnalysis() {
    console.log('🔄 Starting Complete DR Performance Analysis');
    console.log(`📁 Project Root: ${this.projectRoot}`);
    console.log(
      `🎯 RTO Target: ${this.config.rtoTarget}s (${this.config.rtoTarget / 60}min)`
    );
    console.log(
      `🎯 RPO Target: ${this.config.rpoTarget}s (${this.config.rpoTarget / 60}min)`
    );

    const analysis = {
      timestamp: new Date().toISOString(),
      config: this.config,
      infrastructureAnalysis: {},
      performanceBenchmark: {},
      complianceValidation: {},
      recommendations: [],
      summary: {},
    };

    try {
      // 1. Analyze existing DR infrastructure
      console.log('\n📊 Analyzing DR infrastructure configuration...');
      analysis.infrastructureAnalysis = await this.analyzeInfrastructure();

      // 2. Run performance benchmarks
      console.log('\n⚡ Running performance benchmarks...');
      const benchmarker = new DRPerformanceBenchmarker(this.config);
      analysis.performanceBenchmark =
        await benchmarker.runComprehensiveBenchmarks();

      // 3. Validate script execution performance
      console.log('\n🔧 Analyzing failover script performance...');
      analysis.scriptPerformance = await this.analyzeScriptPerformance();

      // 4. Check monitoring configuration
      console.log('\n📈 Validating monitoring configuration...');
      analysis.monitoringValidation = await this.validateMonitoringConfig();

      // 5. Generate compliance report
      console.log('\n✅ Generating compliance validation...');
      analysis.complianceValidation =
        await this.generateComplianceReport(analysis);

      // 6. Create consolidated recommendations
      console.log('\n💡 Creating optimization recommendations...');
      analysis.recommendations =
        await this.consolidateRecommendations(analysis);

      // 7. Generate executive summary
      analysis.summary = this.generateExecutiveSummary(analysis);

      // 8. Save comprehensive report
      await this.saveAnalysisReport(analysis);

      console.log('\n✨ DR Performance Analysis completed successfully');
      this.displaySummary(analysis.summary);

      return analysis;
    } catch (error) {
      console.error('❌ DR Performance Analysis failed:', error);
      analysis.error = {
        message: error.message,
        stack: error.stack,
      };
      return analysis;
    }
  }

  async analyzeInfrastructure() {
    const infrastructure = {
      drScript: {},
      terraformConfig: {},
      workflowConfig: {},
      overallHealth: 'unknown',
    };

    try {
      // Analyze DR test script
      const scriptExists = await this.fileExists(this.drScriptPath);
      if (scriptExists) {
        const scriptContent = await fs.readFile(this.drScriptPath, 'utf8');
        infrastructure.drScript = {
          exists: true,
          size: scriptContent.length,
          rtoTarget: this.extractValueFromScript(scriptContent, 'max_wait'),
          testTypes: this.extractTestTypes(scriptContent),
          healthChecks: this.extractHealthChecks(scriptContent),
          timeoutConfigs: this.extractTimeouts(scriptContent),
        };
      } else {
        infrastructure.drScript = { exists: false };
      }

      // Analyze Terraform monitoring config
      const terraformExists = await this.fileExists(this.terraformPath);
      if (terraformExists) {
        const terraformContent = await fs.readFile(this.terraformPath, 'utf8');
        infrastructure.terraformConfig = {
          exists: true,
          rtoAlarmThreshold: this.extractValueFromTerraform(
            terraformContent,
            'threshold.*900'
          ),
          rpoAlarmThreshold: this.extractValueFromTerraform(
            terraformContent,
            'threshold.*300'
          ),
          dashboardConfigured: terraformContent.includes(
            'aws_cloudwatch_dashboard'
          ),
          syntheticsConfigured: terraformContent.includes(
            'aws_synthetics_canary'
          ),
          automationLambda: terraformContent.includes(
            'aws_lambda_function.dr_automation'
          ),
        };
      } else {
        infrastructure.terraformConfig = { exists: false };
      }

      // Analyze GitHub workflow
      const workflowExists = await this.fileExists(this.workflowPath);
      if (workflowExists) {
        const workflowContent = await fs.readFile(this.workflowPath, 'utf8');
        infrastructure.workflowConfig = {
          exists: true,
          scheduledTests: workflowContent.includes('schedule:'),
          testTypes: this.extractWorkflowTestTypes(workflowContent),
          slackNotifications: workflowContent.includes('SLACK_WEBHOOK_URL'),
          issueCreation: workflowContent.includes('github.rest.issues.create'),
        };
      } else {
        infrastructure.workflowConfig = { exists: false };
      }

      // Assess overall infrastructure health
      const healthScore = this.calculateInfrastructureHealth(infrastructure);
      infrastructure.overallHealth =
        healthScore >= 0.8
          ? 'healthy'
          : healthScore >= 0.6
            ? 'warning'
            : 'critical';
      infrastructure.healthScore = healthScore;
    } catch (error) {
      console.warn(
        'Warning: Infrastructure analysis incomplete:',
        error.message
      );
      infrastructure.error = error.message;
    }

    return infrastructure;
  }

  async analyzeScriptPerformance() {
    const scriptPerf = {
      exists: false,
      executable: false,
      estimatedRuntime: {},
      bottlenecks: [],
      optimizationOpportunities: [],
    };

    try {
      // Check if script exists and is executable
      const scriptStat = await fs.stat(this.drScriptPath);
      scriptPerf.exists = true;
      scriptPerf.executable = (scriptStat.mode & parseInt('111', 8)) !== 0;

      if (!scriptPerf.executable) {
        scriptPerf.bottlenecks.push({
          type: 'PERMISSIONS',
          severity: 'HIGH',
          description: 'DR script is not executable',
        });
      }

      // Analyze script content for performance characteristics
      const scriptContent = await fs.readFile(this.drScriptPath, 'utf8');

      // Estimate runtime for different test types
      scriptPerf.estimatedRuntime = {
        health: this.estimateTestRuntime(scriptContent, 'health'),
        database: this.estimateTestRuntime(scriptContent, 'database'),
        dns: this.estimateTestRuntime(scriptContent, 'dns'),
        kubernetes: this.estimateTestRuntime(scriptContent, 'kubernetes'),
        all: this.estimateTestRuntime(scriptContent, 'all'),
      };

      // Identify potential bottlenecks
      scriptPerf.bottlenecks = this.identifyScriptBottlenecks(scriptContent);

      // Suggest optimizations
      scriptPerf.optimizationOpportunities =
        this.suggestScriptOptimizations(scriptContent);
    } catch (error) {
      console.warn(
        'Warning: Script performance analysis failed:',
        error.message
      );
      scriptPerf.error = error.message;
    }

    return scriptPerf;
  }

  async validateMonitoringConfig() {
    const monitoring = {
      cloudWatchDashboard: false,
      rtoAlarms: false,
      rpoAlarms: false,
      syntheticsCanary: false,
      automatedResponse: false,
      complianceScore: 0,
    };

    try {
      const terraformContent = await fs.readFile(this.terraformPath, 'utf8');

      // Check monitoring components
      monitoring.cloudWatchDashboard = terraformContent.includes(
        'aws_cloudwatch_dashboard'
      );
      monitoring.rtoAlarms =
        terraformContent.includes('rto-exceeded') &&
        terraformContent.includes('threshold           = "900"');
      monitoring.rpoAlarms =
        terraformContent.includes('replication-lag') &&
        terraformContent.includes('threshold           = "300"');
      monitoring.syntheticsCanary = terraformContent.includes(
        'aws_synthetics_canary'
      );
      monitoring.automatedResponse = terraformContent.includes(
        'aws_lambda_function.dr_automation'
      );

      // Calculate compliance score
      const checks = [
        monitoring.cloudWatchDashboard,
        monitoring.rtoAlarms,
        monitoring.rpoAlarms,
        monitoring.syntheticsCanary,
        monitoring.automatedResponse,
      ];
      monitoring.complianceScore =
        checks.filter(Boolean).length / checks.length;

      // Validate alarm thresholds match our targets
      monitoring.thresholdValidation = {
        rtoThreshold: this.extractNumericValue(
          terraformContent,
          /threshold\s*=\s*"(\d+)"/g,
          900
        ),
        rpoThreshold: this.extractNumericValue(
          terraformContent,
          /threshold\s*=\s*"(\d+)"/g,
          300
        ),
        aligned: true,
      };
    } catch (error) {
      console.warn('Warning: Monitoring validation incomplete:', error.message);
      monitoring.error = error.message;
    }

    return monitoring;
  }

  async generateComplianceReport(analysis) {
    const compliance = {
      rtoCompliance: {
        target: this.config.rtoTarget,
        status: 'unknown',
        gaps: [],
        score: 0,
      },
      rpoCompliance: {
        target: this.config.rpoTarget,
        status: 'unknown',
        gaps: [],
        score: 0,
      },
      overallCompliance: 'unknown',
    };

    try {
      // RTO Compliance Analysis
      if (
        analysis.performanceBenchmark &&
        analysis.performanceBenchmark.compliance
      ) {
        const rtoBenchmark = analysis.performanceBenchmark.compliance.rto;
        compliance.rtoCompliance = {
          target: rtoBenchmark.target,
          actual: rtoBenchmark.actual,
          status: rtoBenchmark.compliant ? 'compliant' : 'non-compliant',
          gaps: this.identifyRTOGaps(rtoBenchmark, analysis),
          score: rtoBenchmark.compliant
            ? 1.0
            : Math.max(
                0,
                1 -
                  (rtoBenchmark.actual - rtoBenchmark.target) /
                    rtoBenchmark.target
              ),
        };
      }

      // RPO Compliance Analysis
      if (
        analysis.performanceBenchmark &&
        analysis.performanceBenchmark.compliance
      ) {
        const rpoBenchmark = analysis.performanceBenchmark.compliance.rpo;
        compliance.rpoCompliance = {
          target: rpoBenchmark.target,
          actual: rpoBenchmark.actual,
          status: rpoBenchmark.compliant ? 'compliant' : 'non-compliant',
          gaps: this.identifyRPOGaps(rpoBenchmark, analysis),
          score: rpoBenchmark.compliant
            ? 1.0
            : Math.max(
                0,
                1 -
                  (rpoBenchmark.actual - rpoBenchmark.target) /
                    rpoBenchmark.target
              ),
        };
      }

      // Overall compliance
      const avgScore =
        (compliance.rtoCompliance.score + compliance.rpoCompliance.score) / 2;
      compliance.overallCompliance =
        avgScore >= 0.9
          ? 'compliant'
          : avgScore >= 0.7
            ? 'warning'
            : 'non-compliant';
      compliance.overallScore = avgScore;
    } catch (error) {
      console.warn(
        'Warning: Compliance report generation incomplete:',
        error.message
      );
      compliance.error = error.message;
    }

    return compliance;
  }

  async consolidateRecommendations(analysis) {
    const recommendations = [];

    try {
      // Infrastructure recommendations
      if (
        analysis.infrastructureAnalysis &&
        analysis.infrastructureAnalysis.healthScore < 0.8
      ) {
        recommendations.push({
          category: 'INFRASTRUCTURE',
          priority: 'HIGH',
          title: 'Fix Infrastructure Configuration Issues',
          description:
            'Critical infrastructure components are missing or misconfigured',
          actions: this.getInfrastructureRecommendations(
            analysis.infrastructureAnalysis
          ),
          impact: 'Prevents effective disaster recovery testing and monitoring',
        });
      }

      // Performance recommendations from benchmarker
      if (
        analysis.performanceBenchmark &&
        analysis.performanceBenchmark.recommendations
      ) {
        recommendations.push(...analysis.performanceBenchmark.recommendations);
      }

      // Script optimization recommendations
      if (
        analysis.scriptPerformance &&
        analysis.scriptPerformance.optimizationOpportunities
      ) {
        recommendations.push({
          category: 'AUTOMATION',
          priority: 'MEDIUM',
          title: 'Optimize DR Test Scripts',
          description: 'Improve failover script performance and reliability',
          actions: analysis.scriptPerformance.optimizationOpportunities,
          impact: 'Faster and more reliable DR testing execution',
        });
      }

      // Monitoring recommendations
      if (
        analysis.monitoringValidation &&
        analysis.monitoringValidation.complianceScore < 1.0
      ) {
        recommendations.push({
          category: 'MONITORING',
          priority: 'HIGH',
          title: 'Complete Monitoring Configuration',
          description: 'Essential monitoring components are missing',
          actions: this.getMonitoringRecommendations(
            analysis.monitoringValidation
          ),
          impact:
            'Improved visibility into DR performance and faster issue detection',
        });
      }

      // Compliance recommendations
      if (
        analysis.complianceValidation &&
        analysis.complianceValidation.overallScore < 0.9
      ) {
        recommendations.push({
          category: 'COMPLIANCE',
          priority: 'HIGH',
          title: 'Address RTO/RPO Compliance Gaps',
          description: 'Current DR performance does not meet defined targets',
          actions: [
            ...analysis.complianceValidation.rtoCompliance.gaps,
            ...analysis.complianceValidation.rpoCompliance.gaps,
          ],
          impact:
            'Ensure DR targets are consistently met during actual incidents',
        });
      }
    } catch (error) {
      console.warn(
        'Warning: Recommendation consolidation incomplete:',
        error.message
      );
    }

    return recommendations.sort((a, b) => {
      const priorityOrder = { HIGH: 3, MEDIUM: 2, LOW: 1 };
      return (
        (priorityOrder[b.priority] || 0) - (priorityOrder[a.priority] || 0)
      );
    });
  }

  generateExecutiveSummary(analysis) {
    const summary = {
      overallStatus: 'unknown',
      rtoCompliance: 'unknown',
      rpoCompliance: 'unknown',
      criticalIssues: 0,
      highPriorityRecommendations: 0,
      keyFindings: [],
      nextActions: [],
    };

    try {
      // Overall status assessment
      const scores = [
        analysis.infrastructureAnalysis?.healthScore || 0,
        analysis.monitoringValidation?.complianceScore || 0,
        analysis.complianceValidation?.overallScore || 0,
      ];
      const avgScore = scores.reduce((a, b) => a + b, 0) / scores.length;

      summary.overallStatus =
        avgScore >= 0.8 ? 'healthy' : avgScore >= 0.6 ? 'warning' : 'critical';
      summary.overallScore = avgScore;

      // Compliance status
      if (analysis.complianceValidation) {
        summary.rtoCompliance =
          analysis.complianceValidation.rtoCompliance.status;
        summary.rpoCompliance =
          analysis.complianceValidation.rpoCompliance.status;
      }

      // Count critical issues and high priority recommendations
      if (
        analysis.performanceBenchmark &&
        analysis.performanceBenchmark.bottlenecks
      ) {
        summary.criticalIssues =
          analysis.performanceBenchmark.bottlenecks.filter(
            b => b.severity === 'HIGH'
          ).length;
      }

      if (analysis.recommendations) {
        summary.highPriorityRecommendations = analysis.recommendations.filter(
          r => r.priority === 'HIGH'
        ).length;
      }

      // Key findings
      summary.keyFindings = this.extractKeyFindings(analysis);

      // Next actions
      summary.nextActions = this.generateNextActions(analysis);
    } catch (error) {
      console.warn(
        'Warning: Executive summary generation incomplete:',
        error.message
      );
      summary.error = error.message;
    }

    return summary;
  }

  async saveAnalysisReport(analysis) {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const reportDir = path.join(this.projectRoot, 'infra/reports');
    const reportPath = path.join(
      reportDir,
      `dr-performance-analysis-${timestamp}.json`
    );
    const summaryPath = path.join(
      reportDir,
      `dr-performance-summary-${timestamp}.md`
    );

    try {
      // Ensure reports directory exists
      await fs.mkdir(reportDir, { recursive: true });

      // Save detailed JSON report
      await fs.writeFile(reportPath, JSON.stringify(analysis, null, 2));

      // Generate and save markdown summary
      const markdownSummary = this.generateMarkdownReport(analysis);
      await fs.writeFile(summaryPath, markdownSummary);

      console.log(`\n📊 Analysis reports saved:`);
      console.log(`   Detailed Report: ${reportPath}`);
      console.log(`   Summary Report: ${summaryPath}`);
    } catch (error) {
      console.warn('Warning: Failed to save analysis report:', error.message);
    }
  }

  generateMarkdownReport(analysis) {
    const timestamp = new Date().toISOString();

    let report = `# WRFCoin Disaster Recovery Performance Analysis

**Generated:** ${timestamp}  
**Analysis Duration:** ${((Date.now() - new Date(analysis.timestamp).getTime()) / 1000).toFixed(2)} seconds  
**RTO Target:** ${this.config.rtoTarget}s (${(this.config.rtoTarget / 60).toFixed(1)} minutes)  
**RPO Target:** ${this.config.rpoTarget}s (${(this.config.rpoTarget / 60).toFixed(1)} minutes)  

## Executive Summary

**Overall Status:** ${this.getStatusEmoji(analysis.summary.overallStatus)} ${analysis.summary.overallStatus?.toUpperCase()}  
**RTO Compliance:** ${this.getComplianceEmoji(analysis.summary.rtoCompliance)} ${analysis.summary.rtoCompliance}  
**RPO Compliance:** ${this.getComplianceEmoji(analysis.summary.rpoCompliance)} ${analysis.summary.rpoCompliance}  
**Critical Issues:** ${analysis.summary.criticalIssues}  
**High Priority Recommendations:** ${analysis.summary.highPriorityRecommendations}  

`;

    // Key Findings
    if (
      analysis.summary.keyFindings &&
      analysis.summary.keyFindings.length > 0
    ) {
      report += `### Key Findings

`;
      analysis.summary.keyFindings.forEach((finding, index) => {
        report += `${index + 1}. ${finding}\n`;
      });
      report += '\n';
    }

    // Infrastructure Analysis
    if (analysis.infrastructureAnalysis) {
      const infra = analysis.infrastructureAnalysis;
      report += `### Infrastructure Analysis

| Component | Status | Details |
|-----------|--------|---------|
| DR Test Script | ${infra.drScript.exists ? '✅ Exists' : '❌ Missing'} | ${infra.drScript.exists ? `${infra.drScript.testTypes?.length || 0} test types configured` : 'Script not found'} |
| Terraform Monitoring | ${infra.terraformConfig.exists ? '✅ Configured' : '❌ Missing'} | ${infra.terraformConfig.exists ? (infra.terraformConfig.dashboardConfigured ? 'Dashboard configured' : 'Dashboard missing') : 'Config not found'} |
| GitHub Workflow | ${infra.workflowConfig.exists ? '✅ Configured' : '❌ Missing'} | ${infra.workflowConfig.exists ? (infra.workflowConfig.scheduledTests ? 'Scheduled tests enabled' : 'No scheduled tests') : 'Workflow not found'} |

**Infrastructure Health Score:** ${(infra.healthScore * 100)?.toFixed(1)}%

`;
    }

    // Performance Metrics
    if (
      analysis.performanceBenchmark &&
      analysis.performanceBenchmark.compliance
    ) {
      const compliance = analysis.performanceBenchmark.compliance;
      report += `### Performance Metrics

| Metric | Target | Actual | Status |
|--------|--------|--------|--------|
| RTO | ${compliance.rto.target}s | ${compliance.rto.actual}s | ${compliance.rto.compliant ? '✅' : '❌'} |
| RPO | ${compliance.rpo.target}s | ${compliance.rpo.actual}s | ${compliance.rpo.compliant ? '✅' : '❌'} |

`;
    }

    // High Priority Recommendations
    const highPriorityRecs =
      analysis.recommendations?.filter(r => r.priority === 'HIGH') || [];
    if (highPriorityRecs.length > 0) {
      report += `### High Priority Recommendations

`;
      highPriorityRecs.forEach((rec, index) => {
        report += `#### ${index + 1}. ${rec.title}

${rec.description}

**Category:** ${rec.category}  
**Impact:** ${rec.impact}

**Actions:**
${rec.actions.map(action => `- ${action}`).join('\n')}

`;
      });
    }

    // Next Actions
    if (
      analysis.summary.nextActions &&
      analysis.summary.nextActions.length > 0
    ) {
      report += `### Immediate Next Actions

`;
      analysis.summary.nextActions.forEach((action, index) => {
        report += `${index + 1}. ${action}\n`;
      });
      report += '\n';
    }

    report += `---
*Report generated by WRFCoin DR Performance Analyzer*
`;

    return report;
  }

  displaySummary(summary) {
    console.log('\n🎯 DR Performance Analysis Summary:');
    console.log(
      `   Overall Status: ${this.getStatusEmoji(summary.overallStatus)} ${summary.overallStatus?.toUpperCase()}`
    );
    console.log(
      `   RTO Compliance: ${this.getComplianceEmoji(summary.rtoCompliance)} ${summary.rtoCompliance}`
    );
    console.log(
      `   RPO Compliance: ${this.getComplianceEmoji(summary.rpoCompliance)} ${summary.rpoCompliance}`
    );
    console.log(`   Critical Issues: ${summary.criticalIssues}`);
    console.log(
      `   High Priority Recommendations: ${summary.highPriorityRecommendations}`
    );
  }

  // Utility methods
  async fileExists(filePath) {
    try {
      await fs.access(filePath);
      return true;
    } catch {
      return false;
    }
  }

  extractValueFromScript(content, pattern) {
    const match = content.match(new RegExp(pattern + '=([0-9]+)', 'i'));
    return match ? parseInt(match[1]) : null;
  }

  extractTestTypes(content) {
    const testTypes = [];
    const patterns = [/case "\${1:-([^}]+)}"/g, /"([^"]+)"\)/g];

    patterns.forEach(pattern => {
      let match;
      while ((match = pattern.exec(content)) !== null) {
        if (match[1] && !testTypes.includes(match[1])) {
          testTypes.push(match[1]);
        }
      }
    });

    return testTypes.filter(type =>
      [
        'all',
        'database',
        'dns',
        'kubernetes',
        'redis',
        'backup',
        'health',
      ].includes(type)
    );
  }

  extractHealthChecks(content) {
    return {
      apiHealth: content.includes('HEALTH_ENDPOINT'),
      databaseHealth: content.includes('describe-db-clusters'),
      kubernetesHealth: content.includes('get nodes'),
      redisHealth: content.includes('elasticache'),
    };
  }

  extractTimeouts(content) {
    const timeouts = {};
    const patterns = [
      { name: 'database_failover', pattern: /max_wait=(\d+).*# database/i },
      { name: 'dns_failover', pattern: /sleep (\d+).*# dns/i },
      { name: 'k8s_scaling', pattern: /max_wait=(\d+).*# kubernetes/i },
    ];

    patterns.forEach(({ name, pattern }) => {
      const match = content.match(pattern);
      if (match) {
        timeouts[name] = parseInt(match[1]);
      }
    });

    return timeouts;
  }

  extractValueFromTerraform(content, pattern) {
    const match = content.match(new RegExp(pattern, 'i'));
    return match ? match[0] : null;
  }

  extractWorkflowTestTypes(content) {
    const match = content.match(/options:\s*((?:\s*- \w+\s*)+)/);
    if (match) {
      return match[1]
        .split('-')
        .map(s => s.trim())
        .filter(s => s);
    }
    return [];
  }

  calculateInfrastructureHealth(infrastructure) {
    let score = 0;
    let total = 0;

    // DR Script health
    if (infrastructure.drScript.exists) {
      score += 0.3;
      if (
        infrastructure.drScript.testTypes &&
        infrastructure.drScript.testTypes.length >= 4
      ) {
        score += 0.1;
      }
    }
    total += 0.4;

    // Terraform config health
    if (infrastructure.terraformConfig.exists) {
      score += 0.2;
      if (infrastructure.terraformConfig.dashboardConfigured) score += 0.05;
      if (infrastructure.terraformConfig.syntheticsConfigured) score += 0.05;
      if (infrastructure.terraformConfig.automationLambda) score += 0.1;
    }
    total += 0.4;

    // Workflow health
    if (infrastructure.workflowConfig.exists) {
      score += 0.1;
      if (infrastructure.workflowConfig.scheduledTests) score += 0.05;
      if (infrastructure.workflowConfig.slackNotifications) score += 0.025;
      if (infrastructure.workflowConfig.issueCreation) score += 0.025;
    }
    total += 0.2;

    return total > 0 ? score / total : 0;
  }

  estimateTestRuntime(content, testType) {
    // Base runtime estimates in seconds
    const baseRuntimes = {
      health: 30,
      database: 300,
      dns: 180,
      kubernetes: 600,
      redis: 120,
      backup: 60,
      all: 900,
    };

    let estimate = baseRuntimes[testType] || 60;

    // Adjust based on script complexity
    const complexityFactors = [
      { pattern: /sleep \d+/g, factor: 1.1 },
      { pattern: /while.*do/g, factor: 1.2 },
      { pattern: /aws.*describe/g, factor: 1.05 },
    ];

    complexityFactors.forEach(({ pattern, factor }) => {
      const matches = content.match(pattern);
      if (matches) {
        estimate *= Math.pow(factor, matches.length);
      }
    });

    return Math.round(estimate);
  }

  identifyScriptBottlenecks(content) {
    const bottlenecks = [];

    // Sequential operations that could be parallelized
    if (
      content.includes('test_database_failover') &&
      content.includes('test_dns_failover')
    ) {
      const dbIndex = content.indexOf('test_database_failover');
      const dnsIndex = content.indexOf('test_dns_failover');
      if (Math.abs(dbIndex - dnsIndex) < 1000) {
        bottlenecks.push({
          type: 'SEQUENTIAL_EXECUTION',
          severity: 'MEDIUM',
          description:
            'Database and DNS failover tests run sequentially, could be parallelized',
        });
      }
    }

    // Long sleep operations
    const sleepMatches = content.match(/sleep (\d+)/g);
    if (sleepMatches) {
      const longSleeps = sleepMatches.filter(sleep => {
        const duration = parseInt(sleep.match(/\d+/)[0]);
        return duration > 60;
      });
      if (longSleeps.length > 0) {
        bottlenecks.push({
          type: 'LONG_WAITS',
          severity: 'LOW',
          description: `Script contains ${longSleeps.length} sleep operations > 60 seconds`,
        });
      }
    }

    // No error handling
    if (!content.includes('error_exit') || !content.includes('trap')) {
      bottlenecks.push({
        type: 'ERROR_HANDLING',
        severity: 'MEDIUM',
        description: 'Limited error handling may lead to unclear failure modes',
      });
    }

    return bottlenecks;
  }

  suggestScriptOptimizations(content) {
    const optimizations = [];

    // Parallelization opportunities
    if (
      content.includes('test_database_failover') &&
      content.includes('test_k8s_failover')
    ) {
      optimizations.push(
        'Parallelize independent failover tests (database and K8s)'
      );
    }

    // Intelligent waiting
    if (content.includes('sleep')) {
      optimizations.push(
        'Replace fixed sleep intervals with intelligent polling'
      );
    }

    // Caching improvements
    if (content.match(/aws.*describe/g)?.length > 3) {
      optimizations.push('Cache AWS API responses to reduce API calls');
    }

    // Progress reporting
    if (!content.includes('progress')) {
      optimizations.push(
        'Add detailed progress reporting for long-running operations'
      );
    }

    // Retry mechanisms
    if (!content.includes('retry')) {
      optimizations.push('Implement retry mechanisms for transient failures');
    }

    return optimizations;
  }

  extractNumericValue(content, pattern, target) {
    const matches = [...content.matchAll(pattern)];
    return matches.some(match => parseInt(match[1]) === target);
  }

  identifyRTOGaps(rtoBenchmark, analysis) {
    const gaps = [];

    if (!rtoBenchmark.compliant) {
      gaps.push(
        `Actual RTO (${rtoBenchmark.actual}s) exceeds target (${rtoBenchmark.target}s)`
      );

      if (rtoBenchmark.components) {
        Object.entries(rtoBenchmark.components).forEach(([component, data]) => {
          if (!data.compliant) {
            gaps.push(
              `${component} failover time (${data.actual}s) exceeds RTO target`
            );
          }
        });
      }
    }

    return gaps;
  }

  identifyRPOGaps(rpoBenchmark, analysis) {
    const gaps = [];

    if (!rpoBenchmark.compliant) {
      gaps.push(
        `Actual RPO (${rpoBenchmark.actual}s) exceeds target (${rpoBenchmark.target}s)`
      );

      if (rpoBenchmark.components) {
        Object.entries(rpoBenchmark.components).forEach(([component, data]) => {
          if (!data.compliant) {
            gaps.push(
              `${component} replication lag (${data.actual}s) exceeds RPO target`
            );
          }
        });
      }
    }

    return gaps;
  }

  getInfrastructureRecommendations(infrastructure) {
    const recommendations = [];

    if (!infrastructure.drScript.exists) {
      recommendations.push('Create comprehensive DR test script');
    }

    if (!infrastructure.terraformConfig.exists) {
      recommendations.push('Deploy Terraform monitoring configuration');
    } else {
      if (!infrastructure.terraformConfig.dashboardConfigured) {
        recommendations.push('Configure CloudWatch dashboard for DR metrics');
      }
      if (!infrastructure.terraformConfig.syntheticsConfigured) {
        recommendations.push(
          'Set up CloudWatch Synthetics for uptime monitoring'
        );
      }
    }

    if (!infrastructure.workflowConfig.exists) {
      recommendations.push('Set up automated DR testing workflow');
    }

    return recommendations;
  }

  getMonitoringRecommendations(monitoring) {
    const recommendations = [];

    if (!monitoring.cloudWatchDashboard) {
      recommendations.push(
        'Deploy CloudWatch dashboard for DR metrics visualization'
      );
    }

    if (!monitoring.rtoAlarms) {
      recommendations.push('Configure RTO threshold alarms in CloudWatch');
    }

    if (!monitoring.rpoAlarms) {
      recommendations.push(
        'Configure RPO threshold alarms for replication lag'
      );
    }

    if (!monitoring.syntheticsCanary) {
      recommendations.push(
        'Set up CloudWatch Synthetics canary for continuous monitoring'
      );
    }

    if (!monitoring.automatedResponse) {
      recommendations.push(
        'Implement Lambda-based automated DR response system'
      );
    }

    return recommendations;
  }

  extractKeyFindings(analysis) {
    const findings = [];

    if (analysis.infrastructureAnalysis?.healthScore !== undefined) {
      const score = analysis.infrastructureAnalysis.healthScore;
      findings.push(
        `Infrastructure health score: ${(score * 100).toFixed(1)}%`
      );
    }

    if (analysis.performanceBenchmark?.compliance?.rto?.actual) {
      const rto = analysis.performanceBenchmark.compliance.rto;
      findings.push(
        `Current RTO performance: ${rto.actual}s vs ${rto.target}s target`
      );
    }

    if (analysis.performanceBenchmark?.compliance?.rpo?.actual) {
      const rpo = analysis.performanceBenchmark.compliance.rpo;
      findings.push(
        `Current RPO performance: ${rpo.actual}s vs ${rpo.target}s target`
      );
    }

    if (analysis.performanceBenchmark?.bottlenecks?.length > 0) {
      const highSeverity = analysis.performanceBenchmark.bottlenecks.filter(
        b => b.severity === 'HIGH'
      ).length;
      findings.push(
        `${analysis.performanceBenchmark.bottlenecks.length} performance bottlenecks identified (${highSeverity} high severity)`
      );
    }

    return findings;
  }

  generateNextActions(analysis) {
    const actions = [];

    // High priority recommendations as immediate actions
    const highPriorityRecs =
      analysis.recommendations?.filter(r => r.priority === 'HIGH') || [];
    highPriorityRecs.forEach(rec => {
      actions.push(`Address ${rec.category.toLowerCase()}: ${rec.title}`);
    });

    // Compliance issues
    if (analysis.complianceValidation?.overallScore < 0.9) {
      actions.push(
        'Implement performance optimizations to meet RTO/RPO targets'
      );
    }

    // Infrastructure gaps
    if (analysis.infrastructureAnalysis?.healthScore < 0.8) {
      actions.push(
        'Complete infrastructure configuration and monitoring setup'
      );
    }

    // Regular testing
    actions.push('Schedule monthly DR performance validation tests');
    actions.push('Review and update DR documentation based on findings');

    return actions.slice(0, 5); // Top 5 actions
  }

  getStatusEmoji(status) {
    const emojis = {
      healthy: '✅',
      warning: '⚠️',
      critical: '❌',
      unknown: '❓',
    };
    return emojis[status] || '❓';
  }

  getComplianceEmoji(compliance) {
    const emojis = {
      compliant: '✅',
      'non-compliant': '❌',
      warning: '⚠️',
      unknown: '❓',
    };
    return emojis[compliance] || '❓';
  }
}

// CLI execution
if (require.main === module) {
  const analyzer = new DRPerformanceAnalyzer();

  analyzer
    .runCompleteAnalysis()
    .then(analysis => {
      const success =
        analysis.summary?.overallStatus === 'healthy' &&
        analysis.summary?.rtoCompliance === 'compliant' &&
        analysis.summary?.rpoCompliance === 'compliant';

      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('❌ DR Performance Analysis failed:', error);
      process.exit(1);
    });
}

module.exports = DRPerformanceAnalyzer;
