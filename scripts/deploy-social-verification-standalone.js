const { ethers } = require('hardhat');

/**
 * Standalone SocialVerification contract deployment
 * This script deploys only the SocialVerification contract without dependencies on other contracts
 */
async function main() {
  console.log('🚀 Deploying SocialVerification contract (Standalone)...');

  // Get signers
  const [deployer, oracle1, oracle2, admin] = await ethers.getSigners();
  console.log('📋 Deploying with account:', deployer.address);
  console.log(
    '💰 Account balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address))
  );

  try {
    // Deploy SocialVerification contract
    console.log('\n📝 Deploying SocialVerification contract...');
    const SocialVerification =
      await ethers.getContractFactory('SocialVerification');
    const socialVerification = await SocialVerification.deploy();
    await socialVerification.waitForDeployment();

    const socialVerificationAddress = await socialVerification.getAddress();
    console.log(
      '✅ SocialVerification deployed to:',
      socialVerificationAddress
    );

    // Setup oracle authorization
    console.log('\n🔐 Setting up oracle authorization...');

    // Add multiple oracles for redundancy
    const tx1 = await socialVerification.setOracleAuthorization(
      oracle1.address,
      true
    );
    await tx1.wait();
    console.log('✅ Oracle 1 authorized:', oracle1.address);

    const tx2 = await socialVerification.setOracleAuthorization(
      oracle2.address,
      true
    );
    await tx2.wait();
    console.log('✅ Oracle 2 authorized:', oracle2.address);

    // Configure platform settings
    console.log('\n⚙️  Configuring platform settings...');

    // GitHub: 10% discount
    const tx3 = await socialVerification.configurePlatform(0, true, 100_000); // GITHUB
    await tx3.wait();

    // Twitter: 5% discount
    const tx4 = await socialVerification.configurePlatform(1, true, 50_000); // TWITTER
    await tx4.wait();

    // LinkedIn: 7% discount
    const tx5 = await socialVerification.configurePlatform(2, true, 70_000); // LINKEDIN
    await tx5.wait();

    console.log('✅ Platform configurations updated');

    // Display deployment summary
    console.log('\n📊 Deployment Summary:');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('Contract Address:      ', socialVerificationAddress);
    console.log(
      'Network:               ',
      (await ethers.provider.getNetwork()).name
    );
    console.log(
      'Chain ID:              ',
      (await ethers.provider.getNetwork()).chainId
    );
    console.log(
      'Block Number:          ',
      await ethers.provider.getBlockNumber()
    );
    console.log('Oracle 1:              ', oracle1.address);
    console.log('Oracle 2:              ', oracle2.address);
    console.log('Max Social Discount:   ', '20%');
    console.log('Verification Period:   ', '365 days');
    console.log('GitHub Discount:       ', '10%');
    console.log('Twitter Discount:      ', '5%');
    console.log('LinkedIn Discount:     ', '7%');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

    console.log(
      '\n✨ SocialVerification standalone deployment completed successfully!'
    );
    console.log(
      '🎯 Contract is ready for production use in WRFCoin fair launch'
    );

    // Return deployment info for testing/integration
    return {
      socialVerification: socialVerificationAddress,
      deployer: deployer.address,
      oracle1: oracle1.address,
      oracle2: oracle2.address,
      admin: admin.address,
    };
  } catch (error) {
    console.error('❌ Deployment failed:', error);
    throw error;
  }
}

// Error handling
main()
  .then(deploymentInfo => {
    console.log('\n📋 Deployment Complete!');
    console.log('Deployment Info:', deploymentInfo);
    process.exit(0);
  })
  .catch(error => {
    console.error('❌ Deployment failed:', error);
    process.exit(1);
  });
