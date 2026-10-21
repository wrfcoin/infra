#!/usr/bin/env node

/**
 * Optimized Weather Data Collection Rewards System
 * Maximizes WRF earnings through intelligent data collection and reward optimization
 */

const crypto = require('crypto');

class WeatherRewardOptimizer {
  constructor() {
    this.rewardStructure = {
      // Base rewards per sensor type
      temperature: 0.02,
      humidity: 0.02,
      pressure: 0.03,
      wind_speed: 0.025,
      wind_direction: 0.015,
      rainfall: 0.04, // Higher reward for precipitation data
      solar_radiation: 0.035,
      uv_index: 0.025,
      soil_temperature: 0.03,
      soil_moisture: 0.03,
      air_quality: 0.05, // Premium for air quality data

      // Quality multipliers
      high_precision: 1.5, // Sensors with high precision
      real_time: 1.2, // Real-time vs cached data
      geographic_rarity: 1.3, // Rare geographic locations
      extreme_weather: 2.0, // During extreme weather events

      // Consistency bonuses
      daily_streak: 0.01, // Per day of consistent reporting
      uptime_bonus: 0.5, // 99%+ uptime bonus

      // Cross-validation rewards
      multi_station_verification: 0.1, // When multiple stations verify data
      network_contribution: 0.05, // Contributing to weather network density
    };

    this.qualityThresholds = {
      temperature_precision: 0.1, // Within 0.1°F precision
      pressure_precision: 0.01, // Within 0.01 inHg precision
      wind_precision: 0.5, // Within 0.5 mph precision
      humidity_precision: 1, // Within 1% RH precision
    };

    this.extremeWeatherConditions = {
      temperature: { min: -10, max: 100 }, // Extreme temps in Fahrenheit
      wind_speed: { min: 25 }, // High wind speeds in mph
      pressure: { min: 28.5, max: 31.0 }, // Extreme pressure in inHg
      rainfall_rate: { min: 0.5 }, // Heavy rain in inches/hour
    };
  }

  /**
   * Calculate optimized reward for weather data submission
   */
  calculateReward(weatherData, stationMetrics = {}) {
    let totalReward = 0;
    let rewardBreakdown = {};

    // Base sensor rewards
    for (const [sensorType, sensorData] of Object.entries(
      weatherData.sensors || {}
    )) {
      const baseReward = this.getBaseSensorReward(sensorType, sensorData);
      totalReward += baseReward;
      rewardBreakdown[sensorType] = baseReward;
    }

    // Quality multipliers
    const qualityMultiplier = this.calculateQualityMultiplier(
      weatherData,
      stationMetrics
    );
    totalReward *= qualityMultiplier;
    rewardBreakdown.quality_multiplier = qualityMultiplier;

    // Extreme weather bonus
    const extremeBonus = this.calculateExtremeWeatherBonus(weatherData);
    totalReward += extremeBonus;
    rewardBreakdown.extreme_weather_bonus = extremeBonus;

    // Consistency bonus
    const consistencyBonus = this.calculateConsistencyBonus(stationMetrics);
    totalReward += consistencyBonus;
    rewardBreakdown.consistency_bonus = consistencyBonus;

    // Geographic rarity bonus
    const locationBonus = this.calculateLocationBonus(weatherData);
    totalReward += locationBonus;
    rewardBreakdown.location_bonus = locationBonus;

    // Round to 4 decimal places
    totalReward = Math.round(totalReward * 10000) / 10000;

    return {
      total_reward: totalReward,
      breakdown: rewardBreakdown,
      optimization_suggestions: this.generateOptimizationSuggestions(
        weatherData,
        stationMetrics
      ),
    };
  }

  /**
   * Get base reward for specific sensor type
   */
  getBaseSensorReward(sensorType, sensorData) {
    const sensorKey = this.mapSensorToRewardKey(sensorType);
    const baseRate = this.rewardStructure[sensorKey] || 0.01;

    // Premium for rare or valuable sensors
    if (sensorKey === 'air_quality' || sensorKey === 'soil_moisture') {
      return baseRate * 1.5;
    }

    return baseRate;
  }

  /**
   * Map sensor names to reward structure keys
   */
  mapSensorToRewardKey(sensorType) {
    const mapping = {
      tempf: 'temperature',
      tempinf: 'temperature',
      temp1f: 'temperature',
      temp2f: 'temperature',
      humidity: 'humidity',
      humidity1: 'humidity',
      baromrelin: 'pressure',
      baromabsin: 'pressure',
      windspeedmph: 'wind_speed',
      windgustmph: 'wind_speed',
      winddir: 'wind_direction',
      dailyrainin: 'rainfall',
      hourlyrainin: 'rainfall',
      solarradiation: 'solar_radiation',
      uv: 'uv_index',
      soiltemp1f: 'soil_temperature',
      soilhum1: 'soil_moisture',
      pm25: 'air_quality',
      co2: 'air_quality',
    };

    return mapping[sensorType] || 'temperature';
  }

  /**
   * Calculate quality multiplier based on data precision and timeliness
   */
  calculateQualityMultiplier(weatherData, stationMetrics) {
    let multiplier = 1.0;

    // Real-time data bonus
    const dataAge = Date.now() - new Date(weatherData.timestamp).getTime();
    if (dataAge < 300000) {
      // Less than 5 minutes old
      multiplier *= this.rewardStructure.real_time;
    }

    // High precision bonus (check if sensors meet precision thresholds)
    if (this.hasHighPrecisionData(weatherData)) {
      multiplier *= this.rewardStructure.high_precision;
    }

    // Uptime bonus
    if (stationMetrics.uptime_percentage > 99) {
      multiplier += this.rewardStructure.uptime_bonus;
    }

    return multiplier;
  }

  /**
   * Calculate extreme weather bonus
   */
  calculateExtremeWeatherBonus(weatherData) {
    let bonus = 0;

    for (const [sensorType, sensorData] of Object.entries(
      weatherData.sensors || {}
    )) {
      const value = sensorData.value;

      if (sensorType === 'tempf' && (value < -10 || value > 100)) {
        bonus += 0.1;
      }

      if (sensorType === 'windspeedmph' && value > 25) {
        bonus += 0.15;
      }

      if (sensorType === 'baromrelin' && (value < 28.5 || value > 31.0)) {
        bonus += 0.1;
      }

      if (sensorType === 'hourlyrainin' && value > 0.5) {
        bonus += 0.2;
      }
    }

    return bonus;
  }

  /**
   * Calculate consistency bonus based on station metrics
   */
  calculateConsistencyBonus(stationMetrics) {
    let bonus = 0;

    // Daily streak bonus
    if (stationMetrics.consecutive_days) {
      bonus +=
        stationMetrics.consecutive_days * this.rewardStructure.daily_streak;
    }

    // Network contribution bonus
    if (stationMetrics.network_density_contribution) {
      bonus += this.rewardStructure.network_contribution;
    }

    return Math.min(bonus, 0.5); // Cap consistency bonus at 0.5 WRF
  }

  /**
   * Calculate location-based bonus for geographic rarity
   */
  calculateLocationBonus(weatherData) {
    // This would integrate with geographic analysis
    // For now, return base bonus for remote or underserved areas
    return 0.02;
  }

  /**
   * Check if data meets high precision thresholds
   */
  hasHighPrecisionData(weatherData) {
    // Simplified precision check - in production would analyze sensor specs
    const sensorCount = Object.keys(weatherData.sensors || {}).length;
    return sensorCount >= 8; // Stations with 8+ sensors considered high precision
  }

  /**
   * Generate optimization suggestions for station operators
   */
  generateOptimizationSuggestions(weatherData, stationMetrics) {
    const suggestions = [];

    if (!weatherData.sensors.solarradiation) {
      suggestions.push({
        type: 'sensor_addition',
        suggestion: 'Add solar radiation sensor for +0.035 WRF per reading',
        potential_increase: 0.035,
      });
    }

    if (!weatherData.sensors.pm25) {
      suggestions.push({
        type: 'sensor_addition',
        suggestion: 'Add air quality (PM2.5) sensor for +0.05 WRF per reading',
        potential_increase: 0.05,
      });
    }

    if (
      !stationMetrics.uptime_percentage ||
      stationMetrics.uptime_percentage < 99
    ) {
      suggestions.push({
        type: 'reliability',
        suggestion: 'Improve uptime to 99%+ for 50% reward bonus',
        potential_increase: 0.5,
      });
    }

    const dataAge = Date.now() - new Date(weatherData.timestamp).getTime();
    if (dataAge > 300000) {
      suggestions.push({
        type: 'timeliness',
        suggestion:
          'Reduce data collection interval for real-time bonus (+20%)',
        potential_increase: 0.2,
      });
    }

    return suggestions;
  }

  /**
   * Calculate optimal collection frequency for maximum rewards
   */
  calculateOptimalFrequency(stationCapabilities) {
    // Balance API rate limits, data freshness, and reward potential
    const factors = {
      api_rate_limit: stationCapabilities.max_requests_per_hour || 60,
      data_update_frequency: stationCapabilities.sensor_update_interval || 60, // seconds
      network_conditions: stationCapabilities.connection_stability || 0.95,
    };

    // Optimal frequency balances rewards vs constraints
    const maxFrequency = Math.min(
      factors.api_rate_limit / 60, // Convert to per-minute
      60 / factors.data_update_frequency // Don't collect faster than sensor updates
    );

    // Add buffer for network reliability
    const recommendedFrequency = maxFrequency * factors.network_conditions;

    return {
      recommended_interval_minutes: Math.max(
        1,
        Math.ceil(1 / recommendedFrequency)
      ),
      max_daily_earnings: this.projectDailyEarnings(
        recommendedFrequency,
        stationCapabilities
      ),
      efficiency_score: this.calculateEfficiencyScore(
        recommendedFrequency,
        stationCapabilities
      ),
    };
  }

  /**
   * Project daily earnings based on collection frequency
   */
  projectDailyEarnings(collectionsPerMinute, stationCapabilities) {
    const collectionsPerDay = collectionsPerMinute * 60 * 24;
    const avgRewardPerCollection =
      this.estimateAverageReward(stationCapabilities);
    return collectionsPerDay * avgRewardPerCollection;
  }

  /**
   * Estimate average reward per collection for a station
   */
  estimateAverageReward(stationCapabilities) {
    const sensorCount = stationCapabilities.sensor_types?.length || 5;
    const baseReward = sensorCount * 0.025; // Average sensor reward
    const qualityMultiplier =
      stationCapabilities.precision_grade === 'high' ? 1.5 : 1.0;

    return baseReward * qualityMultiplier;
  }

  /**
   * Calculate efficiency score for collection strategy
   */
  calculateEfficiencyScore(collectionsPerMinute, stationCapabilities) {
    const rewardRate = this.projectDailyEarnings(
      collectionsPerMinute,
      stationCapabilities
    );
    const costFactor = collectionsPerMinute * 0.001; // Simplified cost model

    return Math.round((rewardRate / Math.max(costFactor, 0.001)) * 100) / 100;
  }
}

module.exports = WeatherRewardOptimizer;

// CLI execution
if (require.main === module) {
  const optimizer = new WeatherRewardOptimizer();

  // Example usage with sample data
  const sampleWeatherData = {
    station_id: 'demo-station',
    timestamp: new Date().toISOString(),
    sensors: {
      tempf: { value: 72.5, unit: 'F', type: 'temperature' },
      humidity: { value: 65, unit: '%RH', type: 'humidity' },
      baromrelin: { value: 29.92, unit: 'inHg', type: 'pressure' },
      windspeedmph: { value: 8.5, unit: 'mph', type: 'wind' },
      solarradiation: { value: 456, unit: 'W/m²', type: 'solar' },
    },
  };

  const stationMetrics = {
    uptime_percentage: 99.2,
    consecutive_days: 15,
    network_density_contribution: true,
  };

  const result = optimizer.calculateReward(sampleWeatherData, stationMetrics);

  console.log('🎯 Weather Reward Optimization System');
  console.log('=====================================');
  console.log(`💰 Total Reward: ${result.total_reward} WRF`);
  console.log('\n📊 Reward Breakdown:');
  for (const [key, value] of Object.entries(result.breakdown)) {
    console.log(`   ${key}: ${value}`);
  }

  console.log('\n🚀 Optimization Suggestions:');
  result.optimization_suggestions.forEach((suggestion, index) => {
    console.log(`   ${index + 1}. ${suggestion.suggestion}`);
    console.log(
      `      Potential increase: +${suggestion.potential_increase} WRF`
    );
  });

  // Calculate optimal frequency
  const stationCapabilities = {
    max_requests_per_hour: 60,
    sensor_update_interval: 60,
    connection_stability: 0.95,
    sensor_types: ['temperature', 'humidity', 'pressure', 'wind', 'solar'],
    precision_grade: 'high',
  };

  const optimization = optimizer.calculateOptimalFrequency(stationCapabilities);
  console.log('\n⚡ Optimal Collection Strategy:');
  console.log(
    `   Recommended interval: ${optimization.recommended_interval_minutes} minutes`
  );
  console.log(
    `   Projected daily earnings: ${optimization.max_daily_earnings.toFixed(4)} WRF`
  );
  console.log(`   Efficiency score: ${optimization.efficiency_score}`);
}
