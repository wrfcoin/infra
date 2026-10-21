/**
 * Workflow Optimization Analysis
 * Analyzes current workflows and identifies consolidation opportunities
 */

const fs = require('fs');
const path = require('path');

class WorkflowOptimizer {
  constructor() {
    this.currentWorkflows = [
      // Database-related (now redundant after consolidation)
      'Axelar Schema Push',
      'Create Migration',
      'CrossChain Schema Consolidation',
      'Governance Schema Consolidation',
      'IoT Schema Consolidation',
      'Rewards Schema Consolidation',
      'System Schema Consolidation',
      'Users Schema Consolidation',
      'Oracle Schema Migration',
      'Create Data-Aware Blocks Migration',
      'Consensus Data Migration',
      'Distributed Database Layer',
      'Unified Database Seeding',
      'Setup Governance DB',
      'Setup Wolfram DB',

      // Server duplicates
      'Main API Server',
      'Production API Server',
      'Unified API Server',
      'Testnet API Server',
      'Enhanced Weather Rewards',
      'Enhanced Weather Rewards Fixed',
      'WebSocket Server',
      'WebSocket Server Fixed',
      'Service Control Panel',
      'Service Control Panel Fixed',
      'Enhanced Service Control Panel',

      // Essential workflows to keep
      'AcuRite Weather Station Collector', // Keep - earning WRF tokens
      'Frontend Application', // Keep - main UI
      'Cross-Chain Protocol Server', // Keep - core functionality
      'Cross-Chain WebSocket Port 5001', // Keep - real-time data
      'Contract Integration Port 9000', // Keep - smart contracts
      'IoT Sensor Networks Port 3002', // Keep - sensor management
      'Compute Networks Server', // Keep - computational power
      'Wallet Server Port 4000', // Keep - wallet management
      'Storage Networks Port 7000', // Keep - decentralized storage
      'AI ML Networks Port 6001', // Keep - AI/ML processing
      'Node Discovery Port 9001', // Keep - network discovery
      'NAS Storage Server', // Keep - NAS integration
      'Compute Contribution Server', // Keep - compute rewards
      'Weather Earnings Transfer API', // Keep - weather rewards
      'Governance Server', // Keep - governance functionality
      'Secure Messaging Server', // Keep - secure communications
      'MCP Server', // Keep - MCP protocol
    ];

    this.redundantWorkflows = [
      'Axelar Schema Push',
      'Create Migration',
      'CrossChain Schema Consolidation',
      'Governance Schema Consolidation',
      'IoT Schema Consolidation',
      'Rewards Schema Consolidation',
      'System Schema Consolidation',
      'Users Schema Consolidation',
      'Oracle Schema Migration',
      'Create Data-Aware Blocks Migration',
      'Consensus Data Migration',
      'Distributed Database Layer',
      'Unified Database Seeding',
      'Setup Governance DB',
      'Setup Wolfram DB',
      'Production API Server',
      'Testnet API Server',
      'Enhanced Weather Rewards',
      'Enhanced Weather Rewards Fixed',
      'WebSocket Server Fixed',
      'Service Control Panel',
      'Service Control Panel Fixed',
      'Enhanced Service Control Panel',
    ];

    this.consolidatedWorkflows = [
      'Main Unified API Server', // Combines Main/Production/Unified/Testnet
      'Primary WebSocket Server', // Combines WebSocket/WebSocket Fixed
      'Ultimate Service Control Panel', // Combines all control panels
    ];
  }

  analyzeRedundancy() {
    console.log('📊 Workflow Redundancy Analysis');
    console.log('=================================');
    console.log(`Total configured workflows: ${this.currentWorkflows.length}`);
    console.log(
      `Redundant workflows identified: ${this.redundantWorkflows.length}`
    );
    console.log(
      `Potential consolidations: ${this.consolidatedWorkflows.length}`
    );
    console.log('');

    console.log('🗑️ Workflows to Remove (Database consolidation complete):');
    this.redundantWorkflows.forEach(workflow => {
      console.log(`   ❌ ${workflow}`);
    });
    console.log('');

    console.log('🔧 Workflows to Consolidate:');
    console.log('   🔀 API Servers → Main Unified API Server');
    console.log('   🔀 WebSocket Servers → Primary WebSocket Server');
    console.log('   🔀 Control Panels → Ultimate Service Control Panel');
    console.log('');

    return {
      redundantCount: this.redundantWorkflows.length,
      consolidationOpportunities: this.consolidatedWorkflows.length,
      potentialReduction: this.redundantWorkflows.length + 6, // 6 = servers being consolidated
    };
  }

  generateOptimizationPlan() {
    const analysis = this.analyzeRedundancy();

    const plan = {
      phase1: {
        name: 'Remove Database Migration Workflows',
        description: 'Remove all schema consolidation workflows (complete)',
        workflows: this.redundantWorkflows.filter(
          w =>
            w.includes('Schema') || w.includes('Migration') || w.includes('DB')
        ),
        impact: 'High - eliminates 15 redundant database workflows',
      },
      phase2: {
        name: 'Consolidate API Servers',
        description: 'Merge multiple API servers into single unified server',
        workflows: [
          'Main API Server',
          'Production API Server',
          'Unified API Server',
          'Testnet API Server',
        ],
        newWorkflow: 'Main Unified API Server',
        impact: 'Medium - reduces 4 servers to 1',
      },
      phase3: {
        name: 'Consolidate WebSocket Servers',
        description: 'Merge WebSocket servers into single optimized server',
        workflows: ['WebSocket Server', 'WebSocket Server Fixed'],
        newWorkflow: 'Primary WebSocket Server',
        impact: 'Low - reduces 2 servers to 1',
      },
      phase4: {
        name: 'Consolidate Control Panels',
        description: 'Merge all control panel variants into ultimate version',
        workflows: [
          'Service Control Panel',
          'Service Control Panel Fixed',
          'Enhanced Service Control Panel',
        ],
        newWorkflow: 'Ultimate Service Control Panel',
        impact: 'Medium - reduces 3 panels to 1',
      },
    };

    console.log('📋 Optimization Plan:');
    console.log('====================');
    Object.entries(plan).forEach(([phase, details]) => {
      console.log(`${phase.toUpperCase()}: ${details.name}`);
      console.log(`   Description: ${details.description}`);
      console.log(`   Impact: ${details.impact}`);
      console.log('');
    });

    return plan;
  }

  calculateSavings() {
    const totalWorkflows = this.currentWorkflows.length;
    const redundantCount = this.redundantWorkflows.length;
    const consolidationSavings = 6; // 4 API + 1 WebSocket + 1 Control Panel savings

    const finalCount = totalWorkflows - redundantCount - consolidationSavings;
    const reductionPercent = (
      ((redundantCount + consolidationSavings) / totalWorkflows) *
      100
    ).toFixed(1);

    console.log('💰 Optimization Savings:');
    console.log('========================');
    console.log(`Current workflows: ${totalWorkflows}`);
    console.log(`After optimization: ${finalCount}`);
    console.log(
      `Total reduction: ${redundantCount + consolidationSavings} workflows`
    );
    console.log(`Efficiency gain: ${reductionPercent}% reduction`);
    console.log('');

    return {
      currentCount: totalWorkflows,
      finalCount: finalCount,
      reduction: redundantCount + consolidationSavings,
      efficiencyGain: reductionPercent,
    };
  }
}

// Run analysis
const optimizer = new WorkflowOptimizer();
const analysis = optimizer.analyzeRedundancy();
const plan = optimizer.generateOptimizationPlan();
const savings = optimizer.calculateSavings();

console.log('✅ Analysis Complete!');
console.log(
  `Recommended action: Remove ${analysis.redundantCount} redundant workflows`
);
console.log(
  `Additional consolidation: ${analysis.consolidationOpportunities} opportunities`
);
console.log(
  `Total optimization potential: ${savings.efficiencyGain}% workflow reduction`
);
