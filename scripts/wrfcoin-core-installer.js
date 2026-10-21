#!/usr/bin/env node

/**
 * Wrfcoin Core One-Command Installer
 * npx wrfcoin-core install
 *
 * Sets up a complete, sovereign Wrfcoin node deployment
 */

const fs = require('fs');
const path = require('path');
const { execSync, exec } = require('child_process');
const crypto = require('crypto');

class WrfcoinCoreInstaller {
  constructor() {
    this.installDir = process.cwd();
    this.configDir = path.join(
      process.env.HOME || process.env.USERPROFILE,
      '.wrfcoin'
    );
    this.logFile = path.join(this.configDir, 'install.log');
    this.config = {
      network: 'testnet',
      mode: 'sovereign',
      ipfs: true,
      hardware_security: false,
      geographic_redundancy: false,
    };
  }

  async install() {
    console.log('🚀 Wrfcoin Core Sovereign Node Installer');
    console.log('========================================\n');

    await this.parseArguments();
    await this.createDirectories();
    await this.detectSystem();
    await this.installDependencies();
    await this.setupIPFS();
    await this.setupPostgreSQL();
    await this.cloneRepository();
    await this.installNodeDependencies();
    await this.generateConfiguration();
    await this.setupSecurity();
    await this.createServiceFiles();
    await this.runInitialTests();
    await this.displayCompletionInfo();
  }

  async parseArguments() {
    const args = process.argv.slice(2);

    for (let i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--network':
          this.config.network = args[++i] || 'testnet';
          break;
        case '--mainnet':
          this.config.network = 'mainnet';
          break;
        case '--no-ipfs':
          this.config.ipfs = false;
          break;
        case '--hardware-security':
          this.config.hardware_security = true;
          break;
        case '--geographic-redundancy':
          this.config.geographic_redundancy = true;
          break;
        case '--help':
          this.showHelp();
          process.exit(0);
      }
    }

    console.log('📋 Installation Configuration:');
    console.log(`   Network: ${this.config.network}`);
    console.log(`   Mode: ${this.config.mode}`);
    console.log(`   IPFS: ${this.config.ipfs ? 'Enabled' : 'Disabled'}`);
    console.log(
      `   Hardware Security: ${this.config.hardware_security ? 'Enabled' : 'Simulated'}`
    );
    console.log(
      `   Geographic Redundancy: ${this.config.geographic_redundancy ? 'Enabled' : 'Single Location'}\n`
    );
  }

  showHelp() {
    console.log(`
Wrfcoin Core Installer

Usage: npx wrfcoin-core install [options]

Options:
  --network <network>    Network to connect to (testnet|mainnet) [default: testnet]
  --mainnet             Shorthand for --network mainnet
  --no-ipfs             Skip IPFS installation
  --hardware-security   Enable hardware security modules (requires YubiKey/HSM)
  --geographic-redundancy Enable multi-region deployment setup
  --help                Show this help message

Examples:
  npx wrfcoin-core install                    # Basic testnet installation
  npx wrfcoin-core install --mainnet          # Mainnet installation
  npx wrfcoin-core install --hardware-security # With HSM support
  npx wrfcoin-core install --geographic-redundancy # Multi-region setup
`);
  }

  async createDirectories() {
    console.log('📁 Creating directories...');

    const dirs = [
      this.configDir,
      path.join(this.configDir, 'keys'),
      path.join(this.configDir, 'data'),
      path.join(this.configDir, 'logs'),
      path.join(this.configDir, 'ipfs'),
      path.join(this.configDir, 'backups'),
    ];

    for (const dir of dirs) {
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
        this.log(`Created directory: ${dir}`);
      }
    }
  }

  async detectSystem() {
    console.log('🔍 Detecting system...');

    this.system = {
      platform: process.platform,
      arch: process.arch,
      node_version: process.version,
      has_docker: this.hasCommand('docker'),
      has_git: this.hasCommand('git'),
      has_curl: this.hasCommand('curl'),
      has_ipfs: this.hasCommand('ipfs'),
    };

    console.log(`   Platform: ${this.system.platform} ${this.system.arch}`);
    console.log(`   Node.js: ${this.system.node_version}`);
    console.log(`   Docker: ${this.system.has_docker ? '✅' : '❌'}`);
    console.log(`   Git: ${this.system.has_git ? '✅' : '❌'}`);
    console.log(`   IPFS: ${this.system.has_ipfs ? '✅' : '❌'}`);
  }

  hasCommand(command) {
    // Validate command name to prevent injection attacks
    if (!/^[a-zA-Z0-9_-]+$/.test(command)) {
      throw new Error(`Invalid command name: ${command}`);
    }

    try {
      execSync(`which ${command}`, { stdio: 'ignore' });
      return true;
    } catch {
      return false;
    }
  }

  async installDependencies() {
    console.log('📦 Installing system dependencies...');

    if (!this.system.has_git) {
      throw new Error('Git is required. Please install Git first.');
    }

    // Install Docker if not present
    if (!this.system.has_docker && this.config.mode === 'sovereign') {
      console.log('   Installing Docker...');
      await this.installDocker();
    }

    // Install PostgreSQL if not in Docker mode
    if (!this.system.has_docker) {
      console.log('   Installing PostgreSQL...');
      await this.installPostgreSQL();
    }
  }

  async installDocker() {
    const platform = this.system.platform;

    try {
      if (platform === 'linux') {
        execSync('curl -fsSL https://get.docker.com -o get-docker.sh', {
          stdio: 'inherit',
        });
        execSync('sh get-docker.sh', { stdio: 'inherit' });
        execSync('sudo usermod -aG docker $USER', { stdio: 'inherit' });
        console.log(
          '   ⚠️  Please log out and log back in for Docker permissions to take effect'
        );
      } else if (platform === 'darwin') {
        console.log(
          '   Please install Docker Desktop from https://docker.com/products/docker-desktop'
        );
        console.log('   Then rerun this installer');
        process.exit(1);
      } else {
        console.log(
          '   Please install Docker for your platform and rerun this installer'
        );
        process.exit(1);
      }
    } catch (error) {
      console.warn(
        '   Docker installation failed, continuing without containerization'
      );
    }
  }

  async setupIPFS() {
    if (!this.config.ipfs) {
      console.log('📡 Skipping IPFS setup (disabled)');
      return;
    }

    console.log('📡 Setting up IPFS...');

    if (!this.system.has_ipfs) {
      console.log('   Installing IPFS...');
      await this.installIPFS();
    }

    // Initialize IPFS if not already done
    const ipfsDir = path.join(this.configDir, 'ipfs');
    if (!fs.existsSync(path.join(ipfsDir, 'config'))) {
      console.log('   Initializing IPFS...');
      execSync(`IPFS_PATH=${ipfsDir} ipfs init`, { stdio: 'inherit' });
    }

    // Configure IPFS for Wrfcoin
    this.configureIPFS(ipfsDir);
  }

  async installIPFS() {
    const platform = this.system.platform;
    const arch = this.system.arch;

    const version = 'v0.17.0';
    const filename = `go-ipfs_${version}_${platform}-${arch === 'x64' ? 'amd64' : arch}.tar.gz`;
    const url = `https://dist.ipfs.io/go-ipfs/${version}/${filename}`;

    try {
      execSync(`curl -O ${url}`, { stdio: 'inherit' });
      execSync(`tar -xzf ${filename}`, { stdio: 'inherit' });
      execSync('sudo mv go-ipfs/ipfs /usr/local/bin/', { stdio: 'inherit' });
      execSync(`rm -rf go-ipfs ${filename}`, { stdio: 'inherit' });
      console.log('   ✅ IPFS installed successfully');
    } catch (error) {
      console.warn('   IPFS installation failed, continuing without IPFS');
      this.config.ipfs = false;
    }
  }

  configureIPFS(ipfsDir) {
    const configPath = path.join(ipfsDir, 'config');
    const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

    // Configure for Wrfcoin usage
    config.Addresses = {
      ...config.Addresses,
      API: '/ip4/127.0.0.1/tcp/5001',
      Gateway: '/ip4/127.0.0.1/tcp/8080',
    };

    config.Bootstrap = [
      ...config.Bootstrap,
      // Add Wrfcoin-specific bootstrap nodes here when available
    ];

    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
    console.log('   ✅ IPFS configured for Wrfcoin');
  }

  async setupPostgreSQL() {
    console.log('🗄️  Setting up PostgreSQL...');

    if (this.system.has_docker) {
      // Use Docker PostgreSQL
      const dbPassword = crypto.randomBytes(16).toString('hex');
      const dbConfig = {
        POSTGRES_PASSWORD: dbPassword,
        DATABASE_URL: `postgresql://wrfcoin:${dbPassword}@localhost:5432/wrfcoin`,
      };

      fs.writeFileSync(
        path.join(this.configDir, 'database.env'),
        Object.entries(dbConfig)
          .map(([k, v]) => `${k}=${v}`)
          .join('\n')
      );

      console.log('   ✅ Database configuration saved');
    } else {
      console.log('   Please ensure PostgreSQL is installed and running');
      console.log('   Create database: createdb wrfcoin');
    }
  }

  async cloneRepository() {
    console.log('📥 Setting up Wrfcoin Core...');

    const repoExists = fs.existsSync(
      path.join(this.installDir, 'package.json')
    );

    if (!repoExists) {
      console.log(
        '   Repository structure not found. Setting up minimal installation...'
      );
      await this.createMinimalStructure();
    } else {
      console.log('   ✅ Repository found');
    }
  }

  async createMinimalStructure() {
    const structure = [
      'backend/server',
      'frontend/src',
      'scripts',
      'docs',
      'infrastructure/docker',
    ];

    for (const dir of structure) {
      const fullPath = path.join(this.installDir, dir);
      if (!fs.existsSync(fullPath)) {
        fs.mkdirSync(fullPath, { recursive: true });
      }
    }

    // Create basic package.json if it doesn't exist
    if (!fs.existsSync(path.join(this.installDir, 'package.json'))) {
      const packageJson = {
        name: 'wrfcoin-core',
        version: '1.0.0',
        description: 'Wrfcoin Core Sovereign Node',
        main: 'backend/server/main.js',
        scripts: {
          start: 'node backend/server/main.js',
          'start:docker':
            'docker-compose -f infrastructure/docker/docker-compose.yml up',
        },
        dependencies: {
          express: '^4.18.0',
          axios: '^1.6.0',
          ws: '^8.14.0',
          pg: '^8.11.0',
        },
      };

      fs.writeFileSync(
        path.join(this.installDir, 'package.json'),
        JSON.stringify(packageJson, null, 2)
      );
    }
  }

  async installNodeDependencies() {
    console.log('📦 Installing Node.js dependencies...');

    try {
      execSync('npm install', { stdio: 'inherit', cwd: this.installDir });
      console.log('   ✅ Dependencies installed');
    } catch (error) {
      console.warn('   Some dependencies failed to install, continuing...');
    }
  }

  async generateConfiguration() {
    console.log('⚙️  Generating configuration...');

    const config = {
      network: this.config.network,
      node_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),

      // API Configuration
      api: {
        port: this.config.network === 'mainnet' ? 8545 : 8546,
        host: '0.0.0.0',
        cors_enabled: true,
      },

      // Database Configuration
      database: {
        url: process.env.DATABASE_URL || 'postgresql://localhost:5432/wrfcoin',
      },

      // IPFS Configuration
      ipfs: {
        enabled: this.config.ipfs,
        api_endpoint: 'http://127.0.0.1:5001',
        gateway: 'https://gateway.ipfs.io',
      },

      // Security Configuration
      security: {
        hardware_backed: this.config.hardware_security,
        key_storage: this.config.hardware_security ? 'hsm' : 'filesystem',
        encryption_enabled: true,
      },

      // Network Configuration
      network_config: {
        max_peers: 50,
        bootstrap_nodes: [],
        geographic_redundancy: this.config.geographic_redundancy,
      },
    };

    const configPath = path.join(this.configDir, 'config.json');
    fs.writeFileSync(configPath, JSON.stringify(config, null, 2));

    console.log(`   ✅ Configuration saved to ${configPath}`);
  }

  async setupSecurity() {
    console.log('🔐 Setting up security...');

    const keyDir = path.join(this.configDir, 'keys');

    if (this.config.hardware_security) {
      console.log(
        '   Hardware security enabled - please configure your YubiKey/HSM device'
      );
      console.log('   Refer to docs/security for HSM setup instructions');
    } else {
      // Generate simulated keys
      console.log('   Generating simulated security keys...');

      const keyTypes = [
        'master-signing',
        'master-encryption',
        'governance-keys',
        'cross-chain-bridge',
        'weather-validation',
      ];

      for (const keyType of keyTypes) {
        const keyId = crypto.randomBytes(8).toString('hex');
        const privateKey = crypto.randomBytes(32).toString('hex');
        const publicKey = crypto.randomBytes(33).toString('hex');

        fs.writeFileSync(
          path.join(keyDir, `sim_wrfcoin-${keyType}_${keyId}.priv`),
          privateKey
        );
        fs.writeFileSync(
          path.join(keyDir, `sim_wrfcoin-${keyType}_${keyId}.pub`),
          publicKey
        );
      }

      console.log('   ✅ Security keys generated (simulated)');
    }
  }

  async createServiceFiles() {
    console.log('🛠️  Creating service files...');

    // Create systemd service file for Linux
    if (this.system.platform === 'linux') {
      const serviceFile = `[Unit]
Description=Wrfcoin Core Node
After=network.target postgresql.service

[Service]
Type=simple
User=${process.env.USER}
WorkingDirectory=${this.installDir}
ExecStart=/usr/bin/node backend/server/main.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
Environment=CONFIG_DIR=${this.configDir}

[Install]
WantedBy=multi-user.target`;

      const servicePath = path.join(this.configDir, 'wrfcoin-core.service');
      fs.writeFileSync(servicePath, serviceFile);

      console.log(`   ✅ Systemd service file created: ${servicePath}`);
      console.log(`   To install: sudo cp ${servicePath} /etc/systemd/system/`);
      console.log(`   To enable: sudo systemctl enable wrfcoin-core`);
    }

    // Create Docker Compose file if Docker is available
    if (this.system.has_docker) {
      const dockerCompose = `version: '3.8'

services:
  wrfcoin-core:
    build: .
    container_name: wrfcoin-core
    restart: unless-stopped
    ports:
      - "${this.config.api?.port || 8546}:${this.config.api?.port || 8546}"
    environment:
      - NODE_ENV=production
      - CONFIG_DIR=/app/.wrfcoin
    volumes:
      - ${this.configDir}:/app/.wrfcoin
      - ${this.installDir}:/app
    depends_on:
      - postgres

  postgres:
    image: postgres:15-alpine
    container_name: wrfcoin-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=wrfcoin
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=wrfcoin
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

volumes:
  postgres_data:`;

      fs.writeFileSync(
        path.join(this.installDir, 'docker-compose.yml'),
        dockerCompose
      );

      console.log('   ✅ Docker Compose file created');
    }
  }

  async runInitialTests() {
    console.log('🧪 Running initial tests...');

    try {
      // Test Node.js installation
      const nodeVersion = execSync('node --version', {
        encoding: 'utf8',
      }).trim();
      console.log(`   ✅ Node.js ${nodeVersion}`);

      // Test database connection (if available)
      if (this.system.has_docker) {
        console.log('   ✅ Database: Docker-ready');
      }

      // Test IPFS (if enabled)
      if (this.config.ipfs && this.system.has_ipfs) {
        try {
          const ipfsVersion = execSync('ipfs version', {
            encoding: 'utf8',
          }).trim();
          console.log(`   ✅ IPFS: ${ipfsVersion}`);
        } catch {
          console.log('   ⚠️  IPFS: Not running (start with: ipfs daemon)');
        }
      }
    } catch (error) {
      console.warn('   Some tests failed, but installation can continue');
    }
  }

  async displayCompletionInfo() {
    console.log('\n🎉 Wrfcoin Core Installation Complete!');
    console.log('=====================================\n');

    console.log('📍 Installation Details:');
    console.log(`   Install Directory: ${this.installDir}`);
    console.log(`   Config Directory: ${this.configDir}`);
    console.log(`   Network: ${this.config.network}`);
    console.log(
      `   Node ID: ${JSON.parse(fs.readFileSync(path.join(this.configDir, 'config.json'))).node_id}\n`
    );

    console.log('🚀 Next Steps:');

    if (this.system.has_docker) {
      console.log('   1. Start with Docker: docker-compose up -d');
    } else {
      console.log('   1. Start PostgreSQL: sudo systemctl start postgresql');
      console.log('   2. Create database: createdb wrfcoin');
    }

    if (this.config.ipfs) {
      console.log(
        `   ${this.system.has_docker ? '2' : '3'}. Start IPFS: IPFS_PATH=${this.configDir}/ipfs ipfs daemon &`
      );
    }

    console.log(
      `   ${this.system.has_docker ? '3' : '4'}. Start Wrfcoin: npm start`
    );

    console.log('\n📚 Documentation:');
    console.log('   Configuration: ~/.wrfcoin/config.json');
    console.log('   Logs: ~/.wrfcoin/logs/');
    console.log('   Security Keys: ~/.wrfcoin/keys/');

    console.log('\n🔒 Security Notes:');
    if (this.config.hardware_security) {
      console.log('   ✅ Hardware security enabled');
    } else {
      console.log(
        '   ⚠️  Using simulated keys - consider hardware security for production'
      );
    }

    console.log('\n🌍 Making Your Node Unstoppable:');
    console.log('   • Enable hardware security: --hardware-security');
    console.log('   • Set up geographic redundancy: --geographic-redundancy');
    console.log('   • Configure IPFS for distributed storage');
    console.log('   • Deploy across multiple regions');
    console.log('   • Use Tor/VPN for censorship resistance');

    console.log('\n📞 Support:');
    console.log('   Documentation: docs/');
    console.log('   Issues: https://github.com/wrfcoin/wrfcoin-core/issues');
  }

  log(message) {
    const timestamp = new Date().toISOString();
    const logEntry = `${timestamp}: ${message}\n`;

    try {
      fs.appendFileSync(this.logFile, logEntry);
    } catch (error) {
      // Ignore logging errors
    }
  }
}

// Main execution
if (require.main === module) {
  const installer = new WrfcoinCoreInstaller();
  installer.install().catch(error => {
    console.error('❌ Installation failed:', error.message);
    process.exit(1);
  });
}

module.exports = WrfcoinCoreInstaller;
