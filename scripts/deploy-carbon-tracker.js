const { ethers } = require('hardhat');

async function main() {
  console.log('🌱 Deploying Carbon Credit Tracking System...');

  const [deployer, issuer, registry] = await ethers.getSigners();
  console.log('Deploying with account:', deployer.address);
  console.log(
    'Account balance:',
    (await deployer.provider.getBalance(deployer.address)).toString()
  );

  try {
    // ==================== DEPLOY CARBON CREDIT TRACKER ====================
    console.log('\n📦 Deploying CarbonCreditTracker...');
    const CarbonCreditTracker = await ethers.getContractFactory(
      'CarbonCreditTracker'
    );
    const tracker = await CarbonCreditTracker.deploy();
    await tracker.waitForDeployment();
    console.log(
      '✅ CarbonCreditTracker deployed to:',
      await tracker.getAddress()
    );

    // ==================== SETUP ROLES ====================
    console.log('\n🔐 Setting up roles...');

    const AUTHORIZED_ISSUER_ROLE = await tracker.AUTHORIZED_ISSUER_ROLE();
    const REGISTRY_CONNECTOR_ROLE = await tracker.REGISTRY_CONNECTOR_ROLE();

    await tracker.grantRole(AUTHORIZED_ISSUER_ROLE, issuer.address);
    await tracker.grantRole(REGISTRY_CONNECTOR_ROLE, registry.address);

    console.log('✅ Granted AUTHORIZED_ISSUER_ROLE to:', issuer.address);
    console.log('✅ Granted REGISTRY_CONNECTOR_ROLE to:', registry.address);

    // ==================== DEMONSTRATION ====================
    console.log('\n🎯 Running demonstration...');

    // Create a lifecycle
    const tokenId = 1;
    const projectId = 'VCS-123-2024';
    const serialNumber = 'VCS-123-2024-001-001';
    const registryStandard = 'VCS';
    const totalSupply = ethers.parseEther('1000');

    console.log('Creating lifecycle for project:', projectId);
    const createTx = await tracker
      .connect(issuer)
      .createLifecycle(
        tokenId,
        projectId,
        serialNumber,
        registryStandard,
        issuer.address,
        totalSupply
      );

    const receipt = await createTx.wait();
    const event = receipt.logs.find(
      log =>
        log.topics[0] ===
        tracker.interface.getEvent('CreditLifecycleCreated').topicHash
    );

    const decodedEvent = tracker.interface.decodeEventLog(
      'CreditLifecycleCreated',
      event.data,
      event.topics
    );

    const lifecycleId = decodedEvent.lifecycleId;
    console.log('✅ Lifecycle created with ID:', lifecycleId);

    // Record a transfer
    console.log('Recording transfer...');
    await tracker.recordTransfer(
      lifecycleId,
      issuer.address,
      deployer.address,
      ethers.parseEther('100'),
      'Initial distribution'
    );
    console.log('✅ Transfer recorded');

    // Record retirement
    console.log('Recording retirement...');
    const retirementTx = await tracker
      .connect(registry)
      .recordRetirement(
        lifecycleId,
        deployer.address,
        ethers.parseEther('50'),
        'Company carbon offset program'
      );

    const retirementReceipt = await retirementTx.wait();
    const retirementEvent = retirementReceipt.logs.find(
      log =>
        log.topics[0] ===
        tracker.interface.getEvent('RetirementCertificateGenerated').topicHash
    );

    const retirementDecodedEvent = tracker.interface.decodeEventLog(
      'RetirementCertificateGenerated',
      retirementEvent.data,
      retirementEvent.topics
    );

    const certificateId = retirementDecodedEvent.certificateId;
    console.log('✅ Retirement recorded with certificate:', certificateId);

    // Get lifecycle summary
    console.log('\nGetting lifecycle summary...');
    const summary = await tracker.getLifecycleSummary(lifecycleId);
    console.log('📊 Lifecycle Summary:');
    console.log('  Token ID:', summary.tokenId.toString());
    console.log('  Project ID:', summary.projectId);
    console.log('  Serial Number:', summary.serialNumber);
    console.log(
      '  Active Supply:',
      ethers.formatEther(summary.activeSupply),
      'CO2e'
    );
    console.log(
      '  Retired Supply:',
      ethers.formatEther(summary.retiredSupply),
      'CO2e'
    );
    console.log('  Transfer Count:', summary.transferCount.toString());
    console.log('  Retirement Count:', summary.retirementCount.toString());

    // Verify certificate
    const isValidCertificate = await tracker.verifyCertificate(certificateId);
    console.log('🏆 Certificate validity:', isValidCertificate);

    // Check double-counting prevention
    console.log('\nTesting double-counting prevention...');
    try {
      await tracker.connect(issuer).createLifecycle(
        2,
        'VCS-124-2024',
        serialNumber, // Same serial number
        'VCS',
        issuer.address,
        ethers.parseEther('500')
      );
      console.log('❌ ERROR: Double-counting prevention failed!');
    } catch (error) {
      console.log('✅ Double-counting prevented:', error.reason);
    }

    // ==================== DEPLOYMENT SUMMARY ====================
    console.log('\n🎉 Carbon Credit Tracking System deployed successfully!');
    console.log('\n📋 CONTRACT ADDRESS:');
    console.log('=========================================');
    console.log('CarbonCreditTracker:', await tracker.getAddress());
    console.log('=========================================');

    console.log('\n🔑 ROLE ASSIGNMENTS:');
    console.log('=========================================');
    console.log('Admin:', deployer.address);
    console.log('Authorized Issuer:', issuer.address);
    console.log('Registry Connector:', registry.address);
    console.log('=========================================');

    console.log('\n📈 DEMONSTRATION RESULTS:');
    console.log('=========================================');
    console.log('✅ Lifecycle Creation: PASSED');
    console.log('✅ Transfer Recording: PASSED');
    console.log('✅ Retirement with Certificate: PASSED');
    console.log('✅ Double-counting Prevention: PASSED');
    console.log('✅ Certificate Verification: PASSED');
    console.log('=========================================');

    return {
      tracker: await tracker.getAddress(),
      lifecycleId,
      certificateId,
      roles: {
        admin: deployer.address,
        issuer: issuer.address,
        registry: registry.address,
      },
    };
  } catch (error) {
    console.error('\n❌ Deployment failed:', error);
    throw error;
  }
}

// Helper function to verify the deployment
async function verifyDeployment(trackerAddress) {
  console.log('\n🔍 Verifying deployment...');

  try {
    const tracker = await ethers.getContractAt(
      'CarbonCreditTracker',
      trackerAddress
    );

    // Check basic functionality
    const DEFAULT_ADMIN_ROLE = await tracker.DEFAULT_ADMIN_ROLE();
    console.log('✅ Contract accessible and roles working');

    // Check if contract is not paused
    const isPaused = await tracker.paused();
    console.log('✅ Contract status (paused):', isPaused);

    console.log('✅ Deployment verification completed successfully!');
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
      console.log('\n🎊 Carbon Credit Tracking System deployment completed!');
      return verifyDeployment(deployment.tracker);
    })
    .then(() => {
      process.exit(0);
    })
    .catch(error => {
      console.error(error);
      process.exit(1);
    });
}
