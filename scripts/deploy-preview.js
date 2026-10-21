#!/usr/bin/env node

/**
 * Preview Environment Smart Contract Deployment Script
 * Deploys contracts to testnet with PR-specific configuration
 */

const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

async function main() {
  const prNumber = process.env.PR_NUMBER;
  if (!prNumber) {
    throw new Error('PR_NUMBER environment variable is required');
  }

  console.log(
    `🚀 Deploying contracts for PR #${prNumber} to Sepolia testnet...`
  );

  // Get deployment configuration
  const network = await ethers.provider.getNetwork();
  console.log(`Network: ${network.name} (Chain ID: ${network.chainId})`);

  // Get signers
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(
    `Balance: ${ethers.utils.formatEther(await deployer.getBalance())} ETH`
  );

  // Deployment salt for PR-specific addresses
  const deploymentSalt = ethers.utils.keccak256(
    ethers.utils.toUtf8Bytes(`pr-${prNumber}-wrfcoin`)
  );

  const deployedContracts = {};
  const deploymentDir = path.join(__dirname, '..', 'deployments', 'sepolia');

  // Ensure deployment directory exists
  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  try {
    // Deploy WRF Token
    console.log('\n📄 Deploying WRF Token...');
    const WRFToken = await ethers.getContractFactory('WRFToken');
    const wrfToken = await WRFToken.deploy(
      'WRFCoin Preview Token',
      'WRF-PREV',
      ethers.utils.parseEther('1000000'), // 1M tokens for preview
      deployer.address
    );
    await wrfToken.deployed();
    deployedContracts.WRFToken = wrfToken.address;
    console.log(`✅ WRF Token deployed to: ${wrfToken.address}`);

    // Deploy Carbon Credits
    console.log('\n🌱 Deploying Carbon Credits...');
    const CarbonCredits = await ethers.getContractFactory('CarbonCredits');
    const carbonCredits = await CarbonCredits.deploy(
      'Preview Carbon Credits',
      'PCC',
      `https://preview-api-pr-${prNumber}.fly.dev/api/carbon-credits/`
    );
    await carbonCredits.deployed();
    deployedContracts.CarbonCredits = carbonCredits.address;
    console.log(`✅ Carbon Credits deployed to: ${carbonCredits.address}`);

    // Deploy Computational NFT
    console.log('\n🖥️ Deploying Computational NFT...');
    const ComputationalNFT =
      await ethers.getContractFactory('ComputationalNFT');
    const computationalNFT = await ComputationalNFT.deploy(
      'Preview Computational NFT',
      'PCNFT',
      `https://preview-api-pr-${prNumber}.fly.dev/api/computational-nft/`
    );
    await computationalNFT.deployed();
    deployedContracts.ComputationalNFT = computationalNFT.address;
    console.log(
      `✅ Computational NFT deployed to: ${computationalNFT.address}`
    );

    // Deploy Carbon Credit AMM
    console.log('\n💱 Deploying Carbon Credit AMM...');
    const CarbonCreditAMM = await ethers.getContractFactory('CarbonCreditAMM');
    const carbonAMM = await CarbonCreditAMM.deploy(
      wrfToken.address,
      carbonCredits.address,
      ethers.utils.parseEther('0.003'), // 0.3% fee for preview
      deployer.address
    );
    await carbonAMM.deployed();
    deployedContracts.CarbonCreditAMM = carbonAMM.address;
    console.log(`✅ Carbon Credit AMM deployed to: ${carbonAMM.address}`);

    // Deploy Reward Distributor
    console.log('\n🎁 Deploying Reward Distributor...');
    const RewardDistributor =
      await ethers.getContractFactory('RewardDistributor');
    const rewardDistributor = await RewardDistributor.deploy(
      wrfToken.address,
      carbonCredits.address,
      deployer.address
    );
    await rewardDistributor.deployed();
    deployedContracts.RewardDistributor = rewardDistributor.address;
    console.log(
      `✅ Reward Distributor deployed to: ${rewardDistributor.address}`
    );

    // Deploy Liquidity Pool Manager
    console.log('\n🏊 Deploying Liquidity Pool Manager...');
    const LiquidityPoolManager = await ethers.getContractFactory(
      'LiquidityPoolManager'
    );
    const liquidityManager = await LiquidityPoolManager.deploy(
      wrfToken.address,
      deployer.address
    );
    await liquidityManager.deployed();
    deployedContracts.LiquidityPoolManager = liquidityManager.address;
    console.log(
      `✅ Liquidity Pool Manager deployed to: ${liquidityManager.address}`
    );

    // Setup initial configuration
    console.log('\n⚙️ Setting up initial configuration...');

    // Transfer some tokens for testing
    await wrfToken.transfer(
      carbonAMM.address,
      ethers.utils.parseEther('100000')
    );
    await wrfToken.transfer(
      rewardDistributor.address,
      ethers.utils.parseEther('50000')
    );

    // Grant roles
    const MINTER_ROLE = await carbonCredits.MINTER_ROLE();
    await carbonCredits.grantRole(MINTER_ROLE, rewardDistributor.address);

    console.log('✅ Initial configuration completed');

    // Save deployment information
    const deploymentInfo = {
      network: network.name,
      chainId: network.chainId,
      prNumber: prNumber,
      deployer: deployer.address,
      timestamp: new Date().toISOString(),
      contracts: deployedContracts,
      environment: 'preview',
      gasUsed: {
        // Will be filled by transaction receipts
      },
    };

    // Save to file
    const deploymentFile = path.join(
      deploymentDir,
      `pr-${prNumber}-deployment.json`
    );
    fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));

    console.log(`\n📝 Deployment information saved to: ${deploymentFile}`);

    // Generate environment variables file
    const envVars = Object.entries(deployedContracts)
      .map(
        ([name, address]) =>
          `NEXT_PUBLIC_${name.toUpperCase()}_ADDRESS=${address}`
      )
      .join('\n');

    const envFile = path.join(deploymentDir, `pr-${prNumber}.env`);
    fs.writeFileSync(envFile, envVars);

    console.log(`📝 Environment variables saved to: ${envFile}`);

    // Verify contracts on Etherscan (if API key is available)
    if (process.env.ETHERSCAN_API_KEY) {
      console.log('\n🔍 Verifying contracts on Etherscan...');

      try {
        await hre.run('verify:verify', {
          address: wrfToken.address,
          constructorArguments: [
            'WRFCoin Preview Token',
            'WRF-PREV',
            ethers.utils.parseEther('1000000'),
            deployer.address,
          ],
        });
        console.log('✅ WRF Token verified');
      } catch (error) {
        console.log('⚠️ WRF Token verification failed:', error.message);
      }

      // Add delay between verifications
      await new Promise(resolve => setTimeout(resolve, 5000));

      try {
        await hre.run('verify:verify', {
          address: carbonCredits.address,
          constructorArguments: [
            'Preview Carbon Credits',
            'PCC',
            `https://preview-api-pr-${prNumber}.fly.dev/api/carbon-credits/`,
          ],
        });
        console.log('✅ Carbon Credits verified');
      } catch (error) {
        console.log('⚠️ Carbon Credits verification failed:', error.message);
      }
    }

    console.log('\n🎉 Preview environment deployment completed successfully!');
    console.log('\n📋 Deployment Summary:');
    Object.entries(deployedContracts).forEach(([name, address]) => {
      console.log(`  ${name}: ${address}`);
    });

    console.log(
      `\n🔗 Sepolia Etherscan: https://sepolia.etherscan.io/address/${wrfToken.address}`
    );
    console.log(
      `🌐 Preview Frontend: https://pr-${prNumber}-wrfcoin.vercel.app`
    );
    console.log(`🔌 Preview API: https://preview-api-pr-${prNumber}.fly.dev`);
  } catch (error) {
    console.error('\n❌ Deployment failed:', error);
    process.exit(1);
  }
}

// Handle script execution
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = main;
