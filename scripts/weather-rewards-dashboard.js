#!/usr/bin/env node

/**
 * Weather Rewards Dashboard
 * Real-time monitoring and optimization tracking for weather station earnings
 */

const fs = require('fs');
const path = require('path');
const WeatherRewardOptimizer = require('./optimized-weather-rewards');

class WeatherRewardsDashboard {
  constructor() {
    this.optimizer = new WeatherRewardOptimizer();
    this.stations = new Map();
    this.totalEarnings = 0;
    this.sessionsData = [];
    this.optimizationMetrics = {
      totalOptimizationGains: 0,
      averageMultiplier: 1.0,
      topPerformingStation: null,
    };
  }

  /**
   * Track earnings from a weather station
   */
  trackStationEarnings(stationId, data) {
    if (!this.stations.has(stationId)) {
      this.stations.set(stationId, {
        id: stationId,
        name: data.station_name || stationId,
        totalEarnings: 0,
        totalSubmissions: 0,
        successfulSubmissions: 0,
        failedSubmissions: 0,
        averageReward: 0,
        lastSubmission: null,
        location: data.location || 'Unknown',
        optimizationGains: 0,
        sensors: new Set(),
        qualityScores: [],
        sessionStart: Date.now(),
      });
    }

    const station = this.stations.get(stationId);

    // Update station metrics
    station.totalSubmissions++;
    if (data.success) {
      station.successfulSubmissions++;
      const reward = data.reward || data.optimized_reward || 0.1;
      station.totalEarnings += reward;
      station.averageReward =
        station.totalEarnings / station.successfulSubmissions;
      station.lastSubmission = Date.now();

      // Track optimization gains
      const baseReward = 0.1;
      if (reward > baseReward) {
        station.optimizationGains += reward - baseReward;
        this.optimizationMetrics.totalOptimizationGains += reward - baseReward;
      }

      // Track sensors
      if (data.sensors) {
        Object.keys(data.sensors).forEach(sensor =>
          station.sensors.add(sensor)
        );
      }

      // Track quality
      if (data.quality_score) {
        station.qualityScores.push(data.quality_score);
      }

      this.totalEarnings += reward;
    } else {
      station.failedSubmissions++;
    }

    this.updateOptimizationMetrics();
    this.logSession(stationId, data);
  }

  /**
   * Update global optimization metrics
   */
  updateOptimizationMetrics() {
    let totalMultiplier = 0;
    let stationCount = 0;
    let topStation = null;
    let highestEarnings = 0;

    for (const [stationId, station] of this.stations) {
      if (station.successfulSubmissions > 0) {
        const multiplier = station.averageReward / 0.1; // Compare to base reward
        totalMultiplier += multiplier;
        stationCount++;

        if (station.totalEarnings > highestEarnings) {
          highestEarnings = station.totalEarnings;
          topStation = station;
        }
      }
    }

    this.optimizationMetrics.averageMultiplier =
      stationCount > 0 ? totalMultiplier / stationCount : 1.0;
    this.optimizationMetrics.topPerformingStation = topStation;
  }

  /**
   * Log session data for analytics
   */
  logSession(stationId, data) {
    this.sessionsData.push({
      timestamp: Date.now(),
      stationId: stationId,
      reward: data.reward || data.optimized_reward || 0.1,
      success: data.success,
      sensorCount: data.sensors ? Object.keys(data.sensors).length : 0,
      qualityScore: data.quality_score || 0.8,
      optimizationApplied: data.optimization_applied || false,
    });

    // Keep only last 1000 sessions
    if (this.sessionsData.length > 1000) {
      this.sessionsData = this.sessionsData.slice(-1000);
    }
  }

  /**
   * Generate comprehensive dashboard report
   */
  generateDashboard() {
    const report = {
      timestamp: new Date().toISOString(),
      summary: this.generateSummary(),
      stations: this.generateStationReports(),
      optimization: this.generateOptimizationReport(),
      projections: this.generateProjections(),
      recommendations: this.generateRecommendations(),
    };

    return report;
  }

  /**
   * Generate summary statistics
   */
  generateSummary() {
    const totalSubmissions = Array.from(this.stations.values()).reduce(
      (sum, station) => sum + station.totalSubmissions,
      0
    );
    const successfulSubmissions = Array.from(this.stations.values()).reduce(
      (sum, station) => sum + station.successfulSubmissions,
      0
    );
    const successRate =
      totalSubmissions > 0
        ? (successfulSubmissions / totalSubmissions) * 100
        : 0;

    return {
      total_earnings: this.totalEarnings,
      total_stations: this.stations.size,
      total_submissions: totalSubmissions,
      successful_submissions: successfulSubmissions,
      success_rate: Math.round(successRate * 100) / 100,
      optimization_gains: this.optimizationMetrics.totalOptimizationGains,
      average_multiplier:
        Math.round(this.optimizationMetrics.averageMultiplier * 100) / 100,
    };
  }

  /**
   * Generate detailed station reports
   */
  generateStationReports() {
    const reports = [];

    for (const [stationId, station] of this.stations) {
      const sessionHours =
        (Date.now() - station.sessionStart) / (1000 * 60 * 60);
      const earningsPerHour =
        sessionHours > 0 ? station.totalEarnings / sessionHours : 0;
      const avgQuality =
        station.qualityScores.length > 0
          ? station.qualityScores.reduce((a, b) => a + b, 0) /
            station.qualityScores.length
          : 0;

      reports.push({
        id: stationId,
        name: station.name,
        location: station.location,
        total_earnings: Math.round(station.totalEarnings * 10000) / 10000,
        total_submissions: station.totalSubmissions,
        success_rate:
          station.totalSubmissions > 0
            ? Math.round(
                (station.successfulSubmissions / station.totalSubmissions) *
                  10000
              ) / 100
            : 0,
        average_reward: Math.round(station.averageReward * 10000) / 10000,
        optimization_gains:
          Math.round(station.optimizationGains * 10000) / 10000,
        earnings_per_hour: Math.round(earningsPerHour * 10000) / 10000,
        sensor_count: station.sensors.size,
        sensors: Array.from(station.sensors),
        average_quality: Math.round(avgQuality * 1000) / 1000,
        last_submission: station.lastSubmission
          ? new Date(station.lastSubmission).toISOString()
          : null,
        session_duration_hours: Math.round(sessionHours * 100) / 100,
      });
    }

    return reports.sort((a, b) => b.total_earnings - a.total_earnings);
  }

  /**
   * Generate optimization analysis report
   */
  generateOptimizationReport() {
    const recentSessions = this.sessionsData.slice(-100); // Last 100 sessions
    const optimizedSessions = recentSessions.filter(s => s.optimizationApplied);
    const standardSessions = recentSessions.filter(s => !s.optimizationApplied);

    const avgOptimizedReward =
      optimizedSessions.length > 0
        ? optimizedSessions.reduce((sum, s) => sum + s.reward, 0) /
          optimizedSessions.length
        : 0;
    const avgStandardReward =
      standardSessions.length > 0
        ? standardSessions.reduce((sum, s) => sum + s.reward, 0) /
          standardSessions.length
        : 0.1;

    return {
      total_optimization_gains:
        Math.round(this.optimizationMetrics.totalOptimizationGains * 10000) /
        10000,
      average_reward_multiplier:
        Math.round(this.optimizationMetrics.averageMultiplier * 100) / 100,
      optimized_sessions_count: optimizedSessions.length,
      standard_sessions_count: standardSessions.length,
      average_optimized_reward: Math.round(avgOptimizedReward * 10000) / 10000,
      average_standard_reward: Math.round(avgStandardReward * 10000) / 10000,
      optimization_improvement:
        avgStandardReward > 0
          ? Math.round(
              ((avgOptimizedReward - avgStandardReward) / avgStandardReward) *
                10000
            ) / 100
          : 0,
      top_performing_station: this.optimizationMetrics.topPerformingStation
        ? {
            id: this.optimizationMetrics.topPerformingStation.id,
            name: this.optimizationMetrics.topPerformingStation.name,
            earnings:
              Math.round(
                this.optimizationMetrics.topPerformingStation.totalEarnings *
                  10000
              ) / 10000,
          }
        : null,
    };
  }

  /**
   * Generate earnings projections
   */
  generateProjections() {
    const activeStations = Array.from(this.stations.values()).filter(
      s => s.successfulSubmissions > 0
    );

    if (activeStations.length === 0) {
      return { daily: 0, weekly: 0, monthly: 0, yearly: 0 };
    }

    // Calculate average earnings rate across all stations
    const totalSessionHours = activeStations.reduce((sum, station) => {
      return sum + (Date.now() - station.sessionStart) / (1000 * 60 * 60);
    }, 0);

    const avgHourlyRate =
      totalSessionHours > 0 ? this.totalEarnings / totalSessionHours : 0;

    return {
      hourly: Math.round(avgHourlyRate * 10000) / 10000,
      daily: Math.round(avgHourlyRate * 24 * 10000) / 10000,
      weekly: Math.round(avgHourlyRate * 24 * 7 * 100) / 100,
      monthly: Math.round(avgHourlyRate * 24 * 30 * 100) / 100,
      yearly: Math.round(avgHourlyRate * 24 * 365 * 100) / 100,
    };
  }

  /**
   * Generate optimization recommendations
   */
  generateRecommendations() {
    const recommendations = [];

    for (const [stationId, station] of this.stations) {
      const stationRecommendations = [];

      // Low success rate recommendations
      if (
        station.totalSubmissions > 5 &&
        station.successfulSubmissions / station.totalSubmissions < 0.9
      ) {
        stationRecommendations.push({
          type: 'reliability',
          priority: 'high',
          suggestion: 'Improve station reliability - low success rate detected',
          potential_impact: 'Increase earnings by 20-30%',
        });
      }

      // Sensor diversity recommendations
      if (station.sensors.size < 8) {
        stationRecommendations.push({
          type: 'sensor_expansion',
          priority: 'medium',
          suggestion: `Add more sensors (currently ${station.sensors.size}, optimal: 8+)`,
          potential_impact: `Increase earnings by ${Math.round((8 - station.sensors.size) * 0.025 * 100)} WRF per reading`,
        });
      }

      // Quality improvement recommendations
      const avgQuality =
        station.qualityScores.length > 0
          ? station.qualityScores.reduce((a, b) => a + b, 0) /
            station.qualityScores.length
          : 0;
      if (avgQuality < 0.9) {
        stationRecommendations.push({
          type: 'quality_improvement',
          priority: 'medium',
          suggestion: 'Improve data quality through calibration or maintenance',
          potential_impact: 'Increase quality multiplier by 15-25%',
        });
      }

      if (stationRecommendations.length > 0) {
        recommendations.push({
          station_id: stationId,
          station_name: station.name,
          recommendations: stationRecommendations,
        });
      }
    }

    // Global recommendations
    if (this.optimizationMetrics.averageMultiplier < 2.0) {
      recommendations.push({
        station_id: 'global',
        station_name: 'All Stations',
        recommendations: [
          {
            type: 'optimization_system',
            priority: 'high',
            suggestion: 'Enable optimization system across all stations',
            potential_impact: 'Increase average earnings by 100-300%',
          },
        ],
      });
    }

    return recommendations;
  }

  /**
   * Display formatted dashboard in console
   */
  displayDashboard() {
    const dashboard = this.generateDashboard();

    console.log('\n🎯 Weather Rewards Dashboard');
    console.log('=====================================');

    // Summary
    console.log('📊 Summary Statistics:');
    console.log(
      `   Total Earnings: ${dashboard.summary.total_earnings.toFixed(4)} WRF`
    );
    console.log(`   Active Stations: ${dashboard.summary.total_stations}`);
    console.log(`   Success Rate: ${dashboard.summary.success_rate}%`);
    console.log(
      `   Optimization Gains: +${dashboard.summary.optimization_gains.toFixed(4)} WRF`
    );
    console.log(
      `   Average Multiplier: ${dashboard.summary.average_multiplier}x`
    );

    // Top stations
    console.log('\n🏆 Top Performing Stations:');
    dashboard.stations.slice(0, 3).forEach((station, index) => {
      console.log(`   ${index + 1}. ${station.name}`);
      console.log(
        `      Earnings: ${station.total_earnings} WRF | Rate: ${station.earnings_per_hour}/hr`
      );
      console.log(
        `      Sensors: ${station.sensor_count} | Success: ${station.success_rate}%`
      );
    });

    // Projections
    console.log('\n📈 Earnings Projections:');
    console.log(`   Daily: ${dashboard.projections.daily} WRF`);
    console.log(`   Weekly: ${dashboard.projections.weekly} WRF`);
    console.log(`   Monthly: ${dashboard.projections.monthly} WRF`);
    console.log(`   Yearly: ${dashboard.projections.yearly} WRF`);

    // Optimization insights
    if (dashboard.optimization.optimization_improvement > 0) {
      console.log('\n🚀 Optimization Performance:');
      console.log(
        `   Improvement: ${dashboard.optimization.optimization_improvement}%`
      );
      console.log(
        `   Optimized Avg: ${dashboard.optimization.average_optimized_reward} WRF`
      );
      console.log(
        `   Standard Avg: ${dashboard.optimization.average_standard_reward} WRF`
      );
    }

    // Top recommendations
    console.log('\n💡 Top Recommendations:');
    dashboard.recommendations.slice(0, 3).forEach((rec, index) => {
      if (rec.recommendations.length > 0) {
        const topRec = rec.recommendations[0];
        console.log(
          `   ${index + 1}. ${rec.station_name}: ${topRec.suggestion}`
        );
        console.log(`      Impact: ${topRec.potential_impact}`);
      }
    });

    console.log('\n=====================================');
  }

  /**
   * Save dashboard data to file
   */
  saveDashboard(filename = 'weather-rewards-dashboard.json') {
    const dashboard = this.generateDashboard();
    const filepath = path.join(__dirname, '..', filename);

    try {
      fs.writeFileSync(filepath, JSON.stringify(dashboard, null, 2));
      console.log(`📁 Dashboard saved to: ${filepath}`);
    } catch (error) {
      console.error('Failed to save dashboard:', error.message);
    }
  }

  /**
   * Start real-time monitoring
   */
  startMonitoring(intervalMinutes = 5) {
    console.log(
      `🔄 Starting real-time monitoring (${intervalMinutes} minute intervals)`
    );

    setInterval(
      () => {
        this.displayDashboard();
        this.saveDashboard();
      },
      intervalMinutes * 60 * 1000
    );
  }
}

module.exports = WeatherRewardsDashboard;

// CLI execution
if (require.main === module) {
  const dashboard = new WeatherRewardsDashboard();

  // Simulate some data for demonstration
  dashboard.trackStationEarnings('bryan-acurite-iris-2025', {
    station_name: "Bryan's AcuRite Iris® 2025",
    success: true,
    reward: 0.1,
    sensors: { temp: 1, humidity: 1, pressure: 1, wind: 1 },
    quality_score: 0.95,
    location: 'Suburban',
  });

  dashboard.trackStationEarnings('example-ws5000-ambient', {
    station_name: "Example Station",
    success: true,
    optimized_reward: 0.35,
    sensors: { temp: 1, humidity: 1, pressure: 1, wind: 1, solar: 1, uv: 1 },
    quality_score: 0.92,
    optimization_applied: true,
    location: 'Example location',
  });

  dashboard.displayDashboard();
  dashboard.saveDashboard();
}
