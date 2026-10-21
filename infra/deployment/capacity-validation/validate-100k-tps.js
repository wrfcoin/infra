#!/usr/bin/env node

/**
 * 100k TPS Validation Test
 * Tests the system's ability to handle 100,000+ TPS sustained performance
 */

const CapacityValidationFramework = require('./capacity-validation-framework');

async function validate100kTPS() {
  console.log('🎯 100k TPS Capacity Validation');
  console.log('==============================');
  console.log('Target: 100,000+ TPS sustained performance');
  console.log('Testing progressive scaling from 10k → 100k TPS\n');

  const framework = new CapacityValidationFramework({
    baselineCapacity: 10000, // 10k TPS baseline
    targetCapacity: 100000, // 100k TPS target
    maxCapacity: 150000, // 150k TPS max
    phaseDuration: 10000, // 10 second phases
    warmupDuration: 2000, // 2 second warmup
    incrementStrategy: 'logarithmic',
    monitoring: {
      enabled: true,
      interval: 2000, // 2 second monitoring
    },
  });

  try {
    console.log('🏗️  Initializing Framework...');
    await framework.initialize();
    console.log('✅ Framework initialized');

    console.log('\n📏 Phase 1: Baseline Validation (10k TPS)');
    const baselineResult = await framework.executeBaselineValidation();
    console.log(
      `   Result: ${baselineResult.status} - ${baselineResult.actualTPS || 'N/A'} TPS`
    );

    if (baselineResult.status !== 'PASSED') {
      console.log(
        '❌ Baseline validation failed, cannot proceed to 100k TPS test'
      );
      return false;
    }

    console.log('\n🚀 Phase 2: Incremental Capacity Testing');
    console.log(
      '   Testing progressive scaling: 10k → 25k → 50k → 75k → 100k TPS'
    );

    const incrementalResults =
      await framework.executeIncrementalCapacityTesting();

    console.log('\n📊 Incremental Test Results:');
    incrementalResults.phaseResults.forEach((phase, index) => {
      const status = phase.status === 'PASSED' ? '✅' : '❌';
      console.log(
        `   Phase ${index + 1}: ${status} ${phase.targetCapacity} TPS - ${phase.actualTPS || 'N/A'} achieved`
      );
    });

    // Check if we reached 100k TPS
    const reached100k = incrementalResults.phaseResults.some(
      phase => phase.actualTPS >= 100000 && phase.status === 'PASSED'
    );

    console.log('\n🎯 100k TPS Target Assessment:');
    if (reached100k) {
      console.log('✅ SUCCESS: 100,000+ TPS sustained performance achieved!');
    } else {
      const maxAchieved = Math.max(
        ...incrementalResults.phaseResults.map(p => p.actualTPS || 0)
      );
      console.log(
        `❌ Target not reached. Maximum achieved: ${maxAchieved} TPS`
      );
      console.log(
        '   Reasons: Hardware limitations, network bottlenecks, or optimization needed'
      );
    }

    // Generate comprehensive report
    console.log('\n📋 Generating Performance Report...');
    const report = await framework.generateCapacityReport();

    console.log('\n📈 Final Performance Summary:');
    console.log(`   Overall Grade: ${report.overallGrade}`);
    console.log(`   Peak TPS Achieved: ${report.peakTPS || 'N/A'}`);
    console.log(`   Bottlenecks Detected: ${report.bottlenecks?.length || 0}`);
    console.log(`   Total Test Duration: ${report.totalDuration}ms`);

    if (report.bottlenecks && report.bottlenecks.length > 0) {
      console.log('\n🔍 Performance Bottlenecks:');
      report.bottlenecks.slice(0, 3).forEach((bottleneck, index) => {
        console.log(
          `   ${index + 1}. ${bottleneck.component}: ${bottleneck.severity} - ${bottleneck.description}`
        );
      });
    }

    return reached100k;
  } catch (error) {
    console.error('\n❌ 100k TPS validation failed:', error.message);
    return false;
  }
}

// Run the validation
if (require.main === module) {
  validate100kTPS()
    .then(success => {
      console.log(
        success
          ? '\n🎉 100k TPS validation PASSED!'
          : '\n⚠️  100k TPS validation needs optimization'
      );
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      console.error('Fatal error:', error);
      process.exit(1);
    });
}

module.exports = validate100kTPS;
