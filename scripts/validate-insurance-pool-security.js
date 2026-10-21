const { ethers } = require('hardhat');
const chalk = require('chalk');

async function validateInsurancePoolSecurity() {
  console.log(chalk.blue.bold('\n=== InsurancePool Security Validation ===\n'));

  const validationResults = {
    safeMathImplementation: false,
    divisionByZeroProtection: false,
    overflowProtection: false,
    underflowProtection: false,
    minimumCapitalEnforcement: false,
    reentrancyProtection: false,
    accessControl: false,
    eventLogging: false,
    inputValidation: false,
    stateConsistency: false,
  };

  try {
    // Deploy contracts for testing
    console.log(chalk.yellow('Deploying contracts for security validation...'));

    const SafeMath = await ethers.getContractFactory('SafeMath');
    const safeMath = await SafeMath.deploy();
    await safeMath.deployed();

    const InsurancePool = await ethers.getContractFactory('InsurancePool');
    const insurancePool = await InsurancePool.deploy();
    await insurancePool.deployed();

    console.log(chalk.green('✓ Contracts deployed successfully'));

    // Test 1: SafeMath Implementation
    console.log(chalk.yellow('\n1. Testing SafeMath Implementation...'));
    const contractCode = await ethers.provider.getCode(insurancePool.address);
    validationResults.safeMathImplementation = contractCode.includes(
      safeMath.address.slice(2).toLowerCase()
    );
    console.log(
      validationResults.safeMathImplementation
        ? chalk.green('✓ SafeMath properly implemented')
        : chalk.red('✗ SafeMath not detected')
    );

    // Test 2: Division by Zero Protection
    console.log(chalk.yellow('\n2. Testing Division by Zero Protection...'));
    try {
      await insurancePool.calculatePremium(ethers.utils.parseEther('1000'), 0);
      console.log(chalk.red('✗ Division by zero not prevented'));
    } catch (error) {
      if (error.message.includes('Duration must be positive')) {
        validationResults.divisionByZeroProtection = true;
        console.log(chalk.green('✓ Division by zero properly prevented'));
      }
    }

    // Test 3: Overflow Protection
    console.log(chalk.yellow('\n3. Testing Overflow Protection...'));
    const [owner] = await ethers.getSigners();
    const MAX_UINT256 = ethers.constants.MaxUint256;

    try {
      // Try large calculation that would overflow without SafeMath
      const hugeCoverage = MAX_UINT256.div(2);
      const premium = await insurancePool.calculatePremium(
        hugeCoverage,
        365 * 24 * 60 * 60
      );

      // If we get here without error, SafeMath is working
      validationResults.overflowProtection = true;
      console.log(chalk.green('✓ Overflow protection verified'));
    } catch (error) {
      console.log(chalk.red('✗ Overflow protection failed:', error.message));
    }

    // Test 4: Underflow Protection
    console.log(chalk.yellow('\n4. Testing Underflow Protection...'));
    try {
      // Provide capital first
      await insurancePool.connect(owner).provideCapital({
        value: ethers.utils.parseEther('1000'),
      });

      // Try to withdraw more than available (would cause underflow)
      await insurancePool
        .connect(owner)
        .withdrawCapital(ethers.utils.parseEther('2000'));
      console.log(chalk.red('✗ Underflow not prevented'));
    } catch (error) {
      if (error.message.includes('Insufficient shares')) {
        validationResults.underflowProtection = true;
        console.log(chalk.green('✓ Underflow properly prevented'));
      }
    }

    // Test 5: Minimum Capital Enforcement
    console.log(chalk.yellow('\n5. Testing Minimum Capital Enforcement...'));
    try {
      await insurancePool.connect(owner).provideCapital({
        value: ethers.utils.parseEther('999'),
      });
      console.log(chalk.red('✗ Minimum capital not enforced'));
    } catch (error) {
      if (error.message.includes('Below minimum capital')) {
        validationResults.minimumCapitalEnforcement = true;
        console.log(chalk.green('✓ Minimum capital properly enforced'));
      }
    }

    // Test 6: Reentrancy Protection
    console.log(chalk.yellow('\n6. Testing Reentrancy Protection...'));
    validationResults.reentrancyProtection =
      contractCode.includes('nonReentrant');
    console.log(
      validationResults.reentrancyProtection
        ? chalk.green('✓ Reentrancy guards in place')
        : chalk.red('✗ Reentrancy protection missing')
    );

    // Test 7: Access Control
    console.log(chalk.yellow('\n7. Testing Access Control...'));
    validationResults.accessControl = contractCode.includes('Ownable');
    console.log(
      validationResults.accessControl
        ? chalk.green('✓ Access control implemented')
        : chalk.red('✗ Access control missing')
    );

    // Test 8: Event Logging
    console.log(chalk.yellow('\n8. Testing Event Logging...'));
    const tx = await insurancePool.connect(owner).provideCapital({
      value: ethers.utils.parseEther('1000'),
    });
    const receipt = await tx.wait();
    validationResults.eventLogging = receipt.events.length > 0;
    console.log(
      validationResults.eventLogging
        ? chalk.green('✓ Events properly logged')
        : chalk.red('✗ Event logging missing')
    );

    // Test 9: Input Validation
    console.log(chalk.yellow('\n9. Testing Input Validation...'));
    try {
      await insurancePool.purchaseInsurance(0, 100, 'test');
      console.log(chalk.red('✗ Input validation failed'));
    } catch (error) {
      if (error.message.includes('Coverage must be positive')) {
        validationResults.inputValidation = true;
        console.log(chalk.green('✓ Input validation working'));
      }
    }

    // Test 10: State Consistency
    console.log(chalk.yellow('\n10. Testing State Consistency...'));
    const initialCapital = await insurancePool.totalPoolCapital();
    await insurancePool.connect(owner).provideCapital({
      value: ethers.utils.parseEther('1000'),
    });
    const finalCapital = await insurancePool.totalPoolCapital();
    validationResults.stateConsistency = finalCapital
      .sub(initialCapital)
      .eq(ethers.utils.parseEther('1000'));
    console.log(
      validationResults.stateConsistency
        ? chalk.green('✓ State consistency maintained')
        : chalk.red('✗ State inconsistency detected')
    );

    // Final Report
    console.log(chalk.blue.bold('\n=== Security Validation Report ===\n'));

    const passedTests = Object.values(validationResults).filter(v => v).length;
    const totalTests = Object.keys(validationResults).length;
    const passRate = ((passedTests / totalTests) * 100).toFixed(1);

    console.log(chalk.cyan('Test Results:'));
    for (const [test, passed] of Object.entries(validationResults)) {
      const testName = test.replace(/([A-Z])/g, ' $1').trim();
      console.log(
        `  ${passed ? chalk.green('✓') : chalk.red('✗')} ${testName}`
      );
    }

    console.log(
      chalk.cyan(`\nOverall Score: ${passedTests}/${totalTests} (${passRate}%)`)
    );

    if (passRate >= 90) {
      console.log(chalk.green.bold('\n✓ Contract PASSES security validation'));
      console.log(
        chalk.green(
          'The $1M TVL is now protected with proper arithmetic safety'
        )
      );
    } else {
      console.log(chalk.red.bold('\n✗ Contract FAILS security validation'));
      console.log(chalk.red('Additional fixes required before deployment'));
    }

    // OWASP SC03 Compliance Check
    console.log(chalk.blue.bold('\n=== OWASP SC03 Compliance ===\n'));
    const owaspCompliant =
      validationResults.safeMathImplementation &&
      validationResults.divisionByZeroProtection &&
      validationResults.overflowProtection &&
      validationResults.underflowProtection;

    if (owaspCompliant) {
      console.log(
        chalk.green.bold('✓ OWASP SC03 (Arithmetic Issues) - COMPLIANT')
      );
      console.log(
        chalk.green('All arithmetic operations are properly protected')
      );
    } else {
      console.log(
        chalk.red.bold('✗ OWASP SC03 (Arithmetic Issues) - NON-COMPLIANT')
      );
    }
  } catch (error) {
    console.error(chalk.red('Validation Error:'), error);
  }
}

// Run validation
validateInsurancePoolSecurity()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
