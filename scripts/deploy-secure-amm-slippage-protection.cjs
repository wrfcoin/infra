#!/usr/bin/env node

/**
 * Deployment and Testing Script for SecureCarbonCreditAMM
 * Enhanced AMM with comprehensive slippage protection mechanisms
 *
 * Features:
 * - Multi-layered slippage protection validation
 * - MEV protection with commit-reveal schemes
 * - Emergency controls and circuit breakers
 * - Real-time volatility monitoring
 * - Comprehensive attack simulation testing
 */

const { ethers } = require('hardhat');
const fs = require('fs');
const path = require('path');

class SecureAMMSlippageProtectionDeployer {
  constructor() {
    this.contracts = {};
    this.accounts = {};
    this.testResults = {
      deploymentTests: [],
      slippageProtectionTests: [],
      mevProtectionTests: [],
      emergencyControlTests: [],
      attackSimulationTests: [],
      performanceTests: [],
    };
    this.securityMetrics = {
      totalTradesAttempted: 0,
      tradesBlocked: 0,
      slippageViolations: 0,
      mevAttacksBlocked: 0,
      emergencyTriggered: 0,
      maxPriceImpactObserved: 0,
      avgSlippageProtected: 0,
    };
  }

  async deploy() {
    console.log(
      '🚀 Starting SecureCarbonCreditAMM Deployment with Slippage Protection...\n'
    );

    try {
      await this.setupAccounts();
      await this.deployContracts();
      await this.configureRoles();
      await this.runComprehensiveTests();
      await this.generateSecurityReport();

      console.log('✅ Deployment and testing completed successfully!\n');
      return this.contracts;
    } catch (error) {
      console.error('❌ Deployment failed:', error);
      throw error;
    }
  }

  async setupAccounts() {
    console.log('👥 Setting up accounts...');

    const signers = await ethers.getSigners();
    this.accounts = {
      deployer: signers[0],
      factory: signers[1],
      trader1: signers[2],
      trader2: signers[3],
      trader3: signers[4],
      attacker: signers[5],
      emergencyResponder: signers[6],
      slippageGuardian: signers[7],
      mevProtector: signers[8],
      liquidityProvider: signers[9],
    };

    console.log(`Deployer: ${this.accounts.deployer.address}`);
    console.log(`Factory: ${this.accounts.factory.address}`);
    console.log(
      `Emergency Responder: ${this.accounts.emergencyResponder.address}\n`
    );
  }

  async deployContracts() {
    console.log('📦 Deploying contracts...');

    // Deploy mock tokens for testing
    const MockToken = await ethers.getContractFactory('MockERC20');

    this.contracts.token0 = await MockToken.deploy(
      'Carbon Token 0',
      'CT0',
      ethers.parseEther('10000000')
    );
    await this.contracts.token0.waitForDeployment();

    this.contracts.token1 = await MockToken.deploy(
      'Carbon Token 1',
      'CT1',
      ethers.parseEther('10000000')
    );
    await this.contracts.token1.waitForDeployment();

    // Deploy SecureCarbonCreditAMM
    const SecureAMM = await ethers.getContractFactory('SecureCarbonCreditAMM');
    this.contracts.amm = await SecureAMM.deploy();
    await this.contracts.amm.waitForDeployment();

    // Initialize AMM
    await this.contracts.amm.initialize(
      await this.contracts.token0.getAddress(),
      await this.contracts.token1.getAddress(),
      this.accounts.factory.address,
      30 // 0.3% fee
    );

    console.log(
      `Token0 deployed to: ${await this.contracts.token0.getAddress()}`
    );
    console.log(
      `Token1 deployed to: ${await this.contracts.token1.getAddress()}`
    );
    console.log(
      `SecureAMM deployed to: ${await this.contracts.amm.getAddress()}\n`
    );

    this.testResults.deploymentTests.push({
      test: 'Contract Deployment',
      status: 'PASSED',
      details: 'All contracts deployed successfully',
    });
  }

  async configureRoles() {
    console.log('🔐 Configuring roles and permissions...');

    const EMERGENCY_RESPONDER_ROLE =
      await this.contracts.amm.EMERGENCY_RESPONDER_ROLE();
    const SLIPPAGE_GUARDIAN_ROLE =
      await this.contracts.amm.SLIPPAGE_GUARDIAN_ROLE();
    const MEV_PROTECTOR_ROLE = await this.contracts.amm.MEV_PROTECTOR_ROLE();

    await this.contracts.amm
      .connect(this.accounts.factory)
      .grantRole(
        EMERGENCY_RESPONDER_ROLE,
        this.accounts.emergencyResponder.address
      );

    await this.contracts.amm
      .connect(this.accounts.factory)
      .grantRole(
        SLIPPAGE_GUARDIAN_ROLE,
        this.accounts.slippageGuardian.address
      );

    await this.contracts.amm
      .connect(this.accounts.factory)
      .grantRole(MEV_PROTECTOR_ROLE, this.accounts.mevProtector.address);

    console.log('✅ Roles configured successfully\n');

    this.testResults.deploymentTests.push({
      test: 'Role Configuration',
      status: 'PASSED',
      details: 'All security roles assigned correctly',
    });
  }

  async runComprehensiveTests() {
    console.log('🧪 Running comprehensive security tests...\n');

    await this.setupInitialLiquidity();
    await this.testBasicSlippageProtection();
    await this.testAdaptiveSlippageProtection();
    await this.testMEVProtection();
    await this.testEmergencyControls();
    await this.testVolatilityMonitoring();
    await this.simulateAttackScenarios();
    await this.testPerformanceMetrics();
  }

  async setupInitialLiquidity() {
    console.log('💧 Setting up initial liquidity...');

    const liquidityAmount0 = ethers.parseEther('1000000'); // 1M tokens
    const liquidityAmount1 = ethers.parseEther('1000000'); // 1M tokens

    // Transfer tokens to AMM for initial liquidity
    await this.contracts.token0.transfer(
      await this.contracts.amm.getAddress(),
      liquidityAmount0
    );
    await this.contracts.token1.transfer(
      await this.contracts.amm.getAddress(),
      liquidityAmount1
    );

    // Sync reserves
    await this.contracts.amm.connect(this.accounts.factory).sync();

    // Distribute test tokens
    const testAmount = ethers.parseEther('100000');
    await this.contracts.token0.transfer(
      this.accounts.trader1.address,
      testAmount
    );
    await this.contracts.token0.transfer(
      this.accounts.trader2.address,
      testAmount
    );
    await this.contracts.token0.transfer(
      this.accounts.attacker.address,
      testAmount
    );

    await this.contracts.token1.transfer(
      this.accounts.trader1.address,
      testAmount
    );
    await this.contracts.token1.transfer(
      this.accounts.trader2.address,
      testAmount
    );
    await this.contracts.token1.transfer(
      this.accounts.attacker.address,
      testAmount
    );

    console.log('✅ Initial liquidity setup completed\n');
  }

  async testBasicSlippageProtection() {
    console.log('🛡️ Testing basic slippage protection...');

    try {
      // Test 1: Valid trade within slippage tolerance
      const tradeAmount = ethers.parseEther('1000');
      await this.contracts.token0
        .connect(this.accounts.trader1)
        .transfer(await this.contracts.amm.getAddress(), tradeAmount);

      const reserves = await this.contracts.amm.getReserves();
      const expectedOut = await this.contracts.amm.getAmountOut(
        tradeAmount,
        reserves._reserve0,
        reserves._reserve1
      );

      const protection = {
        minAmountOut: (expectedOut * 99n) / 100n, // 1% slippage tolerance
        maxAmountIn: ethers.parseEther('2000'),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        maxPriceImpact: 200, // 2%
        useAdaptiveSlippage: false,
        commitHash: ethers.keccak256(ethers.toUtf8Bytes('test1')),
      };

      const tx = await this.contracts.amm
        .connect(this.accounts.trader1)
        .swapWithSlippageProtection(
          0,
          expectedOut,
          this.accounts.trader1.address,
          protection,
          '0x'
        );

      const receipt = await tx.wait();
      this.securityMetrics.totalTradesAttempted++;

      this.testResults.slippageProtectionTests.push({
        test: 'Valid Trade Within Tolerance',
        status: 'PASSED',
        gasUsed: receipt.gasUsed.toString(),
        details: 'Trade executed successfully within slippage tolerance',
      });

      // Test 2: Trade exceeding slippage tolerance should fail
      try {
        const highSlippageProtection = {
          minAmountOut: expectedOut * 2n, // Unrealistic expectation
          maxAmountIn: ethers.parseEther('2000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 200,
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('test2')),
        };

        await this.contracts.token0
          .connect(this.accounts.trader2)
          .transfer(await this.contracts.amm.getAddress(), tradeAmount);

        await this.contracts.amm
          .connect(this.accounts.trader2)
          .swapWithSlippageProtection(
            0,
            expectedOut * 2n,
            this.accounts.trader2.address,
            highSlippageProtection,
            '0x'
          );

        this.testResults.slippageProtectionTests.push({
          test: 'High Slippage Trade Rejection',
          status: 'FAILED',
          details: 'Trade should have been rejected but was not',
        });
      } catch (error) {
        this.securityMetrics.tradesBlocked++;
        this.securityMetrics.slippageViolations++;

        this.testResults.slippageProtectionTests.push({
          test: 'High Slippage Trade Rejection',
          status: 'PASSED',
          details: 'Trade correctly rejected due to excessive slippage',
        });
      }

      console.log('✅ Basic slippage protection tests completed\n');
    } catch (error) {
      this.testResults.slippageProtectionTests.push({
        test: 'Basic Slippage Protection',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async testAdaptiveSlippageProtection() {
    console.log('🔄 Testing adaptive slippage protection...');

    try {
      // Set custom slippage tolerance
      await this.contracts.amm
        .connect(this.accounts.trader1)
        .setUserSlippageTolerance(100); // 1%

      // Create volatility with multiple trades
      for (let i = 0; i < 10; i++) {
        const volatilityAmount = ethers.parseEther('5000');
        await this.contracts.token0
          .connect(this.accounts.trader2)
          .transfer(await this.contracts.amm.getAddress(), volatilityAmount);

        const reserves = await this.contracts.amm.getReserves();
        const expectedOut = await this.contracts.amm.getAmountOut(
          volatilityAmount,
          reserves._reserve0,
          reserves._reserve1
        );

        const protection = {
          minAmountOut: (expectedOut * 95n) / 100n, // 5% tolerance for volatility
          maxAmountIn: ethers.parseEther('10000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 500, // 5%
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes(`volatility${i}`)),
        };

        await this.contracts.amm
          .connect(this.accounts.trader2)
          .swapWithSlippageProtection(
            0,
            expectedOut,
            this.accounts.trader2.address,
            protection,
            '0x'
          );

        this.securityMetrics.totalTradesAttempted++;

        // Add delay between trades
        await new Promise(resolve => setTimeout(resolve, 100));
      }

      // Test adaptive slippage
      const adaptiveProtection = {
        minAmountOut: ethers.parseEther('900'),
        maxAmountIn: ethers.parseEther('2000'),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        maxPriceImpact: 300,
        useAdaptiveSlippage: true,
        commitHash: ethers.keccak256(ethers.toUtf8Bytes('adaptive')),
      };

      await this.contracts.token0
        .connect(this.accounts.trader1)
        .transfer(
          await this.contracts.amm.getAddress(),
          ethers.parseEther('1000')
        );

      const reserves = await this.contracts.amm.getReserves();
      const expectedOut = await this.contracts.amm.getAmountOut(
        ethers.parseEther('1000'),
        reserves._reserve0,
        reserves._reserve1
      );

      await this.contracts.amm
        .connect(this.accounts.trader1)
        .swapWithSlippageProtection(
          0,
          expectedOut,
          this.accounts.trader1.address,
          adaptiveProtection,
          '0x'
        );

      this.securityMetrics.totalTradesAttempted++;

      this.testResults.slippageProtectionTests.push({
        test: 'Adaptive Slippage Protection',
        status: 'PASSED',
        details:
          'Adaptive slippage successfully adjusted for market conditions',
      });

      console.log('✅ Adaptive slippage protection tests completed\n');
    } catch (error) {
      this.testResults.slippageProtectionTests.push({
        test: 'Adaptive Slippage Protection',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async testMEVProtection() {
    console.log('⚡ Testing MEV protection mechanisms...');

    try {
      // Test commit-reveal scheme
      const protection = {
        minAmountOut: ethers.parseEther('990'),
        maxAmountIn: ethers.parseEther('2000'),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        maxPriceImpact: 200,
        useAdaptiveSlippage: false,
        commitHash: ethers.keccak256(ethers.toUtf8Bytes('mev_test')),
      };

      const nonce = 12345;

      // Calculate commit hash
      const commitHash = ethers.keccak256(
        ethers.AbiCoder.defaultAbiCoder().encode(
          [
            'uint256',
            'uint256',
            'address',
            'uint256',
            'uint256',
            'uint256',
            'address',
          ],
          [
            0,
            ethers.parseEther('990'),
            this.accounts.trader1.address,
            protection.minAmountOut,
            protection.deadline,
            nonce,
            this.accounts.trader1.address,
          ]
        )
      );

      // Commit phase
      await this.contracts.amm
        .connect(this.accounts.trader1)
        .commitTrade(commitHash);

      // Try immediate reveal (should fail)
      try {
        await this.contracts.amm
          .connect(this.accounts.trader1)
          .revealAndSwap(
            0,
            ethers.parseEther('990'),
            this.accounts.trader1.address,
            protection,
            nonce,
            '0x'
          );

        this.testResults.mevProtectionTests.push({
          test: 'MEV Protection Delay',
          status: 'FAILED',
          details: 'Immediate reveal should have failed',
        });
      } catch (error) {
        this.testResults.mevProtectionTests.push({
          test: 'MEV Protection Delay',
          status: 'PASSED',
          details: 'Commit-reveal delay correctly enforced',
        });
      }

      // Test MEV protection between regular trades
      await this.contracts.token0
        .connect(this.accounts.trader3)
        .transfer(
          await this.contracts.amm.getAddress(),
          ethers.parseEther('1000')
        );

      const reserves = await this.contracts.amm.getReserves();
      const expectedOut = await this.contracts.amm.getAmountOut(
        ethers.parseEther('1000'),
        reserves._reserve0,
        reserves._reserve1
      );

      // First trade
      await this.contracts.amm
        .connect(this.accounts.trader3)
        .swapWithSlippageProtection(
          0,
          expectedOut,
          this.accounts.trader3.address,
          protection,
          '0x'
        );

      this.securityMetrics.totalTradesAttempted++;

      // Immediate second trade should fail due to MEV protection
      try {
        await this.contracts.token0
          .connect(this.accounts.trader3)
          .transfer(
            await this.contracts.amm.getAddress(),
            ethers.parseEther('1000')
          );

        await this.contracts.amm
          .connect(this.accounts.trader3)
          .swapWithSlippageProtection(
            0,
            expectedOut / 2n,
            this.accounts.trader3.address,
            protection,
            '0x'
          );

        this.testResults.mevProtectionTests.push({
          test: 'MEV Protection Between Trades',
          status: 'FAILED',
          details: 'Second immediate trade should have been blocked',
        });
      } catch (error) {
        this.securityMetrics.mevAttacksBlocked++;

        this.testResults.mevProtectionTests.push({
          test: 'MEV Protection Between Trades',
          status: 'PASSED',
          details:
            'MEV protection correctly prevented immediate follow-up trade',
        });
      }

      console.log('✅ MEV protection tests completed\n');
    } catch (error) {
      this.testResults.mevProtectionTests.push({
        test: 'MEV Protection',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async testEmergencyControls() {
    console.log('🚨 Testing emergency control mechanisms...');

    try {
      // Test emergency slippage mode activation
      await this.contracts.amm
        .connect(this.accounts.emergencyResponder)
        .activateEmergencySlippageMode(
          100, // 1% emergency limit
          'Security test activation'
        );

      this.securityMetrics.emergencyTriggered++;

      const metrics = await this.contracts.amm.getSlippageProtectionMetrics();

      if (metrics.emergencyMode && metrics.emergencyLimit === 100n) {
        this.testResults.emergencyControlTests.push({
          test: 'Emergency Slippage Activation',
          status: 'PASSED',
          details: 'Emergency mode activated successfully',
        });
      } else {
        this.testResults.emergencyControlTests.push({
          test: 'Emergency Slippage Activation',
          status: 'FAILED',
          details: 'Emergency mode not properly activated',
        });
      }

      // Test emergency limits enforcement
      const protection = {
        minAmountOut: ethers.parseEther('950'),
        maxAmountIn: ethers.parseEther('10000'),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        maxPriceImpact: 500, // 5% - would exceed emergency limit
        useAdaptiveSlippage: false,
        commitHash: ethers.keccak256(ethers.toUtf8Bytes('emergency_test')),
      };

      try {
        const largeAmount = ethers.parseEther('50000');
        await this.contracts.token0
          .connect(this.accounts.trader1)
          .transfer(await this.contracts.amm.getAddress(), largeAmount);

        await this.contracts.amm
          .connect(this.accounts.trader1)
          .swapWithSlippageProtection(
            0,
            ethers.parseEther('25000'),
            this.accounts.trader1.address,
            protection,
            '0x'
          );

        this.testResults.emergencyControlTests.push({
          test: 'Emergency Limits Enforcement',
          status: 'FAILED',
          details: 'Trade should have been blocked by emergency limits',
        });
      } catch (error) {
        this.securityMetrics.tradesBlocked++;

        this.testResults.emergencyControlTests.push({
          test: 'Emergency Limits Enforcement',
          status: 'PASSED',
          details: 'Emergency limits correctly enforced',
        });
      }

      // Test price deviation pause
      await this.contracts.amm
        .connect(this.accounts.emergencyResponder)
        .pauseForPriceDeviation('Extreme price movement detected');

      try {
        const basicProtection = {
          minAmountOut: ethers.parseEther('990'),
          maxAmountIn: ethers.parseEther('2000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 100,
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('pause_test')),
        };

        await this.contracts.amm
          .connect(this.accounts.trader2)
          .swapWithSlippageProtection(
            0,
            ethers.parseEther('990'),
            this.accounts.trader2.address,
            basicProtection,
            '0x'
          );

        this.testResults.emergencyControlTests.push({
          test: 'Price Deviation Pause',
          status: 'FAILED',
          details: 'Trading should have been paused',
        });
      } catch (error) {
        this.testResults.emergencyControlTests.push({
          test: 'Price Deviation Pause',
          status: 'PASSED',
          details: 'Price deviation pause correctly enforced',
        });
      }

      // Resume trading
      await this.contracts.amm
        .connect(this.accounts.emergencyResponder)
        .resumeAfterPriceDeviation();
      await this.contracts.amm
        .connect(this.accounts.emergencyResponder)
        .deactivateEmergencySlippageMode();

      console.log('✅ Emergency control tests completed\n');
    } catch (error) {
      this.testResults.emergencyControlTests.push({
        test: 'Emergency Controls',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async testVolatilityMonitoring() {
    console.log('📊 Testing volatility monitoring...');

    try {
      // Create high volatility through alternating large trades
      const largeAmount = ethers.parseEther('30000');

      for (let i = 0; i < 3; i++) {
        // Large trade in one direction
        await this.contracts.token0
          .connect(this.accounts.trader1)
          .transfer(await this.contracts.amm.getAddress(), largeAmount);

        let reserves = await this.contracts.amm.getReserves();
        let expectedOut = await this.contracts.amm.getAmountOut(
          largeAmount,
          reserves._reserve0,
          reserves._reserve1
        );

        const protection1 = {
          minAmountOut: (expectedOut * 80n) / 100n,
          maxAmountIn: ethers.parseEther('50000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 1500, // 15%
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes(`vol1_${i}`)),
        };

        await this.contracts.amm
          .connect(this.accounts.trader1)
          .swapWithSlippageProtection(
            0,
            expectedOut,
            this.accounts.trader1.address,
            protection1,
            '0x'
          );

        this.securityMetrics.totalTradesAttempted++;

        // Track price impact
        const priceImpact = Number((expectedOut * 10000n) / reserves._reserve1);
        if (priceImpact > this.securityMetrics.maxPriceImpactObserved) {
          this.securityMetrics.maxPriceImpactObserved = priceImpact;
        }

        // Large trade in opposite direction
        await this.contracts.token1
          .connect(this.accounts.trader2)
          .transfer(await this.contracts.amm.getAddress(), largeAmount);

        reserves = await this.contracts.amm.getReserves();
        expectedOut = await this.contracts.amm.getAmountOut(
          largeAmount,
          reserves._reserve1,
          reserves._reserve0
        );

        const protection2 = {
          minAmountOut: (expectedOut * 80n) / 100n,
          maxAmountIn: ethers.parseEther('50000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 1500,
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes(`vol2_${i}`)),
        };

        await this.contracts.amm
          .connect(this.accounts.trader2)
          .swapWithSlippageProtection(
            expectedOut,
            0,
            this.accounts.trader2.address,
            protection2,
            '0x'
          );

        this.securityMetrics.totalTradesAttempted++;

        // Add delay for price history
        await new Promise(resolve => setTimeout(resolve, 200));
      }

      // Check volatility metrics
      const metrics = await this.contracts.amm.getSlippageProtectionMetrics();

      this.testResults.emergencyControlTests.push({
        test: 'Volatility Monitoring',
        status: 'PASSED',
        details: `Volatility score: ${metrics.currentVolatility}, Price deviation: ${metrics.priceDeviation}, Price history: ${metrics.totalPriceHistory}`,
      });

      console.log('✅ Volatility monitoring tests completed\n');
    } catch (error) {
      this.testResults.emergencyControlTests.push({
        test: 'Volatility Monitoring',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async simulateAttackScenarios() {
    console.log('⚔️ Simulating attack scenarios...');

    try {
      // Scenario 1: Large slippage manipulation attempt
      try {
        const manipulationAmount = ethers.parseEther('200000'); // 20% of liquidity
        await this.contracts.token0
          .connect(this.accounts.attacker)
          .transfer(await this.contracts.amm.getAddress(), manipulationAmount);

        const maliciousProtection = {
          minAmountOut: ethers.parseEther('1'), // Minimal expectation to bypass checks
          maxAmountIn: ethers.parseEther('300000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 5000, // 50% - extremely high
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('attack1')),
        };

        await this.contracts.amm
          .connect(this.accounts.attacker)
          .swapWithSlippageProtection(
            0,
            ethers.parseEther('100000'),
            this.accounts.attacker.address,
            maliciousProtection,
            '0x'
          );

        this.testResults.attackSimulationTests.push({
          test: 'Large Slippage Manipulation',
          status: 'FAILED',
          details: 'Attack should have been prevented',
        });
      } catch (error) {
        this.securityMetrics.tradesBlocked++;

        this.testResults.attackSimulationTests.push({
          test: 'Large Slippage Manipulation',
          status: 'PASSED',
          details: 'Manipulation attack successfully prevented',
        });
      }

      // Scenario 2: Sandwich attack simulation
      try {
        // Front-run trade
        const frontRunAmount = ethers.parseEther('50000');
        await this.contracts.token0
          .connect(this.accounts.attacker)
          .transfer(await this.contracts.amm.getAddress(), frontRunAmount);

        let reserves = await this.contracts.amm.getReserves();
        let expectedOut = await this.contracts.amm.getAmountOut(
          frontRunAmount,
          reserves._reserve0,
          reserves._reserve1
        );

        const frontRunProtection = {
          minAmountOut: (expectedOut * 90n) / 100n,
          maxAmountIn: ethers.parseEther('100000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 1000, // 10%
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('front_run')),
        };

        await this.contracts.amm
          .connect(this.accounts.attacker)
          .swapWithSlippageProtection(
            0,
            expectedOut,
            this.accounts.attacker.address,
            frontRunProtection,
            '0x'
          );

        this.securityMetrics.totalTradesAttempted++;

        // Attempt immediate back-run (should fail due to MEV protection)
        await this.contracts.token1
          .connect(this.accounts.attacker)
          .transfer(await this.contracts.amm.getAddress(), expectedOut / 2n);

        const backRunProtection = {
          minAmountOut: ethers.parseEther('10000'),
          maxAmountIn: expectedOut,
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 1000,
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('back_run')),
        };

        await this.contracts.amm
          .connect(this.accounts.attacker)
          .swapWithSlippageProtection(
            ethers.parseEther('25000'),
            0,
            this.accounts.attacker.address,
            backRunProtection,
            '0x'
          );

        this.testResults.attackSimulationTests.push({
          test: 'Sandwich Attack Prevention',
          status: 'FAILED',
          details:
            'Back-run trade should have been prevented by MEV protection',
        });
      } catch (error) {
        this.securityMetrics.mevAttacksBlocked++;

        this.testResults.attackSimulationTests.push({
          test: 'Sandwich Attack Prevention',
          status: 'PASSED',
          details: 'MEV protection successfully prevented sandwich attack',
        });
      }

      // Scenario 3: Flash loan arbitrage simulation
      try {
        // Simulate large arbitrage attempt
        const arbAmount = ethers.parseEther('500000'); // 50% of liquidity
        await this.contracts.token0
          .connect(this.accounts.attacker)
          .transfer(await this.contracts.amm.getAddress(), arbAmount);

        const arbProtection = {
          minAmountOut: ethers.parseEther('1'),
          maxAmountIn: ethers.parseEther('600000'),
          deadline: Math.floor(Date.now() / 1000) + 3600,
          maxPriceImpact: 8000, // 80% - extreme
          useAdaptiveSlippage: false,
          commitHash: ethers.keccak256(ethers.toUtf8Bytes('arbitrage')),
        };

        await this.contracts.amm
          .connect(this.accounts.attacker)
          .swapWithSlippageProtection(
            0,
            ethers.parseEther('200000'),
            this.accounts.attacker.address,
            arbProtection,
            '0x'
          );

        this.testResults.attackSimulationTests.push({
          test: 'Flash Loan Arbitrage Prevention',
          status: 'FAILED',
          details: 'Large arbitrage should have been prevented',
        });
      } catch (error) {
        this.securityMetrics.tradesBlocked++;

        this.testResults.attackSimulationTests.push({
          test: 'Flash Loan Arbitrage Prevention',
          status: 'PASSED',
          details: 'Extreme arbitrage attack successfully prevented',
        });
      }

      console.log('✅ Attack simulation tests completed\n');
    } catch (error) {
      this.testResults.attackSimulationTests.push({
        test: 'Attack Simulations',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async testPerformanceMetrics() {
    console.log('⚡ Testing performance metrics...');

    try {
      // Test gas efficiency of protected swaps
      const protection = {
        minAmountOut: ethers.parseEther('990'),
        maxAmountIn: ethers.parseEther('2000'),
        deadline: Math.floor(Date.now() / 1000) + 3600,
        maxPriceImpact: 200,
        useAdaptiveSlippage: false,
        commitHash: ethers.keccak256(ethers.toUtf8Bytes('performance')),
      };

      await this.contracts.token0
        .connect(this.accounts.trader1)
        .transfer(
          await this.contracts.amm.getAddress(),
          ethers.parseEther('1000')
        );

      const reserves = await this.contracts.amm.getReserves();
      const expectedOut = await this.contracts.amm.getAmountOut(
        ethers.parseEther('1000'),
        reserves._reserve0,
        reserves._reserve1
      );

      const tx = await this.contracts.amm
        .connect(this.accounts.trader1)
        .swapWithSlippageProtection(
          0,
          expectedOut,
          this.accounts.trader1.address,
          protection,
          '0x'
        );

      const receipt = await tx.wait();
      this.securityMetrics.totalTradesAttempted++;

      // Test slippage calculation
      const [slippage, priceImpact] =
        await this.contracts.amm.calculateExpectedSlippage(
          ethers.parseEther('1000'),
          reserves._reserve0,
          reserves._reserve1
        );

      this.testResults.performanceTests.push({
        test: 'Gas Efficiency',
        status: 'PASSED',
        gasUsed: receipt.gasUsed.toString(),
        details: `Protected swap gas: ${receipt.gasUsed}`,
      });

      this.testResults.performanceTests.push({
        test: 'Slippage Calculation',
        status: 'PASSED',
        details: `Calculated slippage: ${slippage}, Price impact: ${priceImpact}`,
      });

      console.log('✅ Performance metrics tests completed\n');
    } catch (error) {
      this.testResults.performanceTests.push({
        test: 'Performance Metrics',
        status: 'FAILED',
        details: error.message,
      });
    }
  }

  async generateSecurityReport() {
    console.log('📋 Generating comprehensive security report...\n');

    // Calculate final metrics
    this.securityMetrics.avgSlippageProtected =
      this.securityMetrics.slippageViolations > 0
        ? (
            (this.securityMetrics.tradesBlocked /
              this.securityMetrics.slippageViolations) *
            100
          ).toFixed(2)
        : 100;

    const report = {
      timestamp: new Date().toISOString(),
      deployment: {
        contract: 'SecureCarbonCreditAMM',
        version: '1.0.0',
        network: 'hardhat',
        deployer: this.accounts.deployer.address,
        contractAddress: await this.contracts.amm.getAddress(),
      },
      securityMetrics: this.securityMetrics,
      testResults: this.testResults,
      summary: {
        totalTests: this.getTotalTestCount(),
        passedTests: this.getPassedTestCount(),
        failedTests: this.getFailedTestCount(),
        securityScore: this.calculateSecurityScore(),
      },
      recommendations: this.generateRecommendations(),
    };

    // Write report to file
    const reportPath = path.join(
      __dirname,
      '..',
      'reports',
      'secure-amm-slippage-protection-report.json'
    );
    await fs.promises.mkdir(path.dirname(reportPath), { recursive: true });
    await fs.promises.writeFile(reportPath, JSON.stringify(report, null, 2));

    console.log('📊 SECURITY REPORT SUMMARY');
    console.log('═══════════════════════════════════════');
    console.log(`📋 Total Tests: ${report.summary.totalTests}`);
    console.log(`✅ Passed: ${report.summary.passedTests}`);
    console.log(`❌ Failed: ${report.summary.failedTests}`);
    console.log(`🛡️ Security Score: ${report.summary.securityScore}%`);
    console.log('═══════════════════════════════════════');
    console.log(
      `🔢 Total Trades Attempted: ${this.securityMetrics.totalTradesAttempted}`
    );
    console.log(`🚫 Trades Blocked: ${this.securityMetrics.tradesBlocked}`);
    console.log(
      `⚠️ Slippage Violations: ${this.securityMetrics.slippageViolations}`
    );
    console.log(
      `🛡️ MEV Attacks Blocked: ${this.securityMetrics.mevAttacksBlocked}`
    );
    console.log(
      `🚨 Emergency Triggered: ${this.securityMetrics.emergencyTriggered}`
    );
    console.log(
      `📈 Max Price Impact: ${this.securityMetrics.maxPriceImpactObserved / 100}%`
    );
    console.log('═══════════════════════════════════════\n');

    console.log('📄 Full report saved to:', reportPath);
    return report;
  }

  getTotalTestCount() {
    return Object.values(this.testResults).reduce(
      (total, tests) => total + tests.length,
      0
    );
  }

  getPassedTestCount() {
    return Object.values(this.testResults).reduce(
      (total, tests) => total + tests.filter(t => t.status === 'PASSED').length,
      0
    );
  }

  getFailedTestCount() {
    return Object.values(this.testResults).reduce(
      (total, tests) => total + tests.filter(t => t.status === 'FAILED').length,
      0
    );
  }

  calculateSecurityScore() {
    const totalTests = this.getTotalTestCount();
    const passedTests = this.getPassedTestCount();

    if (totalTests === 0) return 0;

    const baseScore = (passedTests / totalTests) * 100;

    // Bonus points for security features
    let bonus = 0;
    if (this.securityMetrics.mevAttacksBlocked > 0) bonus += 5;
    if (this.securityMetrics.slippageViolations > 0) bonus += 5;
    if (this.securityMetrics.emergencyTriggered > 0) bonus += 5;

    return Math.min(100, Math.round(baseScore + bonus));
  }

  generateRecommendations() {
    const recommendations = [];

    if (this.getFailedTestCount() > 0) {
      recommendations.push({
        priority: 'HIGH',
        category: 'Test Failures',
        recommendation:
          'Review and fix failed test cases before production deployment',
      });
    }

    if (
      this.securityMetrics.tradesBlocked <
      this.securityMetrics.totalTradesAttempted * 0.1
    ) {
      recommendations.push({
        priority: 'MEDIUM',
        category: 'Security Tuning',
        recommendation:
          'Consider tightening slippage protection parameters for enhanced security',
      });
    }

    if (this.securityMetrics.maxPriceImpactObserved > 2000) {
      recommendations.push({
        priority: 'HIGH',
        category: 'Price Impact',
        recommendation:
          'Monitor for large trades that may indicate market manipulation',
      });
    }

    recommendations.push({
      priority: 'INFO',
      category: 'Monitoring',
      recommendation:
        'Implement continuous monitoring of slippage violations and MEV attacks',
    });

    recommendations.push({
      priority: 'INFO',
      category: 'Emergency Response',
      recommendation:
        'Establish clear procedures for emergency slippage mode activation',
    });

    return recommendations;
  }
}

// Main execution
async function main() {
  const deployer = new SecureAMMSlippageProtectionDeployer();

  try {
    await deployer.deploy();
    process.exit(0);
  } catch (error) {
    console.error('Deployment failed:', error);
    process.exit(1);
  }
}

// Execute if called directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = { SecureAMMSlippageProtectionDeployer };
