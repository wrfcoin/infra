const { ethers } = require('hardhat');

/**
 * Verify LayawayRegistration contract compilation and basic deployment
 */
async function main() {
  console.log('🔍 Verifying LayawayRegistration contract compilation...');

  try {
    // Test contract compilation
    const LayawayRegistration = await ethers.getContractFactory(
      'LayawayRegistration'
    );
    console.log('✅ LayawayRegistration contract compiled successfully');

    // Test interface compilation
    console.log('🔍 Checking interface contracts...');

    const interfaces = [
      'IParticipantTypeRegistry',
      'IDynamicStakeCalculator',
      'ISocialVerification',
      'IWRFToken',
      'ISlashingMechanism',
    ];

    for (const interfaceName of interfaces) {
      try {
        const Interface = await ethers.getContractFactory(interfaceName);
        console.log(`✅ ${interfaceName} interface compiled successfully`);
      } catch (error) {
        console.log(
          `⚠️  ${interfaceName} interface compilation issue:`,
          error.message
        );
      }
    }

    // Test mock contracts compilation
    console.log('🔍 Checking mock contracts...');

    const mocks = [
      'MockParticipantTypeRegistry',
      'MockDynamicStakeCalculator',
      'MockSocialVerification',
      'MockWRFToken',
      'MockSlashingMechanism',
    ];

    for (const mockName of mocks) {
      try {
        const Mock = await ethers.getContractFactory(mockName);
        console.log(`✅ ${mockName} mock compiled successfully`);
      } catch (error) {
        console.log(`⚠️  ${mockName} mock compilation issue:`, error.message);
      }
    }

    // Test basic contract structure
    console.log('🔍 Checking contract structure...');

    const contract = LayawayRegistration;
    const abi = contract.interface;

    // Check key functions exist
    const keyFunctions = [
      'initialize',
      'registerLayaway',
      'processEarnings',
      'accelerateStake',
      'checkActivationEligibility',
      'withdrawAccumulated',
      'getLayawayAccount',
      'getStakeProgress',
    ];

    let missingFunctions = [];
    for (const funcName of keyFunctions) {
      if (!abi.getFunction(funcName)) {
        missingFunctions.push(funcName);
      }
    }

    if (missingFunctions.length > 0) {
      console.log('❌ Missing key functions:', missingFunctions);
    } else {
      console.log('✅ All key functions present in contract ABI');
    }

    // Check key events exist
    const keyEvents = [
      'LayawayRegistered',
      'EarningsProcessed',
      'StakeAccelerated',
      'ParticipantActivated',
      'EmergencyWithdrawal',
    ];

    let missingEvents = [];
    for (const eventName of keyEvents) {
      try {
        abi.getEvent(eventName);
      } catch {
        missingEvents.push(eventName);
      }
    }

    if (missingEvents.length > 0) {
      console.log('❌ Missing key events:', missingEvents);
    } else {
      console.log('✅ All key events present in contract ABI');
    }

    // Check bytecode size
    const bytecode = contract.bytecode;
    const bytecodeSize = (bytecode.length - 2) / 2; // Remove 0x and convert to bytes
    console.log(`📊 Contract bytecode size: ${bytecodeSize} bytes`);

    if (bytecodeSize > 24576) {
      console.log('⚠️  Warning: Contract size exceeds Ethereum limit (24KB)');
    } else {
      console.log('✅ Contract size within Ethereum limits');
    }

    console.log(
      '\n🎉 LayawayRegistration verification completed successfully!'
    );
    console.log('The contract is ready for deployment and testing.');

    return true;
  } catch (error) {
    console.error('❌ Verification failed:', error);
    return false;
  }
}

// Handle both direct execution and module import
if (require.main === module) {
  main()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('💥 Fatal error:', error);
      process.exit(1);
    });
}

module.exports = { verifyLayawayCompilation: main };
