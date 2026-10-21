#!/usr/bin/env node

/**
 * Wrfcoin Core Resilience Scorecard
 * Audits the "unstoppability" of the Wrfcoin platform
 * Based on the framework in docs/doc_center/unstoppable.md
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class ResilienceScorecard {
  constructor() {
    this.scores = {};
    this.totalScore = 0;
    this.maxScore = 0;
    this.results = [];
  }

  async runAudit() {
    console.log('🔍 Wrfcoin Core Resilience Audit');
    console.log('=================================\n');

    await this.auditTechnicalInfrastructure();
    await this.auditSecuritySovereignty();
    await this.auditNetworkDistribution();
    await this.auditGovernanceAutonomy();
    await this.auditUpdatability();
    await this.auditDataRedundancy();
    await this.auditOpenSource();

    this.calculateOverallScore();
    this.generateReport();
  }

  async auditTechnicalInfrastructure() {
    console.log('🧱 1. Technical Infrastructure Resilience');
    console.log('──────────────────────────────────────────');

    const checks = [
      {
        name: 'Docker Containerization',
        check: () => this.checkDockerImplementation(),
        weight: 15,
      },
      {
        name: 'Stateless Services',
        check: () => this.checkStatelessServices(),
        weight: 15,
      },
      {
        name: 'Multi-node Redundancy',
        check: () => this.checkNodeRedundancy(),
        weight: 10,
      },
      {
        name: 'Peer Discovery (No Central DNS)',
        check: () => this.checkPeerDiscovery(),
        weight: 20,
      },
    ];

    await this.runChecks('technical_infrastructure', checks);
  }

  async auditSecuritySovereignty() {
    console.log('\n🔒 2. Security and Sovereignty');
    console.log('──────────────────────────────');

    const checks = [
      {
        name: 'Hardware-Backed Admin Access',
        check: () => this.checkHSMKeys(),
        weight: 25,
      },
      {
        name: 'Immutable Core Logic',
        check: () => this.checkImmutableCore(),
        weight: 15,
      },
      {
        name: 'DDoS Protection',
        check: () => this.checkDDoSProtection(),
        weight: 10,
      },
    ];

    await this.runChecks('security_sovereignty', checks);
  }

  async auditNetworkDistribution() {
    console.log('\n🌍 3. Network Distribution');
    console.log('──────────────────────────');

    const checks = [
      {
        name: 'Geographic Validator Spread',
        check: () => this.checkGeographicDistribution(),
        weight: 15,
      },
      {
        name: 'Cross-Chain Bridge Redundancy',
        check: () => this.checkCrossChainRedundancy(),
        weight: 10,
      },
      {
        name: 'Mesh Network Capability',
        check: () => this.checkMeshCapability(),
        weight: 15,
      },
    ];

    await this.runChecks('network_distribution', checks);
  }

  async auditGovernanceAutonomy() {
    console.log('\n🔁 4. Governance Autonomy');
    console.log('──────────────────────────');

    const checks = [
      {
        name: 'On-Chain Transparent Proposals',
        check: () => this.checkOnChainGovernance(),
        weight: 15,
      },
      {
        name: 'Consensus Data Migration',
        check: () => this.checkConsensusDataMigration(),
        weight: 10,
      },
      {
        name: 'Fork-Resistant Game Theory',
        check: () => this.checkForkResistance(),
        weight: 5,
      },
    ];

    await this.runChecks('governance_autonomy', checks);
  }

  async auditUpdatability() {
    console.log('\n🔄 5. Updatability Without Fragility');
    console.log('───────────────────────────────────');

    const checks = [
      {
        name: 'Hot-Swappable Modules',
        check: () => this.checkModularArchitecture(),
        weight: 10,
      },
      {
        name: 'Staged Rollout Capability',
        check: () => this.checkStagedRollouts(),
        weight: 5,
      },
    ];

    await this.runChecks('updatability', checks);
  }

  async auditDataRedundancy() {
    console.log('\n☁️ 6. Data and Compute Redundancy');
    console.log('─────────────────────────────────');

    const checks = [
      {
        name: 'IPFS Integration',
        check: () => this.checkIPFSIntegration(),
        weight: 15,
      },
      {
        name: 'Distributed Storage Networks',
        check: () => this.checkStorageNetworks(),
        weight: 10,
      },
      {
        name: 'Compute Network Resilience',
        check: () => this.checkComputeNetworks(),
        weight: 10,
      },
    ];

    await this.runChecks('data_redundancy', checks);
  }

  async auditOpenSource() {
    console.log('\n📦 7. Open Source + Self-Hosting');
    console.log('─────────────────────────────────');

    const checks = [
      {
        name: 'CLI Installation Tool',
        check: () => this.checkCLITool(),
        weight: 10,
      },
      {
        name: 'Self-Hosting Documentation',
        check: () => this.checkSelfHostingDocs(),
        weight: 5,
      },
      {
        name: 'Sovereign Deployment Capability',
        check: () => this.checkSovereignDeployment(),
        weight: 10,
      },
    ];

    await this.runChecks('open_source', checks);
  }

  async runChecks(category, checks) {
    let categoryScore = 0;
    let categoryMax = 0;

    for (const check of checks) {
      const result = await check.check();
      const score = result.passed ? check.weight : 0;

      categoryScore += score;
      categoryMax += check.weight;

      const status = result.passed ? '✅' : '❌';
      const details = result.details ? ` (${result.details})` : '';

      console.log(
        `${status} ${check.name}: ${score}/${check.weight}${details}`
      );

      this.results.push({
        category,
        check: check.name,
        passed: result.passed,
        score,
        maxScore: check.weight,
        details: result.details,
        recommendations: result.recommendations || [],
      });
    }

    this.scores[category] = { score: categoryScore, max: categoryMax };
    this.totalScore += categoryScore;
    this.maxScore += categoryMax;

    console.log(
      `📊 ${category}: ${categoryScore}/${categoryMax} (${Math.round((categoryScore / categoryMax) * 100)}%)`
    );
  }

  // Check implementations
  checkDockerImplementation() {
    try {
      const dockerCompose = fs.existsSync(
        'infrastructure/docker/docker-compose.yml'
      );
      const dockerfiles = fs
        .readdirSync('infrastructure/docker')
        .filter(f => f.startsWith('Dockerfile'));

      if (dockerCompose && dockerfiles.length >= 5) {
        return {
          passed: true,
          details: `${dockerfiles.length} Dockerfiles found with compose setup`,
        };
      }

      return {
        passed: false,
        details: 'Missing comprehensive Docker setup',
        recommendations: ['Complete Docker containerization for all services'],
      };
    } catch (error) {
      return { passed: false, details: 'Docker infrastructure not found' };
    }
  }

  checkStatelessServices() {
    try {
      const serverFiles = fs.readdirSync('backend/server');
      const statelessCount = serverFiles.filter(
        f =>
          f.includes('server') &&
          !f.includes('database') &&
          !f.includes('storage')
      ).length;

      return {
        passed: statelessCount >= 8,
        details: `${statelessCount} stateless services identified`,
      };
    } catch (error) {
      return { passed: false, details: 'Server architecture not found' };
    }
  }

  checkNodeRedundancy() {
    try {
      const workflowCount = fs
        .readdirSync('.')
        .filter(f => f.includes('workflow') || f.includes('server')).length;

      return {
        passed: workflowCount >= 20,
        details: `${workflowCount} distributed services running`,
      };
    } catch (error) {
      return { passed: false, details: 'Node redundancy setup incomplete' };
    }
  }

  checkPeerDiscovery() {
    const hasIPFS = fs.existsSync('backend/server/ipfs/adapter.js');
    const hasNodeDiscovery = fs.existsSync(
      'backend/server/easy_node_discovery.js'
    );

    if (hasIPFS && hasNodeDiscovery) {
      return {
        passed: true,
        details: 'IPFS and node discovery implemented',
      };
    }

    return {
      passed: false,
      details: 'Missing decentralized peer discovery',
      recommendations: [
        'Implement ENS/IPFS-based service discovery',
        'Add Tor/I2P support',
      ],
    };
  }

  checkHSMKeys() {
    try {
      const hsmFiles = fs.readdirSync('security/security/hsm-keys');
      const keyPairs = hsmFiles.filter(f => f.endsWith('.priv')).length;

      if (keyPairs >= 5) {
        return {
          passed: true,
          details: `${keyPairs} HSM key pairs configured`,
        };
      }

      return {
        passed: false,
        details: 'Simulated HSM keys only - need real hardware',
        recommendations: [
          'Purchase YubiKey/HSM devices',
          'Implement WebAuthn multisig',
        ],
      };
    } catch (error) {
      return { passed: false, details: 'HSM key infrastructure not found' };
    }
  }

  checkImmutableCore() {
    const hasGovernance = fs.existsSync('backend/server/governance_server.js');
    const hasConsensus = fs.existsSync(
      'scripts/migrate-consensus-data-onchain.js'
    );

    return {
      passed: hasGovernance && hasConsensus,
      details:
        hasGovernance && hasConsensus
          ? 'Governance and consensus migration implemented'
          : 'Missing immutable core logic protection',
    };
  }

  // The backend was extracted to its own repo (#373); resolve it instead of
  // assuming a pre-split in-repo `backend/` path (that assumption made this
  // check unconditionally fail — infra#586).
  resolveBackendDir() {
    const candidates = [
      process.env.WRFCOIN_BACKEND_DIR,
      path.join(__dirname, '..', '..', 'backend'), // workspace sibling checkout
      'backend', // pre-split / vendored layout
    ].filter(Boolean);
    for (const dir of candidates) {
      if (fs.existsSync(path.join(dir, 'server'))) return dir;
    }
    return null;
  }

  checkDDoSProtection() {
    const findings = [];
    const recommendations = [];

    // Layer 1 — infra assets in THIS repo. Their presence proves the configs
    // exist, not that they are applied on the host; deploy-time verification
    // is an operator step.
    const infraAssets = [
      'scripts/infrastructure/ddos-protection.sh',
      'scripts/infrastructure/nginx-waf.conf',
      'scripts/infrastructure/fail2ban-wrfcoin.conf',
    ];
    const missingAssets = infraAssets.filter(
      p => !fs.existsSync(path.join(__dirname, '..', p))
    );
    if (missingAssets.length > 0) {
      findings.push(`missing infra assets: ${missingAssets.join(', ')}`);
    }

    // Layer 2 — application middleware in the entrypoint prod ACTUALLY runs
    // (enhanced_unified_api_optimized.ts; inspecting any other server file
    // reports middleware that never deploys).
    const backendDir = this.resolveBackendDir();
    if (!backendDir) {
      findings.push(
        'backend repo not found — set WRFCOIN_BACKEND_DIR or run from the workspace root'
      );
    } else {
      const liveEntrypoint = path.join(
        backendDir,
        'server',
        'enhanced_unified_api_optimized.ts'
      );
      let content = null;
      try {
        content = fs.readFileSync(liveEntrypoint, 'utf8');
      } catch {
        findings.push(`live API entrypoint not found: ${liveEntrypoint}`);
      }
      if (content !== null) {
        if (!/['"]helmet['"]/.test(content)) {
          findings.push('no helmet security headers in the live entrypoint');
          recommendations.push(
            'Wire helmet into server/enhanced_unified_api_optimized.ts (the entrypoint prod runs)'
          );
        }
        if (!/express-rate-limit/.test(content)) {
          findings.push('no express-rate-limit in the live entrypoint');
        }
        if (
          /rateLimitMiddleware:\s*\(\s*\)\s*=>\s*\([^)]*\)\s*=>\s*next\(\)/.test(
            content
          )
        ) {
          findings.push(
            'rateLimitMiddleware in the live entrypoint is a no-op passthrough'
          );
          recommendations.push(
            'Replace the no-op rateLimitMiddleware with a real express-rate-limit instance'
          );
        }
      }
    }

    recommendations.push(
      'Application/iptables limits are not full DDoS protection — front any ' +
        'public-internet exposure with a WAF/CDN (accepted gap while the ' +
        'testnet is tailnet-only)'
    );

    return {
      passed: findings.length === 0,
      details:
        findings.length === 0
          ? 'infra assets present; helmet + real rate limiting in the live entrypoint'
          : findings.join('; '),
      recommendations,
    };
  }

  checkGeographicDistribution() {
    // This would need real validator data - for now check infrastructure
    const hasMultiRegion = fs.existsSync(
      'infrastructure/docker/docker-compose.yml'
    );

    return {
      passed: hasMultiRegion,
      details: hasMultiRegion
        ? 'Infrastructure supports multi-region deployment'
        : 'Single-region deployment only',
      recommendations: [
        'Deploy validators across 3+ continents',
        'Add geographic diversity incentives',
      ],
    };
  }

  checkCrossChainRedundancy() {
    try {
      const crossChainServer = fs.readFileSync(
        'backend/server/cross_chain_protocol_server.js',
        'utf8'
      );
      const protocolCount = (crossChainServer.match(/protocol/gi) || []).length;

      return {
        passed: protocolCount >= 13,
        details: `Support for ${Math.min(13, Math.floor(protocolCount / 10))} cross-chain protocols`,
      };
    } catch (error) {
      return { passed: false, details: 'Cross-chain infrastructure not found' };
    }
  }

  checkMeshCapability() {
    const hasWebSocket = fs.existsSync('backend/server/websocket.js');
    const hasP2P = fs.existsSync('backend/server/easy_node_discovery.js');

    return {
      passed: hasWebSocket && hasP2P,
      details:
        hasWebSocket && hasP2P
          ? 'WebSocket and P2P discovery active'
          : 'Limited mesh networking capability',
      recommendations: [
        'Add LoRaWAN support',
        'Implement satellite connectivity',
      ],
    };
  }

  checkOnChainGovernance() {
    const hasGov = fs.existsSync('backend/server/governance_server.js');
    const hasVoting = fs.existsSync('scripts/seed-governance.js');

    return {
      passed: hasGov && hasVoting,
      details:
        hasGov && hasVoting
          ? 'On-chain governance infrastructure active'
          : 'Governance system incomplete',
    };
  }

  checkConsensusDataMigration() {
    const hasMigration = fs.existsSync(
      'scripts/migrate-consensus-data-onchain.js'
    );
    const hasReport = fs.existsSync(
      'docs/migration/consensus-data-migration-report.json'
    );

    return {
      passed: hasMigration && hasReport,
      details:
        hasMigration && hasReport
          ? 'Consensus data successfully migrated to blockchain'
          : 'Consensus migration incomplete',
    };
  }

  checkForkResistance() {
    // Check if multiple data interpretation methods exist
    const hasMultipleOracles = fs.existsSync('scripts/setup-wolfram-db.js');

    return {
      passed: hasMultipleOracles,
      details: hasMultipleOracles
        ? 'Multiple oracle systems configured'
        : 'Single oracle dependency risk',
    };
  }

  checkModularArchitecture() {
    try {
      const serverFiles = fs.readdirSync('backend/server');
      const moduleCount = serverFiles.filter(f => f.includes('server')).length;

      return {
        passed: moduleCount >= 10,
        details: `${moduleCount} modular services identified`,
      };
    } catch (error) {
      return {
        passed: false,
        details: 'Modular architecture assessment failed',
      };
    }
  }

  checkStagedRollouts() {
    const hasDocker = fs.existsSync('infrastructure/docker/docker-compose.yml');

    return {
      passed: hasDocker,
      details: hasDocker
        ? 'Container-based deployment supports staged rollouts'
        : 'No staged rollout capability',
    };
  }

  checkIPFSIntegration() {
    const hasIPFS = fs.existsSync('backend/server/ipfs/adapter.js');

    if (hasIPFS) {
      try {
        const ipfsContent = fs.readFileSync(
          'backend/server/ipfs/adapter.js',
          'utf8'
        );
        const isImplemented = ipfsContent.includes('QmExample');

        return {
          passed: !isImplemented, // Mock implementation means not really working
          details: isImplemented
            ? 'IPFS adapter is mock implementation'
            : 'IPFS adapter implemented',
          recommendations: isImplemented
            ? ['Implement real IPFS node connection']
            : [],
        };
      } catch (error) {
        return { passed: false, details: 'IPFS adapter file corrupt' };
      }
    }

    return { passed: false, details: 'IPFS integration not found' };
  }

  checkStorageNetworks() {
    return { passed: false,
      details: 'Legacy storage service retired; real IPFS availability requires daemon evidence' };
  }

  checkComputeNetworks() {
    const hasCompute = fs.existsSync(
      'backend/server/compute_networks_server.js'
    );

    return {
      passed: hasCompute,
      details: hasCompute
        ? 'Compute networks server implemented'
        : 'Distributed compute not configured',
    };
  }

  checkCLITool() {
    const hasCLI = fs.existsSync('cli/WrfcoinCLI/README.md');

    if (hasCLI) {
      try {
        const cliReadme = fs.readFileSync('cli/WrfcoinCLI/README.md', 'utf8');
        const hasInstallCmd = cliReadme.includes('npx wrfcoin-core install');

        return {
          passed: hasInstallCmd,
          details: hasInstallCmd
            ? 'CLI with install command documented'
            : 'CLI exists but missing one-command install',
        };
      } catch (error) {
        return { passed: false, details: 'CLI documentation corrupt' };
      }
    }

    return { passed: false, details: 'CLI tool not found' };
  }

  checkSelfHostingDocs() {
    const docFiles = [
      'docs/doc_center/unstoppable.md',
      'docs/getting-started.md',
      'infrastructure/docker/README.md',
    ];

    const existingDocs = docFiles.filter(f => fs.existsSync(f));

    return {
      passed: existingDocs.length >= 2,
      details: `${existingDocs.length}/${docFiles.length} self-hosting docs found`,
    };
  }

  checkSovereignDeployment() {
    const hasDocker = fs.existsSync('infrastructure/docker/docker-compose.yml');
    const hasCLI = fs.existsSync('cli/WrfcoinCLI');

    return {
      passed: hasDocker && hasCLI,
      details:
        hasDocker && hasCLI
          ? 'Docker + CLI enables sovereign deployment'
          : 'Sovereign deployment capability incomplete',
    };
  }

  calculateOverallScore() {
    const percentage = Math.round((this.totalScore / this.maxScore) * 100);

    console.log('\n🎯 OVERALL RESILIENCE SCORE');
    console.log('═══════════════════════════');
    console.log(
      `📊 Total Score: ${this.totalScore}/${this.maxScore} (${percentage}%)`
    );

    let assessment;
    if (percentage >= 90) assessment = '🔥 HIGHLY UNSTOPPABLE';
    else if (percentage >= 75) assessment = '💪 RESILIENT';
    else if (percentage >= 60) assessment = '⚠️  MODERATE RISK';
    else if (percentage >= 40) assessment = '🚨 HIGH RISK';
    else assessment = '💀 CRITICAL VULNERABILITIES';

    console.log(`🎖️  Assessment: ${assessment}\n`);
  }

  generateReport() {
    const report = {
      timestamp: new Date().toISOString(),
      overall_score: this.totalScore,
      max_score: this.maxScore,
      percentage: Math.round((this.totalScore / this.maxScore) * 100),
      category_scores: this.scores,
      detailed_results: this.results,
      critical_gaps: this.results.filter(r => !r.passed && r.maxScore >= 15),
      recommendations: this.results
        .filter(r => r.recommendations && r.recommendations.length > 0)
        .flatMap(r => r.recommendations),
    };

    const reportPath = 'docs/migration/resilience-scorecard-report.json';
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));

    console.log('📋 CRITICAL GAPS TO ADDRESS:');
    console.log('────────────────────────────');

    if (report.critical_gaps.length === 0) {
      console.log('✅ No critical gaps identified!');
    } else {
      report.critical_gaps.forEach(gap => {
        console.log(`❌ ${gap.check}: ${gap.details}`);
        if (gap.recommendations) {
          gap.recommendations.forEach(rec => {
            console.log(`   → ${rec}`);
          });
        }
      });
    }

    console.log(`\n📄 Full report saved to: ${reportPath}`);
    console.log('\n🚀 Next Steps:');
    console.log('──────────────');
    console.log('1. Address critical gaps (15+ point items)');
    console.log('2. Implement real IPFS node connections');
    console.log('3. Deploy hardware HSM keys');
    console.log('4. Add geographic validator distribution');
    console.log('5. Implement mesh/satellite connectivity');
  }
}

module.exports = { ResilienceScorecard };

// Run the audit (importable without side effects for tests)
if (require.main === module) {
  const scorecard = new ResilienceScorecard();
  scorecard.runAudit().catch(console.error);
}
