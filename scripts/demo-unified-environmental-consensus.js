/**
 * Proof of Publishing Consensus Demo
 * Shows how Proof of Publishing combines all four proof types
 * for optimal environmental data validation and forecasting rewards
 */

const axios = require('axios');
const crypto = require('crypto');

class ProofOfPublishingDemo {
  constructor() {
    this.baseUrl = 'http://localhost:3001';
    this.nodes = new Map();
    this.dataSources = new Map();
    this.forecasts = new Map();
    this.regions = new Map();

    this.initializeRegions();
  }

  /**
   * Initialize geographic regions with environmental priorities
   */
  initializeRegions() {
    const regions = [
      {
        id: 'amazon_rainforest',
        name: 'Amazon Rainforest',
        latBounds: [-20.0, 5.0],
        lonBounds: [-80.0, -50.0],
        scarcityMultiplier: 3.0,
        priorityScore: 1.0,
      },
      {
        id: 'arctic_region',
        name: 'Arctic Region',
        latBounds: [66.5, 90.0],
        lonBounds: [-180.0, 180.0],
        scarcityMultiplier: 2.5,
        priorityScore: 0.9,
      },
      {
        id: 'north_america',
        name: 'North America',
        latBounds: [25.0, 70.0],
        lonBounds: [-170.0, -50.0],
        scarcityMultiplier: 1.0,
        priorityScore: 0.6,
      },
    ];

    regions.forEach(region => {
      this.regions.set(region.id, region);
    });

    console.log(
      '🌍 Initialized environmental regions with scarcity multipliers'
    );
  }

  /**
   * Demo 1: Register environmental nodes with different capabilities
   */
  async demoNodeRegistration() {
    console.log('\n📋 Demo 1: Environmental Node Registration');
    console.log('==========================================');

    const nodes = [
      {
        id: 'weather_station_bryan',
        address: 'wrf717d72395303fcb2aed4df368f32f1078d18e9cc',
        stake: 10000,
        contributionTypes: ['WeatherData', 'LocationVerification'],
        regions: ['north_america'],
        description: "Bryan's AcuRite Iris 2025 Weather Station",
      },
      {
        id: 'amazon_forecaster',
        address: 'wrfamazon123456789abcdef',
        stake: 25000,
        contributionTypes: ['EnvironmentalForecasting', 'ComputationalWork'],
        regions: ['amazon_rainforest'],
        description: 'Amazon Rainforest Climate Forecasting Node',
      },
      {
        id: 'arctic_researcher',
        address: 'wrfarctic987654321fedcba',
        stake: 20000,
        contributionTypes: ['DataQualityAssurance', 'EnvironmentalPublishing'],
        regions: ['arctic_region'],
        description: 'Arctic Climate Research Station',
      },
      {
        id: 'global_storage_node',
        address: 'wrfglobal555666777888999',
        stake: 15000,
        contributionTypes: ['DataStorage', 'DataQualityAssurance'],
        regions: ['north_america', 'amazon_rainforest', 'arctic_region'],
        description: 'Global Environmental Data Storage Provider',
      },
    ];

    for (const nodeConfig of nodes) {
      // Register node in unified consensus
      const node = {
        id: nodeConfig.id,
        address: nodeConfig.address,
        stake: nodeConfig.stake,
        contributionTypes: new Set(nodeConfig.contributionTypes),
        regions: new Set(nodeConfig.regions),
        dataSources: [],
        environmentalScore: 0.0,
        usefulnessScore: 0.0,
        informationScore: 0.0,
        locationScore: 0.0,
        publishingScore: 0.0,
        reputation: 1.0,
        active: true,
        lastBlockHeight: 0,
        blocksProduced: 0,
        totalRewards: 0,
      };

      this.nodes.set(nodeConfig.id, node);

      console.log(`✅ Registered: ${nodeConfig.description}`);
      console.log(`   Address: ${nodeConfig.address}`);
      console.log(`   Stake: ${nodeConfig.stake} WRF`);
      console.log(
        `   Capabilities: ${nodeConfig.contributionTypes.join(', ')}`
      );
      console.log(`   Regions: ${nodeConfig.regions.join(', ')}\n`);
    }

    console.log(
      `🎉 Successfully registered ${nodes.length} environmental nodes`
    );
  }

  /**
   * Demo 2: Register environmental data sources with location verification
   */
  async demoDataSourceRegistration() {
    console.log('\n📊 Demo 2: Environmental Data Source Registration');
    console.log('===============================================');

    // Register Bryan's actual AcuRite weather station
    const bryanStation = {
      id: 'bryan_acurite_iris_2025',
      name: "Bryan's AcuRite Iris® 2025",
      dataType: 'weather',
      location: [40.7128, -74.006], // Example coordinates
      region: 'north_america',
      qualityScore: 0.85,
      locationVerified: true,
      authMethod: 'MyAcuRite API',
      lastUpdate: Date.now(),
      submissionCount: 13, // Current count from logs
      validationCount: 13,
    };

    this.dataSources.set(bryanStation.id, bryanStation);

    // Assign to weather station node
    const weatherNode = this.nodes.get('weather_station_bryan');
    weatherNode.dataSources.push(bryanStation.id);

    console.log('🌡️ Registered weather station data source:');
    console.log(`   Station: ${bryanStation.name}`);
    console.log(
      `   Location: ${bryanStation.location[0]}, ${bryanStation.location[1]}`
    );
    console.log(`   Region: ${bryanStation.region}`);
    console.log(`   Quality Score: ${bryanStation.qualityScore}`);
    console.log(`   Total Submissions: ${bryanStation.submissionCount}`);
    console.log(`   Authentication: ${bryanStation.authMethod}`);
    console.log(
      `   Location Verified: ${bryanStation.locationVerified ? 'Yes' : 'No'}`
    );

    // Register additional hypothetical sources for demo
    const amazonStation = {
      id: 'amazon_research_station_1',
      name: 'Amazon Research Station Alpha',
      dataType: 'environmental',
      location: [-3.4653, -62.2159], // Manaus coordinates
      region: 'amazon_rainforest',
      qualityScore: 0.92,
      locationVerified: true,
      authMethod: 'Research Institute API',
      lastUpdate: Date.now(),
      submissionCount: 156,
      validationCount: 150,
    };

    this.dataSources.set(amazonStation.id, amazonStation);
    const amazonNode = this.nodes.get('amazon_forecaster');
    amazonNode.dataSources.push(amazonStation.id);

    console.log('\n🌳 Registered Amazon research station:');
    console.log(`   Station: ${amazonStation.name}`);
    console.log(
      `   Location: ${amazonStation.location[0]}, ${amazonStation.location[1]}`
    );
    console.log(`   Quality Score: ${amazonStation.qualityScore}`);
    console.log(
      `   Scarcity Multiplier: ${this.regions.get(amazonStation.region).scarcityMultiplier}x`
    );
  }

  /**
   * Demo 3: Simulate environmental data updates and score calculations
   */
  async demoEnvironmentalDataUpdates() {
    console.log('\n🔄 Demo 3: Environmental Data Updates & Score Calculation');
    console.log('========================================================');

    // Simulate Bryan's weather station data updates
    const bryanNode = this.nodes.get('weather_station_bryan');
    const bryanSource = this.dataSources.get('bryan_acurite_iris_2025');

    console.log("📈 Processing weather data from Bryan's AcuRite station...");

    // Simulate multiple data updates
    for (let i = 0; i < 5; i++) {
      const dataQuality = 0.8 + Math.random() * 0.2; // 0.8 to 1.0
      const locationVerified = true;

      // Update data source metrics
      bryanSource.submissionCount++;
      bryanSource.validationCount++;
      bryanSource.lastUpdate = Date.now();

      // Update quality score with exponential moving average
      const alpha = 0.1;
      bryanSource.qualityScore =
        alpha * dataQuality + (1.0 - alpha) * bryanSource.qualityScore;

      // Update node scores based on contribution
      const infoBoost = dataQuality * 0.1;
      bryanNode.informationScore = Math.min(
        bryanNode.informationScore + infoBoost,
        1.0
      );

      if (locationVerified) {
        const locationBoost = 0.05;
        bryanNode.locationScore = Math.min(
          bryanNode.locationScore + locationBoost,
          1.0
        );
      }

      console.log(
        `   Update ${i + 1}: Quality=${dataQuality.toFixed(3)}, Location=${locationVerified ? 'Verified' : 'Pending'}`
      );
    }

    // Recalculate environmental score
    this.recalculateEnvironmentalScore(bryanNode);

    console.log('\n📊 Updated Node Scores:');
    console.log(
      `   Information Score: ${bryanNode.informationScore.toFixed(3)}`
    );
    console.log(`   Location Score: ${bryanNode.locationScore.toFixed(3)}`);
    console.log(
      `   Environmental Score: ${bryanNode.environmentalScore.toFixed(3)}`
    );
    console.log(`   Data Quality: ${bryanSource.qualityScore.toFixed(3)}`);
  }

  /**
   * Demo 4: Environmental forecasting with WRF model simulation
   */
  async demoEnvironmentalForecasting() {
    console.log('\n🌤️ Demo 4: Environmental Forecasting with WRF Models');
    console.log('==================================================');

    const amazonNode = this.nodes.get('amazon_forecaster');
    const amazonRegion = this.regions.get('amazon_rainforest');

    // Simulate WRF forecast submission
    const forecast = {
      id: `forecast_${Date.now()}`,
      forecaster: amazonNode.id,
      inputDataHash: crypto
        .createHash('sha256')
        .update('amazon_weather_data_' + Date.now())
        .digest('hex'),
      modelType: 'WRF-Chem', // Weather Research & Forecasting with Chemistry
      modelVersion: crypto
        .createHash('sha256')
        .update('wrf_v4.3.2')
        .digest('hex'),
      geographicBounds: amazonRegion,
      timeRange: [Date.now(), Date.now() + 7 * 24 * 60 * 60 * 1000], // 7-day forecast
      forecastData: JSON.stringify({
        temperature: { min: 24.5, max: 32.1, avg: 28.3 },
        humidity: { min: 78, max: 95, avg: 86 },
        precipitation: { total: 145.2, days: 4 },
        airQuality: { pm25: 12.3, ozone: 0.045 },
        deforestation_risk: 'moderate',
        carbon_flux: -2.3, // Negative = carbon sink
      }),
      complexityScore: 0.85, // High complexity for climate chemistry model
      timestamp: Date.now(),
      accuracyScore: null, // Will be filled after verification
    };

    this.forecasts.set(forecast.id, forecast);

    console.log('🧠 Environmental forecast submitted:');
    console.log(`   Forecaster: ${forecast.forecaster}`);
    console.log(`   Model: ${forecast.modelType}`);
    console.log(
      `   Region: ${amazonRegion.name} (${amazonRegion.scarcityMultiplier}x scarcity bonus)`
    );
    console.log(`   Complexity Score: ${forecast.complexityScore}`);
    console.log(`   Time Range: 7-day forecast`);
    console.log(`   Data: Amazon climate + air quality + carbon flux`);

    // Simulate forecast verification after some time
    setTimeout(() => {
      this.verifyForecast(forecast.id, 0.78); // 78% accuracy
    }, 1000);
  }

  /**
   * Verify a forecast and update publishing scores
   */
  verifyForecast(forecastId, accuracy) {
    const forecast = this.forecasts.get(forecastId);
    const node = this.nodes.get(forecast.forecaster);
    const region = this.regions.get(forecast.geographicBounds.id);

    console.log('\n✅ Forecast Verification Complete:');
    console.log(`   Forecast ID: ${forecastId.substring(0, 16)}...`);
    console.log(`   Accuracy: ${(accuracy * 100).toFixed(1)}%`);

    // Set accuracy score
    forecast.accuracyScore = accuracy;

    // Update node scores
    const publishingBoost = accuracy * 0.2;
    node.publishingScore = Math.min(
      node.publishingScore + publishingBoost,
      1.0
    );

    const usefulnessBoost = forecast.complexityScore * accuracy * 0.15;
    node.usefulnessScore = Math.min(
      node.usefulnessScore + usefulnessBoost,
      1.0
    );

    // Apply regional scarcity multiplier
    const regionalBonus = region.scarcityMultiplier * 0.05;
    node.environmentalScore += regionalBonus;

    // Recalculate overall environmental score
    this.recalculateEnvironmentalScore(node);

    console.log(
      `   Publishing Score: ${node.publishingScore.toFixed(3)} (+${publishingBoost.toFixed(3)})`
    );
    console.log(
      `   Usefulness Score: ${node.usefulnessScore.toFixed(3)} (+${usefulnessBoost.toFixed(3)})`
    );
    console.log(
      `   Regional Bonus: +${regionalBonus.toFixed(3)} (${region.scarcityMultiplier}x Amazon multiplier)`
    );
    console.log(
      `   New Environmental Score: ${node.environmentalScore.toFixed(3)}`
    );

    // Move to verified forecasts
    this.forecasts.delete(forecastId);
    // In real implementation, would store in verified_forecasts
  }

  /**
   * Demo 5: Block production scheduling based on environmental scores
   */
  async demoBlockProductionScheduling() {
    console.log('\n🏗️ Demo 5: Environmental Block Production Scheduling');
    console.log('==================================================');

    // Calculate total environmental score
    let totalScore = 0;
    const activeNodes = Array.from(this.nodes.values()).filter(
      node => node.active
    );

    activeNodes.forEach(node => {
      totalScore += node.environmentalScore;
    });

    console.log('📊 Node Environmental Rankings:');
    console.log('================================');

    // Sort nodes by environmental score
    const rankedNodes = activeNodes.sort(
      (a, b) => b.environmentalScore - a.environmentalScore
    );

    rankedNodes.forEach((node, index) => {
      const percentage =
        totalScore > 0 ? (node.environmentalScore / totalScore) * 100 : 0;
      const slots = Math.round((node.environmentalScore / totalScore) * 50); // 50 slots per round

      console.log(`${index + 1}. ${node.id}:`);
      console.log(
        `   Environmental Score: ${node.environmentalScore.toFixed(3)}`
      );
      console.log(
        `   - Usefulness: ${node.usefulnessScore.toFixed(3)} (35% weight)`
      );
      console.log(
        `   - Information: ${node.informationScore.toFixed(3)} (25% weight)`
      );
      console.log(
        `   - Location: ${node.locationScore.toFixed(3)} (20% weight)`
      );
      console.log(
        `   - Publishing: ${node.publishingScore.toFixed(3)} (20% weight)`
      );
      console.log(
        `   Block Production Allocation: ${percentage.toFixed(1)}% (${slots} slots)`
      );
      console.log('');
    });

    console.log('🎯 Top Environmental Contributors:');
    console.log(
      `   1st: ${rankedNodes[0]?.id || 'N/A'} - Leading environmental data provider`
    );
    console.log(
      `   2nd: ${rankedNodes[1]?.id || 'N/A'} - Strong multi-contribution profile`
    );
    console.log(
      `   3rd: ${rankedNodes[2]?.id || 'N/A'} - Consistent environmental validation`
    );
  }

  /**
   * Demo 6: Real-time integration with actual weather data
   */
  async demoRealTimeIntegration() {
    console.log('\n🔗 Demo 6: Real-Time Weather Data Integration');
    console.log('===========================================');

    console.log('🌡️ Current weather station status:');
    console.log("   Bryan's AcuRite Iris® 2025: ACTIVE");
    console.log('   Collection Interval: 60 seconds');
    console.log('   Reward Rate: 0.1 WRF per reading');
    console.log('   Authentication: MyAcuRite API ✅');

    // Simulate integration with current data
    const bryanNode = this.nodes.get('weather_station_bryan');
    const currentRewards = 1.3; // From current logs

    console.log('\n📈 Integration with Proof of Publishing:');
    console.log(`   Current WRF Earned: ${currentRewards} WRF`);
    console.log(
      `   Environmental Score: ${bryanNode.environmentalScore.toFixed(3)}`
    );
    console.log(
      `   Data Quality Bonus: +${(bryanNode.informationScore * 0.1).toFixed(3)} WRF/reading`
    );
    console.log(
      `   Location Verification Bonus: +${(bryanNode.locationScore * 0.05).toFixed(3)} WRF/reading`
    );

    const enhancedReward =
      0.1 *
      (1 + bryanNode.informationScore * 0.1 + bryanNode.locationScore * 0.05);
    console.log(
      `   Enhanced Reward Rate: ${enhancedReward.toFixed(4)} WRF per reading`
    );
    console.log(
      `   Improvement: +${((enhancedReward - 0.1) * 100).toFixed(1)}% over base rate`
    );
  }

  /**
   * Recalculate environmental score using unified weights
   */
  recalculateEnvironmentalScore(node) {
    const weights = {
      usefulness: 0.35, // Environmental forecasting
      information: 0.25, // Data quality
      location: 0.2, // Geographic verification
      publishing: 0.2, // Forecast publishing
    };

    node.environmentalScore =
      node.usefulnessScore * weights.usefulness +
      node.informationScore * weights.information +
      node.locationScore * weights.location +
      node.publishingScore * weights.publishing;

    // Apply reputation multiplier
    node.environmentalScore *= node.reputation;
  }

  /**
   * Run complete unified environmental consensus demonstration
   */
  async runCompleteDemo() {
    console.log('📝 PROOF OF PUBLISHING CONSENSUS DEMONSTRATION');
    console.log('==============================================');
    console.log(
      'Combining Proof of Usefulness, Information, Location & Publishing'
    );
    console.log(
      'for optimal environmental data validation and forecasting rewards\n'
    );

    try {
      await this.demoNodeRegistration();
      await this.demoDataSourceRegistration();
      await this.demoEnvironmentalDataUpdates();
      await this.demoEnvironmentalForecasting();

      // Wait for forecast verification
      await new Promise(resolve => setTimeout(resolve, 1500));

      await this.demoBlockProductionScheduling();
      await this.demoRealTimeIntegration();

      console.log('\n🎉 PROOF OF PUBLISHING DEMONSTRATION COMPLETE');
      console.log('============================================');
      console.log('✅ Successfully combined all four proof types');
      console.log('✅ Environmental data validation optimized');
      console.log('✅ Weather station integration enhanced');
      console.log('✅ Forecasting rewards system active');
      console.log('✅ Geographic scarcity bonuses applied');
      console.log('✅ Reputation-based scoring implemented');

      console.log('\n💡 Key Benefits:');
      console.log(
        '   • Single Proof of Publishing mechanism replaces complex hybrid system'
      );
      console.log(
        '   • Weather stations earn enhanced rewards for data quality'
      );
      console.log(
        '   • Environmental forecasting prioritized over wasteful mining'
      );
      console.log(
        '   • Geographic regions with data scarcity receive bonus rewards'
      );
      console.log('   • Proof of Location renamed and integrated seamlessly');
      console.log('   • Real-world environmental impact measurement enabled');
      console.log(
        '   • PoS and DPoS preserved for traditional validation needs'
      );
    } catch (error) {
      console.error('❌ Demo error:', error.message);
    }
  }
}

// Run the demonstration
const demo = new ProofOfPublishingDemo();
demo.runCompleteDemo();
