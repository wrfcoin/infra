const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

/**
 * Enhanced Fair Launch Deployment Script
 *
 * This script deploys the complete enhanced fair launch system including:
 * - ParticipantTypeRegistry (already enhanced)
 * - FairLaunchStakeManager (existing)
 * - FairLaunchIntegrationManager (new)
 * - WRFToken integration
 *
 * The deployment follows a secure, production-ready approach with proper
 * configuration, role assignments, and verification steps.
 */

async function main() {
  console.log('🚀 Starting Enhanced Fair Launch System Deployment');
  console.log('='.repeat(60));

  // Get deployment accounts
  const [deployer, emergencyMultisig, treasury, oracle, validator] =
    await ethers.getSigners();

  console.log('📋 Deployment Configuration:');
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Emergency Multisig: ${emergencyMultisig.address}`);
  console.log(`Treasury: ${treasury.address}`);
  console.log(`Oracle: ${oracle.address}`);
  console.log(`Validator: ${validator.address}`);
  console.log('');

  const deploymentResults = {};
  const gasUsed = [];

  try {
    // ========== STEP 1: Deploy Core Contracts ==========
    console.log('🏗️  STEP 1: Deploying Core Contracts');
    console.log('-'.repeat(40));

    // Deploy ParticipantTypeRegistry
    console.log('Deploying ParticipantTypeRegistry...');
    const ParticipantTypeRegistry = await ethers.getContractFactory(
      'ParticipantTypeRegistry'
    );
    const participantRegistry = await ParticipantTypeRegistry.deploy();
    await participantRegistry.waitForDeployment();

    const registryAddress = await participantRegistry.getAddress();
    console.log(`✅ ParticipantTypeRegistry deployed: ${registryAddress}`);
    deploymentResults.participantRegistry = registryAddress;

    // Deploy FairLaunchStakeManager
    console.log('Deploying FairLaunchStakeManager...');
    const FairLaunchStakeManager = await ethers.getContractFactory(
      'FairLaunchStakeManager'
    );
    const stakeManager = await FairLaunchStakeManager.deploy(
      emergencyMultisig.address,
      treasury.address
    );
    await stakeManager.waitForDeployment();

    const stakeManagerAddress = await stakeManager.getAddress();
    console.log(`✅ FairLaunchStakeManager deployed: ${stakeManagerAddress}`);
    deploymentResults.stakeManager = stakeManagerAddress;

    // Get WRFToken address (assume already deployed)
    let wrfTokenAddress;
    try {
      // Try to get from existing deployment
      const existingDeployment = JSON.parse(
        fs.readFileSync(
          path.join(
            __dirname,
            '../deployment-reports/contracts-deployment.json'
          ),
          'utf8'
        )
      );
      wrfTokenAddress =
        existingDeployment.WRFToken || existingDeployment.wrfToken;
    } catch (error) {
      console.log(
        '⚠️  WRFToken not found in existing deployments, deploying new one...'
      );

      const WRFToken = await ethers.getContractFactory('WRFToken');
      const wrfToken = await WRFToken.deploy();
      await wrfToken.waitForDeployment();
      wrfTokenAddress = await wrfToken.getAddress();

      console.log(`✅ WRFToken deployed: ${wrfTokenAddress}`);
    }

    if (wrfTokenAddress) {
      console.log(`✅ WRFToken found/deployed: ${wrfTokenAddress}`);
      deploymentResults.wrfToken = wrfTokenAddress;
    }

    // Deploy FairLaunchIntegrationManager
    console.log('Deploying FairLaunchIntegrationManager...');
    const FairLaunchIntegrationManager = await ethers.getContractFactory(
      'FairLaunchIntegrationManager'
    );
    const integrationManager = await FairLaunchIntegrationManager.deploy(
      registryAddress,
      stakeManagerAddress,
      wrfTokenAddress
    );
    await integrationManager.waitForDeployment();

    const integrationManagerAddress = await integrationManager.getAddress();
    console.log(
      `✅ FairLaunchIntegrationManager deployed: ${integrationManagerAddress}`
    );
    deploymentResults.integrationManager = integrationManagerAddress;

    console.log('');

    // ========== STEP 2: Configure Roles and Permissions ==========
    console.log('🔐 STEP 2: Configuring Roles and Permissions');
    console.log('-'.repeat(40));

    // Configure ParticipantTypeRegistry roles
    console.log('Configuring ParticipantTypeRegistry roles...');
    const ORACLE_ROLE = await participantRegistry.ORACLE_ROLE();
    const VALIDATOR_ROLE = await participantRegistry.VALIDATOR_ROLE();
    const SLASHING_ROLE = await participantRegistry.SLASHING_ROLE();

    await participantRegistry.grantRole(ORACLE_ROLE, oracle.address);
    await participantRegistry.grantRole(VALIDATOR_ROLE, validator.address);
    await participantRegistry.grantRole(
      SLASHING_ROLE,
      emergencyMultisig.address
    );
    console.log('✅ ParticipantTypeRegistry roles configured');

    // Configure integration contracts
    console.log('Setting up contract integrations...');
    await participantRegistry.setFairLaunchContracts(
      stakeManagerAddress,
      wrfTokenAddress
    );
    console.log('✅ Contract integrations configured');

    console.log('');

    // ========== STEP 3: Configure Staking Assets ==========
    console.log('💰 STEP 3: Configuring Staking Assets');
    console.log('-'.repeat(40));

    // Set up WRF as staking asset
    console.log('Adding WRF as staking asset...');
    await stakeManager.setSupportedAsset(
      wrfTokenAddress,
      18, // decimals
      ethers.parseEther('100'), // min stake: 100 WRF
      ethers.parseEther('50000'), // max stake: 50,000 WRF
      'WRF'
    );

    // Set initial price (assuming $1 per WRF for demo)
    await stakeManager.setOraclePrice(
      wrfTokenAddress,
      1000000, // $1.00 with precision (1e6)
      oracle.address // Oracle address
    );
    console.log('✅ WRF staking asset configured');

    // Add ETH as staking asset (if desired)
    console.log('Adding ETH as staking asset...');
    const WETH_ADDRESS = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'; // Mainnet WETH
    // For testnets, use appropriate WETH address or deploy mock

    await stakeManager.setSupportedAsset(
      WETH_ADDRESS,
      18,
      ethers.parseEther('0.1'), // min stake: 0.1 ETH
      ethers.parseEther('10'), // max stake: 10 ETH
      'ETH'
    );

    await stakeManager.setOraclePrice(
      WETH_ADDRESS,
      2000000000, // $2000 per ETH with precision
      oracle.address
    );
    console.log('✅ ETH staking asset configured');

    console.log('');

    // ========== STEP 4: Initialize Fair Launch Parameters ==========
    console.log('⚙️  STEP 4: Initializing Fair Launch Parameters');
    console.log('-'.repeat(40));

    // Set minimum participants
    const minimumParticipants = 100;
    await integrationManager.updateMinimumParticipants(minimumParticipants);
    console.log(`✅ Minimum participants set to: ${minimumParticipants}`);

    console.log('');

    // ========== STEP 5: Verification and Testing ==========
    console.log('✅ STEP 5: Verification and Testing');
    console.log('-'.repeat(40));

    // Verify contract deployments
    console.log('Verifying contract states...');

    const totalParticipants = await participantRegistry.totalParticipants();
    const fairLaunchActive = await integrationManager.fairLaunchActive();
    const supportedAssets = await stakeManager.getSupportedAssets();

    console.log(`- ParticipantRegistry participants: ${totalParticipants}`);
    console.log(`- Fair launch active: ${fairLaunchActive}`);
    console.log(`- Supported staking assets: ${supportedAssets.length}`);

    // Test registrations
    console.log('\nTesting participant registration...');
    const testLocation = {
      latitude: 40750000, // NYC
      longitude: -73985000,
      zone: 0,
      countryCode: ethers.encodeBytes32String('US'),
      regionCode: ethers.encodeBytes32String('NY'),
    };

    await participantRegistry.connect(oracle).registerParticipant(
      deployer.address,
      0, // WEATHER_STATION
      testLocation,
      1 // EMAIL_VERIFIED
    );
    console.log('✅ Test participant registration successful');

    // Test eligibility checking
    const [eligible, reason] =
      await integrationManager.checkFairLaunchEligibility(deployer.address);
    console.log(
      `- Fair launch eligibility: ${eligible} ${reason ? `(${reason})` : ''}`
    );

    console.log('');

    // ========== STEP 6: Save Deployment Results ==========
    console.log('💾 STEP 6: Saving Deployment Results');
    console.log('-'.repeat(40));

    const deploymentReport = {
      network: (await ethers.provider.getNetwork()).name,
      chainId: (await ethers.provider.getNetwork()).chainId,
      timestamp: new Date().toISOString(),
      deployer: deployer.address,
      contracts: deploymentResults,
      configuration: {
        minimumParticipants,
        supportedAssets: supportedAssets.length,
        roles: {
          oracle: oracle.address,
          validator: validator.address,
          emergencyMultisig: emergencyMultisig.address,
          treasury: treasury.address,
        },
      },
      verification: {
        totalParticipants: totalParticipants.toString(),
        fairLaunchActive,
        testRegistrationSuccessful: true,
        testEligibilityCheck: eligible,
      },
    };

    // Ensure reports directory exists
    const reportsDir = path.join(__dirname, '../deployment-reports');
    if (!fs.existsSync(reportsDir)) {
      fs.mkdirSync(reportsDir, { recursive: true });
    }

    // Save deployment report
    const reportPath = path.join(
      reportsDir,
      `enhanced-fair-launch-deployment-${Date.now()}.json`
    );
    fs.writeFileSync(reportPath, JSON.stringify(deploymentReport, null, 2));
    console.log(`✅ Deployment report saved: ${reportPath}`);

    // Save to main deployment file
    const mainDeploymentPath = path.join(
      reportsDir,
      'enhanced-fair-launch-deployment.json'
    );
    fs.writeFileSync(
      mainDeploymentPath,
      JSON.stringify(deploymentReport, null, 2)
    );
    console.log(`✅ Main deployment file updated: ${mainDeploymentPath}`);

    console.log('');

    // ========== DEPLOYMENT SUMMARY ==========
    console.log('🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!');
    console.log('='.repeat(60));
    console.log('📄 Contract Addresses:');
    Object.entries(deploymentResults).forEach(([name, address]) => {
      console.log(`   ${name}: ${address}`);
    });

    console.log('\n🔧 Next Steps:');
    console.log('1. Verify contracts on blockchain explorer');
    console.log('2. Set up monitoring and alerting');
    console.log('3. Configure frontend integration');
    console.log('4. Test fair launch activation');
    console.log('5. Prepare for mainnet launch');

    console.log('\n⚠️  Security Reminders:');
    console.log('- Transfer admin roles to multisig wallets');
    console.log('- Set up proper oracle price feeds');
    console.log('- Configure monitoring systems');
    console.log('- Conduct final security audit');
  } catch (error) {
    console.error('\n❌ Deployment failed:', error.message);
    console.error(error);
    process.exit(1);
  }
}

// Handle unhandled promise rejections
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection at:', promise, 'reason:', reason);
  process.exit(1);
});

// Run the deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = { main };
