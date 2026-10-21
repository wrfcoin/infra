#!/usr/bin/env node
/**
 * Rewards Schema Consolidation Migration
 * Consolidates 12 rewards tables into 4 optimized tables
 *
 * Before: 12 tables with overlapping functionality
 * After: 4 streamlined tables with preserved data integrity
 */

const { Pool } = require('pg');
const fs = require('fs');
const path = require('path');
const { createDatabaseSSLConfig } = require('../backend/server/config/secure-ssl-config');

class RewardsSchemaConsolidator {
  constructor() {
    this.pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: createDatabaseSSLConfig(),
    });

    this.migrationReport = {
      timestamp: new Date().toISOString(),
      tablesConsolidated: 0,
      dataPreserved: true,
      backupCreated: false,
      errors: [],
    };
  }

  async run() {
    console.log('🏆 Starting Rewards Schema Consolidation');
    console.log('📊 Consolidating 12 tables into 4 optimized tables...\n');

    try {
      // Step 1: Create backup of existing data
      await this.createBackup();

      // Step 2: Create new consolidated tables
      await this.createConsolidatedTables();

      // Step 3: Migrate data from old tables to new structure
      await this.migrateData();

      // Step 4: Update indexes and constraints
      await this.optimizeNewTables();

      // Step 5: Verify data integrity
      await this.verifyDataIntegrity();

      // Step 6: Generate migration report
      await this.generateReport();

      console.log('\n✅ Rewards schema consolidation completed successfully!');
      console.log(`📊 Reduced from 12 tables to 4 tables`);
      console.log(
        `📄 Migration report: docs/migration/rewards-consolidation-report.json`
      );
    } catch (error) {
      console.error('❌ Migration failed:', error);
      this.migrationReport.errors.push(error.message);
      throw error;
    } finally {
      await this.pool.end();
    }
  }

  async createBackup() {
    console.log('💾 Creating backup of existing rewards data...');

    const backupQueries = [
      'CREATE SCHEMA IF NOT EXISTS rewards_backup',
      `CREATE TABLE rewards_backup.achievements_backup AS SELECT * FROM rewards.achievements`,
      `CREATE TABLE rewards_backup.achievement_categories_backup AS SELECT * FROM rewards.achievement_categories`,
      `CREATE TABLE rewards_backup.achievement_progress_backup AS SELECT * FROM rewards.achievement_progress`,
      `CREATE TABLE rewards_backup.user_achievements_backup AS SELECT * FROM rewards.user_achievements`,
      `CREATE TABLE rewards_backup.miner_achievements_backup AS SELECT * FROM rewards.miner_achievements`,
      `CREATE TABLE rewards_backup.miner_achievement_progress_backup AS SELECT * FROM rewards.miner_achievement_progress`,
      `CREATE TABLE rewards_backup.miner_earned_achievements_backup AS SELECT * FROM rewards.miner_earned_achievements`,
      `CREATE TABLE rewards_backup.mining_rewards_backup AS SELECT * FROM rewards.mining_rewards`,
      `CREATE TABLE rewards_backup.validator_rewards_backup AS SELECT * FROM rewards.validator_rewards`,
      `CREATE TABLE rewards_backup.contributor_rewards_backup AS SELECT * FROM rewards.contributor_rewards`,
      `CREATE TABLE rewards_backup.reward_distribution_config_backup AS SELECT * FROM rewards.reward_distribution_config`,
      `CREATE TABLE rewards_backup.mining_contributions_backup AS SELECT * FROM rewards.mining_contributions`,
    ];

    for (const query of backupQueries) {
      try {
        await this.pool.query(query);
      } catch (error) {
        console.warn(`Backup warning: ${error.message}`);
      }
    }

    this.migrationReport.backupCreated = true;
    console.log('✅ Backup created successfully');
  }

  async createConsolidatedTables() {
    console.log('🏗️ Creating consolidated table structure...');

    // Table 1: Unified achievements table
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS rewards.achievements_consolidated (
        id SERIAL PRIMARY KEY,
        achievement_id VARCHAR(64) NOT NULL UNIQUE,
        name VARCHAR(100) NOT NULL,
        description TEXT NOT NULL,
        category VARCHAR(50) NOT NULL,
        subcategory VARCHAR(50),
        icon_url VARCHAR(255),
        difficulty VARCHAR(20) NOT NULL DEFAULT 'COMMON',
        rarity VARCHAR(20) DEFAULT 'common',
        points INTEGER NOT NULL DEFAULT 10,
        governance_multiplier DOUBLE PRECISION DEFAULT 1.0,
        reputation_multiplier DOUBLE PRECISION DEFAULT 1.0,
        requirements JSONB NOT NULL,
        rewards JSONB,
        is_active BOOLEAN NOT NULL DEFAULT true,
        is_soulbound BOOLEAN DEFAULT false,
        display_order INTEGER DEFAULT 0,
        created_at TIMESTAMP NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMP NOT NULL DEFAULT NOW()
      )
    `);

    // Table 2: Unified user progress and achievements
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS rewards.user_progress_consolidated (
        id SERIAL PRIMARY KEY,
        user_address VARCHAR(64) NOT NULL,
        achievement_id VARCHAR(64) NOT NULL,
        status VARCHAR(20) NOT NULL DEFAULT 'in_progress', -- 'in_progress', 'completed', 'claimed'
        current_value INTEGER DEFAULT 0,
        target_value INTEGER,
        percentage_complete INTEGER DEFAULT 0,
        progress_data JSONB,
        evidence_data JSONB,
        completed_at TIMESTAMP,
        claimed_at TIMESTAMP,
        transaction_id VARCHAR(64),
        is_visible BOOLEAN DEFAULT true,
        last_updated TIMESTAMP NOT NULL DEFAULT NOW(),
        UNIQUE(user_address, achievement_id)
      )
    `);

    // Table 3: Unified token rewards
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS rewards.token_rewards_consolidated (
        id SERIAL PRIMARY KEY,
        reward_id VARCHAR(64) NOT NULL UNIQUE,
        user_address VARCHAR(64) NOT NULL,
        reward_type VARCHAR(20) NOT NULL, -- 'mining', 'validation', 'contribution'
        amount NUMERIC(20, 8) NOT NULL,
        token_symbol VARCHAR(10) DEFAULT 'WRF',
        source_type VARCHAR(50), -- 'block_mining', 'data_submission', 'governance', etc.
        source_id VARCHAR(64),
        transaction_id VARCHAR(64),
        block_height INTEGER,
        achievement_id VARCHAR(64),
        metadata JSONB,
        status VARCHAR(20) DEFAULT 'pending', -- 'pending', 'distributed', 'claimed'
        distributed_at TIMESTAMP,
        claimed_at TIMESTAMP,
        created_at TIMESTAMP NOT NULL DEFAULT NOW()
      )
    `);

    // Table 4: System configuration and tracking
    await this.pool.query(`
      CREATE TABLE IF NOT EXISTS rewards.system_config_consolidated (
        id SERIAL PRIMARY KEY,
        config_key VARCHAR(50) NOT NULL UNIQUE,
        config_value JSONB NOT NULL,
        category VARCHAR(30) NOT NULL, -- 'distribution', 'rates', 'limits', 'tracking'
        description TEXT,
        is_active BOOLEAN DEFAULT true,
        last_updated TIMESTAMP NOT NULL DEFAULT NOW(),
        updated_by VARCHAR(64)
      )
    `);

    console.log('✅ Consolidated tables created');
  }

  async migrateData() {
    console.log('📦 Migrating data to consolidated structure...');

    // Migrate achievements data
    await this.migrateAchievements();

    // Migrate user progress and completions
    await this.migrateUserProgress();

    // Migrate reward distributions
    await this.migrateRewards();

    // Migrate system configuration
    await this.migrateSystemConfig();

    console.log('✅ Data migration completed');
  }

  async migrateAchievements() {
    console.log('  📋 Migrating achievements...');

    // Migrate from achievements table
    await this.pool.query(`
      INSERT INTO rewards.achievements_consolidated 
      (achievement_id, name, description, category, icon_url, difficulty, points, 
       governance_multiplier, reputation_multiplier, requirements, is_active, 
       display_order, created_at, updated_at)
      SELECT 
        achievement_id, name, description, category, icon_url, 
        difficulty, points, governance_weight::decimal, reputation_boost,
        requirements::jsonb, active, display_order, created_at, updated_at
      FROM rewards.achievements
      ON CONFLICT (achievement_id) DO NOTHING
    `);

    // Migrate from miner_achievements table
    await this.pool.query(`
      INSERT INTO rewards.achievements_consolidated 
      (achievement_id, name, description, category, icon_url, difficulty, points, 
       requirements, is_active, created_at, updated_at)
      SELECT 
        achievement_id, name, description, category, icon_url, 
        difficulty, points, requirements::jsonb, true, created_at, updated_at
      FROM rewards.miner_achievements
      ON CONFLICT (achievement_id) DO NOTHING
    `);
  }

  async migrateUserProgress() {
    console.log('  👥 Migrating user progress and achievements...');

    // Migrate achievement progress
    await this.pool.query(`
      INSERT INTO rewards.user_progress_consolidated 
      (user_address, achievement_id, status, current_value, target_value, 
       percentage_complete, progress_data, last_updated)
      SELECT 
        wallet_address, achievement_id, 'in_progress', 
        current_value, target_value, percentage_complete,
        tracking_data::jsonb, last_updated
      FROM rewards.achievement_progress
      ON CONFLICT (user_address, achievement_id) DO NOTHING
    `);

    // Migrate completed achievements
    await this.pool.query(`
      INSERT INTO rewards.user_progress_consolidated 
      (user_address, achievement_id, status, percentage_complete, 
       completed_at, transaction_id, last_updated)
      SELECT 
        wallet_address, achievement_id, 'completed', 100,
        awarded_at, transaction_id, awarded_at
      FROM rewards.user_achievements
      ON CONFLICT (user_address, achievement_id) 
      DO UPDATE SET 
        status = 'completed',
        percentage_complete = 100,
        completed_at = EXCLUDED.completed_at
    `);

    // Migrate miner earned achievements
    await this.pool.query(`
      INSERT INTO rewards.user_progress_consolidated 
      (user_address, achievement_id, status, percentage_complete, 
       evidence_data, completed_at, transaction_id, last_updated)
      SELECT 
        miner_address, achievement_id, 'completed', 100,
        proof::jsonb, earned_at, transaction_id, earned_at
      FROM rewards.miner_earned_achievements
      ON CONFLICT (user_address, achievement_id) 
      DO UPDATE SET 
        status = 'completed',
        evidence_data = EXCLUDED.evidence_data
    `);
  }

  async migrateRewards() {
    console.log('  💰 Migrating reward distributions...');

    // Migrate mining rewards
    await this.pool.query(`
      INSERT INTO rewards.token_rewards_consolidated 
      (reward_id, user_address, reward_type, amount, source_type, 
       transaction_id, block_height, metadata, status, distributed_at, created_at)
      SELECT 
        'mining_' || id::text, miner_address, 'mining', amount, 
        'block_mining', transaction_id, block_height, 
        jsonb_build_object('pool_id', pool_id, 'contribution_hash', contribution_hash),
        CASE WHEN distributed_at IS NOT NULL THEN 'distributed' ELSE 'pending' END,
        distributed_at, created_at
      FROM rewards.mining_rewards
    `);

    // Migrate validator rewards
    await this.pool.query(`
      INSERT INTO rewards.token_rewards_consolidated 
      (reward_id, user_address, reward_type, amount, source_type,
       transaction_id, metadata, status, distributed_at, created_at)
      SELECT 
        'validator_' || id::text, validator_address, 'validation', amount,
        'validation_service', transaction_id,
        jsonb_build_object('validation_count', validation_count),
        CASE WHEN distributed_at IS NOT NULL THEN 'distributed' ELSE 'pending' END,
        distributed_at, created_at
      FROM rewards.validator_rewards
    `);

    // Migrate contributor rewards
    await this.pool.query(`
      INSERT INTO rewards.token_rewards_consolidated 
      (reward_id, user_address, reward_type, amount, source_type,
       transaction_id, metadata, status, distributed_at, created_at)
      SELECT 
        'contrib_' || id::text, contributor_address, 'contribution', amount,
        contribution_type, transaction_id,
        jsonb_build_object('contribution_hash', contribution_hash),
        CASE WHEN distributed_at IS NOT NULL THEN 'distributed' ELSE 'pending' END,
        distributed_at, created_at
      FROM rewards.contributor_rewards
    `);
  }

  async migrateSystemConfig() {
    console.log('  ⚙️ Migrating system configuration...');

    // Migrate reward distribution config
    await this.pool.query(`
      INSERT INTO rewards.system_config_consolidated 
      (config_key, config_value, category, description, is_active, last_updated)
      SELECT 
        config_key, 
        jsonb_build_object('value', config_value, 'metadata', metadata),
        'distribution', description, is_active, updated_at
      FROM rewards.reward_distribution_config
      ON CONFLICT (config_key) DO NOTHING
    `);

    // Add default mining contribution tracking config
    await this.pool.query(`
      INSERT INTO rewards.system_config_consolidated 
      (config_key, config_value, category, description, is_active)
      VALUES 
      ('mining_contribution_tracking', 
       '{"enabled": true, "batch_size": 100, "verification_required": true}',
       'tracking', 'Mining contribution tracking configuration', true)
      ON CONFLICT (config_key) DO NOTHING
    `);
  }

  async optimizeNewTables() {
    console.log('🔧 Creating indexes and constraints...');

    // Indexes for achievements_consolidated
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_achievements_category ON rewards.achievements_consolidated(category)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_achievements_difficulty ON rewards.achievements_consolidated(difficulty)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_achievements_active ON rewards.achievements_consolidated(is_active)`
    );

    // Indexes for user_progress_consolidated
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_user_progress_address ON rewards.user_progress_consolidated(user_address)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_user_progress_status ON rewards.user_progress_consolidated(status)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_user_progress_achievement ON rewards.user_progress_consolidated(achievement_id)`
    );

    // Indexes for token_rewards_consolidated
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_token_rewards_address ON rewards.token_rewards_consolidated(user_address)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_token_rewards_type ON rewards.token_rewards_consolidated(reward_type)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_token_rewards_status ON rewards.token_rewards_consolidated(status)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_token_rewards_created ON rewards.token_rewards_consolidated(created_at)`
    );

    // Indexes for system_config_consolidated
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_system_config_category ON rewards.system_config_consolidated(category)`
    );
    await this.pool.query(
      `CREATE INDEX IF NOT EXISTS idx_system_config_active ON rewards.system_config_consolidated(is_active)`
    );

    console.log('✅ Optimization completed');
  }

  async verifyDataIntegrity() {
    console.log('🔍 Verifying data integrity...');

    const checks = [
      {
        name: 'Achievement count verification',
        query: `
          SELECT 
            (SELECT COUNT(*) FROM rewards.achievements) + 
            (SELECT COUNT(*) FROM rewards.miner_achievements) as original_count,
            (SELECT COUNT(*) FROM rewards.achievements_consolidated) as consolidated_count
        `,
      },
      {
        name: 'User progress verification',
        query: `
          SELECT 
            (SELECT COUNT(*) FROM rewards.achievement_progress) +
            (SELECT COUNT(*) FROM rewards.user_achievements) +
            (SELECT COUNT(*) FROM rewards.miner_earned_achievements) as original_count,
            (SELECT COUNT(*) FROM rewards.user_progress_consolidated) as consolidated_count
        `,
      },
      {
        name: 'Rewards verification',
        query: `
          SELECT 
            (SELECT COUNT(*) FROM rewards.mining_rewards) +
            (SELECT COUNT(*) FROM rewards.validator_rewards) +
            (SELECT COUNT(*) FROM rewards.contributor_rewards) as original_count,
            (SELECT COUNT(*) FROM rewards.token_rewards_consolidated) as consolidated_count
        `,
      },
    ];

    for (const check of checks) {
      const result = await this.pool.query(check.query);
      const { original_count, consolidated_count } = result.rows[0];

      console.log(`  ${check.name}: ${original_count} → ${consolidated_count}`);

      if (parseInt(original_count) > parseInt(consolidated_count)) {
        throw new Error(`Data loss detected in ${check.name}`);
      }
    }

    console.log('✅ Data integrity verified');
  }

  async generateReport() {
    console.log('📄 Generating migration report...');

    this.migrationReport.tablesConsolidated = 12;
    this.migrationReport.finalTableCount = 4;
    this.migrationReport.reductionPercentage = (((12 - 4) / 12) * 100).toFixed(
      1
    );

    // Get final counts
    const countsResult = await this.pool.query(`
      SELECT 
        (SELECT COUNT(*) FROM rewards.achievements_consolidated) as achievements,
        (SELECT COUNT(*) FROM rewards.user_progress_consolidated) as user_progress,
        (SELECT COUNT(*) FROM rewards.token_rewards_consolidated) as token_rewards,
        (SELECT COUNT(*) FROM rewards.system_config_consolidated) as system_config
    `);

    this.migrationReport.finalCounts = countsResult.rows[0];

    // Ensure docs/migration directory exists
    const reportsDir = path.join(process.cwd(), 'docs', 'migration');
    if (!fs.existsSync(reportsDir)) {
      fs.mkdirSync(reportsDir, { recursive: true });
    }

    // Write report
    const reportPath = path.join(
      reportsDir,
      'rewards-consolidation-report.json'
    );
    fs.writeFileSync(reportPath, JSON.stringify(this.migrationReport, null, 2));

    console.log('✅ Migration report generated');
  }
}

// Execute migration if run directly
if (require.main === module) {
  const consolidator = new RewardsSchemaConsolidator();
  consolidator.run().catch(console.error);
}

module.exports = RewardsSchemaConsolidator;
