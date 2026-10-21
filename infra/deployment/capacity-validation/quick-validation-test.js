#!/usr/bin/env node

/**
 * Quick Capacity Validation Test
 * Validates the capacity validation framework with shorter test duration
 */

const CapacityValidationFramework = require('./capacity-validation-framework');

async function quickValidationTest() {
  console.log('🧪 Quick Capacity Validation Test');
  console.log('================================');

  const framework = new CapacityValidationFramework({
    baselineCapacity: 5000, // 5k TPS baseline
    targetCapacity: 10000, // 10k TPS target
    maxCapacity: 15000, // 15k TPS max
    phaseDuration: 5000, // 5 second phases
    warmupDuration: 1000, // 1 second warmup
    monitoring: {
      enabled: true,
      interval: 1000, // 1 second monitoring
    },
  });

  try {
    // Initialize framework
    console.log('\n🏗️  Initializing Framework...');
    await framework.initialize();
    console.log('✅ Framework initialized successfully');

    // Run baseline validation only
    console.log('\n📏 Running Baseline Validation (10k TPS)...');
    const baselineResult = await framework.executeBaselineValidation();

    console.log('\n📊 Baseline Results:');
    console.log(`   Target TPS: ${baselineResult.targetCapacity}`);
    console.log(`   Achieved TPS: ${baselineResult.actualTPS || 'N/A'}`);
    console.log(`   Success Rate: ${baselineResult.successRate || 'N/A'}%`);
    console.log(`   Grade: ${baselineResult.grade || 'N/A'}`);
    console.log(`   Status: ${baselineResult.status}`);

    // Generate quick report
    console.log('\n📋 Generating Quick Report...');
    const report = await framework.generateCapacityReport();

    console.log('\n🎯 Summary:');
    console.log(`   Overall Grade: ${report.overallGrade}`);
    console.log(`   Test Duration: ${report.totalDuration}ms`);
    console.log(`   Components Tested: ${report.componentsValidated}`);

    console.log('\n✅ Quick validation test completed successfully!');
    return true;
  } catch (error) {
    console.error('\n❌ Quick validation test failed:', error.message);
    return false;
  }
}

// Run the test
if (require.main === module) {
  quickValidationTest()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('Fatal error:', error);
      process.exit(1);
    });
}

module.exports = quickValidationTest;
