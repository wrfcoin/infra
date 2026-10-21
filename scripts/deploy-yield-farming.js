const { ethers } = require('hardhat');

async function main() {
  console.log('🌱 Deploying Carbon Credit Yield Farming Infrastructure...');

  const [deployer, feeRecipient] = await ethers.getSigners();
  console.log('Deploying with account:', deployer.address);
  console.log(
    'Account balance:',
    (await deployer.provider.getBalance(deployer.address)).toString()
  );

  // Deployment configuration
  const config = {
    // Existing contract addresses (should be updated with actual deployed addresses)
    usdcAddress:
      process.env.USDC_ADDRESS || '0x0000000000000000000000000000000000000000',
    wrfTokenAddress:
      process.env.WRF_TOKEN_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    poolManagerAddress:
      process.env.POOL_MANAGER_ADDRESS ||
      '0x0000000000000000000000000000000000000000',
    qualityOracleAddress:
      process.env.QUALITY_ORACLE_ADDRESS ||
      '0x0000000000000000000000000000000000000000',

    // Yield farming configuration
    initialRewardRate: ethers.parseEther('1'), // 1 WRF per second
    totalAllocation: ethers.parseEther('10000000'), // 10M WRF tokens
    vestingDuration: 7 * 24 * 60 * 60, // 7 days
    earlyVestingFee: 2000, // 20%

    // Governance configuration
    votingDelay: 7200, // ~1 day
    votingPeriod: 50400, // ~7 days
    proposalThreshold: ethers.parseEther('10000'), // 10,000 WRF
    quorum: 20, // 20%
  };

  try {
    // ==================== DEPLOY REWARD DISTRIBUTOR ====================
    console.log('\n📦 Deploying RewardDistributor...');
    const RewardDistributor =
      await ethers.getContractFactory('RewardDistributor');
    const rewardDistributor = await RewardDistributor.deploy(
      feeRecipient.address,
      config.qualityOracleAddress
    );
    await rewardDistributor.waitForDeployment();
    console.log(
      '✅ RewardDistributor deployed to:',
      await rewardDistributor.getAddress()
    );

    // ==================== DEPLOY FARMING POOL IMPLEMENTATION ====================
    console.log('\n📦 Deploying CarbonFarmingPool implementation...');
    const CarbonFarmingPool =
      await ethers.getContractFactory('CarbonFarmingPool');
    const farmImplementation = await CarbonFarmingPool.deploy();
    await farmImplementation.waitForDeployment();
    console.log(
      '✅ CarbonFarmingPool implementation deployed to:',
      await farmImplementation.getAddress()
    );

    // ==================== DEPLOY YIELD FARMING MANAGER ====================
    console.log('\n📦 Deploying YieldFarmingManager...');
    const YieldFarmingManager = await ethers.getContractFactory(
      'YieldFarmingManager'
    );
    const yieldFarmingManager = await YieldFarmingManager.deploy(
      config.poolManagerAddress,
      config.wrfTokenAddress,
      await farmImplementation.getAddress(),
      await rewardDistributor.getAddress()
    );
    await yieldFarmingManager.waitForDeployment();
    console.log(
      '✅ YieldFarmingManager deployed to:',
      await yieldFarmingManager.getAddress()
    );

    // ==================== DEPLOY GOVERNANCE ====================
    console.log('\n📦 Deploying YieldFarmingGovernance...');
    const YieldFarmingGovernance = await ethers.getContractFactory(
      'YieldFarmingGovernance'
    );
    const governance = await YieldFarmingGovernance.deploy(
      await yieldFarmingManager.getAddress(),
      await rewardDistributor.getAddress(),
      config.wrfTokenAddress
    );
    await governance.waitForDeployment();
    console.log(
      '✅ YieldFarmingGovernance deployed to:',
      await governance.getAddress()
    );

    // ==================== SETUP PERMISSIONS ====================
    console.log('\n🔐 Setting up permissions...');

    // Grant distributor role to yield farming manager
    const DISTRIBUTOR_ROLE = await rewardDistributor.DISTRIBUTOR_ROLE();
    await rewardDistributor.grantRole(
      DISTRIBUTOR_ROLE,
      await yieldFarmingManager.getAddress()
    );
    console.log('✅ Granted DISTRIBUTOR_ROLE to YieldFarmingManager');

    // Grant management roles to governance
    const REWARD_MANAGER_ROLE = await yieldFarmingManager.REWARD_MANAGER_ROLE();
    const FARM_MANAGER_ROLE = await yieldFarmingManager.FARM_MANAGER_ROLE();
    await yieldFarmingManager.grantRole(
      REWARD_MANAGER_ROLE,
      await governance.getAddress()
    );
    await yieldFarmingManager.grantRole(
      FARM_MANAGER_ROLE,
      await governance.getAddress()
    );
    console.log('✅ Granted management roles to Governance');

    // ==================== CONFIGURE REWARD TOKENS ====================
    console.log('\n⚙️ Configuring reward tokens...');

    await rewardDistributor.configureRewardToken(
      config.wrfTokenAddress,
      config.totalAllocation,
      config.initialRewardRate,
      config.vestingDuration,
      'governance'
    );
    console.log('✅ Configured WRF as governance reward token');

    // ==================== SETUP ORACLES ====================
    console.log('\n🔮 Setting up oracles...');

    if (
      config.qualityOracleAddress !==
      '0x0000000000000000000000000000000000000000'
    ) {
      await yieldFarmingManager.setQualityOracle(config.qualityOracleAddress);
      console.log('✅ Set quality oracle in YieldFarmingManager');
    }

    // ==================== DEPLOYMENT SUMMARY ====================
    console.log('\n🎉 Deployment completed successfully!');
    console.log('\n📋 CONTRACT ADDRESSES:');
    console.log('==========================================');
    console.log(
      'RewardDistributor:      ',
      await rewardDistributor.getAddress()
    );
    console.log(
      'CarbonFarmingPool (impl):',
      await farmImplementation.getAddress()
    );
    console.log(
      'YieldFarmingManager:    ',
      await yieldFarmingManager.getAddress()
    );
    console.log('YieldFarmingGovernance: ', await governance.getAddress());
    console.log('==========================================');

    // ==================== CONFIGURATION SUMMARY ====================
    console.log('\n⚙️ CONFIGURATION:');
    console.log('==========================================');
    console.log(
      'Initial Reward Rate:    ',
      ethers.formatEther(config.initialRewardRate),
      'WRF/second'
    );
    console.log(
      'Total Allocation:       ',
      ethers.formatEther(config.totalAllocation),
      'WRF'
    );
    console.log(
      'Vesting Duration:       ',
      config.vestingDuration / (24 * 60 * 60),
      'days'
    );
    console.log('Early Vesting Fee:      ', config.earlyVestingFee / 100, '%');
    console.log('Governance Quorum:      ', config.quorum, '%');
    console.log(
      'Proposal Threshold:     ',
      ethers.formatEther(config.proposalThreshold),
      'WRF'
    );
    console.log('==========================================');

    // ==================== VERIFICATION INFO ====================
    console.log('\n🔍 CONTRACT VERIFICATION:');
    console.log('==========================================');
    console.log('To verify contracts on Etherscan, run:');
    console.log(
      `npx hardhat verify --network <network> ${await rewardDistributor.getAddress()} "${feeRecipient.address}" "${config.qualityOracleAddress}"`
    );
    console.log(
      `npx hardhat verify --network <network> ${await farmImplementation.getAddress()}`
    );
    console.log(
      `npx hardhat verify --network <network> ${await yieldFarmingManager.getAddress()} "${config.poolManagerAddress}" "${config.wrfTokenAddress}" "${await farmImplementation.getAddress()}" "${await rewardDistributor.getAddress()}"`
    );
    console.log(
      `npx hardhat verify --network <network> ${await governance.getAddress()} "${await yieldFarmingManager.getAddress()}" "${await rewardDistributor.getAddress()}" "${config.wrfTokenAddress}"`
    );
    console.log('==========================================');

    // ==================== SAVE DEPLOYMENT ====================
    const deployment = {
      network: (await ethers.provider.getNetwork()).name,
      chainId: (await ethers.provider.getNetwork()).chainId,
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      contracts: {
        RewardDistributor: await rewardDistributor.getAddress(),
        CarbonFarmingPool: await farmImplementation.getAddress(),
        YieldFarmingManager: await yieldFarmingManager.getAddress(),
        YieldFarmingGovernance: await governance.getAddress(),
      },
      configuration: config,
      transactions: {
        RewardDistributor: rewardDistributor.deploymentTransaction().hash,
        CarbonFarmingPool: farmImplementation.deploymentTransaction().hash,
        YieldFarmingManager: yieldFarmingManager.deploymentTransaction().hash,
        YieldFarmingGovernance: governance.deploymentTransaction().hash,
      },
    };

    // Save to file
    const fs = require('fs');
    const deploymentFile = `deployment-yield-farming-${Date.now()}.json`;
    fs.writeFileSync(deploymentFile, JSON.stringify(deployment, null, 2));
    console.log(`\n💾 Deployment info saved to: ${deploymentFile}`);

    return deployment;
  } catch (error) {
    console.error('\n❌ Deployment failed:', error);
    throw error;
  }
}

// Helper function to verify deployment
async function verifyDeployment(addresses) {
  console.log('\n🔍 Verifying deployment...');

  try {
    // Verify RewardDistributor
    const rewardDistributor = await ethers.getContractAt(
      'RewardDistributor',
      addresses.RewardDistributor
    );
    const supportedTokens = await rewardDistributor.getSupportedTokens();
    console.log(
      '✅ RewardDistributor working - supported tokens:',
      supportedTokens.length
    );

    // Verify YieldFarmingManager
    const yieldFarmingManager = await ethers.getContractAt(
      'YieldFarmingManager',
      addresses.YieldFarmingManager
    );
    const farmsCount = await yieldFarmingManager.getFarmsCount();
    console.log(
      '✅ YieldFarmingManager working - farms count:',
      farmsCount.toString()
    );

    // Verify Governance
    const governance = await ethers.getContractAt(
      'YieldFarmingGovernance',
      addresses.YieldFarmingGovernance
    );
    const votingParams = await governance.getVotingParams();
    console.log(
      '✅ YieldFarmingGovernance working - voting delay:',
      votingParams.votingDelay.toString(),
      'blocks'
    );

    console.log('✅ All contracts verified successfully!');
    return true;
  } catch (error) {
    console.error('❌ Verification failed:', error);
    return false;
  }
}

// Export for use in tests
module.exports = { main, verifyDeployment };

// Run deployment if called directly
if (require.main === module) {
  main()
    .then(deployment => {
      console.log('\n🎊 Yield Farming deployment completed!');
      return verifyDeployment(deployment.contracts);
    })
    .then(() => {
      process.exit(0);
    })
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
