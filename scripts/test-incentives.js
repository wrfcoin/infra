#!/usr/bin/env node

/**
 * Incentive Testing Script
 * Tests reward distribution and tokenomics mechanisms
 */

const axios = require('axios');
const crypto = require('crypto');

class IncentiveTest {
  constructor() {
    this.config = {
      wrfcoinNodeUrl: process.env.WRFCOIN_NODE_URL || 'http://localhost:3000',
      testWalletAddress: process.env.TEST_WALLET || 'test-wallet-001',
      rewardPoolSize: parseFloat(process.env.REWARD_POOL) || 1000000, // WRF tokens
      testDuration: parseInt(process.env.TEST_DURATION) || 60000, // ms
    };

    this.testResults = {
      rewardPoolSetup: false,
      stakingRewards: false,
      validationRewards: false,
      dataContributionRewards: false,
      governanceIncentives: false,
      slashingMechanisms: false,
      tokenDistribution: false,
    };
  }

  /**
   * Test reward pool setup and management
   */
  async testRewardPoolSetup() {
    console.log('🏦 Testing reward pool setup...');

    try {
      const poolConfig = {
        totalPool: this.config.rewardPoolSize,
        stakingAllocation: 0.4, // 40% for staking rewards
        validationAllocation: 0.25, // 25% for validation rewards
        dataAllocation: 0.2, // 20% for data contribution
        governanceAllocation: 0.1, // 10% for governance participation
        developmentAllocation: 0.05, // 5% for development fund
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/incentives/setup-pool`,
        poolConfig,
        { timeout: 20000 }
      );

      if (response.data.success) {
        console.log('✅ Reward pool setup successful');
        console.log(`💰 Total Pool: ${response.data.totalPool} WRF`);
        console.log(`📊 Staking Pool: ${response.data.stakingPool} WRF`);
        console.log(`🔍 Validation Pool: ${response.data.validationPool} WRF`);
        console.log(`📡 Data Pool: ${response.data.dataPool} WRF`);
        console.log(`🏛️  Governance Pool: ${response.data.governancePool} WRF`);

        this.poolId = response.data.poolId;
        this.testResults.rewardPoolSetup = true;
        return true;
      }

      throw new Error('Reward pool setup failed');
    } catch (error) {
      console.error('❌ Reward pool setup failed:', error.message);
      return false;
    }
  }

  /**
   * Test staking rewards calculation
   */
  async testStakingRewards() {
    console.log('🥩 Testing staking rewards...');

    try {
      const stakingScenarios = [
        { amount: 1000, duration: 30, lockPeriod: 'none' }, // 30 days, no lock
        { amount: 5000, duration: 90, lockPeriod: '3months' }, // 90 days, 3 month lock
        { amount: 10000, duration: 365, lockPeriod: '1year' }, // 1 year, 1 year lock
        { amount: 50000, duration: 730, lockPeriod: '2years' }, // 2 years, 2 year lock
      ];

      let totalRewards = 0;

      for (const scenario of stakingScenarios) {
        const response = await axios.post(
          `${this.config.wrfcoinNodeUrl}/api/incentives/calculate-staking`,
          {
            stakedAmount: scenario.amount,
            stakingDuration: scenario.duration,
            lockPeriod: scenario.lockPeriod,
            walletAddress: this.config.testWalletAddress,
          },
          { timeout: 15000 }
        );

        if (response.data.rewards) {
          const apr = (
            (response.data.rewards / scenario.amount) *
            (365 / scenario.duration) *
            100
          ).toFixed(2);
          console.log(
            `💎 ${scenario.amount} WRF (${scenario.duration}d, ${scenario.lockPeriod}): ${response.data.rewards} WRF reward (${apr}% APR)`
          );
          totalRewards += response.data.rewards;
        }
      }

      if (totalRewards > 0) {
        console.log(`✅ Staking rewards calculated: ${totalRewards} total WRF`);
        this.testResults.stakingRewards = true;
        return true;
      }

      throw new Error('No staking rewards calculated');
    } catch (error) {
      console.error('❌ Staking rewards test failed:', error.message);
      return false;
    }
  }

  /**
   * Test validation rewards
   */
  async testValidationRewards() {
    console.log('🔍 Testing validation rewards...');

    try {
      const validationData = {
        validatorAddress: this.config.testWalletAddress,
        blocksValidated: 150,
        uptime: 0.98,
        slashingEvents: 0,
        consensusParticipation: 0.95,
        networkContribution: 0.87,
        period: '24hours',
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/incentives/validation-rewards`,
        validationData,
        { timeout: 20000 }
      );

      if (response.data.totalReward) {
        console.log('✅ Validation rewards calculated');
        console.log(`🏆 Base Reward: ${response.data.baseReward} WRF`);
        console.log(`⏰ Uptime Bonus: ${response.data.uptimeBonus} WRF`);
        console.log(`🤝 Consensus Bonus: ${response.data.consensusBonus} WRF`);
        console.log(`🌐 Network Bonus: ${response.data.networkBonus} WRF`);
        console.log(`💰 Total Reward: ${response.data.totalReward} WRF`);
        console.log(`📈 Effective APY: ${response.data.effectiveAPY}%`);

        this.testResults.validationRewards = true;
        return true;
      }

      throw new Error('Validation rewards calculation failed');
    } catch (error) {
      console.error('❌ Validation rewards test failed:', error.message);
      return false;
    }
  }

  /**
   * Test data contribution rewards
   */
  async testDataContributionRewards() {
    console.log('📡 Testing data contribution rewards...');

    try {
      const contributionData = {
        contributorAddress: this.config.testWalletAddress,
        dataSubmissions: [
          { type: 'weather', quality: 0.95, uniqueness: 0.87, size: 1024 },
          {
            type: 'environmental',
            quality: 0.91,
            uniqueness: 0.92,
            size: 2048,
          },
          { type: 'climate', quality: 0.88, uniqueness: 0.76, size: 512 },
        ],
        validationScore: 0.93,
        period: '7days',
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/incentives/data-contribution`,
        contributionData,
        { timeout: 25000 }
      );

      if (response.data.totalReward) {
        console.log('✅ Data contribution rewards calculated');
        console.log(`📊 Quality Score: ${response.data.qualityScore}/1.0`);
        console.log(
          `🔍 Uniqueness Score: ${response.data.uniquenessScore}/1.0`
        );
        console.log(`📏 Volume Bonus: ${response.data.volumeBonus} WRF`);
        console.log(
          `✅ Validation Bonus: ${response.data.validationBonus} WRF`
        );
        console.log(`💎 Total Reward: ${response.data.totalReward} WRF`);

        this.testResults.dataContributionRewards = true;
        return true;
      }

      throw new Error('Data contribution rewards failed');
    } catch (error) {
      console.error('❌ Data contribution rewards test failed:', error.message);
      return false;
    }
  }

  /**
   * Test governance incentives
   */
  async testGovernanceIncentives() {
    console.log('🏛️ Testing governance incentives...');

    try {
      const governanceData = {
        participantAddress: this.config.testWalletAddress,
        proposalsCreated: 3,
        votesParticipated: 25,
        delegationsReceived: 15000, // WRF delegated to this address
        discussionContributions: 12,
        period: '1month',
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/incentives/governance-participation`,
        governanceData,
        { timeout: 20000 }
      );

      if (response.data.totalIncentive) {
        console.log('✅ Governance incentives calculated');
        console.log(`📝 Proposal Bonus: ${response.data.proposalBonus} WRF`);
        console.log(`🗳️  Voting Reward: ${response.data.votingReward} WRF`);
        console.log(
          `👥 Delegation Bonus: ${response.data.delegationBonus} WRF`
        );
        console.log(
          `💬 Discussion Reward: ${response.data.discussionReward} WRF`
        );
        console.log(
          `🏆 Leadership Bonus: ${response.data.leadershipBonus} WRF`
        );
        console.log(`💰 Total Incentive: ${response.data.totalIncentive} WRF`);

        this.testResults.governanceIncentives = true;
        return true;
      }

      throw new Error('Governance incentives calculation failed');
    } catch (error) {
      console.error('❌ Governance incentives test failed:', error.message);
      return false;
    }
  }

  /**
   * Test slashing mechanisms
   */
  async testSlashingMechanisms() {
    console.log('⚔️ Testing slashing mechanisms...');

    try {
      const slashingScenarios = [
        {
          name: 'Validation Failure',
          data: {
            validatorAddress: this.config.testWalletAddress,
            infraction: 'invalid_block_signature',
            severity: 'medium',
            stakedAmount: 10000,
          },
        },
        {
          name: 'Network Downtime',
          data: {
            validatorAddress: this.config.testWalletAddress,
            infraction: 'excessive_downtime',
            severity: 'low',
            downtimePercent: 15.5,
          },
        },
        {
          name: 'Malicious Behavior',
          data: {
            validatorAddress: this.config.testWalletAddress,
            infraction: 'double_signing',
            severity: 'high',
            evidenceHash: crypto.randomBytes(32).toString('hex'),
          },
        },
      ];

      let totalSlashed = 0;

      for (const scenario of slashingScenarios) {
        const response = await axios.post(
          `${this.config.wrfcoinNodeUrl}/api/incentives/calculate-slashing`,
          scenario.data,
          { timeout: 15000 }
        );

        if (response.data.slashAmount !== undefined) {
          console.log(
            `⚔️ ${scenario.name}: ${response.data.slashAmount} WRF slashed (${response.data.slashPercent}%)`
          );
          totalSlashed += response.data.slashAmount;
        }
      }

      console.log(
        `✅ Slashing mechanisms validated: ${totalSlashed} total WRF slashed`
      );
      this.testResults.slashingMechanisms = true;
      return true;
    } catch (error) {
      console.error('❌ Slashing mechanisms test failed:', error.message);
      return false;
    }
  }

  /**
   * Test token distribution mechanics
   */
  async testTokenDistribution() {
    console.log('🪙 Testing token distribution...');

    try {
      const distributionData = {
        epoch: Date.now(),
        totalRewards: 50000,
        participants: [
          {
            address: 'validator_001',
            type: 'validator',
            performance: 0.95,
            stake: 100000,
          },
          {
            address: 'data_contrib_001',
            type: 'data_contributor',
            performance: 0.87,
            stake: 25000,
          },
          {
            address: 'staker_001',
            type: 'staker',
            performance: 1.0,
            stake: 75000,
          },
          {
            address: 'governance_001',
            type: 'governance',
            performance: 0.92,
            stake: 50000,
          },
        ],
      };

      const response = await axios.post(
        `${this.config.wrfcoinNodeUrl}/api/incentives/distribute-rewards`,
        distributionData,
        { timeout: 30000 }
      );

      if (response.data.distributionComplete) {
        console.log('✅ Token distribution completed');
        console.log(
          `💰 Total Distributed: ${response.data.totalDistributed} WRF`
        );
        console.log(`👥 Participants: ${response.data.participantCount}`);

        // Show individual distributions
        for (const participant of response.data.distributions) {
          console.log(
            `  💎 ${participant.address}: ${participant.reward} WRF (${participant.type})`
          );
        }

        console.log(`🏦 Remaining Pool: ${response.data.remainingPool} WRF`);
        console.log(`📊 Distribution Efficiency: ${response.data.efficiency}%`);

        this.testResults.tokenDistribution = true;
        return true;
      }

      throw new Error('Token distribution failed');
    } catch (error) {
      console.error('❌ Token distribution test failed:', error.message);
      return false;
    }
  }

  /**
   * Run complete incentive test suite
   */
  async runTests() {
    console.log('🚀 Starting incentive mechanism tests...\n');

    const tests = [
      { name: 'Reward Pool Setup', fn: () => this.testRewardPoolSetup() },
      { name: 'Staking Rewards', fn: () => this.testStakingRewards() },
      { name: 'Validation Rewards', fn: () => this.testValidationRewards() },
      {
        name: 'Data Contribution Rewards',
        fn: () => this.testDataContributionRewards(),
      },
      {
        name: 'Governance Incentives',
        fn: () => this.testGovernanceIncentives(),
      },
      { name: 'Slashing Mechanisms', fn: () => this.testSlashingMechanisms() },
      { name: 'Token Distribution', fn: () => this.testTokenDistribution() },
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
      await new Promise(resolve => setTimeout(resolve, 2000));
    }

    // Print summary
    console.log('\n📊 Incentive Test Summary:');
    console.log(`✅ Passed: ${passed}`);
    console.log(`❌ Failed: ${failed}`);
    console.log(
      `📈 Success Rate: ${((passed / (passed + failed)) * 100).toFixed(1)}%`
    );

    // Economic model summary
    if (passed > 0) {
      console.log('\n🎯 Economic Model Capabilities:');
      if (this.testResults.rewardPoolSetup)
        console.log('  ✅ Systematic reward pool management');
      if (this.testResults.stakingRewards)
        console.log('  ✅ Time-based staking incentives');
      if (this.testResults.validationRewards)
        console.log('  ✅ Performance-based validation rewards');
      if (this.testResults.dataContributionRewards)
        console.log('  ✅ Quality-driven data incentives');
      if (this.testResults.governanceIncentives)
        console.log('  ✅ Participation-based governance rewards');
      if (this.testResults.slashingMechanisms)
        console.log('  ✅ Behavioral correction mechanisms');
      if (this.testResults.tokenDistribution)
        console.log('  ✅ Automated fair distribution');
    }

    return { passed, failed, results: this.testResults };
  }
}

// Run if called directly
if (require.main === module) {
  const incentiveTest = new IncentiveTest();
  incentiveTest
    .runTests()
    .then(results => {
      process.exit(results.failed > 0 ? 1 : 0);
    })
    .catch(error => {
      console.error('💥 Incentive test suite failed:', error);
      process.exit(1);
    });
}

module.exports = IncentiveTest;
