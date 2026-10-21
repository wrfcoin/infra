#!/usr/bin/env node

/**
 * Bittensor Integration Test
 * Tests AI/ML model integration with Bittensor network
 */

const axios = require('axios');
const crypto = require('crypto');

class BittensorTest {
  constructor() {
    this.config = {
      bittensorUrl: process.env.BITTENSOR_URL || 'https://api.bittensor.com',
      wrfcoinNodeUrl: process.env.WRFCOIN_NODE_URL || 'http://localhost:3000',
      subnetId: process.env.BITTENSOR_SUBNET || '1',
      hotkey: process.env.BITTENSOR_HOTKEY || 'test-hotkey',
      coldkey: process.env.BITTENSOR_COLDKEY || 'test-coldkey',
    };

    this.testResults = {
      networkConnection: false,
      modelRegistration: false,
      inferenceTest: false,
      rewardDistribution: false,
      performanceMetrics: false,
    };
  }

  /**
   * Test Bittensor network connection
   */
  async testNetworkConnection() {
    console.log('🔗 Testing Bittensor network connection...');

    try {
      // Simulate Bittensor network status check
      const response = await axios.get(
        `${this.config.wrfcoinNodeUrl}/api/ai-ml/bittensor/status`,
        { timeout: 10000 }
      );

      if (response.data.connected) {
        console.log('✅ Bittensor network connection established');
        console.log(`🌐 Subnet ID: ${response.data.subnetId}`);
        console.log(`🔥 Active Neurons: ${response.data.activeNeurons}`);
        this.testResults.networkConnection = true;
        return true;
      }

      throw new Error('Network not connected');
    } catch (error) {
      console.error('❌ Bittensor network connection failed:', error.message);
      return false;
    }
  }

  /**
   * Test AI model registration
   */
  async testModelRegistration() {
    console.log('🤖 Testing AI model registration...');

    try {
      const modelConfig = {
        name: 'climate-prediction-model',
        type: 'neural-network',
        version: '1.0.0',
        description: 'Climate prediction model for weather forecasting',
        inputs: ['temperature', 'humidity', 'pressure'],
        outputs: ['weather_prediction', 'confidence_score'],
        hotkey: this.config.hotkey,
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/ai-ml/bittensor/register`,
        modelConfig,
        { timeout: 30000 }
      );

      if (response.data.success) {
        console.log('✅ AI model registered successfully');
        console.log(`🆔 Model UID: ${response.data.uid}`);
        console.log(`⚡ Stake Required: ${response.data.stakeRequired} TAO`);
        this.testResults.modelRegistration = true;
        return true;
      }

      throw new Error('Model registration failed');
    } catch (error) {
      console.error('❌ AI model registration failed:', error.message);
      return false;
    }
  }

  /**
   * Test inference functionality
   */
  async testInference() {
    console.log('🧠 Testing AI model inference...');

    try {
      const inferenceData = {
        modelId: 'climate-prediction-model',
        inputs: {
          temperature: 25.5,
          humidity: 65.2,
          pressure: 1013.25,
        },
        requestId: crypto.randomUUID(),
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/ai-ml/bittensor/inference`,
        inferenceData,
        { timeout: 60000 }
      );

      if (response.data.prediction) {
        console.log('✅ AI inference completed successfully');
        console.log(`🌤️  Prediction: ${response.data.prediction.weather}`);
        console.log(`📊 Confidence: ${response.data.prediction.confidence}%`);
        console.log(`⏱️  Processing Time: ${response.data.processingTime}ms`);
        this.testResults.inferenceTest = true;
        return true;
      }

      throw new Error('Inference failed');
    } catch (error) {
      console.error('❌ AI inference test failed:', error.message);
      return false;
    }
  }

  /**
   * Test reward distribution
   */
  async testRewardDistribution() {
    console.log('💰 Testing reward distribution...');

    try {
      // Simulate mining rewards for AI computation
      const rewardData = {
        hotkey: this.config.hotkey,
        performance: 0.95,
        computationTime: 1250,
        accuracyScore: 0.87,
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/ai-ml/bittensor/rewards`,
        rewardData,
        { timeout: 30000 }
      );

      if (response.data.rewardCalculated) {
        console.log('✅ Reward distribution calculated');
        console.log(`🏆 WRF Reward: ${response.data.wrfReward}`);
        console.log(`🥇 TAO Reward: ${response.data.taoReward}`);
        console.log(`📈 Performance Score: ${response.data.performanceScore}`);
        this.testResults.rewardDistribution = true;
        return true;
      }

      throw new Error('Reward calculation failed');
    } catch (error) {
      console.error('❌ Reward distribution test failed:', error.message);
      return false;
    }
  }

  /**
   * Test performance metrics
   */
  async testPerformanceMetrics() {
    console.log('📊 Testing performance metrics collection...');

    try {
      const response = await axios.get(
        `${this.config.wrfcoinNodeUrl}/api/ai-ml/bittensor/metrics/${this.config.hotkey}`,
        { timeout: 15000 }
      );

      if (response.data.metrics) {
        console.log('✅ Performance metrics collected');
        console.log(
          `🔥 Total Inferences: ${response.data.metrics.totalInferences}`
        );
        console.log(
          `⚡ Average Response Time: ${response.data.metrics.avgResponseTime}ms`
        );
        console.log(`🎯 Accuracy Rate: ${response.data.metrics.accuracyRate}%`);
        console.log(
          `💎 Reputation Score: ${response.data.metrics.reputationScore}`
        );
        this.testResults.performanceMetrics = true;
        return true;
      }

      throw new Error('Metrics collection failed');
    } catch (error) {
      console.error('❌ Performance metrics test failed:', error.message);
      return false;
    }
  }

  /**
   * Run complete Bittensor integration test suite
   */
  async runTests() {
    console.log('🚀 Starting Bittensor integration tests...\n');

    const tests = [
      { name: 'Network Connection', fn: () => this.testNetworkConnection() },
      { name: 'Model Registration', fn: () => this.testModelRegistration() },
      { name: 'Inference Test', fn: () => this.testInference() },
      { name: 'Reward Distribution', fn: () => this.testRewardDistribution() },
      { name: 'Performance Metrics', fn: () => this.testPerformanceMetrics() },
    ];

    let passed = 0;
    let failed = 0;

    for (const test of tests) {
      console.log(`\n📋 Running ${test.name}...`);

      try {
        const result = await test.fn();
        if (result) {
          passed++;
        } else {
          failed++;
        }
      } catch (error) {
        console.error(`❌ ${test.name} failed with error:`, error.message);
        failed++;
      }

      // Wait between tests to avoid overwhelming the system
      await new Promise(resolve => setTimeout(resolve, 2000));
    }

    // Print summary
    console.log('\n📊 Bittensor Integration Test Summary:');
    console.log(`✅ Passed: ${passed}`);
    console.log(`❌ Failed: ${failed}`);
    console.log(
      `📈 Success Rate: ${((passed / (passed + failed)) * 100).toFixed(1)}%`
    );

    // Additional metrics
    if (passed > 0) {
      console.log('\n🎯 Integration Capabilities:');
      if (this.testResults.networkConnection)
        console.log('  ✅ Network connectivity established');
      if (this.testResults.modelRegistration)
        console.log('  ✅ AI model deployment ready');
      if (this.testResults.inferenceTest)
        console.log('  ✅ Real-time inference operational');
      if (this.testResults.rewardDistribution)
        console.log('  ✅ Incentive mechanisms active');
      if (this.testResults.performanceMetrics)
        console.log('  ✅ Performance monitoring enabled');
    }

    return { passed, failed, results: this.testResults };
  }
}

// Run if called directly
if (require.main === module) {
  const bittensorTest = new BittensorTest();
  bittensorTest
    .runTests()
    .then(results => {
      process.exit(results.failed > 0 ? 1 : 0);
    })
    .catch(error => {
      console.error('💥 Bittensor test suite failed:', error);
      process.exit(1);
    });
}

module.exports = BittensorTest;
