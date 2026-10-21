/**
 * Cross-Chain Schema Enhancement Migration
 * Adds missing columns to support enhanced bridge protocols
 */

const { Pool } = require('pg');
const { createDatabaseSSLConfig } = require('../backend/server/config/secure-ssl-config');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: createDatabaseSSLConfig(),
});

async function enhanceCrossChainSchema() {
  try {
    console.log('🔄 Enhancing cross-chain schema...');

    // Add missing columns to cross_chain_bridges table
    await pool.query(`
      ALTER TABLE crosschain.cross_chain_bridges 
      ADD COLUMN IF NOT EXISTS protocol_name VARCHAR(50),
      ADD COLUMN IF NOT EXISTS bridge_name VARCHAR(100),
      ADD COLUMN IF NOT EXISTS supported_chains JSONB,
      ADD COLUMN IF NOT EXISTS native_token VARCHAR(10),
      ADD COLUMN IF NOT EXISTS base_fee DECIMAL(10,4),
      ADD COLUMN IF NOT EXISTS percentage_fee DECIMAL(5,2),
      ADD COLUMN IF NOT EXISTS average_time VARCHAR(50),
      ADD COLUMN IF NOT EXISTS security_model VARCHAR(100),
      ADD COLUMN IF NOT EXISTS metadata JSONB
    `);

    // Add missing columns to cross_chain_transfers table
    await pool.query(`
      ALTER TABLE crosschain.cross_chain_transfers 
      ADD COLUMN IF NOT EXISTS user_address VARCHAR(100),
      ADD COLUMN IF NOT EXISTS token_symbol VARCHAR(10),
      ADD COLUMN IF NOT EXISTS fee_amount DECIMAL(18,8),
      ADD COLUMN IF NOT EXISTS received_amount DECIMAL(18,8),
      ADD COLUMN IF NOT EXISTS transaction_hash VARCHAR(100),
      ADD COLUMN IF NOT EXISTS estimated_time VARCHAR(50)
    `);

    console.log('✅ Cross-chain schema enhancement completed!');
  } catch (error) {
    console.error('❌ Error enhancing schema:', error);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  enhanceCrossChainSchema();
}

module.exports = enhanceCrossChainSchema;
