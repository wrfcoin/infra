const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

// Determine project root from script location
const SCRIPT_DIR = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, '..');

/**
 * Security Validation Script for NFT Royalty Calculation
 * Validates OWASP SC03 Arithmetic Issues protection
 */
async function validateArithmeticSecurity() {
  console.log('🔍 Starting NFT Royalty Calculation Security Validation');
  console.log('='.repeat(60));

  const securityReport = {
    timestamp: new Date().toISOString(),
    testsPassed: 0,
    testsFailed: 0,
    criticalIssues: [],
    warnings: [],
    recommendations: [],
  };

  try {
    // 1. Code Analysis - Check SafeMath usage
    console.log('\n📊 PHASE 1: Static Code Analysis');
    const contractPath = path.join(PROJECT_ROOT, 'contracts/SecureNFTMarketplace.sol');
    const contractCode = fs.readFileSync(contractPath, 'utf8');

    // Check Solidity version
    const solidityVersionMatch = contractCode.match(
      /pragma solidity \^?([\d\.]+)/
    );
    const solidityVersion = solidityVersionMatch
      ? solidityVersionMatch[1]
      : 'unknown';
    console.log(`✓ Solidity Version: ${solidityVersion}`);

    if (parseFloat(solidityVersion) >= 0.8) {
      securityReport.testsPassed++;
      console.log('✓ Using Solidity 0.8+ with built-in overflow protection');
    } else {
      securityReport.criticalIssues.push(
        'Using outdated Solidity version without built-in overflow protection'
      );
      securityReport.testsFailed++;
    }

    // Check for SafeMath usage patterns
    const safeMathImport = contractCode.includes(
      'import "@openzeppelin/contracts/utils/math/SafeMath.sol"'
    );
    const safeMathUsing = contractCode.includes('using SafeMath for uint256');
    const safeMathOperations = contractCode.match(/\.(add|sub|mul|div)\(/g);

    console.log(`📝 SafeMath Import: ${safeMathImport ? 'YES' : 'NO'}`);
    console.log(`📝 SafeMath Using: ${safeMathUsing ? 'YES' : 'NO'}`);
    console.log(
      `📝 SafeMath Operations: ${safeMathOperations ? safeMathOperations.length : 0}`
    );

    // 2. Check for critical arithmetic patterns
    console.log('\n🔒 PHASE 2: Critical Arithmetic Pattern Analysis');

    // Check for royalty calculation patterns
    const royaltyCalcRegex =
      /salePrice\s*\*\s*.*percentage.*\/.*BASIS_POINTS|percentage\s*\*\s*salePrice\s*\/.*BASIS_POINTS/g;
    const royaltyCalculations = contractCode.match(royaltyCalcRegex);

    if (royaltyCalculations) {
      console.log(
        `🔍 Found ${royaltyCalculations.length} royalty calculation patterns`
      );
      royaltyCalculations.forEach((calc, i) => {
        console.log(`   ${i + 1}. ${calc.trim()}`);
      });
      securityReport.testsPassed++;
    } else {
      console.log('⚠️  No explicit royalty calculation patterns found');
      securityReport.warnings.push(
        'Could not identify explicit royalty calculation patterns'
      );
    }

    // Check for percentage validation
    const percentageValidation = [
      /require\(.*percentage.*<=.*MAX_.*PERCENTAGE/,
      /require\(.*totalPercentage.*<=.*MAX_ROYALTY_PERCENTAGE/,
      /require\(.*percentage.*<=.*BASIS_POINTS/,
    ];

    let validationChecks = 0;
    percentageValidation.forEach((pattern, i) => {
      if (pattern.test(contractCode)) {
        validationChecks++;
        console.log(`✓ Percentage validation pattern ${i + 1} found`);
      }
    });

    if (validationChecks >= 2) {
      securityReport.testsPassed++;
      console.log('✓ Adequate percentage validation checks implemented');
    } else {
      securityReport.warnings.push(
        'Insufficient percentage validation patterns detected'
      );
    }

    // 3. Check for bounds checking
    console.log('\n🛡️  PHASE 3: Bounds Checking Analysis');

    const boundsChecks = [
      /require\(.*<=.*type\(uint256\)\.max/,
      /require\(.*>=.*MIN_/,
      /require\(.*<=.*MAX_/,
      /require\(.*> 0,/,
      /require\(.*!= address\(0\)/,
    ];

    let boundsFound = 0;
    boundsChecks.forEach((pattern, i) => {
      const matches = contractCode.match(pattern);
      if (matches) {
        boundsFound += matches.length;
      }
    });

    console.log(`📊 Total bounds checking patterns: ${boundsFound}`);
    if (boundsFound >= 10) {
      securityReport.testsPassed++;
      console.log('✓ Comprehensive bounds checking implemented');
    } else {
      securityReport.warnings.push(
        `Limited bounds checking detected (${boundsFound} patterns)`
      );
    }

    // 4. Check for reentrancy protection
    console.log('\n🔄 PHASE 4: Reentrancy Protection Analysis');

    const reentrancyProtection = [
      /import.*ReentrancyGuard/,
      /ReentrancyGuard/,
      /nonReentrant/,
    ];

    let reentrancyFound = 0;
    reentrancyProtection.forEach(pattern => {
      if (pattern.test(contractCode)) reentrancyFound++;
    });

    if (reentrancyFound >= 2) {
      securityReport.testsPassed++;
      console.log('✓ Reentrancy protection properly implemented');
    } else {
      securityReport.criticalIssues.push('Insufficient reentrancy protection');
      securityReport.testsFailed++;
    }

    // 5. Check for event emission on critical operations
    console.log('\n📡 PHASE 5: Security Event Analysis');

    const securityEvents = [
      /emit.*ArithmeticSecurityEvent/,
      /emit.*RoyaltyCalculationSecured/,
      /emit.*SecurityAlert/,
    ];

    let eventsFound = 0;
    securityEvents.forEach(pattern => {
      const matches = contractCode.match(pattern);
      if (matches) eventsFound += matches.length;
    });

    console.log(`📊 Security events found: ${eventsFound}`);
    if (eventsFound >= 3) {
      securityReport.testsPassed++;
      console.log('✓ Adequate security event emission');
    } else {
      securityReport.warnings.push(
        `Limited security event emission (${eventsFound} events)`
      );
    }

    // 6. Generate recommendations
    console.log('\n💡 PHASE 6: Security Recommendations');

    if (safeMathImport && parseFloat(solidityVersion) >= 0.8) {
      securityReport.recommendations.push(
        'Remove SafeMath import - Solidity 0.8+ has built-in overflow protection'
      );
      securityReport.recommendations.push(
        'Replace SafeMath operations with native arithmetic operators'
      );
    }

    securityReport.recommendations.push(
      'Ensure all arithmetic operations have proper bounds checking'
    );
    securityReport.recommendations.push(
      'Add comprehensive unit tests for edge cases (zero values, maximum values)'
    );
    securityReport.recommendations.push(
      'Implement fuzzing tests for arithmetic operations'
    );
    securityReport.recommendations.push(
      'Add gas optimization analysis for arithmetic operations'
    );

    // 7. Final assessment
    console.log('\n📋 PHASE 7: Final Security Assessment');

    const totalTests = securityReport.testsPassed + securityReport.testsFailed;
    const successRate =
      totalTests > 0 ? (securityReport.testsPassed / totalTests) * 100 : 0;

    console.log(`✅ Tests Passed: ${securityReport.testsPassed}`);
    console.log(`❌ Tests Failed: ${securityReport.testsFailed}`);
    console.log(`⚠️  Warnings: ${securityReport.warnings.length}`);
    console.log(`🚨 Critical Issues: ${securityReport.criticalIssues.length}`);
    console.log(`📊 Success Rate: ${successRate.toFixed(1)}%`);

    // Risk Assessment
    let riskLevel = 'LOW';
    if (securityReport.criticalIssues.length > 0) {
      riskLevel = 'CRITICAL';
    } else if (
      securityReport.testsFailed > 0 ||
      securityReport.warnings.length > 3
    ) {
      riskLevel = 'MEDIUM';
    }

    console.log(`🎯 Risk Level: ${riskLevel}`);

    // OWASP SC03 Compliance Assessment
    const sc03Compliant =
      parseFloat(solidityVersion) >= 0.8 &&
      boundsFound >= 10 &&
      reentrancyFound >= 2 &&
      securityReport.criticalIssues.length === 0;

    console.log(
      `\n🛡️  OWASP SC03 Compliance: ${sc03Compliant ? '✅ COMPLIANT' : '❌ NON-COMPLIANT'}`
    );

    // 8. Write detailed report
    const reportPath = path.join(PROJECT_ROOT, 'security_validation_report.json');
    securityReport.riskLevel = riskLevel;
    securityReport.sc03Compliant = sc03Compliant;
    securityReport.successRate = successRate;
    securityReport.summary = {
      solidityVersion,
      safeMathUsage: safeMathImport,
      boundsChecking: boundsFound,
      reentrancyProtection: reentrancyFound >= 2,
      securityEvents: eventsFound,
    };

    fs.writeFileSync(reportPath, JSON.stringify(securityReport, null, 2));
    console.log(`\n📄 Detailed report saved to: ${reportPath}`);

    return securityReport;
  } catch (error) {
    console.error('❌ Security validation failed:', error.message);
    securityReport.criticalIssues.push(
      `Validation script error: ${error.message}`
    );
    return securityReport;
  }
}

// Run validation if called directly
if (require.main === module) {
  validateArithmeticSecurity()
    .then(report => {
      console.log('\n🎉 Security validation completed!');
      process.exit(report.criticalIssues.length > 0 ? 1 : 0);
    })
    .catch(error => {
      console.error('❌ Validation failed:', error);
      process.exit(1);
    });
}

module.exports = { validateArithmeticSecurity };
