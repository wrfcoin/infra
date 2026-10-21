const { ethers } = require('hardhat');

/**
 * Deploy SocialVerification contract and integrate with fair launch system
 * This script demonstrates complete deployment and integration process
 */
async function main() {
  console.log(
    '🚀 Deploying SocialVerification contract for WRFCoin Fair Launch...'
  );

  // Get signers
  const [deployer, oracle1, oracle2, admin] = await ethers.getSigners();
  console.log('📋 Deploying contracts with account:', deployer.address);
  console.log(
    '💰 Account balance:',
    ethers.formatEther(await ethers.provider.getBalance(deployer.address))
  );

  // Deploy SocialVerification contract
  console.log('\n📝 Deploying SocialVerification contract...');
  const SocialVerification =
    await ethers.getContractFactory('SocialVerification');
  const socialVerification = await SocialVerification.deploy();
  await socialVerification.waitForDeployment();

  const socialVerificationAddress = await socialVerification.getAddress();
  console.log('✅ SocialVerification deployed to:', socialVerificationAddress);

  // Setup oracle authorization
  console.log('\n🔐 Setting up oracle authorization...');

  // Add multiple oracles for redundancy
  await socialVerification.setOracleAuthorization(oracle1.address, true);
  await socialVerification.setOracleAuthorization(oracle2.address, true);
  console.log('✅ Oracle 1 authorized:', oracle1.address);
  console.log('✅ Oracle 2 authorized:', oracle2.address);

  // Configure platform settings (optional customization)
  console.log('\n⚙️  Configuring platform settings...');

  // GitHub: 10% discount (can be increased for ecosystem contributors)
  await socialVerification.configurePlatform(0, true, 100_000); // GITHUB

  // Twitter: 5% discount
  await socialVerification.configurePlatform(1, true, 50_000); // TWITTER

  // LinkedIn: 7% discount
  await socialVerification.configurePlatform(2, true, 70_000); // LINKEDIN

  console.log('✅ Platform configurations updated');

  // Display deployment summary
  console.log('\n📊 Deployment Summary:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('Contract Address:      ', socialVerificationAddress);
  console.log('Max Social Discount:   ', '20%');
  console.log('Verification Period:   ', '365 days');
  console.log('GitHub Discount:       ', '10%');
  console.log('Twitter Discount:      ', '5%');
  console.log('LinkedIn Discount:     ', '7%');
  console.log('Rate Limit Cooldown:   ', '24 hours');
  console.log('Max Daily Verifications:', '50');
  console.log('Max Attempts:          ', '5');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  // Integration examples
  console.log('\n🔗 Integration Examples:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  // Example 1: Check if user has GitHub verification
  console.log('\n1️⃣  Check GitHub Verification:');
  console.log('```solidity');
  console.log(
    'bool hasGitHub = socialVerification.hasGitHubVerification(userAddress);'
  );
  console.log('```');

  // Example 2: Get combined social discount
  console.log('\n2️⃣  Get Combined Social Discount:');
  console.log('```solidity');
  console.log(
    '(uint256 totalDiscount, uint256[3] memory platformDiscounts, bool hasActive) = '
  );
  console.log('  socialVerification.getCombinedDiscount(userAddress);');
  console.log('```');

  // Example 3: Integration with DynamicStakeCalculator
  console.log('\n3️⃣  Integration with DynamicStakeCalculator:');
  console.log('```solidity');
  console.log('// In DynamicStakeCalculator.getSocialDiscount()');
  console.log(
    'uint256 socialMultiplier = socialVerification.getSocialVerificationDiscount(participant);'
  );
  console.log(
    'return socialMultiplier; // Returns multiplier (e.g., 0.8 for 20% discount)'
  );
  console.log('```');

  // Verification workflow example
  console.log('\n🔄 Verification Workflow:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('1. User submits verification with proof data');
  console.log('2. Oracle validates against platform APIs');
  console.log('3. Oracle marks verification as VERIFIED or REJECTED');
  console.log('4. User receives discount in staking calculations');
  console.log('5. Verification expires after 1 year (renewable)');

  // Generate sample verification submission
  console.log('\n📝 Sample Verification Submission:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

  const sampleIdentityFingerprint = {
    emailHash: ethers.keccak256(ethers.toUtf8Bytes('user@example.com')),
    phoneHash: ethers.keccak256(ethers.toUtf8Bytes('+1234567890')),
    deviceFingerprint: ethers.keccak256(ethers.toUtf8Bytes('device123')),
    behaviorFingerprint: ethers.keccak256(ethers.toUtf8Bytes('behavior123')),
    creationTimestamp: Math.floor(Date.now() / 1000),
  };

  const sampleGitHubData = ethers.AbiCoder.defaultAbiCoder().encode(
    ['uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'bool', 'string[]'],
    [
      180 * 24 * 60 * 60, // accountAge (6 months)
      15, // publicRepositories
      100, // commitsLastYear
      500, // contributionsScore
      1, // tier (CONTRIBUTOR)
      false, // ecosystemContributor
      ['awesome-repo', 'weather-app', 'blockchain-tools'], // topRepositories
    ]
  );

  console.log('GitHub Data Structure:');
  console.log('- Account Age: 6 months');
  console.log('- Public Repos: 15');
  console.log('- Commits/Year: 100');
  console.log('- Contribution Score: 500');
  console.log('- Tier: CONTRIBUTOR');
  console.log(
    '- Top Repositories: awesome-repo, weather-app, blockchain-tools'
  );

  // Oracle verification criteria
  console.log('\n🔍 Oracle Verification Criteria:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('GitHub Requirements:');
  console.log('  ✓ Account age ≥ 6 months');
  console.log('  ✓ Public repositories ≥ 10');
  console.log('  ✓ Commits in past year ≥ 50');
  console.log('  ✓ Active contributions to open source');
  console.log('  ✓ WRFCoin ecosystem contributions (bonus)');

  console.log('\nTwitter Requirements:');
  console.log('  ✓ Verified account (blue checkmark)');
  console.log('  ✓ Account age ≥ 1 year');
  console.log('  ✓ Followers ≥ 1,000');
  console.log('  ✓ Recent activity (last 3 months)');
  console.log('  ✓ No suspension history');

  console.log('\nLinkedIn Requirements:');
  console.log('  ✓ Professional profile completeness');
  console.log('  ✓ Connections ≥ 500');
  console.log('  ✓ Work experience verification');
  console.log('  ✓ Education background');
  console.log('  ✓ Industry endorsements');

  // Security features highlight
  console.log('\n🔒 Security Features:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('✅ Identity deduplication prevents multiple accounts');
  console.log('✅ Rate limiting prevents spam verification attempts');
  console.log('✅ EIP-712 signature verification for authenticity');
  console.log('✅ Oracle authorization with multi-signature support');
  console.log('✅ Time-based verification expiration (1 year)');
  console.log('✅ Emergency pause and admin controls');
  console.log('✅ Comprehensive audit trails and transparency');
  console.log('✅ Anti-replay protection for verification submissions');

  // Integration with fair launch contracts
  console.log('\n🏗️  Fair Launch Integration:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('The SocialVerification contract integrates with:');
  console.log(
    '• DynamicStakeCalculator - Provides social discount multipliers'
  );
  console.log(
    '• FairLaunchStakeManager - Receives staking discount calculations'
  );
  console.log('• ParticipantTypeRegistry - Tracks verification status');
  console.log('• WRFToken - Applies discounts to registration requirements');

  // Future enhancements
  console.log('\n🚀 Future Enhancements:');
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('• Additional platforms (Discord, Telegram, Medium)');
  console.log('• AI-powered behavioral analysis for fraud detection');
  console.log('• Cross-platform verification correlation');
  console.log('• Automated renewal before expiration');
  console.log('• Social graph analysis for authenticity scoring');
  console.log('• Integration with decentralized identity protocols');

  console.log('\n✨ SocialVerification deployment completed successfully!');
  console.log('🎯 Contract is ready for production use in WRFCoin fair launch');

  // Return deployment info for testing/integration
  return {
    socialVerification: socialVerificationAddress,
    deployer: deployer.address,
    oracle1: oracle1.address,
    oracle2: oracle2.address,
    admin: admin.address,
  };
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
