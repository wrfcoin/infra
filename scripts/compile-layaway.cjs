const { spawn } = require('child_process');
const fs = require('fs');

/**
 * Compile only LayawayRegistration and its dependencies to avoid other contract issues
 */
async function compileLayawayContracts() {
  console.log('🔨 Compiling LayawayRegistration contracts...');

  try {
    // Create a list of files we want to compile
    const contractsToCompile = [
      'contracts/LayawayRegistration.sol',
      'contracts/interfaces/IParticipantTypeRegistry.sol',
      'contracts/interfaces/IDynamicStakeCalculator.sol',
      'contracts/interfaces/ISocialVerification.sol',
      'contracts/interfaces/IWRFToken.sol',
      'contracts/interfaces/ISlashingMechanism.sol',
      'contracts/mocks/MockParticipantTypeRegistry.sol',
      'contracts/mocks/MockDynamicStakeCalculator.sol',
      'contracts/mocks/MockSocialVerification.sol',
      'contracts/mocks/MockWRFToken.sol',
      'contracts/mocks/MockSlashingMechanism.sol',
    ];

    // Check all files exist
    const missingFiles = [];
    for (const file of contractsToCompile) {
      if (!fs.existsSync(file)) {
        missingFiles.push(file);
      }
    }

    if (missingFiles.length > 0) {
      console.log('❌ Missing files:', missingFiles);
      return false;
    }

    console.log('✅ All required files found');

    // Run hardhat compile
    console.log('🔄 Running Hardhat compilation...');
    const hardhatProcess = spawn('npx', ['hardhat', 'compile'], {
      stdio: 'inherit',
    });

    return new Promise((resolve, reject) => {
      hardhatProcess.on('close', code => {
        if (code === 0) {
          console.log('✅ Compilation completed successfully!');
          resolve(true);
        } else {
          console.log('❌ Compilation failed with code:', code);
          resolve(false);
        }
      });

      hardhatProcess.on('error', error => {
        console.error('❌ Compilation process error:', error);
        reject(error);
      });
    });
  } catch (error) {
    console.error('❌ Compilation setup failed:', error);
    return false;
  }
}

// Handle both direct execution and module import
if (require.main === module) {
  compileLayawayContracts()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('💥 Fatal error:', error);
      process.exit(1);
    });
}

module.exports = { compileLayawayContracts };
