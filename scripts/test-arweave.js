#!/usr/bin/env node

/**
 * Arweave Integration Test
 * Tests permanent data storage functionality with Arweave network
 */

const axios = require('axios');
const crypto = require('crypto');

class ArweaveTest {
  constructor() {
    this.config = {
      arweaveUrl: process.env.ARWEAVE_URL || 'https://arweave.net',
      wrfcoinNodeUrl: process.env.WRFCOIN_NODE_URL || 'http://localhost:3000',
      walletPath: process.env.ARWEAVE_WALLET || './arweave-wallet.json',
      testDataSize: parseInt(process.env.TEST_DATA_SIZE) || 1024, // bytes
    };

    this.testResults = {
      networkConnection: false,
      walletValidation: false,
      dataUpload: false,
      dataRetrieval: false,
      permanentStorage: false,
      costCalculation: false,
    };
  }

  /**
   * Test Arweave network connection
   */
  async testNetworkConnection() {
    console.log('🔗 Testing Arweave network connection...');

    try {
      const response = await axios.get(`${this.config.arweaveUrl}/info`, {
        timeout: 10000,
      });

      if (response.data.network) {
        console.log('✅ Arweave network connection established');
        console.log(`🌐 Network: ${response.data.network}`);
        console.log(`📦 Current Block: ${response.data.current}`);
        console.log(`📏 Block Height: ${response.data.height}`);
        this.testResults.networkConnection = true;
        return true;
      }

      throw new Error('Invalid network response');
    } catch (error) {
      console.error('❌ Arweave network connection failed:', error.message);
      return false;
    }
  }

  /**
   * Test wallet validation
   */
  async testWalletValidation() {
    console.log('👛 Testing Arweave wallet validation...');

    try {
      // Simulate wallet validation through Wrfcoin storage service
      const response = await axios.get(
        `${this.config.wrfcoinNodeUrl}/api/storage/arweave/wallet/validate`,
        { timeout: 15000 }
      );

      if (response.data.valid) {
        console.log('✅ Arweave wallet validated');
        console.log(`📍 Wallet Address: ${response.data.address}`);
        console.log(`💰 Balance: ${response.data.balance} AR`);
        console.log(`🔑 Key Type: ${response.data.keyType}`);
        this.testResults.walletValidation = true;
        return true;
      }

      throw new Error('Wallet validation failed');
    } catch (error) {
      console.error('❌ Arweave wallet validation failed:', error.message);
      return false;
    }
  }

  /**
   * Test data upload to Arweave
   */
  async testDataUpload() {
    console.log('📤 Testing data upload to Arweave...');

    try {
      // Generate test climate data
      const testData = {
        type: 'climate-data',
        timestamp: Date.now(),
        stationId: 'test-station-001',
        measurements: {
          temperature: 22.5,
          humidity: 58.3,
          pressure: 1015.2,
          windSpeed: 12.8,
          windDirection: 'NW',
        },
        metadata: {
          source: 'wrfcoin-test',
          quality: 'high',
          verified: true,
        },
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/storage/arweave/upload`,
        {
          data: JSON.stringify(testData),
          tags: [
            { name: 'Content-Type', value: 'application/json' },
            { name: 'App-Name', value: 'Wrfcoin' },
            { name: 'Data-Type', value: 'climate-measurement' },
            { name: 'Version', value: '1.0' },
          ],
        },
        { timeout: 60000 }
      );

      if (response.data.transactionId) {
        console.log('✅ Data uploaded to Arweave successfully');
        console.log(`🔗 Transaction ID: ${response.data.transactionId}`);
        console.log(`💾 Data Size: ${response.data.dataSize} bytes`);
        console.log(`💰 Cost: ${response.data.cost} AR`);

        // Store transaction ID for retrieval test
        this.uploadedTxId = response.data.transactionId;
        this.testResults.dataUpload = true;
        return true;
      }

      throw new Error('Upload failed');
    } catch (error) {
      console.error('❌ Data upload test failed:', error.message);
      return false;
    }
  }

  /**
   * Test data retrieval from Arweave
   */
  async testDataRetrieval() {
    console.log('📥 Testing data retrieval from Arweave...');

    if (!this.uploadedTxId) {
      console.error(
        '❌ No uploaded transaction ID available for retrieval test'
      );
      return false;
    }

    try {
      // Wait for data to be mined (in real scenario, this could take longer)
      console.log('⏳ Waiting for data to be mined...');
      await new Promise(resolve => setTimeout(resolve, 5000));

      const response = await axios.get(
        `${this.config.wrfcoinNodeUrl}/api/storage/arweave/retrieve/${this.uploadedTxId}`,
        { timeout: 30000 }
      );

      if (response.data.data) {
        console.log('✅ Data retrieved from Arweave successfully');

        const retrievedData = JSON.parse(response.data.data);
        console.log(`📊 Data Type: ${retrievedData.type}`);
        console.log(
          `🌡️  Temperature: ${retrievedData.measurements.temperature}°C`
        );
        console.log(`💧 Humidity: ${retrievedData.measurements.humidity}%`);
        console.log(
          `⏰ Timestamp: ${new Date(retrievedData.timestamp).toISOString()}`
        );

        this.testResults.dataRetrieval = true;
        return true;
      }

      throw new Error('Data retrieval failed');
    } catch (error) {
      console.error('❌ Data retrieval test failed:', error.message);
      return false;
    }
  }

  /**
   * Test permanent storage verification
   */
  async testPermanentStorage() {
    console.log('🔒 Testing permanent storage verification...');

    try {
      const response = await axios.get(
        `${this.config.wrfcoinNodeUrl}/api/storage/arweave/verify-permanence`,
        { timeout: 20000 }
      );

      if (response.data.permanent) {
        console.log('✅ Permanent storage verified');
        console.log(`📊 Storage Guarantee: ${response.data.guarantee} years`);
        console.log(
          `🔐 Immutability: ${response.data.immutable ? 'Confirmed' : 'Not confirmed'}`
        );
        console.log(
          `🌐 Global Accessibility: ${response.data.globallyAccessible ? 'Yes' : 'No'}`
        );
        this.testResults.permanentStorage = true;
        return true;
      }

      throw new Error('Permanent storage not verified');
    } catch (error) {
      console.error('❌ Permanent storage verification failed:', error.message);
      return false;
    }
  }

  /**
   * Test storage cost calculation
   */
  async testCostCalculation() {
    console.log('💰 Testing storage cost calculation...');

    try {
      const testSizes = [1024, 10240, 102400, 1048576]; // 1KB, 10KB, 100KB, 1MB

      for (const size of testSizes) {
        const response = await axios.post(
          `${this.config.wrfcoinNodeUrl}/api/storage/arweave/calculate-cost`,
          { dataSize: size },
          { timeout: 10000 }
        );

        if (response.data.cost) {
          console.log(
            `💾 ${this.formatBytes(size)}: ${response.data.cost} AR (≈ $${response.data.usdCost})`
          );
        }
      }

      console.log('✅ Storage cost calculation completed');
      this.testResults.costCalculation = true;
      return true;
    } catch (error) {
      console.error('❌ Cost calculation test failed:', error.message);
      return false;
    }
  }

  /**
   * Format bytes to human readable string
   */
  formatBytes(bytes) {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  /**
   * Run complete Arweave integration test suite
   */
  async runTests() {
    console.log('🚀 Starting Arweave integration tests...\n');

    const tests = [
      { name: 'Network Connection', fn: () => this.testNetworkConnection() },
      { name: 'Wallet Validation', fn: () => this.testWalletValidation() },
      { name: 'Data Upload', fn: () => this.testDataUpload() },
      { name: 'Data Retrieval', fn: () => this.testDataRetrieval() },
      { name: 'Permanent Storage', fn: () => this.testPermanentStorage() },
      { name: 'Cost Calculation', fn: () => this.testCostCalculation() },
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

      // Wait between tests
      await new Promise(resolve => setTimeout(resolve, 1000));
    }

    // Print summary
    console.log('\n📊 Arweave Integration Test Summary:');
    console.log(`✅ Passed: ${passed}`);
    console.log(`❌ Failed: ${failed}`);
    console.log(
      `📈 Success Rate: ${((passed / (passed + failed)) * 100).toFixed(1)}%`
    );

    // Storage capabilities summary
    if (passed > 0) {
      console.log('\n🎯 Storage Capabilities:');
      if (this.testResults.networkConnection)
        console.log('  ✅ Arweave network connectivity');
      if (this.testResults.dataUpload)
        console.log('  ✅ Permanent data storage');
      if (this.testResults.dataRetrieval)
        console.log('  ✅ Global data accessibility');
      if (this.testResults.permanentStorage)
        console.log('  ✅ Immutable storage guarantee');
      if (this.testResults.costCalculation)
        console.log('  ✅ Predictable storage costs');
    }

    return { passed, failed, results: this.testResults };
  }
}

// Run if called directly
if (require.main === module) {
  const arweaveTest = new ArweaveTest();
  arweaveTest
    .runTests()
    .then(results => {
      process.exit(results.failed > 0 ? 1 : 0);
    })
    .catch(error => {
      console.error('💥 Arweave test suite failed:', error);
      process.exit(1);
    });
}

module.exports = ArweaveTest;
