#!/usr/bin/env node

/**
 * Proof of Presence (PoP) Test
 * Tests location verification and presence validation functionality
 */

const axios = require('axios');
const crypto = require('crypto');

class ProofOfPresenceTest {
  constructor() {
    this.config = {
      wrfcoinNodeUrl: process.env.WRFCOIN_NODE_URL || 'http://localhost:3000',
      testLatitude: parseFloat(process.env.TEST_LATITUDE) || 40.7128,
      testLongitude: parseFloat(process.env.TEST_LONGITUDE) || -74.006,
      accuracyThreshold: parseFloat(process.env.ACCURACY_THRESHOLD) || 100, // meters
      verificationTimeout: parseInt(process.env.VERIFICATION_TIMEOUT) || 30000, // ms
    };

    this.testResults = {
      deviceRegistration: false,
      locationProof: false,
      timestampVerification: false,
      fraudDetection: false,
      consensusValidation: false,
      rewardCalculation: false,
    };
  }

  /**
   * Test device registration for PoP
   */
  async testDeviceRegistration() {
    console.log('📱 Testing device registration...');

    try {
      const deviceInfo = {
        deviceId: crypto.randomUUID(),
        deviceType: 'mobile',
        os: 'test-os',
        appVersion: '1.0.0',
        publicKey: crypto.randomBytes(32).toString('hex'),
        capabilities: ['gps', 'cellular', 'wifi'],
        registrationTime: Date.now(),
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/pop/register-device`,
        deviceInfo,
        { timeout: this.config.verificationTimeout }
      );

      if (response.data.success) {
        console.log('✅ Device registered successfully');
        console.log(`🆔 Device ID: ${response.data.deviceId}`);
        console.log(`🔐 Registration Hash: ${response.data.registrationHash}`);
        console.log(
          `⏰ Valid Until: ${new Date(response.data.validUntil).toISOString()}`
        );

        this.registeredDeviceId = response.data.deviceId;
        this.testResults.deviceRegistration = true;
        return true;
      }

      throw new Error('Device registration failed');
    } catch (error) {
      console.error('❌ Device registration failed:', error.message);
      return false;
    }
  }

  /**
   * Test location proof generation
   */
  async testLocationProof() {
    console.log('📍 Testing location proof generation...');

    if (!this.registeredDeviceId) {
      console.error('❌ No registered device for location proof test');
      return false;
    }

    try {
      // Generate location proof with multiple verification methods
      const proofData = {
        deviceId: this.registeredDeviceId,
        location: {
          latitude: this.config.testLatitude,
          longitude: this.config.testLongitude,
          accuracy: 15.5, // meters
          altitude: 10.2,
          speed: 0,
          bearing: null,
        },
        timestamp: Date.now(),
        verificationMethods: [
          {
            type: 'gps',
            satellites: 8,
            hdop: 1.2,
            signal_strength: -120,
          },
          {
            type: 'cellular',
            towers: [
              { id: 'tower_001', signal: -85, distance: 250 },
              { id: 'tower_002', signal: -92, distance: 450 },
            ],
          },
          {
            type: 'wifi',
            networks: [
              { bssid: 'aa:bb:cc:dd:ee:ff', signal: -45 },
              { bssid: '11:22:33:44:55:66', signal: -67 },
            ],
          },
        ],
        nonce: crypto.randomBytes(16).toString('hex'),
      };

      // Sign the proof data
      const proofHash = crypto
        .createHash('sha256')
        .update(JSON.stringify(proofData))
        .digest('hex');

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/pop/submit-proof`,
        {
          ...proofData,
          proofHash: proofHash,
          signature: crypto.randomBytes(64).toString('hex'), // Simulated signature
        },
        { timeout: this.config.verificationTimeout }
      );

      if (response.data.verified) {
        console.log('✅ Location proof generated and verified');
        console.log(
          `📍 Location: ${proofData.location.latitude}, ${proofData.location.longitude}`
        );
        console.log(`🎯 Accuracy: ${proofData.location.accuracy}m`);
        console.log(`🔗 Proof Hash: ${proofHash}`);
        console.log(`⭐ Confidence Score: ${response.data.confidenceScore}%`);

        this.proofHash = proofHash;
        this.testResults.locationProof = true;
        return true;
      }

      throw new Error('Location proof verification failed');
    } catch (error) {
      console.error('❌ Location proof test failed:', error.message);
      return false;
    }
  }

  /**
   * Test timestamp verification
   */
  async testTimestampVerification() {
    console.log('⏰ Testing timestamp verification...');

    try {
      const timestamps = [
        Date.now() - 1000, // 1 second ago
        Date.now(), // now
        Date.now() + 1000, // 1 second future
        Date.now() + 300000, // 5 minutes future (should fail)
      ];

      let validCount = 0;

      for (const timestamp of timestamps) {
        const response = await axios.post(
          `${this.config.wrfcoinNodeUrl}/api/pop/verify-timestamp`,
          {
            timestamp: timestamp,
            tolerance: 60000, // 1 minute tolerance
          },
          { timeout: 10000 }
        );

        if (response.data.valid) {
          validCount++;
          console.log(
            `✅ Timestamp ${new Date(timestamp).toISOString()} is valid`
          );
        } else {
          console.log(
            `❌ Timestamp ${new Date(timestamp).toISOString()} is invalid: ${response.data.reason}`
          );
        }
      }

      if (validCount >= 2) {
        // At least 2 valid timestamps expected
        console.log('✅ Timestamp verification working correctly');
        this.testResults.timestampVerification = true;
        return true;
      }

      throw new Error('Insufficient valid timestamps');
    } catch (error) {
      console.error('❌ Timestamp verification failed:', error.message);
      return false;
    }
  }

  /**
   * Test fraud detection mechanisms
   */
  async testFraudDetection() {
    console.log('🕵️ Testing fraud detection...');

    try {
      // Test various fraud scenarios
      const fraudTests = [
        {
          name: 'Impossible Speed',
          data: {
            previousLocation: {
              lat: 40.7128,
              lon: -74.006,
              time: Date.now() - 60000,
            },
            currentLocation: { lat: 34.0522, lon: -118.2437, time: Date.now() },
          },
        },
        {
          name: 'Duplicate Proof',
          data: {
            proofHash: this.proofHash || 'duplicate-hash-test',
            timestamp: Date.now(),
          },
        },
        {
          name: 'Invalid Signature',
          data: {
            deviceId: this.registeredDeviceId,
            signature: 'invalid-signature-data',
          },
        },
      ];

      let detectedCount = 0;

      for (const test of fraudTests) {
        const response = await axios.post(
          `${this.config.wrfcoinNodeUrl}/api/pop/detect-fraud`,
          test.data,
          { timeout: 15000 }
        );

        if (response.data.fraudDetected) {
          detectedCount++;
          console.log(
            `✅ ${test.name}: Fraud detected - ${response.data.reason}`
          );
        } else {
          console.log(`⚠️  ${test.name}: No fraud detected (unexpected)`);
        }
      }

      if (detectedCount >= 2) {
        console.log('✅ Fraud detection mechanisms working properly');
        this.testResults.fraudDetection = true;
        return true;
      }

      throw new Error('Fraud detection insufficient');
    } catch (error) {
      console.error('❌ Fraud detection test failed:', error.message);
      return false;
    }
  }

  /**
   * Test consensus validation
   */
  async testConsensusValidation() {
    console.log('🤝 Testing consensus validation...');

    try {
      const consensusData = {
        proofHash: this.proofHash || 'consensus-test-hash',
        validators: [
          { id: 'validator_1', vote: 'valid', confidence: 0.95 },
          { id: 'validator_2', vote: 'valid', confidence: 0.87 },
          { id: 'validator_3', vote: 'invalid', confidence: 0.72 },
          { id: 'validator_4', vote: 'valid', confidence: 0.91 },
        ],
        consensusThreshold: 0.75,
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/pop/consensus-validation`,
        consensusData,
        { timeout: 20000 }
      );

      if (response.data.consensusReached) {
        console.log('✅ Consensus validation completed');
        console.log(`🗳️  Validators: ${response.data.totalValidators}`);
        console.log(`✅ Valid Votes: ${response.data.validVotes}`);
        console.log(`❌ Invalid Votes: ${response.data.invalidVotes}`);
        console.log(`📊 Consensus Score: ${response.data.consensusScore}%`);
        console.log(`🏆 Final Decision: ${response.data.finalDecision}`);

        this.testResults.consensusValidation = true;
        return true;
      }

      throw new Error('Consensus not reached');
    } catch (error) {
      console.error('❌ Consensus validation failed:', error.message);
      return false;
    }
  }

  /**
   * Test reward calculation for PoP
   */
  async testRewardCalculation() {
    console.log('💰 Testing PoP reward calculation...');

    try {
      const rewardData = {
        deviceId: this.registeredDeviceId,
        validProofs: 15,
        fraudulentProofs: 0,
        consensusParticipation: 12,
        accuracyScore: 0.94,
        stakeDuration: 7200000, // 2 hours in milliseconds
        locationDifficulty: 'urban', // urban, suburban, rural
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/pop/calculate-rewards`,
        rewardData,
        { timeout: 15000 }
      );

      if (response.data.totalReward) {
        console.log('✅ PoP rewards calculated successfully');
        console.log(`🪙 Base Reward: ${response.data.baseReward} WRF`);
        console.log(`🎯 Accuracy Bonus: ${response.data.accuracyBonus} WRF`);
        console.log(`🤝 Consensus Bonus: ${response.data.consensusBonus} WRF`);
        console.log(`📍 Location Bonus: ${response.data.locationBonus} WRF`);
        console.log(`💎 Total Reward: ${response.data.totalReward} WRF`);
        console.log(`📈 APY Estimate: ${response.data.apyEstimate}%`);

        this.testResults.rewardCalculation = true;
        return true;
      }

      throw new Error('Reward calculation failed');
    } catch (error) {
      console.error('❌ Reward calculation failed:', error.message);
      return false;
    }
  }

  /**
   * Run complete Proof of Presence test suite
   */
  async runTests() {
    console.log('🚀 Starting Proof of Presence tests...\n');

    const tests = [
      { name: 'Device Registration', fn: () => this.testDeviceRegistration() },
      { name: 'Location Proof', fn: () => this.testLocationProof() },
      {
        name: 'Timestamp Verification',
        fn: () => this.testTimestampVerification(),
      },
      { name: 'Fraud Detection', fn: () => this.testFraudDetection() },
      {
        name: 'Consensus Validation',
        fn: () => this.testConsensusValidation(),
      },
      { name: 'Reward Calculation', fn: () => this.testRewardCalculation() },
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
      await new Promise(resolve => setTimeout(resolve, 1500));
    }

    // Print summary
    console.log('\n📊 Proof of Presence Test Summary:');
    console.log(`✅ Passed: ${passed}`);
    console.log(`❌ Failed: ${failed}`);
    console.log(
      `📈 Success Rate: ${((passed / (passed + failed)) * 100).toFixed(1)}%`
    );

    // PoP capabilities summary
    if (passed > 0) {
      console.log('\n🎯 PoP Capabilities:');
      if (this.testResults.deviceRegistration)
        console.log('  ✅ Device identity management');
      if (this.testResults.locationProof)
        console.log('  ✅ Multi-method location verification');
      if (this.testResults.timestampVerification)
        console.log('  ✅ Temporal validation');
      if (this.testResults.fraudDetection)
        console.log('  ✅ Anti-fraud mechanisms');
      if (this.testResults.consensusValidation)
        console.log('  ✅ Decentralized validation');
      if (this.testResults.rewardCalculation)
        console.log('  ✅ Performance-based rewards');
    }

    return { passed, failed, results: this.testResults };
  }
}

// Run if called directly
if (require.main === module) {
  const popTest = new ProofOfPresenceTest();
  popTest
    .runTests()
    .then(results => {
      process.exit(results.failed > 0 ? 1 : 0);
    })
    .catch(error => {
      console.error('💥 PoP test suite failed:', error);
      process.exit(1);
    });
}

module.exports = ProofOfPresenceTest;
