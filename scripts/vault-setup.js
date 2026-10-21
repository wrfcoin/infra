#!/usr/bin/env node

/**
 * HashiCorp Vault Setup Script for Wrfcoin Platform
 *
 * This script helps set up and configure Vault for the Wrfcoin platform
 * including development and production environments.
 */

const fs = require('fs').promises;
const path = require('path');
const { spawn } = require('child_process');

class VaultSetup {
  constructor() {
    this.vaultProcess = null;
    this.isDevMode = process.env.NODE_ENV !== 'production';
    this.vaultDir = path.join(process.cwd(), '.vault');
    this.configFile = path.join(this.vaultDir, 'config.hcl');
    this.initFile = path.join(this.vaultDir, 'init.json');
  }

  /**
   * Main setup orchestration
   */
  async setup() {
    try {
      console.log('🏗️ Setting up HashiCorp Vault for Wrfcoin Platform...');
      console.log(`📍 Mode: ${this.isDevMode ? 'Development' : 'Production'}`);

      // Create vault directory
      await this.createVaultDirectory();

      // Generate vault configuration
      await this.generateVaultConfig();

      if (this.isDevMode) {
        // Start Vault in dev mode
        await this.startDevVault();
      } else {
        // Production setup instructions
        await this.generateProductionInstructions();
      }

      // Initialize Vault
      await this.initializeVault();

      // Setup policies and secrets
      await this.setupPoliciesAndSecrets();

      console.log('✅ Vault setup completed successfully!');
    } catch (error) {
      console.error('❌ Vault setup failed:', error.message);
      process.exit(1);
    }
  }

  /**
   * Create vault directory structure
   */
  async createVaultDirectory() {
    try {
      await fs.mkdir(this.vaultDir, { recursive: true });
      await fs.mkdir(path.join(this.vaultDir, 'data'), { recursive: true });
      await fs.mkdir(path.join(this.vaultDir, 'logs'), { recursive: true });
      console.log('📁 Vault directory structure created');
    } catch (error) {
      throw new Error(`Failed to create vault directory: ${error.message}`);
    }
  }

  /**
   * Generate Vault configuration file
   */
  async generateVaultConfig() {
    const config = this.isDevMode
      ? this.getDevConfig()
      : this.getProductionConfig();

    try {
      await fs.writeFile(this.configFile, config);
      console.log(`📝 Vault configuration written to ${this.configFile}`);
    } catch (error) {
      throw new Error(`Failed to write vault config: ${error.message}`);
    }
  }

  /**
   * Development Vault configuration
   */
  getDevConfig() {
    return `
# Vault Development Configuration
ui = true
disable_mlock = true

storage "file" {
  path = "${path.join(this.vaultDir, 'data').replace(/\\/g, '/')}"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

# Development-only settings
log_level = "Debug"
default_lease_ttl = "1h"
max_lease_ttl = "24h"
`;
  }

  /**
   * Production Vault configuration
   */
  getProductionConfig() {
    return `
# Vault Production Configuration
ui = true
disable_mlock = false

storage "consul" {
  address = "127.0.0.1:8500"
  path    = "vault/"
}

# HTTP listener
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_cert_file = "/opt/vault/tls/tls.crt"
  tls_key_file  = "/opt/vault/tls/tls.key"
}

# HTTPS API
api_addr = "https://vault.wrfcoin.com:8200"
cluster_addr = "https://vault.wrfcoin.com:8201"

# Production security settings
log_level = "Info"
default_lease_ttl = "15m"
max_lease_ttl = "4h"

# Seal configuration (AWS KMS recommended)
seal "awskms" {
  region     = "us-west-2"
  kms_key_id = "alias/vault-unseal-key"
}

# Telemetry
telemetry {
  prometheus_retention_time = "30s"
  disable_hostname = true
}
`;
  }

  /**
   * Start Vault in development mode
   */
  async startDevVault() {
    return new Promise((resolve, reject) => {
      console.log('🚀 Starting Vault in development mode...');

      // Check if vault command exists
      const vaultCmd = process.platform === 'win32' ? 'vault.exe' : 'vault';

      this.vaultProcess = spawn(
        vaultCmd,
        [
          'server',
          '-config',
          this.configFile,
          '-dev-root-token-id=dev-root-token',
        ],
        {
          stdio: ['pipe', 'pipe', 'pipe'],
          detached: false,
        }
      );

      let output = '';

      this.vaultProcess.stdout.on('data', data => {
        output += data.toString();
        if (output.includes('Vault server started!')) {
          console.log('✅ Vault server started successfully');

          // Set environment variables for development
          process.env.VAULT_ADDR = 'http://127.0.0.1:8200';
          process.env.VAULT_TOKEN = 'dev-root-token';

          setTimeout(resolve, 2000); // Give vault time to fully start
        }
      });

      this.vaultProcess.stderr.on('data', data => {
        console.log('Vault output:', data.toString());
      });

      this.vaultProcess.on('error', error => {
        if (error.code === 'ENOENT') {
          reject(
            new Error(
              'Vault binary not found. Please install HashiCorp Vault:\n' +
                'https://www.vaultproject.io/downloads'
            )
          );
        } else {
          reject(error);
        }
      });

      // Timeout after 30 seconds
      setTimeout(() => {
        if (!process.env.VAULT_TOKEN) {
          reject(new Error('Vault failed to start within 30 seconds'));
        }
      }, 30000);
    });
  }

  /**
   * Initialize Vault (unseal, create initial secrets)
   */
  async initializeVault() {
    console.log('🔐 Initializing Vault...');

    if (this.isDevMode) {
      // In dev mode, vault is already initialized
      console.log('✅ Vault initialized (development mode)');
      return;
    }

    // Production initialization would be done manually for security
    console.log(
      '⚠️ Production Vault must be initialized manually for security'
    );
  }

  /**
   * Setup policies and initial secrets
   */
  async setupPoliciesAndSecrets() {
    console.log('📋 Setting up Vault policies and secrets...');

    try {
      // Import and initialize vault configuration
      const vaultConfig = require('../backend/security/vault-config');
      await vaultConfig.initialize();

      console.log('✅ Vault policies and secrets configured');
    } catch (error) {
      console.warn('⚠️ Could not setup policies and secrets:', error.message);
      console.log(
        '💡 You may need to run this setup after Vault is fully operational'
      );
    }
  }

  /**
   * Generate production setup instructions
   */
  async generateProductionInstructions() {
    const instructions = `
# HashiCorp Vault Production Setup Instructions

## Prerequisites
1. Install HashiCorp Vault: https://www.vaultproject.io/downloads
2. Install Consul (for storage backend): https://www.consul.io/downloads
3. Obtain TLS certificates for HTTPS

## Setup Steps

### 1. Start Consul (storage backend)
\`\`\`bash
consul agent -server -bootstrap -data-dir=/opt/consul/data -bind=127.0.0.1
\`\`\`

### 2. Start Vault Server
\`\`\`bash
vault server -config=${this.configFile}
\`\`\`

### 3. Initialize Vault (SECURE - Save the keys!)
\`\`\`bash
export VAULT_ADDR="https://vault.wrfcoin.com:8200"
vault operator init -key-shares=5 -key-threshold=3
\`\`\`

### 4. Unseal Vault (requires 3 of 5 keys)
\`\`\`bash
vault operator unseal <key1>
vault operator unseal <key2>
vault operator unseal <key3>
\`\`\`

### 5. Configure Authentication
\`\`\`bash
# Login with root token
vault auth <root-token>

# Enable AppRole authentication
vault auth enable approle

# Create role for Wrfcoin application
vault write auth/approle/role/wrfcoin-app \\
    policies="wrfcoin-app" \\
    token_ttl=15m \\
    token_max_ttl=4h
\`\`\`

### 6. Set Environment Variables
\`\`\`bash
export VAULT_ADDR="https://vault.wrfcoin.com:8200"
export VAULT_AUTH_METHOD="approle"
export VAULT_ROLE_ID="<role-id>"
export VAULT_SECRET_ID="<secret-id>"
\`\`\`

### 7. Initialize Wrfcoin Configuration
\`\`\`bash
node scripts/vault-setup.js
\`\`\`

## Security Considerations
- Store unseal keys in separate secure locations
- Use auto-unseal with cloud KMS in production
- Regularly rotate the root token
- Monitor audit logs
- Implement backup and disaster recovery procedures

## High Availability
For production HA setup, configure multiple Vault servers with Consul cluster.
`;

    const instructionsFile = path.join(this.vaultDir, 'PRODUCTION_SETUP.md');
    await fs.writeFile(instructionsFile, instructions);
    console.log(
      `📚 Production setup instructions written to ${instructionsFile}`
    );
  }

  /**
   * Generate environment file template
   */
  async generateEnvTemplate() {
    const envTemplate = `
# HashiCorp Vault Configuration
VAULT_ADDR=http://127.0.0.1:8200
VAULT_TOKEN=dev-root-token
VAULT_AUTH_METHOD=token
VAULT_NAMESPACE=wrfcoin
VAULT_MOUNT_PATH=secret
VAULT_SKIP_VERIFY=true

# For AppRole authentication (production)
# VAULT_ROLE_ID=your-role-id
# VAULT_SECRET_ID=your-secret-id

# For Kubernetes authentication
# VAULT_K8S_ROLE=wrfcoin-app
`;

    const envFile = path.join(process.cwd(), '.env.vault');
    await fs.writeFile(envFile, envTemplate.trim());
    console.log(`📝 Vault environment template written to ${envFile}`);
  }

  /**
   * Cleanup (stop dev vault)
   */
  async cleanup() {
    if (this.vaultProcess) {
      console.log('🧹 Stopping Vault development server...');
      this.vaultProcess.kill();
      this.vaultProcess = null;
    }
  }
}

// Handle script execution
if (require.main === module) {
  const setup = new VaultSetup();

  // Handle cleanup on exit
  process.on('SIGINT', async () => {
    console.log('\n🛑 Received SIGINT, cleaning up...');
    await setup.cleanup();
    process.exit(0);
  });

  process.on('SIGTERM', async () => {
    console.log('\n🛑 Received SIGTERM, cleaning up...');
    await setup.cleanup();
    process.exit(0);
  });

  // Run setup
  setup.setup().catch(error => {
    console.error('Setup failed:', error.message);
    process.exit(1);
  });
}

module.exports = VaultSetup;
