#!/usr/bin/env node

/**
 * Unified Wrfcoin Database Tool (wrf-db-tool)
 * Consolidates all database operations into a single CLI with subcommands
 *
 * Usage:
 *   wrf-db-tool push                    - Push schema changes to database
 *   wrf-db-tool migrate --apply         - Apply database migrations
 *   wrf-db-tool migrate --list          - List available migrations
 *   wrf-db-tool migrate --create <name> - Create new migration
 *   wrf-db-tool seed --rewards          - Seed rewards data
 *   wrf-db-tool seed --validators       - Seed validator data
 *   wrf-db-tool seed --achievements     - Seed achievements data
 *   wrf-db-tool seed --governance       - Seed governance data
 *   wrf-db-tool seed --all              - Seed all data
 *   wrf-db-tool generate --schema       - Generate schema files
 *   wrf-db-tool setup --governance      - Setup governance database
 *   wrf-db-tool setup --wolfram         - Setup Wolfram database
 *   wrf-db-tool status                  - Show database status
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

class WrfDatabaseTool {
  constructor() {
    this.args = process.argv.slice(2);
    this.command = this.args[0];
    this.subcommand = this.args[1];
    this.flags = this.parseFlags();

    // Database connection check
    this.dbUrl = process.env.DATABASE_URL;
    if (!this.dbUrl) {
      console.error('❌ DATABASE_URL environment variable not set');
      process.exit(1);
    }
  }

  parseFlags() {
    const flags = {};
    this.args.forEach((arg, index) => {
      if (arg.startsWith('--')) {
        const flagName = arg.slice(2);
        const nextArg = this.args[index + 1];
        flags[flagName] = nextArg && !nextArg.startsWith('--') ? nextArg : true;
      }
    });
    return flags;
  }

  async run() {
    console.log(`🗄️  Wrfcoin Database Tool v1.0`);
    console.log(`📅 ${new Date().toISOString()}`);
    console.log('');

    try {
      switch (this.command) {
        case 'push':
          await this.handlePush();
          break;
        case 'migrate':
          await this.handleMigrate();
          break;
        case 'seed':
          await this.handleSeed();
          break;
        case 'generate':
          await this.handleGenerate();
          break;
        case 'setup':
          await this.handleSetup();
          break;
        case 'status':
          await this.handleStatus();
          break;
        case 'help':
        case '--help':
        case '-h':
          this.showHelp();
          break;
        default:
          console.error(`❌ Unknown command: ${this.command}`);
          this.showHelp();
          process.exit(1);
      }
    } catch (error) {
      console.error(`❌ Error: ${error.message}`);
      process.exit(1);
    }
  }

  async handlePush() {
    console.log('🚀 Pushing schema changes to database...');

    try {
      // Use drizzle-kit to push schema changes
      execSync('npx drizzle-kit push', {
        stdio: 'inherit',
        cwd: process.cwd(),
        env: { ...process.env },
      });
      console.log('✅ Schema push completed successfully');
    } catch (error) {
      throw new Error(`Schema push failed: ${error.message}`);
    }
  }

  async handleMigrate() {
    if (this.flags.apply) {
      console.log('🔄 Applying database migrations...');
      try {
        execSync('npx drizzle-kit migrate', {
          stdio: 'inherit',
          cwd: process.cwd(),
          env: { ...process.env },
        });
        console.log('✅ Migrations applied successfully');
      } catch (error) {
        throw new Error(`Migration failed: ${error.message}`);
      }
    } else if (this.flags.list) {
      console.log('📋 Listing available migrations...');
      const migrationsDir = path.join(process.cwd(), 'backend/drizzle');
      if (fs.existsSync(migrationsDir)) {
        const migrations = fs
          .readdirSync(migrationsDir)
          .filter(file => file.endsWith('.sql'))
          .sort();

        if (migrations.length === 0) {
          console.log('📭 No migrations found');
        } else {
          console.log('Available migrations:');
          migrations.forEach((migration, index) => {
            console.log(`  ${index + 1}. ${migration}`);
          });
        }
      } else {
        console.log('📁 Migrations directory not found');
      }
    } else if (this.flags.create) {
      const migrationName = this.flags.create;
      console.log(`📝 Creating migration: ${migrationName}`);
      try {
        execSync(`npx drizzle-kit generate --name=${migrationName}`, {
          stdio: 'inherit',
          cwd: process.cwd(),
          env: { ...process.env },
        });
        console.log(`✅ Migration ${migrationName} created successfully`);
      } catch (error) {
        throw new Error(`Migration creation failed: ${error.message}`);
      }
    } else {
      console.error(
        '❌ Migration subcommand required: --apply, --list, or --create <name>'
      );
      process.exit(1);
    }
  }

  async handleSeed() {
    const seeders = [];

    if (this.flags.rewards || this.flags.all) seeders.push('rewards');
    if (this.flags.validators || this.flags.all) seeders.push('validators');
    if (this.flags.achievements || this.flags.all) seeders.push('achievements');
    if (this.flags.governance || this.flags.all) seeders.push('governance');

    if (seeders.length === 0) {
      console.error(
        '❌ Seed target required: --rewards, --validators, --achievements, --governance, or --all'
      );
      process.exit(1);
    }

    console.log(`🌱 Seeding database with: ${seeders.join(', ')}`);

    for (const seeder of seeders) {
      try {
        console.log(`📦 Seeding ${seeder}...`);

        // Check if existing seeder files exist and run them
        const existingSeederPath = path.join(__dirname, `seed-${seeder}.js`);
        if (fs.existsSync(existingSeederPath)) {
          execSync(`node ${existingSeederPath}`, {
            stdio: 'inherit',
            cwd: process.cwd(),
            env: { ...process.env },
          });
        } else {
          console.log(
            `⚠️  Seeder for ${seeder} not found, creating basic seeder...`
          );
          this.createSeeder(seeder);
        }
        console.log(`✅ ${seeder} seeding completed`);
      } catch (error) {
        console.error(`❌ Failed to seed ${seeder}: ${error.message}`);
      }
    }
  }

  async handleGenerate() {
    if (this.flags.schema) {
      console.log('🏗️  Generating database schema...');
      try {
        execSync('npx drizzle-kit introspect', {
          stdio: 'inherit',
          cwd: process.cwd(),
          env: { ...process.env },
        });
        console.log('✅ Schema generation completed');
      } catch (error) {
        throw new Error(`Schema generation failed: ${error.message}`);
      }
    } else {
      console.error('❌ Generate target required: --schema');
      process.exit(1);
    }
  }

  async handleSetup() {
    if (this.flags.governance) {
      console.log('🏛️  Setting up governance database...');
      await this.setupGovernanceDb();
    } else if (this.flags.wolfram) {
      console.log('🧮 Setting up Wolfram database...');
      await this.setupWolframDb();
    } else {
      console.error('❌ Setup target required: --governance or --wolfram');
      process.exit(1);
    }
  }

  async handleStatus() {
    console.log('📊 Database Status Report');
    console.log('========================');

    try {
      // Check database connection
      const { Pool } = require('pg');
      const pool = new Pool({ connectionString: this.dbUrl });

      await pool.query('SELECT NOW()');
      console.log('✅ Database connection: OK');

      // Check tables
      const result = await pool.query(`
                SELECT table_name 
                FROM information_schema.tables 
                WHERE table_schema = 'public'
                ORDER BY table_name
            `);

      console.log(`📋 Tables found: ${result.rows.length}`);
      result.rows.forEach(row => {
        console.log(`  • ${row.table_name}`);
      });

      // Check migration status
      try {
        const migrationResult = await pool.query(`
                    SELECT * FROM __drizzle_migrations 
                    ORDER BY created_at DESC 
                    LIMIT 5
                `);
        console.log(`🔄 Recent migrations: ${migrationResult.rows.length}`);
        migrationResult.rows.forEach(row => {
          console.log(
            `  • ${row.hash} (${new Date(row.created_at).toISOString()})`
          );
        });
      } catch (error) {
        console.log('📭 No migration history found');
      }

      await pool.end();
    } catch (error) {
      console.error(`❌ Database status check failed: ${error.message}`);
    }
  }

  createSeeder(type) {
    const seederTemplate = `/**
 * Seeder for ${type} data
 * Generated by wrf-db-tool
 */

const { Pool } = require('pg');

async function seed${type.charAt(0).toUpperCase() + type.slice(1)}() {
    const pool = new Pool({
        connectionString: process.env.DATABASE_URL
    });

    try {
        console.log('🌱 Seeding ${type} data...');
        
        // Add your seeding logic here
        // Example:
        // await pool.query('INSERT INTO ${type} (name, value) VALUES ($1, $2)', ['example', 'data']);
        
        console.log('✅ ${type} seeding completed');
    } catch (error) {
        console.error('❌ Seeding failed:', error);
        throw error;
    } finally {
        await pool.end();
    }
}

if (require.main === module) {
    seed${type.charAt(0).toUpperCase() + type.slice(1)}().catch(console.error);
}

module.exports = { seed${type.charAt(0).toUpperCase() + type.slice(1)} };`;

    const seederPath = path.join(__dirname, `seed-${type}.js`);
    fs.writeFileSync(seederPath, seederTemplate);
    console.log(`✅ Created seeder: ${seederPath}`);
  }

  async setupGovernanceDb() {
    console.log('🏛️  Creating governance tables...');

    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: this.dbUrl });

    try {
      await pool.query(`
                CREATE TABLE IF NOT EXISTS governance_proposals (
                    id SERIAL PRIMARY KEY,
                    title VARCHAR(255) NOT NULL,
                    description TEXT,
                    proposer VARCHAR(255),
                    status VARCHAR(50) DEFAULT 'pending',
                    votes_for INTEGER DEFAULT 0,
                    votes_against INTEGER DEFAULT 0,
                    created_at TIMESTAMP DEFAULT NOW(),
                    voting_ends_at TIMESTAMP
                );
            `);

      await pool.query(`
                CREATE TABLE IF NOT EXISTS governance_votes (
                    id SERIAL PRIMARY KEY,
                    proposal_id INTEGER REFERENCES governance_proposals(id),
                    voter_address VARCHAR(255),
                    vote_type VARCHAR(10) CHECK (vote_type IN ('for', 'against')),
                    weight DECIMAL(18, 8),
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);

      console.log('✅ Governance database setup completed');
    } catch (error) {
      throw new Error(`Governance setup failed: ${error.message}`);
    } finally {
      await pool.end();
    }
  }

  async setupWolframDb() {
    console.log('🧮 Creating Wolfram integration tables...');

    const { Pool } = require('pg');
    const pool = new Pool({ connectionString: this.dbUrl });

    try {
      await pool.query(`
                CREATE TABLE IF NOT EXISTS wolfram_computations (
                    id SERIAL PRIMARY KEY,
                    query TEXT NOT NULL,
                    result JSONB,
                    computation_time DECIMAL(10, 3),
                    status VARCHAR(50) DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT NOW(),
                    updated_at TIMESTAMP DEFAULT NOW()
                );
            `);

      await pool.query(`
                CREATE TABLE IF NOT EXISTS wolfram_cache (
                    id SERIAL PRIMARY KEY,
                    query_hash VARCHAR(64) UNIQUE,
                    result JSONB,
                    expires_at TIMESTAMP,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);

      console.log('✅ Wolfram database setup completed');
    } catch (error) {
      throw new Error(`Wolfram setup failed: ${error.message}`);
    } finally {
      await pool.end();
    }
  }

  showHelp() {
    console.log(`
🗄️  Wrfcoin Database Tool (wrf-db-tool)

Usage:
  wrf-db-tool <command> [options]

Commands:
  push                    Push schema changes to database
  migrate --apply         Apply pending migrations
  migrate --list          List available migrations
  migrate --create <name> Create new migration
  seed --rewards          Seed rewards data
  seed --validators       Seed validator data
  seed --achievements     Seed achievements data
  seed --governance       Seed governance data
  seed --all              Seed all data types
  generate --schema       Generate schema from database
  setup --governance      Setup governance database
  setup --wolfram         Setup Wolfram database
  status                  Show database status and health
  help                    Show this help message

Examples:
  wrf-db-tool push
  wrf-db-tool migrate --apply
  wrf-db-tool seed --rewards --validators
  wrf-db-tool setup --governance
  wrf-db-tool status

Environment Variables:
  DATABASE_URL - PostgreSQL connection string (required)
        `);
  }
}

// Main execution
if (require.main === module) {
  const tool = new WrfDatabaseTool();
  tool.run().catch(error => {
    console.error('💥 Fatal error:', error.message);
    process.exit(1);
  });
}

module.exports = WrfDatabaseTool;
