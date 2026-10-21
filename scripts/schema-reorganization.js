/**
 * Wrfcoin Database Schema Reorganization
 * Migrates 95 tables into 9 logical schemas for better maintainability
 */

const { Pool } = require('pg');
const { createDatabaseSSLConfig } = require('../backend/server/config/secure-ssl-config');

const DATABASE_URL = process.env.DATABASE_URL;

if (!DATABASE_URL) {
  console.error('❌ DATABASE_URL environment variable is required');
  process.exit(1);
}

const pool = new Pool({
  connectionString: DATABASE_URL,
  ssl: createDatabaseSSLConfig(),
});

// Schema definitions with table mappings
const SCHEMA_MAPPINGS = {
  core: {
    description: 'Blockchain Core Operations',
    tables: [
      'blocks',
      'transactions',
      'computational_work_proofs',
      'trust_anchors',
      'trust_endorsements',
      'slash_events',
      'shards',
      'shard_rebalance_operations',
    ],
  },
  governance: {
    description: 'Governance & Voting System',
    tables: [
      'governance_proposals',
      'governance_votes',
      'governance_treasury_transactions',
      'governance_foundation_members',
      'governance_foundation_actions',
      'governance_parameters',
      'governance_parameter_history',
      'governance_phase_transitions',
      'governance_budget_categories',
      'governance_contributions',
      'governance_delegations',
      'governance_rewards',
      'integration_governance',
    ],
  },
  rewards: {
    description: 'Achievements & Economic Incentives',
    tables: [
      'achievements',
      'achievement_categories',
      'achievement_progress',
      'user_achievements',
      'miner_achievements',
      'miner_achievement_progress',
      'miner_earned_achievements',
      'mining_rewards',
      'validator_rewards',
      'contributor_rewards',
      'reward_distribution_config',
      'mining_contributions',
    ],
  },
  iot: {
    description: 'Environmental & Sensor Data',
    tables: [
      'environmental_data_submissions',
      'environmental_submissions',
      'environmental_attestations',
      'environmental_offset_proofs',
      'foam_device_verifications',
      'foam_points',
      'luftdaten_measurements',
      'luftdaten_sensors',
      'ttn_devices',
      'ttn_measurements',
      'ttn_sensors',
      'streamr_data_points',
      'streamr_products',
      'streamr_streams',
      'streamr_subscriptions',
    ],
  },
  crosschain: {
    description: 'Cross-Chain Operations',
    tables: [
      'bridge_transactions',
      'cross_chain_bridges',
      'cross_chain_transfers',
      'axelar_chains',
      'axelar_messages',
      'axelar_tokens',
      'axelar_transfers',
      'layer_zero_adapter_params',
      'layer_zero_chains',
      'layer_zero_messages',
      'layer_zero_relayers',
      'layer_zero_token_transfers',
      'wormhole_messages',
      'wormhole_nft_transfers',
      'wormhole_transfers',
      'wormhole_vaas',
    ],
  },
  users: {
    description: 'User, Wallets, and Identity',
    tables: [
      'users',
      'user_operations',
      'smart_wallets',
      'decentralized_identities',
      'verifiable_credentials',
      'reputation_events',
      'reputation_rankings',
      'reputation_scores',
      'delegations',
      'voting_power',
      'node_peers',
    ],
  },
  analytics: {
    description: 'Forecasts and Metrics',
    tables: [
      'forecast_coverage_metrics',
      'data_validation_attestations',
      'proximity_incentives',
      'validator_activity',
      'validator_oracle_participation',
      'computational_block_data',
      'computational_tasks',
      'computational_nodes',
    ],
  },
  infra: {
    description: 'Infrastructure & System Management',
    tables: [
      'migrations',
      'bundle_operations',
      'bundles',
      'integration_fire_drills',
      'sponsors',
      'akash_deployments',
      'algorithm_advancements',
      'computational_nfts',
    ],
  },
  oracle: {
    description: 'External Knowledge & Oracle Services',
    tables: [
      'oracle_requests',
      'oracle_responses',
      'wolfram_settings',
      'validators',
    ],
  },
};

class SchemaReorganizer {
  constructor() {
    this.client = null;
    this.dryRun = process.argv.includes('--dry-run');
  }

  async connect() {
    this.client = await pool.connect();
    console.log('✅ Connected to database');
  }

  async disconnect() {
    if (this.client) {
      this.client.release();
      console.log('✅ Disconnected from database');
    }
    await pool.end();
  }

  async createSchemas() {
    console.log('\n🏗️  Creating new schemas...');

    for (const [schemaName, config] of Object.entries(SCHEMA_MAPPINGS)) {
      const createSchemaSQL = `CREATE SCHEMA IF NOT EXISTS ${schemaName};`;
      const commentSQL = `COMMENT ON SCHEMA ${schemaName} IS '${config.description}';`;

      if (this.dryRun) {
        console.log(`[DRY RUN] ${createSchemaSQL}`);
        console.log(`[DRY RUN] ${commentSQL}`);
      } else {
        await this.client.query(createSchemaSQL);
        await this.client.query(commentSQL);
        console.log(`✅ Created schema: ${schemaName}`);
      }
    }
  }

  async checkTableExists(tableName) {
    const result = await this.client.query(
      'SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name = $1)',
      [tableName]
    );
    return result.rows[0].exists;
  }

  async moveTable(tableName, targetSchema) {
    const exists = await this.checkTableExists(tableName);
    if (!exists) {
      console.log(`⚠️  Table ${tableName} does not exist - skipping`);
      return false;
    }

    const moveSQL = `ALTER TABLE ${tableName} SET SCHEMA ${targetSchema};`;

    if (this.dryRun) {
      console.log(`[DRY RUN] ${moveSQL}`);
    } else {
      try {
        await this.client.query(moveSQL);
        console.log(`✅ Moved ${tableName} → ${targetSchema}`);
        return true;
      } catch (error) {
        console.log(`❌ Failed to move ${tableName}: ${error.message}`);
        return false;
      }
    }
    return true;
  }

  async migrateTables() {
    console.log('\n📦 Moving tables to new schemas...');

    let totalMoved = 0;
    let totalFailed = 0;

    for (const [schemaName, config] of Object.entries(SCHEMA_MAPPINGS)) {
      console.log(`\n📁 Processing schema: ${schemaName}`);

      for (const tableName of config.tables) {
        const success = await this.moveTable(tableName, schemaName);
        if (success) {
          totalMoved++;
        } else {
          totalFailed++;
        }
      }
    }

    console.log(`\n📊 Migration Summary:`);
    console.log(`✅ Tables moved: ${totalMoved}`);
    console.log(`❌ Failed moves: ${totalFailed}`);
  }

  async createConvenienceViews() {
    console.log('\n👁️  Creating convenience views for cross-schema queries...');

    const viewDefinitions = [
      {
        name: 'unified_rewards_view',
        sql: `
          CREATE OR REPLACE VIEW public.unified_rewards_view AS
          SELECT 
            'mining' as reward_type,
            id,
            amount,
            created_at
          FROM rewards.mining_rewards
          UNION ALL
          SELECT 
            'validator' as reward_type,
            id,
            amount,
            created_at
          FROM rewards.validator_rewards;
        `,
      },
      {
        name: 'sensor_data_unified',
        sql: `
          CREATE OR REPLACE VIEW public.sensor_data_unified AS
          SELECT 
            'luftdaten' as sensor_type,
            sensor_id,
            temperature,
            humidity,
            created_at
          FROM iot.luftdaten_measurements
          UNION ALL
          SELECT 
            'ttn' as sensor_type,
            device_id as sensor_id,
            temperature,
            humidity,
            created_at
          FROM iot.ttn_measurements;
        `,
      },
    ];

    for (const view of viewDefinitions) {
      if (this.dryRun) {
        console.log(`[DRY RUN] Creating view: ${view.name}`);
      } else {
        try {
          await this.client.query(view.sql);
          console.log(`✅ Created view: ${view.name}`);
        } catch (error) {
          console.log(
            `⚠️  View ${view.name} creation failed: ${error.message}`
          );
        }
      }
    }
  }

  async updatePermissions() {
    console.log('\n🔐 Setting schema permissions...');

    const permissionSQL = [
      'GRANT USAGE ON SCHEMA core TO PUBLIC;',
      'GRANT USAGE ON SCHEMA governance TO PUBLIC;',
      'GRANT USAGE ON SCHEMA rewards TO PUBLIC;',
      'GRANT USAGE ON SCHEMA iot TO PUBLIC;',
      'GRANT USAGE ON SCHEMA crosschain TO PUBLIC;',
      'GRANT USAGE ON SCHEMA users TO PUBLIC;',
      'GRANT USAGE ON SCHEMA analytics TO PUBLIC;',
      'GRANT USAGE ON SCHEMA infra TO PUBLIC;',
      'GRANT USAGE ON SCHEMA oracle TO PUBLIC;',
    ];

    for (const sql of permissionSQL) {
      if (this.dryRun) {
        console.log(`[DRY RUN] ${sql}`);
      } else {
        try {
          await this.client.query(sql);
        } catch (error) {
          console.log(`⚠️  Permission setting failed: ${error.message}`);
        }
      }
    }

    if (!this.dryRun) {
      console.log('✅ Schema permissions configured');
    }
  }

  async generateMigrationReport() {
    console.log('\n📋 Generating migration report...');

    const report = {
      timestamp: new Date().toISOString(),
      schemas: {},
      totalTables: 0,
    };

    for (const [schemaName, config] of Object.entries(SCHEMA_MAPPINGS)) {
      const tableCount = config.tables.length;
      report.schemas[schemaName] = {
        description: config.description,
        tableCount,
        tables: config.tables,
      };
      report.totalTables += tableCount;
    }

    const reportPath = 'docs/architecture/schema-migration-report.json';
    const fs = require('fs');

    if (!this.dryRun) {
      fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
      console.log(`✅ Report saved to: ${reportPath}`);
    } else {
      console.log(`[DRY RUN] Would save report to: ${reportPath}`);
    }

    return report;
  }

  async run() {
    try {
      console.log('🚀 Starting Wrfcoin Database Schema Reorganization');
      console.log(`Mode: ${this.dryRun ? 'DRY RUN' : 'LIVE MIGRATION'}`);

      await this.connect();
      await this.createSchemas();
      await this.migrateTables();
      await this.createConvenienceViews();
      await this.updatePermissions();

      const report = await this.generateMigrationReport();

      console.log('\n🎉 Schema reorganization completed successfully!');
      console.log(`📊 Total schemas: ${Object.keys(SCHEMA_MAPPINGS).length}`);
      console.log(`📊 Total tables: ${report.totalTables}`);

      if (this.dryRun) {
        console.log('\n💡 Run without --dry-run to execute the migration');
      }
    } catch (error) {
      console.error('❌ Migration failed:', error);
      process.exit(1);
    } finally {
      await this.disconnect();
    }
  }
}

// Run the migration
if (require.main === module) {
  const reorganizer = new SchemaReorganizer();
  reorganizer.run();
}

module.exports = SchemaReorganizer;
