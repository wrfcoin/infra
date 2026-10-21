#!/usr/bin/env node

/**
 * Create Database Schema for Performance Dashboard
 * Sets up tables for security events, performance metrics, and weather station data
 */

const { Pool } = require('pg');
const { createDatabaseSSLConfig } = require('../backend/server/config/secure-ssl-config');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: createDatabaseSSLConfig(),
});

async function createDashboardSchema() {
  const client = await pool.connect();

  try {
    console.log('📊 Creating Performance Dashboard Database Schema...');

    // Create security_events table
    await client.query(`
      CREATE TABLE IF NOT EXISTS security_events (
        id SERIAL PRIMARY KEY,
        event_type VARCHAR(100) NOT NULL,
        severity VARCHAR(20) NOT NULL DEFAULT 'low',
        description TEXT,
        source_component VARCHAR(100),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        resolved_at TIMESTAMP,
        metadata JSONB
      );
    `);

    // Create performance_metrics table
    await client.query(`
      CREATE TABLE IF NOT EXISTS performance_metrics (
        id SERIAL PRIMARY KEY,
        metric_name VARCHAR(100) NOT NULL,
        metric_value DECIMAL(15,6) NOT NULL,
        metric_unit VARCHAR(20),
        component VARCHAR(100),
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        metadata JSONB
      );
    `);

    // Create weather_stations table
    await client.query(`
      CREATE TABLE IF NOT EXISTS weather_stations (
        id SERIAL PRIMARY KEY,
        station_id VARCHAR(100) UNIQUE NOT NULL,
        location VARCHAR(200),
        status VARCHAR(20) DEFAULT 'active',
        last_report_time TIMESTAMP,
        validation_score DECIMAL(5,2) DEFAULT 100.00,
        tamper_alert_count INTEGER DEFAULT 0,
        hardware_model VARCHAR(100),
        firmware_version VARCHAR(50),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      );
    `);

    // Create compliance_status table
    await client.query(`
      CREATE TABLE IF NOT EXISTS compliance_status (
        id SERIAL PRIMARY KEY,
        framework_id VARCHAR(50) NOT NULL,
        framework_name VARCHAR(100) NOT NULL,
        compliance_score DECIMAL(5,2) NOT NULL,
        status VARCHAR(20) NOT NULL,
        last_assessment TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        next_assessment TIMESTAMP,
        evidence_count INTEGER DEFAULT 0,
        gaps_count INTEGER DEFAULT 0
      );
    `);

    // Insert initial weather stations
    await client.query(`
      INSERT INTO weather_stations (station_id, location, hardware_model, firmware_version, validation_score)
      SELECT 'bryan-acurite-iris-2025', 'Bryan, TX', 'AcuRite Iris', '1.2.3', 98.5
      WHERE NOT EXISTS (SELECT 1 FROM weather_stations WHERE station_id = 'bryan-acurite-iris-2025')
      
      UNION ALL
      
      SELECT 'weather-station-001', 'Protected Location', 'Davis Vantage Pro2', '2.1.0', 99.2
      WHERE NOT EXISTS (SELECT 1 FROM weather_stations WHERE station_id = 'weather-station-001')
      
      UNION ALL
      
      SELECT 'weather-station-002', 'Protected Location', 'WeatherFlow Tempest', '1.5.2', 97.8
      WHERE NOT EXISTS (SELECT 1 FROM weather_stations WHERE station_id = 'weather-station-002');
    `);

    // Insert compliance framework status
    await client.query(`
      INSERT INTO compliance_status (framework_id, framework_name, compliance_score, status)
      SELECT 'soc2', 'SOC 2 Type II', 100.00, 'Compliant'
      WHERE NOT EXISTS (SELECT 1 FROM compliance_status WHERE framework_id = 'soc2')
      
      UNION ALL
      
      SELECT 'iso27001', 'ISO 27001:2022', 100.00, 'Compliant'
      WHERE NOT EXISTS (SELECT 1 FROM compliance_status WHERE framework_id = 'iso27001')
      
      UNION ALL
      
      SELECT 'pcidss', 'PCI DSS v4.0', 100.00, 'Compliant'
      WHERE NOT EXISTS (SELECT 1 FROM compliance_status WHERE framework_id = 'pcidss')
      
      UNION ALL
      
      SELECT 'gdpr', 'GDPR', 100.00, 'Compliant'
      WHERE NOT EXISTS (SELECT 1 FROM compliance_status WHERE framework_id = 'gdpr')
      
      UNION ALL
      
      SELECT 'nist', 'NIST CSF 2.0', 100.00, 'Compliant'
      WHERE NOT EXISTS (SELECT 1 FROM compliance_status WHERE framework_id = 'nist');
    `);

    // Insert sample security events for demonstration
    await client.query(`
      INSERT INTO security_events (event_type, severity, description, source_component)
      VALUES 
        ('authentication_success', 'low', 'Successful user authentication', 'auth_service'),
        ('failed_login_attempt', 'medium', 'Multiple failed login attempts detected', 'auth_service'),
        ('security_scan_completed', 'low', 'Automated security scan completed successfully', 'security_scanner'),
        ('compliance_check_passed', 'low', 'All compliance checks passed', 'compliance_monitor'),
        ('weather_data_validated', 'low', 'Weather data signature verified', 'weather_validator'),
        ('tamper_detection_test', 'low', 'Tamper detection system test completed', 'weather_station'),
        ('backup_completed', 'low', 'Database backup completed successfully', 'backup_service')
    `);

    // Insert sample performance metrics
    const now = new Date();
    const performanceData = [];

    // Generate last hour of performance data
    for (let i = 0; i < 60; i++) {
      const timestamp = new Date(now.getTime() - i * 60000);

      performanceData.push(
        [
          'base_layer_tps',
          (Math.random() * 500 + 500).toFixed(2),
          'tps',
          'blockchain_core',
          timestamp,
        ],
        [
          'layer2_tps',
          (Math.random() * 3000 + 2000).toFixed(2),
          'tps',
          'layer2_network',
          timestamp,
        ],
        [
          'network_latency',
          (Math.random() * 2 + 1).toFixed(1),
          'ms',
          'network',
          timestamp,
        ],
        [
          'network_throughput',
          (Math.random() * 0.5 + 1).toFixed(1),
          'GB/s',
          'network',
          timestamp,
        ],
        [
          'packet_loss',
          (Math.random() * 0.02).toFixed(4),
          'percent',
          'network',
          timestamp,
        ],
        [
          'active_connections',
          Math.floor(Math.random() * 500 + 1000),
          'count',
          'network',
          timestamp,
        ]
      );
    }

    for (const [
      metricName,
      value,
      unit,
      component,
      timestamp,
    ] of performanceData) {
      await client.query(
        `
        INSERT INTO performance_metrics (metric_name, metric_value, metric_unit, component, timestamp)
        VALUES ($1, $2, $3, $4, $5)
      `,
        [metricName, value, unit, component, timestamp]
      );
    }

    // Update weather station last report times
    await client.query(`
      UPDATE weather_stations 
      SET last_report_time = CURRENT_TIMESTAMP - INTERVAL '2 minutes'
      WHERE station_id = 'bryan-acurite-iris-2025'
    `);

    await client.query(`
      UPDATE weather_stations 
      SET last_report_time = CURRENT_TIMESTAMP - INTERVAL '1 minute'
      WHERE station_id = 'weather-station-001'
    `);

    await client.query(`
      UPDATE weather_stations 
      SET last_report_time = CURRENT_TIMESTAMP - INTERVAL '3 minutes'
      WHERE station_id = 'weather-station-002'
    `);

    // Create indexes for performance
    await client.query(`
      CREATE INDEX IF NOT EXISTS idx_security_events_created_at ON security_events(created_at);
      CREATE INDEX IF NOT EXISTS idx_security_events_severity ON security_events(severity);
      CREATE INDEX IF NOT EXISTS idx_performance_metrics_timestamp ON performance_metrics(timestamp);
      CREATE INDEX IF NOT EXISTS idx_performance_metrics_name ON performance_metrics(metric_name);
      CREATE INDEX IF NOT EXISTS idx_weather_stations_status ON weather_stations(status);
    `);

    console.log('✅ Performance Dashboard Schema Created Successfully');
    console.log(
      '   📊 Tables: security_events, performance_metrics, weather_stations, compliance_status'
    );
    console.log('   🚀 Sample data inserted for demonstration');
    console.log('   🔍 Indexes created for optimal query performance');
  } catch (error) {
    console.error('❌ Error creating dashboard schema:', error.message);
    throw error;
  } finally {
    client.release();
    await pool.end();
  }
}

// Run the schema creation
createDashboardSchema()
  .then(() => {
    console.log('🎯 Dashboard schema setup complete');
    process.exit(0);
  })
  .catch(error => {
    console.error('💥 Schema creation failed:', error.message);
    process.exit(1);
  });
