const { ethers, upgrades } = require('hardhat');

async function main() {
  console.log('🚀 Deploying Carbon Credit Insurance Protocol...\n');

  const [deployer] = await ethers.getSigners();
  console.log('Deploying from account:', deployer.address);
  console.log(
    'Account balance:',
    ethers.formatEther(await deployer.provider.getBalance(deployer.address)),
    'ETH\n'
  );

  // Contract factories
  const WRFToken = await ethers.getContractFactory('WRFToken');
  const EnhancedCarbonCredits = await ethers.getContractFactory(
    'EnhancedCarbonCredits'
  );
  const QualityOracle = await ethers.getContractFactory('QualityOracle');
  const VolatilityOracle = await ethers.getContractFactory('VolatilityOracle');
  const InsurancePool = await ethers.getContractFactory('InsurancePool');
  const InsuranceGovernance = await ethers.getContractFactory(
    'InsuranceGovernance'
  );
  const CarbonCreditInsurance = await ethers.getContractFactory(
    'CarbonCreditInsurance'
  );

  // Check if WRF Token and Carbon Credits are already deployed
  let wrfToken, carbonCredits, qualityOracle, volatilityOracle;

  const network = await ethers.provider.getNetwork();
  console.log(
    `Deploying to network: ${network.name} (Chain ID: ${network.chainId})\n`
  );

  try {
    // Try to get existing contract addresses from environment or config
    const WRF_TOKEN_ADDRESS = process.env.WRF_TOKEN_ADDRESS;
    const CARBON_CREDITS_ADDRESS = process.env.CARBON_CREDITS_ADDRESS;
    const QUALITY_ORACLE_ADDRESS = process.env.QUALITY_ORACLE_ADDRESS;
    const VOLATILITY_ORACLE_ADDRESS = process.env.VOLATILITY_ORACLE_ADDRESS;

    if (WRF_TOKEN_ADDRESS) {
      console.log('📋 Using existing WRF Token at:', WRF_TOKEN_ADDRESS);
      wrfToken = await WRFToken.attach(WRF_TOKEN_ADDRESS);
    } else {
      console.log('📋 Deploying WRF Token...');
      wrfToken = await WRFToken.deploy();
      await wrfToken.waitForDeployment();
      console.log('✅ WRF Token deployed to:', wrfToken.target);
    }

    if (CARBON_CREDITS_ADDRESS) {
      console.log(
        '📋 Using existing Enhanced Carbon Credits at:',
        CARBON_CREDITS_ADDRESS
      );
      carbonCredits = await EnhancedCarbonCredits.attach(
        CARBON_CREDITS_ADDRESS
      );
    } else {
      console.log('📋 Deploying Enhanced Carbon Credits...');
      carbonCredits = await EnhancedCarbonCredits.deploy(wrfToken.target);
      await carbonCredits.waitForDeployment();
      console.log(
        '✅ Enhanced Carbon Credits deployed to:',
        carbonCredits.target
      );
    }

    if (QUALITY_ORACLE_ADDRESS) {
      console.log(
        '📋 Using existing Quality Oracle at:',
        QUALITY_ORACLE_ADDRESS
      );
      qualityOracle = await QualityOracle.attach(QUALITY_ORACLE_ADDRESS);
    } else {
      console.log('📋 Deploying Quality Oracle...');
      qualityOracle = await QualityOracle.deploy();
      await qualityOracle.waitForDeployment();
      console.log('✅ Quality Oracle deployed to:', qualityOracle.target);
    }

    if (VOLATILITY_ORACLE_ADDRESS) {
      console.log(
        '📋 Using existing Volatility Oracle at:',
        VOLATILITY_ORACLE_ADDRESS
      );
      volatilityOracle = await VolatilityOracle.attach(
        VOLATILITY_ORACLE_ADDRESS
      );
    } else {
      console.log('📋 Deploying Volatility Oracle...');
      volatilityOracle = await VolatilityOracle.deploy();
      await volatilityOracle.waitForDeployment();
      console.log('✅ Volatility Oracle deployed to:', volatilityOracle.target);
    }
  } catch (error) {
    console.error('Error with existing contracts, deploying new ones...');

    console.log('📋 Deploying WRF Token...');
    wrfToken = await WRFToken.deploy();
    await wrfToken.waitForDeployment();
    console.log('✅ WRF Token deployed to:', wrfToken.target);

    console.log('📋 Deploying Enhanced Carbon Credits...');
    carbonCredits = await EnhancedCarbonCredits.deploy(wrfToken.target);
    await carbonCredits.waitForDeployment();
    console.log(
      '✅ Enhanced Carbon Credits deployed to:',
      carbonCredits.target
    );

    console.log('📋 Deploying Quality Oracle...');
    qualityOracle = await QualityOracle.deploy();
    await qualityOracle.waitForDeployment();
    console.log('✅ Quality Oracle deployed to:', qualityOracle.target);

    console.log('📋 Deploying Volatility Oracle...');
    volatilityOracle = await VolatilityOracle.deploy();
    await volatilityOracle.waitForDeployment();
    console.log('✅ Volatility Oracle deployed to:', volatilityOracle.target);
  }

  console.log('\n🏦 Deploying Insurance Protocol Components...\n');

  // Deploy Insurance Pool
  console.log('📋 Deploying Insurance Pool...');
  const insurancePool = await InsurancePool.deploy(wrfToken.target);
  await insurancePool.waitForDeployment();
  console.log('✅ Insurance Pool deployed to:', insurancePool.target);

  // Deploy Insurance Governance
  console.log('📋 Deploying Insurance Governance...');
  const insuranceGovernance = await InsuranceGovernance.deploy(wrfToken.target);
  await insuranceGovernance.waitForDeployment();
  console.log(
    '✅ Insurance Governance deployed to:',
    insuranceGovernance.target
  );

  // Deploy Main Insurance Contract
  console.log('📋 Deploying Carbon Credit Insurance...');
  const insurance = await CarbonCreditInsurance.deploy(
    carbonCredits.target,
    wrfToken.target,
    qualityOracle.target,
    volatilityOracle.target
  );
  await insurance.waitForDeployment();
  console.log('✅ Carbon Credit Insurance deployed to:', insurance.target);

  console.log('\n🔧 Setting up contract connections and roles...\n');

  // Set up insurance contract connections
  console.log('📋 Connecting insurance to pool and governance...');
  await insurance.setInsurancePool(insurancePool.target);
  await insurance.setGovernanceContract(insuranceGovernance.target);

  // Grant roles to insurance contract on pool
  console.log('📋 Granting insurance contract roles on pool...');
  const INSURANCE_CONTRACT_ROLE = await insurancePool.INSURANCE_CONTRACT_ROLE();
  const CLAIMS_PAYER_ROLE = await insurancePool.CLAIMS_PAYER_ROLE();

  await insurancePool.grantRole(INSURANCE_CONTRACT_ROLE, insurance.target);
  await insurancePool.grantRole(CLAIMS_PAYER_ROLE, insurance.target);

  // Set up governance connections
  console.log('📋 Connecting governance to insurance and pool...');
  await insuranceGovernance.setInsuranceContract(insurance.target);
  await insuranceGovernance.setInsurancePool(insurancePool.target);

  // Grant necessary roles on carbon credits if we deployed it
  if (!process.env.CARBON_CREDITS_ADDRESS) {
    console.log('📋 Granting roles on carbon credits...');
    const AUTHORIZED_ISSUER_ROLE = await carbonCredits.AUTHORIZED_ISSUER_ROLE();
    await carbonCredits.grantRole(AUTHORIZED_ISSUER_ROLE, deployer.address);
  }

  // Grant oracle roles
  console.log('📋 Granting oracle roles...');
  const ORACLE_UPDATER_ROLE = await qualityOracle.ORACLE_UPDATER_ROLE();
  const PRICE_FEEDER_ROLE = await volatilityOracle.PRICE_FEEDER_ROLE();

  await qualityOracle.grantRole(ORACLE_UPDATER_ROLE, deployer.address);
  await volatilityOracle.grantRole(PRICE_FEEDER_ROLE, deployer.address);

  console.log('\n🧪 Setting up initial test data...\n');

  // Create a sample carbon credit batch for testing
  if (!process.env.CARBON_CREDITS_ADDRESS) {
    console.log('📋 Creating sample carbon credit batch...');

    const totalSupply = 10000; // 10,000 kg CO2e
    const vintage = 2024;
    const expiryDate = Math.floor(Date.now() / 1000) + 365 * 24 * 60 * 60; // 1 year

    try {
      await carbonCredits.createBatch(
        totalSupply,
        'SAMPLE-PROJECT-001',
        vintage,
        'VM0034',
        'renewable-energy',
        'VCS',
        'Global',
        expiryDate,
        'QmSampleHash123...',
        'https://registry.verra.org/SAMPLE-PROJECT-001',
        'https://metadata.uri/sample-project-001'
      );
      console.log('✅ Sample carbon credit batch created (Token ID: 1)');

      // Immobilize some credits for the deployer
      await carbonCredits.immobilizeCredits(1, 5000, deployer.address);
      console.log('✅ Immobilized 5000 credits for deployer');
    } catch (error) {
      console.log('⚠️  Could not create sample batch (may already exist)');
    }
  }

  // Set up initial oracle data
  console.log('📋 Setting up initial oracle data...');
  try {
    await qualityOracle.updateQualityScore(
      carbonCredits.target,
      750, // Good quality score
      'Initial deployment quality assessment'
    );
    console.log('✅ Initial quality score set to 750');

    await volatilityOracle.updateVolatility(
      carbonCredits.target,
      wrfToken.target,
      ethers.parseEther('50') // 50 WRF per tonne
    );
    console.log('✅ Initial volatility data set');
  } catch (error) {
    console.log('⚠️  Could not set initial oracle data:', error.message);
  }

  console.log('\n📊 Deployment Summary:\n');
  console.log('='.repeat(60));
  console.log('🪙  WRF Token:                 ', wrfToken.target);
  console.log('🌱  Enhanced Carbon Credits:   ', carbonCredits.target);
  console.log('📊  Quality Oracle:            ', qualityOracle.target);
  console.log('📈  Volatility Oracle:         ', volatilityOracle.target);
  console.log('🏦  Insurance Pool:            ', insurancePool.target);
  console.log('🗳️   Insurance Governance:     ', insuranceGovernance.target);
  console.log('🛡️  Carbon Credit Insurance:   ', insurance.target);
  console.log('='.repeat(60));

  console.log('\n🔑 Role Setup Summary:\n');
  console.log('✅ Insurance contract has pool management roles');
  console.log('✅ Governance connected to insurance and pool');
  console.log('✅ Oracle update roles granted to deployer');
  console.log('✅ Sample data initialized');

  console.log('\n📝 Next Steps:\n');
  console.log('1. Verify contracts on block explorer');
  console.log('2. Set up frontend integration');
  console.log('3. Configure additional oracle data sources');
  console.log('4. Test insurance policy creation and claims');
  console.log('5. Set up governance proposals for parameter updates');

  // Save deployment addresses
  const deploymentInfo = {
    network: network.name,
    chainId: network.chainId,
    timestamp: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      wrfToken: wrfToken.target,
      carbonCredits: carbonCredits.target,
      qualityOracle: qualityOracle.target,
      volatilityOracle: volatilityOracle.target,
      insurancePool: insurancePool.target,
      insuranceGovernance: insuranceGovernance.target,
      carbonCreditInsurance: insurance.target,
    },
  };

  console.log('\n💾 Saving deployment info to deployments.json...');

  const fs = require('fs');
  const path = require('path');

  const deploymentsDir = path.join(__dirname, '..', 'deployments');
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir);
  }

  const deploymentPath = path.join(
    deploymentsDir,
    `${network.name}-insurance-deployment.json`
  );
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));

  console.log('✅ Deployment info saved to:', deploymentPath);

  console.log(
    '\n🎉 Carbon Credit Insurance Protocol deployment completed successfully! 🎉'
  );
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error('❌ Deployment failed:', error);
    process.exit(1);
  });
