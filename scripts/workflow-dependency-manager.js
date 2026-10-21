#!/usr/bin/env node

/**
 * WRF Workflow Dependency Manager
 * Smart tagging and dependency orchestration for 74-workflow system
 * Implements earnings protection and cascade prevention strategies
 */

const fs = require('fs');
const path = require('path');

class WorkflowDependencyManager {
  constructor() {
    this.metadataFile = 'docs/architecture/workflow-metadata-registry.json';
    this.metadata = this.loadMetadata();
  }

  loadMetadata() {
    try {
      const data = fs.readFileSync(this.metadataFile, 'utf8');
      return JSON.parse(data);
    } catch (error) {
      console.error('❌ Failed to load workflow metadata:', error.message);
      return { workflows: {}, dependency_groups: {}, restart_strategies: {} };
    }
  }

  // Query workflows by tags
  getWorkflowsByTags(tags) {
    const results = [];
    for (const [id, workflow] of Object.entries(this.metadata.workflows)) {
      if (tags.some(tag => workflow.tags.includes(tag))) {
        results.push({ id, ...workflow });
      }
    }
    return results;
  }

  // Get dependency chain for a workflow
  getDependencyChain(workflowId, visited = new Set()) {
    if (visited.has(workflowId)) return []; // Prevent circular dependencies
    visited.add(workflowId);

    const workflow = this.metadata.workflows[workflowId];
    if (!workflow) return [];

    const chain = [workflowId];

    for (const dep of workflow.dependencies || []) {
      const depId = this.normalizeWorkflowId(dep);
      chain.push(...this.getDependencyChain(depId, visited));
    }

    return [...new Set(chain)]; // Remove duplicates
  }

  // Get restart order based on dependencies
  getRestartOrder(workflowIds) {
    const order = [];
    const processed = new Set();

    const addToOrder = id => {
      if (processed.has(id)) return;

      const workflow = this.metadata.workflows[id];
      if (!workflow) return;

      // Add dependencies first
      for (const dep of workflow.dependencies || []) {
        const depId = this.normalizeWorkflowId(dep);
        if (workflowIds.includes(depId)) {
          addToOrder(depId);
        }
      }

      order.push(id);
      processed.add(id);
    };

    workflowIds.forEach(addToOrder);
    return order;
  }

  // Check if workflow is earnings-critical
  isEarningsCritical(workflowId) {
    const workflow = this.metadata.workflows[workflowId];
    return (
      workflow &&
      (workflow.tags.includes('@earnings') ||
        workflow.tags.includes('@critical') ||
        this.metadata.restart_strategies.earnings_protection?.never_restart?.includes(
          workflowId
        ))
    );
  }

  // Visualize dependency graph
  visualizeDependencies(workflowId = null) {
    console.log('\n🔗 WRF Workflow Dependency Graph\n');

    const workflows = workflowId
      ? [this.metadata.workflows[workflowId]]
      : Object.values(this.metadata.workflows);

    workflows.forEach(workflow => {
      if (!workflow) return;

      const statusIcon = workflow.status === 'running' ? '✅' : '⭕';
      const criticalIcon = this.isEarningsCritical(workflow.name) ? '💰' : '';

      console.log(`${statusIcon} ${criticalIcon} ${workflow.name}`);
      console.log(`   📋 Tags: ${workflow.tags.join(', ')}`);
      console.log(`   🏗️  Group: ${workflow.group} | Scope: ${workflow.scope}`);

      if (workflow.port) {
        console.log(`   🔌 Port: ${workflow.port}`);
      }

      if (workflow.dependencies?.length > 0) {
        console.log(`   ⬇️  Depends on: ${workflow.dependencies.join(', ')}`);
      }

      if (workflow.dependents?.length > 0) {
        console.log(`   ⬆️  Supports: ${workflow.dependents.join(', ')}`);
      }

      if (workflow.current_earnings) {
        console.log(`   💰 Earnings: ${workflow.current_earnings}`);
      }

      console.log('');
    });
  }

  // Smart restart with earnings protection
  smartRestart(workflowIds, options = {}) {
    console.log('\n🔄 Smart Restart Analysis\n');

    // Check for earnings-critical workflows
    const earningsCritical = workflowIds.filter(id =>
      this.isEarningsCritical(id)
    );
    if (earningsCritical.length > 0 && !options.forceEarnings) {
      console.log('⚠️  EARNINGS PROTECTION TRIGGERED');
      console.log(
        `💰 The following workflows are earnings-critical: ${earningsCritical.join(', ')}`
      );
      console.log('🛡️  Use --force-earnings flag to override protection');
      return false;
    }

    // Calculate restart order
    const restartOrder = this.getRestartOrder(workflowIds);
    console.log('📋 Restart Order:');
    restartOrder.forEach((id, index) => {
      const workflow = this.metadata.workflows[id];
      console.log(
        `   ${index + 1}. ${workflow?.name || id} (${workflow?.restart_mode || 'graceful'})`
      );
    });

    // Show affected dependents
    const affectedDependents = new Set();
    workflowIds.forEach(id => {
      const workflow = this.metadata.workflows[id];
      if (workflow?.dependents) {
        workflow.dependents.forEach(dep => affectedDependents.add(dep));
      }
    });

    if (affectedDependents.size > 0) {
      console.log('\n⚠️  Affected Dependents:');
      Array.from(affectedDependents).forEach(dep => {
        console.log(`   📡 ${dep}`);
      });
    }

    return restartOrder;
  }

  // Health check based on tags
  healthCheckByTags(tags) {
    console.log(`\n🏥 Health Check: ${tags.join(', ')}\n`);

    const workflows = this.getWorkflowsByTags(tags);
    workflows.forEach(workflow => {
      const statusIcon = workflow.status === 'running' ? '✅' : '❌';
      const healthInterval = workflow.health_check?.interval || 'N/A';

      console.log(`${statusIcon} ${workflow.name}`);
      console.log(`   🔄 Check interval: ${healthInterval}s`);
      console.log(`   📊 Status: ${workflow.status}`);

      if (workflow.current_earnings) {
        console.log(`   💰 Earnings: ${workflow.current_earnings}`);
      }
      console.log('');
    });
  }

  normalizeWorkflowId(name) {
    return name.toLowerCase().replace(/[^a-z0-9]/g, '_');
  }
}

// CLI Interface
function main() {
  const manager = new WorkflowDependencyManager();
  const args = process.argv.slice(2);
  const command = args[0];

  switch (command) {
    case 'visualize':
      manager.visualizeDependencies(args[1]);
      break;

    case 'query':
      const tags = args.slice(1);
      const results = manager.getWorkflowsByTags(tags);
      console.log(
        `\n🔍 Found ${results.length} workflows with tags: ${tags.join(', ')}\n`
      );
      results.forEach(w => console.log(`✅ ${w.name} (${w.status})`));
      break;

    case 'health':
      const healthTags = args.slice(1) || ['@critical', '@realtime'];
      manager.healthCheckByTags(healthTags);
      break;

    case 'restart':
      const workflowIds = args.slice(1);
      const forceEarnings = args.includes('--force-earnings');
      manager.smartRestart(workflowIds, { forceEarnings });
      break;

    case 'earnings':
      console.log('\n💰 Earnings-Protected Workflows:\n');
      const earningsWorkflows = manager.getWorkflowsByTags([
        '@earnings',
        '@critical',
      ]);
      earningsWorkflows.forEach(w => {
        console.log(`💰 ${w.name} - Status: ${w.status}`);
        if (w.current_earnings)
          console.log(`   📈 Earned: ${w.current_earnings}`);
      });
      break;

    default:
      console.log(`
🔗 WRF Workflow Dependency Manager

Usage: node workflow-dependency-manager.js <command> [args]

Commands:
  visualize [workflow]     Show dependency graph
  query <tags...>         Find workflows by tags  
  health [tags...]        Health check by tags
  restart <workflows...>  Smart restart with protection
  earnings               Show earnings-protected workflows

Examples:
  node workflow-dependency-manager.js query @critical @realtime
  node workflow-dependency-manager.js health @earnings
  node workflow-dependency-manager.js restart acurite_weather_station_collector
  node workflow-dependency-manager.js visualize
      `);
  }
}

if (require.main === module) {
  main();
}

module.exports = WorkflowDependencyManager;
