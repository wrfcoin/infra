/**
 * Comprehensive Test Suite for Capacity Validation Framework
 *
 * Tests the complete capacity validation and horizontal scalability framework
 * including all components: CapacityValidationFramework, CapacityValidationManager,
 * HorizontalScalabilityManager, and BottleneckDetectionSystem.
 */

const CapacityValidationFramework = require('./capacity-validation-framework');
const CapacityValidationManager = require('./capacity-validation-manager');
const HorizontalScalabilityManager = require('./horizontal-scalability-manager');
const BottleneckDetectionSystem = require('./bottleneck-detection-system');

describe('Capacity Validation Framework - Complete Integration Tests', () => {
  let framework;
  let capacityValidator;
  let scalabilityManager;
  let bottleneckDetector;

  const testConfig = {
    baselineCapacity: 10000,
    targetCapacity: 50000,
    maxCapacity: 100000,
    initialNodeCount: 1,
    maxNodeCount: 5,
    loadIncrementStrategy: 'exponential',
    integrationMode: 'standalone',
    debugMode: true,
  };

  beforeAll(async () => {
    console.log('🏗️  Setting up Capacity Validation Framework Test Suite');
    console.log('================================================');

    // Initialize framework
    framework = new CapacityValidationFramework(testConfig);
    await framework.initialize();

    // Initialize individual components for unit testing
    capacityValidator = new CapacityValidationManager({
      baselineCapacity: testConfig.baselineCapacity,
      targetCapacity: testConfig.targetCapacity,
      maxCapacity: testConfig.maxCapacity,
    });

    scalabilityManager = new HorizontalScalabilityManager({
      initialNodeCount: testConfig.initialNodeCount,
      maxNodeCount: testConfig.maxNodeCount,
    });

    bottleneckDetector = new BottleneckDetectionSystem({
      monitoringInterval: 1, // 1 second for testing
      cpuThreshold: 0.8,
      memoryThreshold: 0.85,
    });

    console.log('✅ Framework initialization completed');
  });

  describe('Framework Integration Tests', () => {
    test('should initialize framework with all components', async () => {
      expect(framework).toBeDefined();
      expect(framework.capacityValidator).toBeDefined();
      expect(framework.scalabilityManager).toBeDefined();
      expect(framework.bottleneckDetector).toBeDefined();
      expect(framework.workloadGenerator).toBeDefined();
    });

    test('should validate framework configuration', async () => {
      const capabilities = framework.getCapabilities();

      expect(capabilities.capacityTesting).toBe(true);
      expect(capabilities.horizontalScaling).toBe(true);
      expect(capabilities.bottleneckDetection).toBe(true);
      expect(capabilities.maxCapacity).toBe(testConfig.maxCapacity);
      expect(capabilities.maxNodes).toBe(testConfig.maxNodeCount);
    });

    test('should execute complete capacity validation workflow', async () => {
      console.log('\n🚀 Testing Complete Capacity Validation Workflow');

      const startTime = Date.now();
      const report = await framework.executeCapacityValidation();
      const duration = Date.now() - startTime;

      console.log(`   ⏱️  Test completed in ${Math.round(duration / 1000)}s`);

      // Validate report structure
      expect(report).toBeDefined();
      expect(report.timestamp).toBeDefined();
      expect(report.executionSummary).toBeDefined();
      expect(report.capacityValidation).toBeDefined();
      expect(report.horizontalScalability).toBeDefined();
      expect(report.bottleneckAnalysis).toBeDefined();
      expect(report.performanceMetrics).toBeDefined();
      expect(report.recommendations).toBeDefined();

      // Validate execution summary
      expect(report.executionSummary.maxCapacityAchieved).toBeGreaterThan(0);
      expect(report.executionSummary.maxNodesUsed).toBeGreaterThanOrEqual(
        testConfig.initialNodeCount
      );
      expect(report.executionSummary.overallStatus).toBe('SUCCESS');

      // Validate capacity validation results
      expect(report.capacityValidation.baselineCapacity).toBe(
        testConfig.baselineCapacity
      );
      expect(report.capacityValidation.targetCapacity).toBe(
        testConfig.targetCapacity
      );
      expect(report.capacityValidation.achievedCapacity).toBeGreaterThan(0);

      // Validate horizontal scalability results
      expect(report.horizontalScalability.initialNodeCount).toBe(
        testConfig.initialNodeCount
      );
      expect(report.horizontalScalability.maxNodeCount).toBeGreaterThanOrEqual(
        testConfig.initialNodeCount
      );

      // Validate bottleneck analysis
      expect(report.bottleneckAnalysis.systemHealth).toBeDefined();
      expect(Array.isArray(report.bottleneckAnalysis.bottlenecks)).toBe(true);

      console.log(
        `   📊 Max Capacity: ${report.executionSummary.maxCapacityAchieved.toLocaleString()} TPS`
      );
      console.log(`   📈 Max Nodes: ${report.executionSummary.maxNodesUsed}`);
      console.log(
        `   🎯 System Health: ${report.bottleneckAnalysis.systemHealth}`
      );
      console.log(`   ✅ Workflow test completed successfully`);
    }, 120000); // 2 minute timeout
  });

  describe('Capacity Validation Manager Tests', () => {
    test('should validate baseline capacity', async () => {
      console.log('\n📏 Testing Baseline Capacity Validation');

      // Mock workload generator
      const mockWorkloadGenerator = {
        updateConfig: jest.fn(),
        startEnterpriseWorkload: jest.fn().mockResolvedValue({
          performanceMetrics: {
            actualTPS: '9500',
            successRate: '98.5%',
            averageLatency: '45ms',
            totalTransactions: 570000,
            successfulTransactions: 561750,
          },
        }),
      };

      const baselineResult = await capacityValidator.validateBaseline(
        testConfig.baselineCapacity,
        mockWorkloadGenerator
      );

      expect(baselineResult).toBeDefined();
      expect(baselineResult.phase).toBe('BASELINE');
      expect(baselineResult.targetCapacity).toBe(testConfig.baselineCapacity);
      expect(baselineResult.achievedCapacity).toBe(9500);
      expect(baselineResult.passed).toBe(true);

      console.log(
        `   ✅ Baseline validation: ${baselineResult.achievedCapacity} TPS achieved`
      );
    });

    test('should execute incremental capacity testing', async () => {
      console.log('\n📈 Testing Incremental Capacity Testing');

      // Mock workload generator with progressive results
      let callCount = 0;
      const mockWorkloadGenerator = {
        updateConfig: jest.fn(),
        startEnterpriseWorkload: jest.fn().mockImplementation(() => {
          callCount++;
          const tps = Math.min(50000, 10000 * Math.pow(1.25, callCount - 1));
          return Promise.resolve({
            performanceMetrics: {
              actualTPS: tps.toFixed(0),
              successRate: '97.2%',
              averageLatency: `${50 + callCount * 10}ms`,
              totalTransactions: tps * 60,
              successfulTransactions: tps * 60 * 0.972,
            },
          });
        }),
      };

      // Mock bottleneck detector
      const mockBottleneckDetector = {
        startMonitoring: jest.fn(),
        stopMonitoring: jest.fn(),
        getDetectedBottlenecks: jest.fn().mockResolvedValue([]),
      };

      const incrementalResults =
        await capacityValidator.executeIncrementalTesting(
          testConfig.baselineCapacity,
          testConfig.targetCapacity,
          mockWorkloadGenerator,
          mockBottleneckDetector
        );

      expect(incrementalResults).toBeDefined();
      expect(incrementalResults.maxAchievedCapacity).toBeGreaterThan(
        testConfig.baselineCapacity
      );
      expect(incrementalResults.totalPhases).toBeGreaterThan(0);
      expect(incrementalResults.phaseResults).toBeDefined();
      expect(Array.isArray(incrementalResults.phaseResults)).toBe(true);

      console.log(
        `   📊 Max capacity achieved: ${incrementalResults.maxAchievedCapacity.toLocaleString()} TPS`
      );
      console.log(`   📈 Phases completed: ${incrementalResults.totalPhases}`);
      console.log(`   ✅ Incremental testing completed successfully`);
    });
  });

  describe('Horizontal Scalability Manager Tests', () => {
    test('should initialize baseline nodes', async () => {
      console.log('\n🚀 Testing Node Initialization');

      await scalabilityManager.initializeBaselineNodes();

      const state = scalabilityManager.getCurrentState();
      expect(state.currentNodeCount).toBe(testConfig.initialNodeCount);
      expect(state.activeNodes.size).toBe(testConfig.initialNodeCount);

      console.log(`   ✅ ${state.currentNodeCount} baseline nodes initialized`);
    });

    test('should execute scaling scenarios', async () => {
      console.log('\n📈 Testing Horizontal Scaling Scenarios');

      // Mock capacity validator and workload generator
      const mockCapacityValidator = {
        testCurrentCapacity: jest.fn().mockResolvedValue({
          achievedTPS: 25000,
          efficiency: 85,
        }),
      };

      const mockWorkloadGenerator = {
        updateConfig: jest.fn(),
        startEnterpriseWorkload: jest.fn().mockResolvedValue({
          performanceMetrics: {
            actualTPS: '35000',
            averageLatency: '65ms',
          },
        }),
      };

      const mockBottleneckDetector = {
        getDetectedBottlenecks: jest.fn().mockResolvedValue([]),
      };

      const scalingResults = await scalabilityManager.executeScalingScenarios(
        mockCapacityValidator,
        mockWorkloadGenerator,
        mockBottleneckDetector
      );

      expect(scalingResults).toBeDefined();
      expect(Array.isArray(scalingResults)).toBe(true);
      expect(scalingResults.length).toBeGreaterThan(0);

      const passedScenarios = scalingResults.filter(r => r.success);
      console.log(`   📊 Scenarios tested: ${scalingResults.length}`);
      console.log(`   ✅ Successful scenarios: ${passedScenarios.length}`);
      console.log(`   ✅ Scaling scenarios completed successfully`);
    });

    test('should handle node lifecycle operations', async () => {
      console.log('\n🔄 Testing Node Lifecycle Operations');

      const initialState = scalabilityManager.getCurrentState();
      const initialNodeCount = initialState.currentNodeCount;

      // Test adding a node
      await scalabilityManager.startNode('test-node-lifecycle-1');

      let currentState = scalabilityManager.getCurrentState();
      expect(currentState.currentNodeCount).toBe(initialNodeCount + 1);
      expect(currentState.activeNodes.has('test-node-lifecycle-1')).toBe(true);

      console.log(
        `   ⬆️  Node added: ${currentState.currentNodeCount} total nodes`
      );

      // Test removing a node
      await scalabilityManager.stopNode('test-node-lifecycle-1');

      currentState = scalabilityManager.getCurrentState();
      expect(currentState.currentNodeCount).toBe(initialNodeCount);
      expect(currentState.activeNodes.has('test-node-lifecycle-1')).toBe(false);

      console.log(
        `   ⬇️  Node removed: ${currentState.currentNodeCount} total nodes`
      );
      console.log(`   ✅ Node lifecycle operations completed successfully`);
    });
  });

  describe('Bottleneck Detection System Tests', () => {
    test('should start and stop monitoring', async () => {
      console.log('\n🔍 Testing Bottleneck Detection Monitoring');

      expect(bottleneckDetector.state.isMonitoring).toBe(false);

      await bottleneckDetector.startMonitoring();
      expect(bottleneckDetector.state.isMonitoring).toBe(true);
      expect(bottleneckDetector.state.monitoringStartTime).toBeDefined();

      console.log(`   ✅ Monitoring started successfully`);

      // Let it run for a few seconds to collect some data
      await new Promise(resolve => setTimeout(resolve, 3000));

      expect(bottleneckDetector.state.historicalData.length).toBeGreaterThan(0);
      console.log(
        `   📊 Collected ${bottleneckDetector.state.historicalData.length} data points`
      );

      await bottleneckDetector.stopMonitoring();
      expect(bottleneckDetector.state.isMonitoring).toBe(false);

      console.log(`   ✅ Monitoring stopped successfully`);
    });

    test('should detect and analyze bottlenecks', async () => {
      console.log('\n🚨 Testing Bottleneck Detection and Analysis');

      await bottleneckDetector.startMonitoring();

      // Let monitoring run for a bit to collect data
      await new Promise(resolve => setTimeout(resolve, 5000));

      const detectedBottlenecks =
        await bottleneckDetector.getDetectedBottlenecks();

      console.log(`   📊 Bottlenecks detected: ${detectedBottlenecks.length}`);

      if (detectedBottlenecks.length > 0) {
        const criticalBottlenecks = detectedBottlenecks.filter(
          b => b.severity === 'critical'
        );
        const highBottlenecks = detectedBottlenecks.filter(
          b => b.severity === 'high'
        );

        console.log(`   🔴 Critical: ${criticalBottlenecks.length}`);
        console.log(`   🟠 High: ${highBottlenecks.length}`);

        // Validate bottleneck structure
        detectedBottlenecks.forEach(bottleneck => {
          expect(bottleneck.type).toBeDefined();
          expect(bottleneck.severity).toBeDefined();
          expect(bottleneck.component).toBeDefined();
          expect(bottleneck.description).toBeDefined();
          expect(bottleneck.recommendation).toBeDefined();
        });
      }

      // Test comprehensive analysis
      const analysis = await bottleneckDetector.performComprehensiveAnalysis();

      expect(analysis).toBeDefined();
      expect(analysis.systemHealth).toBeDefined();
      expect(analysis.bottlenecks).toBeDefined();
      expect(analysis.recommendations).toBeDefined();
      expect(analysis.performanceIndicators).toBeDefined();

      console.log(`   🎯 System Health: ${analysis.systemHealth}`);
      console.log(`   💡 Recommendations: ${analysis.recommendations.length}`);

      await bottleneckDetector.stopMonitoring();

      console.log(
        `   ✅ Bottleneck detection and analysis completed successfully`
      );
    });

    test('should perform trend analysis', async () => {
      console.log('\n📈 Testing Trend Analysis');

      await bottleneckDetector.startMonitoring();

      // Let it run longer to build trend data
      await new Promise(resolve => setTimeout(resolve, 8000));

      const state = bottleneckDetector.getCurrentState();

      // Check if trend data was collected
      const trendData = state.trendData;
      expect(trendData).toBeDefined();
      expect(trendData.cpu).toBeDefined();
      expect(trendData.memory).toBeDefined();
      expect(trendData.latency).toBeDefined();

      console.log(`   📊 CPU trends: ${trendData.cpu.length} data points`);
      console.log(
        `   📊 Memory trends: ${trendData.memory.length} data points`
      );
      console.log(
        `   📊 Latency trends: ${trendData.latency.length} data points`
      );

      await bottleneckDetector.stopMonitoring();

      console.log(`   ✅ Trend analysis completed successfully`);
    });
  });

  describe('Performance and Load Tests', () => {
    test('should handle high-frequency capacity testing', async () => {
      console.log('\n⚡ Testing High-Frequency Capacity Testing');

      const testIterations = 5;
      const results = [];

      for (let i = 0; i < testIterations; i++) {
        const startTime = Date.now();

        // Mock workload generator for quick tests
        const mockWorkloadGenerator = {
          updateConfig: jest.fn(),
          startEnterpriseWorkload: jest.fn().mockResolvedValue({
            performanceMetrics: {
              actualTPS: (15000 + Math.random() * 10000).toFixed(0),
              successRate: '96.8%',
              averageLatency: `${60 + Math.random() * 40}ms`,
            },
          }),
        };

        const result = await capacityValidator.validateBaseline(
          10000 + i * 5000,
          mockWorkloadGenerator
        );

        const duration = Date.now() - startTime;
        results.push({
          iteration: i + 1,
          duration,
          achieved: result.achievedCapacity,
        });

        console.log(
          `   🔄 Iteration ${i + 1}: ${result.achievedCapacity} TPS in ${duration}ms`
        );
      }

      const avgDuration =
        results.reduce((sum, r) => sum + r.duration, 0) / results.length;
      const avgTPS =
        results.reduce((sum, r) => sum + r.achieved, 0) / results.length;

      console.log(`   📊 Average duration: ${Math.round(avgDuration)}ms`);
      console.log(`   📊 Average TPS: ${Math.round(avgTPS).toLocaleString()}`);
      console.log(`   ✅ High-frequency testing completed successfully`);

      expect(avgDuration).toBeLessThan(5000); // Should complete within 5 seconds
      expect(avgTPS).toBeGreaterThan(10000);
    });

    test('should handle concurrent scaling operations', async () => {
      console.log('\n🔀 Testing Concurrent Scaling Operations');

      const concurrentOperations = [];

      // Create multiple concurrent scaling operations
      for (let i = 0; i < 3; i++) {
        const operation = scalabilityManager.startNode(
          `concurrent-node-${i + 1}`
        );
        concurrentOperations.push(operation);
      }

      // Wait for all operations to complete
      await Promise.all(concurrentOperations);

      const state = scalabilityManager.getCurrentState();
      expect(state.currentNodeCount).toBeGreaterThanOrEqual(
        testConfig.initialNodeCount + 3
      );

      console.log(
        `   📊 Total nodes after concurrent scaling: ${state.currentNodeCount}`
      );

      // Clean up - remove concurrent nodes
      const cleanupOperations = [];
      for (let i = 0; i < 3; i++) {
        const operation = scalabilityManager.stopNode(
          `concurrent-node-${i + 1}`
        );
        cleanupOperations.push(operation);
      }

      await Promise.all(cleanupOperations);

      console.log(`   ✅ Concurrent scaling operations completed successfully`);
    });
  });

  describe('Error Handling and Edge Cases', () => {
    test('should handle invalid configuration gracefully', () => {
      console.log('\n⚠️  Testing Invalid Configuration Handling');

      expect(() => {
        new CapacityValidationFramework({
          baselineCapacity: 100000, // Higher than target
          targetCapacity: 50000,
          maxCapacity: 200000,
        });
      }).not.toThrow();

      expect(() => {
        new CapacityValidationManager({
          baselineCapacity: -1000, // Negative value
        });
      }).not.toThrow();

      console.log(`   ✅ Invalid configuration handled gracefully`);
    });

    test('should handle component failures gracefully', async () => {
      console.log('\n💥 Testing Component Failure Handling');

      // Test with failing workload generator
      const failingWorkloadGenerator = {
        updateConfig: jest.fn(),
        startEnterpriseWorkload: jest
          .fn()
          .mockRejectedValue(new Error('Simulated failure')),
      };

      try {
        await capacityValidator.validateBaseline(
          10000,
          failingWorkloadGenerator
        );
        // Should not reach here if error handling is working
        expect(false).toBe(true);
      } catch (error) {
        expect(error.message).toContain('Simulated failure');
        console.log(
          `   ✅ Component failure handled gracefully: ${error.message}`
        );
      }
    });

    test('should handle resource constraints', async () => {
      console.log('\n🎯 Testing Resource Constraint Handling');

      // Test with very high capacity requirements
      const highCapacityConfig = {
        ...testConfig,
        targetCapacity: 1000000, // 1M TPS
        maxCapacity: 2000000, // 2M TPS
      };

      const highCapacityValidator = new CapacityValidationManager(
        highCapacityConfig
      );

      const mockWorkloadGenerator = {
        updateConfig: jest.fn(),
        startEnterpriseWorkload: jest.fn().mockResolvedValue({
          performanceMetrics: {
            actualTPS: '50000', // Much lower than target
            successRate: '85%', // Lower success rate
            averageLatency: '500ms', // Higher latency
          },
        }),
      };

      const result = await highCapacityValidator.validateBaseline(
        highCapacityConfig.baselineCapacity,
        mockWorkloadGenerator
      );

      expect(result).toBeDefined();
      expect(result.passed).toBe(false); // Should fail due to constraints

      console.log(
        `   📊 High capacity test result: ${result.passed ? 'PASSED' : 'FAILED'}`
      );
      console.log(`   ✅ Resource constraint handling completed successfully`);
    });
  });

  afterAll(async () => {
    console.log('\n🧹 Cleaning up test environment...');

    // Stop any running monitoring
    if (bottleneckDetector.state.isMonitoring) {
      await bottleneckDetector.stopMonitoring();
    }

    // Clean up any remaining nodes
    const state = scalabilityManager.getCurrentState();
    const nodeIds = Array.from(state.activeNodes.keys());

    for (const nodeId of nodeIds) {
      try {
        await scalabilityManager.stopNode(nodeId);
      } catch (error) {
        console.log(
          `   ⚠️  Failed to cleanup node ${nodeId}: ${error.message}`
        );
      }
    }

    console.log('✅ Test environment cleanup completed');
    console.log(
      '\n🎉 Capacity Validation Framework Test Suite Completed Successfully'
    );
    console.log(
      '================================================================'
    );
  });
});

// Performance benchmarking utility
function runPerformanceBenchmark() {
  console.log('\n🏃‍♂️ Running Performance Benchmark...');
  console.log('=====================================');

  const metrics = {
    frameworkInitialization: 0,
    capacityValidation: 0,
    horizontalScaling: 0,
    bottleneckDetection: 0,
    memoryUsage: process.memoryUsage(),
  };

  console.log('📊 Performance Metrics:');
  console.log(
    `   Memory Usage: ${Math.round(metrics.memoryUsage.heapUsed / 1024 / 1024)}MB`
  );
  console.log(`   Framework Init: ${metrics.frameworkInitialization}ms`);
  console.log(`   Capacity Test: ${metrics.capacityValidation}ms`);
  console.log(`   Scaling Test: ${metrics.horizontalScaling}ms`);
  console.log(`   Bottleneck Detection: ${metrics.bottleneckDetection}ms`);

  return metrics;
}

// Export for external usage
module.exports = {
  CapacityValidationFramework,
  CapacityValidationManager,
  HorizontalScalabilityManager,
  BottleneckDetectionSystem,
  runPerformanceBenchmark,
};
