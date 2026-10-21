// SPDX-License-Identifier: MIT
const { ethers } = require('hardhat');
const { deployContract, verifyContract } = require('./utils/deploy-utils');

/**
 * Deploy Advanced Governance System
 *
 * This script deploys the complete governance system including:
 * - DPoS Validator System
 * - Climate Emergency Protocol
 * - Stakeholder Incentives
 * - Governance Analytics
 * - Compliance Module
 * - Enhanced Treasury
 */

async function main() {
  console.log('🌿 Deploying WRF Advanced Governance System...\n');

  const [deployer] = await ethers.getSigners();
  console.log(`Deploying with account: ${deployer.address}`);
  console.log(
    `Account balance: ${ethers.formatEther(await deployer.provider.getBalance(deployer.address))} ETH\n`
  );

  const deployedContracts = {};

  try {
    // 1. Deploy WRF Token (if not already deployed)
    console.log('📊 Deploying WRF Token...');
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy();
    await wrfToken.waitForDeployment();
    deployedContracts.wrfToken = await wrfToken.getAddress();
    console.log(`✅ WRF Token deployed at: ${deployedContracts.wrfToken}\n`);

    // 2. Deploy TimeLock Controller
    console.log('⏰ Deploying TimeHLock Controller...');
    const TimelockController = await ethers.getContractFactory(
      '@openzeppelin/contracts/governance/TimelockController.sol:TimelockController'
    );
    const timelock = await TimelockController.deploy(
      86400, // 1 day delay
      [deployer.address], // proposers
      [deployer.address], // executors
      deployer.address // admin
    );
    await timelock.waitForDeployment();
    deployedContracts.timelock = await timelock.getAddress();
    console.log(
      `✅ TimelockController deployed at: ${deployedContracts.timelock}\n`
    );

    // 3. Deploy WRF Governor
    console.log('🏛️ Deploying WRF Governor...');
    const WRFGovernor = await ethers.getContractFactory('WRFGovernor');
    const governor = await WRFGovernor.deploy(
      deployedContracts.wrfToken,
      deployedContracts.timelock,
      1, // voting delay
      604800, // voting period (1 week)
      ethers.parseEther('1000'), // proposal threshold
      4 // quorum fraction (4%)
    );
    await governor.waitForDeployment();
    deployedContracts.governor = await governor.getAddress();
    console.log(`✅ WRF Governor deployed at: ${deployedContracts.governor}\n`);

    // 4. Deploy DPoS Validator System
    console.log('⚡ Deploying DPoS Validator System...');
    const DPoSValidator = await ethers.getContractFactory('DPoSValidator');
    const dposValidator = await DPoSValidator.deploy(
      deployedContracts.wrfToken,
      86400 // epoch duration (1 day)
    );
    await dposValidator.waitForDeployment();
    deployedContracts.dposValidator = await dposValidator.getAddress();
    console.log(
      `✅ DPoS Validator deployed at: ${deployedContracts.dposValidator}\n`
    );

    // 5. Deploy Climate Emergency Protocol
    console.log('🌡️ Deploying Climate Emergency Protocol...');
    const ClimateEmergencyProtocol = await ethers.getContractFactory(
      'ClimateEmergencyProtocol'
    );
    const emergencyProtocol = await ClimateEmergencyProtocol.deploy(
      deployedContracts.wrfToken,
      deployer.address, // emergency vault
      deployer.address // admin
    );
    await emergencyProtocol.waitForDeployment();
    deployedContracts.emergencyProtocol = await emergencyProtocol.getAddress();
    console.log(
      `✅ Climate Emergency Protocol deployed at: ${deployedContracts.emergencyProtocol}\n`
    );

    // 6. Deploy Stakeholder Incentives
    console.log('🎁 Deploying Stakeholder Incentives...');
    const StakeholderIncentives = await ethers.getContractFactory(
      'StakeholderIncentives'
    );
    const incentives = await StakeholderIncentives.deploy(
      deployedContracts.wrfToken,
      ethers.ZeroAddress, // achievement NFT (to be deployed separately)
      deployer.address
    );
    await incentives.waitForDeployment();
    deployedContracts.incentives = await incentives.getAddress();
    console.log(
      `✅ Stakeholder Incentives deployed at: ${deployedContracts.incentives}\n`
    );

    // 7. Deploy Governance Analytics
    console.log('📈 Deploying Governance Analytics...');
    const GovernanceAnalytics = await ethers.getContractFactory(
      'GovernanceAnalytics'
    );
    const analytics = await GovernanceAnalytics.deploy(deployer.address);
    await analytics.waitForDeployment();
    deployedContracts.analytics = await analytics.getAddress();
    console.log(
      `✅ Governance Analytics deployed at: ${deployedContracts.analytics}\n`
    );

    // 8. Deploy Compliance Module
    console.log('⚖️ Deploying Compliance Module...');
    const ComplianceModule =
      await ethers.getContractFactory('ComplianceModule');
    const compliance = await ComplianceModule.deploy(deployer.address);
    await compliance.waitForDeployment();
    deployedContracts.compliance = await compliance.getAddress();
    console.log(
      `✅ Compliance Module deployed at: ${deployedContracts.compliance}\n`
    );

    // 9. Deploy Enhanced Treasury
    console.log('💰 Deploying Enhanced Treasury...');
    const EnhancedTreasury =
      await ethers.getContractFactory('EnhancedTreasury');
    const treasury = await EnhancedTreasury.deploy(
      deployer.address,
      deployedContracts.timelock,
      1500 // 15% emergency fund
    );
    await treasury.waitForDeployment();
    deployedContracts.treasury = await treasury.getAddress();
    console.log(
      `✅ Enhanced Treasury deployed at: ${deployedContracts.treasury}\n`
    );

    // 10. Post-deployment configuration
    console.log('⚙️ Configuring governance system...');

    // Grant necessary roles
    await emergencyProtocol.grantRole(
      await emergencyProtocol.ORACLE_ROLE(),
      deployer.address
    );
    await emergencyProtocol.grantRole(
      await emergencyProtocol.GUARDIAN_ROLE(),
      deployer.address
    );

    await incentives.grantRole(
      await incentives.INCENTIVE_MANAGER_ROLE(),
      deployer.address
    );

    await analytics.grantRole(
      await analytics.DATA_PROVIDER_ROLE(),
      deployer.address
    );
    await analytics.grantRole(
      await analytics.ANALYTICS_MANAGER_ROLE(),
      deployer.address
    );

    await compliance.grantRole(
      await compliance.KYC_PROVIDER_ROLE(),
      deployer.address
    );
    await compliance.grantRole(
      await compliance.COMPLIANCE_OFFICER_ROLE(),
      deployer.address
    );

    await treasury.grantRole(
      await treasury.TREASURY_MANAGER_ROLE(),
      deployer.address
    );
    await treasury.grantRole(
      await treasury.FUND_ALLOCATOR_ROLE(),
      deployer.address
    );
    await treasury.grantRole(await treasury.AUDITOR_ROLE(), deployer.address);

    console.log('✅ Initial configuration completed\n');

    // 11. Summary
    console.log('🎉 Advanced Governance System Deployment Complete!\n');
    console.log('='.repeat(60));
    console.log('📋 DEPLOYMENT SUMMARY');
    console.log('='.repeat(60));

    Object.entries(deployedContracts).forEach(([name, address]) => {
      console.log(`${name.padEnd(20)}: ${address}`);
    });

    console.log('\n🔗 Network:', (await deployer.provider.getNetwork()).name);
    console.log('⛽ Total gas used: Calculating...');

    // 12. Save deployment info
    const deploymentInfo = {
      network: (await deployer.provider.getNetwork()).name,
      chainId: (await deployer.provider.getNetwork()).chainId,
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      contracts: deployedContracts,
    };

    const fs = require('fs');
    const path = require('path');

    // Ensure deployments directory exists
    const deploymentsDir = path.join(__dirname, '..', 'deployments');
    if (!fs.existsSync(deploymentsDir)) {
      fs.mkdirSync(deploymentsDir, { recursive: true });
    }

    // Save deployment info
    const deploymentFile = path.join(
      deploymentsDir,
      `governance-${Date.now()}.json`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));

    console.log(`\n💾 Deployment info saved to: ${deploymentFile}`);
    console.log('\n🚀 Governance system is ready for use!');

    return deployedContracts;
  } catch (error) {
    console.error('❌ Deployment failed:', error);
    process.exit(1);
  }
}

// Helper function to calculate total gas used
async function getTotalGasUsed(txs) {
  let totalGas = BigInt(0);
  for (const tx of txs) {
    const receipt = await tx.wait();
    totalGas += receipt.gasUsed;
  }
  return totalGas;
}

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
