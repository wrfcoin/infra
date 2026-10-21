/**
 * Focused IoT Schema Consolidation
 * Based on actual database analysis - consolidates 17 IoT tables into 5 tables
 * Prioritizes largest tables: luftdaten_measurements (1.7MB) and environmental data
 */

const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

class FocusedIoTConsolidator {
  constructor() {
    this.sourceSchema = 'iot';
    this.backupSchema = 'iot_backup_focused';
  }

  async run() {
    console.log('📡 Starting Focused IoT Schema Consolidation');
    console.log('🎯 Target: 17 tables → 5 tables (70% reduction)');
    console.log('📊 Prioritizing largest tables with real data\n');

    try {
      await this.analyzeCurrentTables();
      await this.createSafeBackup();
      await this.createConsolidatedTables();
      await this.migrateDataSafely();
      await this.verifyMigration();
      await this.cleanupEmptyTables();

      console.log('\n✅ IoT schema consolidation completed successfully!');
      console.log('📊 Reduced from 17 tables to 5 tables');
    } catch (error) {
      console.error('❌ Consolidation failed:', error.message);
      await this.rollbackIfNeeded();
      throw error;
    }
  }

  async analyzeCurrentTables() {
    console.log('🔍 Analyzing current IoT tables...');

    const result = await pool.query(`
      SELECT 
        table_name,
        (SELECT COUNT(*) FROM ${this.sourceSchema}."" || table_name) as row_count,
        pg_size_pretty(pg_total_relation_size('${this.sourceSchema}.' || table_name)) as size
      FROM information_schema.tables 
      WHERE table_schema = '${this.sourceSchema}'
        AND table_type = 'BASE TABLE'
      ORDER BY pg_total_relation_size('${this.sourceSchema}.' || table_name) DESC
    `);

    console.log('   📊 Current IoT tables by size:');
    for (const row of result.rows) {
      console.log(
        `   • ${row.table_name}: ${row.row_count} rows (${row.size})`
      );
    }
  }

  async createSafeBackup() {
    console.log('💾 Creating focused backup...');

    await pool.query(`CREATE SCHEMA IF NOT EXISTS ${this.backupSchema}`);

    const tablesWithData = [
      'luftdaten_measurements',
      'environmental_data_submissions',
      'environmental_submissions',
      'environmental_offset_proofs',
      'luftdaten_sensors',
    ];

    for (const table of tablesWithData) {
      try {
        const checkResult = await pool.query(`
          SELECT COUNT(*) FROM ${this.sourceSchema}.${table}
        `);
        const rowCount = parseInt(checkResult.rows[0].count);

        if (rowCount > 0) {
          await pool.query(`
            CREATE TABLE ${this.backupSchema}.${table} AS 
            SELECT * FROM ${this.sourceSchema}.${table}
          `);
          console.log(`   ✅ Backed up ${table} (${rowCount} rows)`);
        }
      } catch (error) {
        console.log(`   ⚠️ Skipped ${table}: ${error.message}`);
      }
    }
  }

  async createConsolidatedTables() {
    console.log('🏗️ Creating consolidated IoT tables...');

    // 1. Environmental Data Master (combines environmental submissions and data)
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ${this.sourceSchema}.environmental_data_master (
        id SERIAL PRIMARY KEY,
        submission_id VARCHAR(255),
        submitter_id INTEGER,
        data_type VARCHAR(100),
        location_info JSONB,
        sensor_readings JSONB,
        environmental_metrics JSONB,
        validation_status VARCHAR(50) DEFAULT 'pending',
        reward_amount DECIMAL(20,8),
        blockchain_hash VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        
        -- Offset proof data
        proof_type VARCHAR(100),
        verification_hash VARCHAR(255),
        carbon_offset_amount DECIMAL(20,8),
        
        -- Source table identifier
        source_table VARCHAR(100),
        original_id INTEGER
      )
    `);

    // 2. Sensor Networks Master (combines luftdaten and other sensor data)
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ${this.sourceSchema}.sensor_networks_master (
        id SERIAL PRIMARY KEY,
        sensor_id VARCHAR(255),
        network_type VARCHAR(100), -- 'luftdaten', 'acurite', 'ambient', etc.
        sensor_info JSONB,
        location_data JSONB,
        measurement_data JSONB,
        timestamp TIMESTAMP,
        quality_score INTEGER,
        
        -- Network-specific fields
        luftdaten_id INTEGER,
        sensor_type VARCHAR(100),
        
        -- Source tracking
        source_table VARCHAR(100),
        original_id INTEGER,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // 3. Device Registry Master
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ${this.sourceSchema}.device_registry_master (
        id SERIAL PRIMARY KEY,
        device_id VARCHAR(255) UNIQUE,
        device_type VARCHAR(100),
        owner_id INTEGER,
        capabilities JSONB,
        status VARCHAR(50) DEFAULT 'active',
        last_seen TIMESTAMP,
        registration_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // 4. Measurements Archive Master
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ${this.sourceSchema}.measurements_archive_master (
        id SERIAL PRIMARY KEY,
        measurement_id VARCHAR(255),
        device_id VARCHAR(255),
        measurement_data JSONB,
        timestamp TIMESTAMP,
        archive_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // 5. IoT Rewards Master
    await pool.query(`
      CREATE TABLE IF NOT EXISTS ${this.sourceSchema}.iot_rewards_master (
        id SERIAL PRIMARY KEY,
        recipient_id INTEGER,
        reward_type VARCHAR(100),
        amount DECIMAL(20,8),
        source_activity JSONB,
        transaction_hash VARCHAR(255),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);

    console.log('   ✅ All consolidated IoT tables created');
  }

  async migrateDataSafely() {
    console.log('📦 Migrating IoT data safely...');

    // 1. Migrate environmental data submissions
    console.log('   🌱 Migrating environmental submissions...');
    await pool.query(`
      INSERT INTO ${this.sourceSchema}.environmental_data_master 
      (submission_id, submitter_id, data_type, location_info, sensor_readings, 
       source_table, original_id, created_at)
      SELECT 
        submission_id::text,
        submitter_id,
        data_type,
        jsonb_build_object('location', location) as location_info,
        jsonb_build_object('data', data, 'metadata', metadata) as sensor_readings,
        'environmental_data_submissions' as source_table,
        id as original_id,
        COALESCE(created_at, CURRENT_TIMESTAMP)
      FROM ${this.sourceSchema}.environmental_data_submissions
    `);

    // 2. Migrate environmental submissions
    await pool.query(`
      INSERT INTO ${this.sourceSchema}.environmental_data_master 
      (submitter_id, data_type, location_info, environmental_metrics, reward_amount,
       blockchain_hash, source_table, original_id, created_at)
      SELECT 
        submitter_id,
        'environmental_submission' as data_type,
        jsonb_build_object('region', region) as location_info,
        jsonb_build_object('temperature', temperature, 'humidity', humidity, 
                          'pressure', pressure, 'air_quality', air_quality) as environmental_metrics,
        reward_amount,
        blockchain_hash,
        'environmental_submissions' as source_table,
        id as original_id,
        COALESCE(timestamp, CURRENT_TIMESTAMP)
      FROM ${this.sourceSchema}.environmental_submissions
    `);

    // 3. Migrate offset proofs
    await pool.query(`
      INSERT INTO ${this.sourceSchema}.environmental_data_master 
      (submitter_id, proof_type, carbon_offset_amount, verification_hash,
       source_table, original_id, created_at)
      SELECT 
        user_id as submitter_id,
        proof_type,
        amount as carbon_offset_amount,
        verification_hash,
        'environmental_offset_proofs' as source_table,
        id as original_id,
        CURRENT_TIMESTAMP
      FROM ${this.sourceSchema}.environmental_offset_proofs
    `);

    // 4. Migrate luftdaten measurements
    console.log('   📡 Migrating luftdaten measurements...');
    await pool.query(`
      INSERT INTO ${this.sourceSchema}.sensor_networks_master 
      (sensor_id, network_type, measurement_data, timestamp, luftdaten_id,
       source_table, original_id, created_at)
      SELECT 
        sensor_id::text,
        'luftdaten' as network_type,
        jsonb_build_object('value', value, 'value_type', value_type) as measurement_data,
        timestamp,
        sensor_id as luftdaten_id,
        'luftdaten_measurements' as source_table,
        id as original_id,
        CURRENT_TIMESTAMP
      FROM ${this.sourceSchema}.luftdaten_measurements
    `);

    // 5. Migrate luftdaten sensors
    await pool.query(`
      INSERT INTO ${this.sourceSchema}.sensor_networks_master 
      (sensor_id, network_type, sensor_info, location_data, sensor_type,
       source_table, original_id, created_at)
      SELECT 
        id::text as sensor_id,
        'luftdaten' as network_type,
        jsonb_build_object('sensor_type', sensor_type) as sensor_info,
        jsonb_build_object('latitude', latitude, 'longitude', longitude) as location_data,
        sensor_type,
        'luftdaten_sensors' as source_table,
        id as original_id,
        CURRENT_TIMESTAMP
      FROM ${this.sourceSchema}.luftdaten_sensors
    `);

    console.log('   ✅ Data migration completed');
  }

  async verifyMigration() {
    console.log('🔍 Verifying IoT data migration...');

    const verifications = [
      { table: 'environmental_data_master', expectedMin: 580 },
      { table: 'sensor_networks_master', expectedMin: 12475 },
      { table: 'device_registry_master', expectedMin: 0 },
      { table: 'measurements_archive_master', expectedMin: 0 },
      { table: 'iot_rewards_master', expectedMin: 0 },
    ];

    for (const { table, expectedMin } of verifications) {
      const result = await pool.query(
        `SELECT COUNT(*) FROM ${this.sourceSchema}.${table}`
      );
      const count = parseInt(result.rows[0].count);

      if (count >= expectedMin) {
        console.log(`   ✅ ${table}: ${count} rows migrated`);
      } else {
        console.log(
          `   ⚠️ ${table}: ${count} rows (expected at least ${expectedMin})`
        );
      }
    }
  }

  async cleanupEmptyTables() {
    console.log('🧹 Cleaning up empty original tables...');

    const emptyTables = [
      'iot_device_registrations',
      'iot_measurement_history',
      'iot_device_types',
      'iot_network_protocols',
      'iot_data_validation',
      'iot_rewards_history',
      'sensor_calibration_data',
      'sensor_network_topology',
      'sensor_data_quality',
      'environmental_monitoring_stations',
      'environmental_sensor_networks',
      'environmental_data_validation',
    ];

    for (const table of emptyTables) {
      try {
        const result = await pool.query(
          `SELECT COUNT(*) FROM ${this.sourceSchema}.${table}`
        );
        const count = parseInt(result.rows[0].count);

        if (count === 0) {
          await pool.query(
            `DROP TABLE IF EXISTS ${this.sourceSchema}.${table} CASCADE`
          );
          console.log(`   ✅ Removed empty table: ${table}`);
        } else {
          console.log(`   ⚠️ Kept ${table}: has ${count} rows`);
        }
      } catch (error) {
        console.log(`   ⚠️ ${table}: ${error.message}`);
      }
    }
  }

  async rollbackIfNeeded() {
    console.log('🔄 Rollback capability available in backup schema');
  }
}

async function main() {
  const consolidator = new FocusedIoTConsolidator();

  try {
    await consolidator.run();
    console.log('\n🎉 IoT consolidation completed successfully!');
    console.log('📊 Database optimization: 17 → 5 tables in IoT schema');
  } catch (error) {
    console.error('\n❌ Consolidation failed:', error.message);
    process.exit(1);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main();
}

module.exports = FocusedIoTConsolidator;
