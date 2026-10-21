const { ethers, upgrades } = require('hardhat');
const { deploymentConfig } = require('./deployment-config');

/**
 * Deploy LayawayRegistration contract with all dependencies
 */
async function main() {
  console.log('🚀 Starting LayawayRegistration deployment...');

  const [deployer] = await ethers.getSigners();
  console.log('Deploying contracts with account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.formatEther(await deployer.provider.getBalance(deployer.address))
  );

  const networkName = (await ethers.provider.getNetwork()).name;
  console.log('Deploying to network:', networkName);

  // Deploy dependencies first (or use existing addresses)
  let participantTypeRegistry,
    stakeCalculator,
    socialVerification,
    wrfToken,
    slashingMechanism;

  try {
    // Check if we're in test environment or need to deploy dependencies
    const config = deploymentConfig[networkName] || deploymentConfig.localhost;

    if (config.dependencies.deployed) {
      console.log('📋 Using existing dependency addresses...');
      participantTypeRegistry = {
        address: config.dependencies.participantTypeRegistry,
      };
      stakeCalculator = { address: config.dependencies.stakeCalculator };
      socialVerification = { address: config.dependencies.socialVerification };
      wrfToken = { address: config.dependencies.wrfToken };
      slashingMechanism = { address: config.dependencies.slashingMechanism };
    } else {
      console.log('🏭 Deploying dependency contracts...');

      // Deploy ParticipantTypeRegistry
      const ParticipantTypeRegistry = await ethers.getContractFactory(
        'ParticipantTypeRegistry'
      );
      participantTypeRegistry = await ParticipantTypeRegistry.deploy();
      await participantTypeRegistry.waitForDeployment();
      console.log(
        '✅ ParticipantTypeRegistry deployed to:',
        await participantTypeRegistry.getAddress()
      );

      // Deploy DynamicStakeCalculator
      const DynamicStakeCalculator = await ethers.getContractFactory(
        'DynamicStakeCalculator'
      );
      stakeCalculator = await DynamicStakeCalculator.deploy();
      await stakeCalculator.waitForDeployment();
      console.log(
        '✅ DynamicStakeCalculator deployed to:',
        await stakeCalculator.getAddress()
      );

      // Deploy SocialVerification
      const SocialVerification =
        await ethers.getContractFactory('SocialVerification');
      socialVerification = await SocialVerification.deploy();
      await socialVerification.waitForDeployment();
      console.log(
        '✅ SocialVerification deployed to:',
        await socialVerification.getAddress()
      );

      // Use existing WRFToken if available, otherwise deploy mock
      if (config.dependencies.wrfToken) {
        wrfToken = { address: config.dependencies.wrfToken };
        console.log(
          '✅ Using existing WRFToken at:',
          config.dependencies.wrfToken
        );
      } else {
        const WRFToken = await ethers.getContractFactory('WRFToken');
        wrfToken = await WRFToken.deploy();
        await wrfToken.waitForDeployment();
        console.log('✅ WRFToken deployed to:', await wrfToken.getAddress());
      }

      // Deploy SlashingMechanism
      const SlashingMechanism =
        await ethers.getContractFactory('SlashingMechanism');
      slashingMechanism = await SlashingMechanism.deploy();
      await slashingMechanism.waitForDeployment();
      console.log(
        '✅ SlashingMechanism deployed to:',
        await slashingMechanism.getAddress()
      );
    }

    // Deploy LayawayRegistration with upgrades proxy
    console.log('🏗️ Deploying LayawayRegistration (Upgradeable)...');
    const LayawayRegistration = await ethers.getContractFactory(
      'LayawayRegistration'
    );

    const layawayRegistration = await upgrades.deployProxy(
      LayawayRegistration,
      [
        (await participantTypeRegistry.getAddress?.()) ||
          participantTypeRegistry.address,
        (await stakeCalculator.getAddress?.()) || stakeCalculator.address,
        (await socialVerification.getAddress?.()) || socialVerification.address,
        (await wrfToken.getAddress?.()) || wrfToken.address,
        (await slashingMechanism.getAddress?.()) || slashingMechanism.address,
      ],
      {
        initializer: 'initialize',
        kind: 'uups',
      }
    );

    await layawayRegistration.waitForDeployment();
    const layawayAddress = await layawayRegistration.getAddress();
    console.log('🎉 LayawayRegistration deployed to:', layawayAddress);

    // Configure payment assets
    console.log('⚙️ Configuring payment assets...');

    // Configure ETH
    await layawayRegistration.configurePaymentAsset(
      0, // PaymentAsset.ETH
      ethers.ZeroAddress,
      true
    );
    console.log('✅ ETH payment asset configured');

    // Configure USDC if available
    if (config.tokens?.usdc) {
      await layawayRegistration.configurePaymentAsset(
        2, // PaymentAsset.USDC
        config.tokens.usdc,
        true
      );
      console.log('✅ USDC payment asset configured');
    }

    // Grant earnings distributor role to deployer temporarily
    const EARNINGS_DISTRIBUTOR_ROLE = ethers.keccak256(
      ethers.toUtf8Bytes('EARNINGS_DISTRIBUTOR_ROLE')
    );
    await layawayRegistration.grantRole(
      EARNINGS_DISTRIBUTOR_ROLE,
      deployer.address
    );
    console.log('✅ Earnings distributor role granted to deployer');

    // Set up initial configuration if specified
    if (config.layawayConfig) {
      console.log('⚙️ Updating layaway configuration...');
      await layawayRegistration.updateLayawayConfiguration(
        config.layawayConfig.multiMethodPeriod,
        config.layawayConfig.singleMethodPeriod,
        config.layawayConfig.unverifiedPeriod,
        config.layawayConfig.slashingMultiplier
      );
      console.log('✅ Layaway configuration updated');
    }

    // Verify deployment
    console.log('\n📊 Deployment Summary:');
    console.log('=====================================');
    console.log(`LayawayRegistration: ${layawayAddress}`);
    console.log(
      `ParticipantTypeRegistry: ${(await participantTypeRegistry.getAddress?.()) || participantTypeRegistry.address}`
    );
    console.log(
      `DynamicStakeCalculator: ${(await stakeCalculator.getAddress?.()) || stakeCalculator.address}`
    );
    console.log(
      `SocialVerification: ${(await socialVerification.getAddress?.()) || socialVerification.address}`
    );
    console.log(
      `WRFToken: ${(await wrfToken.getAddress?.()) || wrfToken.address}`
    );
    console.log(
      `SlashingMechanism: ${(await slashingMechanism.getAddress?.()) || slashingMechanism.address}`
    );
    console.log('=====================================');

    // Get initial state
    const config_state = await layawayRegistration.config();
    console.log('\n⚙️ Initial Configuration:');
    console.log(
      `Multi-method period: ${config_state.multiMethodPeriod} seconds (${config_state.multiMethodPeriod / (24 * 60 * 60)} days)`
    );
    console.log(
      `Single-method period: ${config_state.singleMethodPeriod} seconds (${config_state.singleMethodPeriod / (24 * 60 * 60)} days)`
    );
    console.log(
      `Unverified period: ${config_state.unverifiedPeriod} seconds (${config_state.unverifiedPeriod / (24 * 60 * 60)} days)`
    );
    console.log(
      `Slashing multiplier: ${config_state.slashingMultiplier / 100}%`
    );
    console.log(
      `Emergency withdrawal enabled: ${config_state.emergencyWithdrawalEnabled}`
    );

    // Save deployment info
    const deploymentInfo = {
      network: networkName,
      timestamp: new Date().toISOString(),
      deployer: deployer.address,
      contracts: {
        LayawayRegistration: layawayAddress,
        ParticipantTypeRegistry:
          (await participantTypeRegistry.getAddress?.()) ||
          participantTypeRegistry.address,
        DynamicStakeCalculator:
          (await stakeCalculator.getAddress?.()) || stakeCalculator.address,
        SocialVerification:
          (await socialVerification.getAddress?.()) ||
          socialVerification.address,
        WRFToken: (await wrfToken.getAddress?.()) || wrfToken.address,
        SlashingMechanism:
          (await slashingMechanism.getAddress?.()) || slashingMechanism.address,
      },
      configuration: {
        multiMethodPeriod: config_state.multiMethodPeriod.toString(),
        singleMethodPeriod: config_state.singleMethodPeriod.toString(),
        unverifiedPeriod: config_state.unverifiedPeriod.toString(),
        slashingMultiplier: config_state.slashingMultiplier.toString(),
        emergencyWithdrawalEnabled: config_state.emergencyWithdrawalEnabled,
      },
    };

    // Write to file
    const fs = require('fs');
    const path = require('path');
    const deploymentsDir = path.join(__dirname, '../deployments');
    if (!fs.existsSync(deploymentsDir)) {
      fs.mkdirSync(deploymentsDir);
    }

    const deploymentFile = path.join(
      deploymentsDir,
      `layaway-registration-${networkName}-${Date.now()}.json`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
    console.log(`\n💾 Deployment info saved to: ${deploymentFile}`);

    // Instructions for next steps
    console.log('\n🔄 Next Steps:');
    console.log('1. Grant EARNINGS_DISTRIBUTOR_ROLE to appropriate addresses');
    console.log('2. Configure additional payment assets if needed');
    console.log('3. Set up participant type registry with real data');
    console.log('4. Configure stake calculator with proper algorithms');
    console.log('5. Test with small amounts before going live');

    return layawayAddress;
  } catch (error) {
    console.error('❌ Deployment failed:', error);
    process.exitCode = 1;
    return null;
  }
}

// Handle both direct execution and module import
if (require.main === module) {
  main()
    .then(address => {
      if (address) {
        console.log('✅ Deployment completed successfully!');
        process.exit(0);
      } else {
        process.exit(1);
      }
    })
    .catch(error => {
      console.error('💥 Fatal error:', error);
      process.exit(1);
    });
}

module.exports = { deployLayawayRegistration: main };
