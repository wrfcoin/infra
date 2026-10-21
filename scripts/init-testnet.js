#!/usr/bin/env node

/**
 * WRFCoin Testnet Initialization Script
 * Creates a test network for friends and family testing
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { ethers } from 'ethers';
import yaml from 'js-yaml';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TESTNET_CONFIG_DIR = path.join(__dirname, '..', 'configs', 'testnet');

// Parse command line arguments
const args = process.argv.slice(2);
const networkName = args.includes('--network')
  ? args[args.indexOf('--network') + 1]
  : 'family';
const validatorCount = args.includes('--validators')
  ? parseInt(args[args.indexOf('--validators') + 1], 10)
  : 3;

if (!Number.isInteger(validatorCount) || validatorCount <= 0) {
  console.error('❌ --validators must be a positive integer');
  process.exit(1);
}

console.log('🚀 WRFCoin Testnet Initializer');
console.log('================================');
console.log(`Network Name: ${networkName}`);
console.log(`Validators: ${validatorCount}`);
console.log('');

const chainId = process.env.WRFCOIN_CHAIN_ID || '777';
if (!/^[1-9][0-9]*$/.test(chainId) || !Number.isSafeInteger(Number(chainId))) {
  throw new Error('WRFCOIN_CHAIN_ID must be a positive safe integer');
}

// Configuration
const config = {
  chainId: Number(chainId),
  networkName: `WRFCoin ${networkName} Testnet`,
  symbol: 'WRF',
  decimals: 18,
  initialSupply: '1000000', // 1 million WRF
  blockTime: 5, // 5 seconds
  consensusType: 'PoA', // Proof of Authority for testnet
  gasPrice: '1000000000', // 1 gwei
  gasLimit: '8000000',
  faucetAmount: '1000', // 1000 WRF per request
  ports: {
    rpc: 8545,
    ws: 8546,
    api: 4001,
    frontend: 5000,
  },
};

// Generate validator accounts
function generateValidators(count) {
  const validators = [];
  for (let i = 0; i < count; i++) {
    const wallet = ethers.Wallet.createRandom();
    validators.push({
      address: wallet.address,
      privateKey: wallet.privateKey,
      publicKey: wallet.signingKey?.publicKey || wallet.publicKey || null,
      mnemonic: wallet.mnemonic?.phrase || null,
      balance: '100000', // 100k WRF for validators
    });
  }
  return validators;
}

// Generate test accounts
function generateTestAccounts(count = 10) {
  const accounts = [];
  for (let i = 0; i < count; i++) {
    const wallet = ethers.Wallet.createRandom();
    accounts.push({
      address: wallet.address,
      privateKey: wallet.privateKey,
      mnemonic: wallet.mnemonic?.phrase || null,
      balance: '1000', // 1000 WRF for test accounts
    });
  }
  return accounts;
}

// Create genesis block
function createGenesisBlock(validators, accounts) {
  const timestamp = Date.now();
  const genesisBlock = {
    config: {
      chainId: config.chainId,
      homesteadBlock: 0,
      eip150Block: 0,
      eip155Block: 0,
      eip158Block: 0,
      byzantiumBlock: 0,
      constantinopleBlock: 0,
      petersburgBlock: 0,
      istanbulBlock: 0,
      berlinBlock: 0,
      londonBlock: 0,
      consensus: {
        type: config.consensusType,
        validators: validators.map(v => v.address),
        blockTime: config.blockTime,
      },
    },
    difficulty: '0x1',
    gasLimit: config.gasLimit,
    timestamp: timestamp,
    extraData: '0x00',
    alloc: {},
  };

  // Allocate initial balances
  validators.forEach(validator => {
    genesisBlock.alloc[validator.address.toLowerCase()] = {
      balance: ethers.parseEther(validator.balance).toString(),
    };
  });

  accounts.forEach(account => {
    genesisBlock.alloc[account.address.toLowerCase()] = {
      balance: ethers.parseEther(account.balance).toString(),
    };
  });

  // Add faucet account
  const faucetWallet = ethers.Wallet.createRandom();
  genesisBlock.alloc[faucetWallet.address.toLowerCase()] = {
    balance: ethers.parseEther('500000').toString(), // 500k for faucet
  };

  return {
    genesis: genesisBlock,
    faucet: {
      address: faucetWallet.address,
      privateKey: faucetWallet.privateKey,
    },
  };
}

// Create network configuration files
function createNetworkConfig(validators, accounts, genesis, faucet) {
  const networkConfig = {
    name: config.networkName,
    chainId: config.chainId,
    symbol: config.symbol,
    decimals: config.decimals,
    rpcUrl: `http://localhost:${config.ports.rpc}`,
    wsUrl: `ws://localhost:${config.ports.ws}`,
    apiUrl: `http://localhost:${config.ports.api}`,
    frontendUrl: `http://localhost:${config.ports.frontend}`,
    blockExplorer: `http://localhost:${config.ports.frontend}/explorer`,
    faucet: {
      url: `http://localhost:${config.ports.api}/api/faucet`,
      address: faucet.address,
      amount: config.faucetAmount,
    },
    consensus: {
      type: config.consensusType,
      blockTime: config.blockTime,
      validators: validators.map(v => ({
        address: v.address,
        name: `Validator ${validators.indexOf(v) + 1}`,
      })),
    },
    contracts: {
      // Will be populated after deployment
      token: null,
      governance: null,
      carbonCredit: null,
      defi: null,
      nft: null,
    },
  };

  return networkConfig;
}

// Save configuration files
function saveConfigurations(
  validators,
  accounts,
  genesis,
  faucet,
  networkConfig
) {
  // Create directory if it doesn't exist
  if (!fs.existsSync(TESTNET_CONFIG_DIR)) {
    fs.mkdirSync(TESTNET_CONFIG_DIR, { recursive: true });
  }

  // Save genesis block
  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'genesis.json'),
    JSON.stringify(genesis, null, 2)
  );

  // Save network configuration
  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'network.json'),
    JSON.stringify(networkConfig, null, 2)
  );

  // Save validator keys (TESTNET ONLY - NEVER DO THIS IN PRODUCTION!)
  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'validators.json'),
    JSON.stringify(validators, null, 2)
  );

  // Save test accounts
  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'test-accounts.json'),
    JSON.stringify(accounts, null, 2)
  );

  // Save faucet configuration
  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'faucet.json'),
    JSON.stringify(faucet, null, 2)
  );

  // Create .env.testnet file
  const envContent = `
# WRFCoin Testnet Configuration
NODE_ENV=testnet
NETWORK_NAME="${config.networkName}"
CHAIN_ID=${config.chainId}

# Database
DATABASE_URL=postgresql://wrfcoin:testnet123@localhost:5432/wrfcoin_testnet

# Faucet
FAUCET_ADDRESS=${faucet.address}
FAUCET_PRIVATE_KEY=${faucet.privateKey}
FAUCET_AMOUNT=${config.faucetAmount}

# Network
RPC_URL=http://localhost:${config.ports.rpc}
WS_URL=ws://localhost:${config.ports.ws}
API_URL=http://localhost:${config.ports.api}

# Security (Testnet only!)
JWT_SECRET=${crypto.randomBytes(32).toString('hex')}
ENCRYPTION_KEY=${crypto.randomBytes(32).toString('hex')}

# Features
ENABLE_FAUCET=true
ENABLE_MINING=true
MINING_DIFFICULTY=1
ENABLE_DEBUG=true
`.trim();

  fs.writeFileSync(path.join(TESTNET_CONFIG_DIR, '.env.testnet'), envContent);
}

// Create Docker compose for testnet
function createDockerCompose() {
  if (!process.env.POSTGRES_PASSWORD) {
    throw new Error('POSTGRES_PASSWORD required');
  }
  const dockerCompose = {
    version: '3.8',
    services: {
      blockchain: {
        build: {
          context: '../..',
          dockerfile: 'blockchain-core/Dockerfile',
        },
        ports: [`${config.ports.rpc}:8545`, `${config.ports.ws}:8546`],
        environment: {
          NETWORK: 'testnet',
          CHAIN_ID: config.chainId,
        },
        volumes: ['./genesis.json:/app/genesis.json', './data:/app/data'],
      },
      api: {
        build: {
          context: '../..',
          dockerfile: 'backend/Dockerfile',
        },
        ports: [`${config.ports.api}:4001`],
        environment: {
          NODE_ENV: 'testnet',
          DATABASE_URL: 'postgresql://postgres:testnet@db:5432/wrfcoin',
        },
        depends_on: ['blockchain', 'db'],
      },
      frontend: {
        build: {
          context: '../..',
          dockerfile: 'frontend/Dockerfile',
        },
        ports: [`${config.ports.frontend}:5000`],
        environment: {
          REACT_APP_NETWORK: 'testnet',
          REACT_APP_CHAIN_ID: config.chainId,
          REACT_APP_API_URL: `http://localhost:${config.ports.api}`,
        },
        depends_on: ['api'],
      },
      db: {
        image: 'postgres:15',
        environment: {
          POSTGRES_DB: 'wrfcoin',
          POSTGRES_USER: 'postgres',
          POSTGRES_PASSWORD: process.env.POSTGRES_PASSWORD || (() => { throw new Error('POSTGRES_PASSWORD required'); })(),
        },
        volumes: ['postgres-data:/var/lib/postgresql/data'],
      },
    },
    volumes: {
      'postgres-data': {},
    },
    networks: {
      default: {
        name: 'wrfcoin-testnet',
      },
    },
  };

  fs.writeFileSync(
    path.join(TESTNET_CONFIG_DIR, 'docker-compose.testnet.yml'),
    yaml.dump(dockerCompose)
  );
}

// Print account information
function printAccountInfo(validators, accounts, faucet, networkConfig) {
  console.log('\n✅ Testnet Initialized Successfully!');
  console.log('=====================================\n');

  console.log('📋 Network Information:');
  console.log(`  Name: ${networkConfig.name}`);
  console.log(`  Chain ID: ${networkConfig.chainId}`);
  console.log(`  RPC URL: ${networkConfig.rpcUrl}`);
  console.log(`  Frontend: ${networkConfig.frontendUrl}`);
  console.log('');

  console.log('👥 Validator Accounts:');
  validators.forEach((validator, index) => {
    console.log(`  Validator ${index + 1}:`);
    console.log(`    Address: ${validator.address}`);
    console.log(`    Balance: ${validator.balance} WRF`);
    console.log(`    Private Key: ${validator.privateKey.substring(0, 10)}...`);
    console.log('');
  });

  console.log('💰 Test Accounts (Share with testers):');
  accounts.slice(0, 5).forEach((account, index) => {
    console.log(`  Account ${index + 1}:`);
    console.log(`    Address: ${account.address}`);
    console.log(`    Balance: ${account.balance} WRF`);
    console.log(`    Mnemonic: ${account.mnemonic}`);
    console.log('');
  });

  console.log('🚰 Faucet Information:');
  console.log(`  Address: ${faucet.address}`);
  console.log(`  URL: ${networkConfig.faucet.url}`);
  console.log(`  Amount per request: ${networkConfig.faucet.amount} WRF`);
  console.log('');

  console.log('📁 Configuration Files Saved:');
  console.log('  configs/testnet/genesis.json');
  console.log('  configs/testnet/network.json');
  console.log('  configs/testnet/validators.json');
  console.log('  configs/testnet/test-accounts.json');
  console.log('  configs/testnet/.env.testnet');
  console.log('  configs/testnet/docker-compose.testnet.yml');
  console.log('');

  console.log('🚀 Next Steps:');
  console.log('  1. Start the testnet:');
  console.log(
    '     docker-compose -f configs/testnet/docker-compose.testnet.yml up -d'
  );
  console.log('');
  console.log('  2. Or use manual start:');
  console.log('     npm run start:testnet');
  console.log('');
  console.log('  3. Share test accounts with friends and family');
  console.log('  4. Access the platform at http://localhost:5000');
  console.log('');
  console.log('⚠️  IMPORTANT: This is a TESTNET configuration.');
  console.log('    Never use these keys or configurations in production!');
}

// Main execution
async function main() {
  try {
    console.log('🔧 Generating validators...');
    const validators = generateValidators(validatorCount);

    console.log('👤 Generating test accounts...');
    const accounts = generateTestAccounts(10);

    console.log('⛓️  Creating genesis block...');
    const { genesis, faucet } = createGenesisBlock(validators, accounts);

    console.log('📝 Creating network configuration...');
    const networkConfig = createNetworkConfig(
      validators,
      accounts,
      genesis,
      faucet
    );

    console.log('💾 Saving configurations...');
    saveConfigurations(validators, accounts, genesis, faucet, networkConfig);

    console.log('🐳 Creating Docker configuration...');
    createDockerCompose();

    printAccountInfo(validators, accounts, faucet, networkConfig);
  } catch (error) {
    console.error('❌ Error initializing testnet:', error);
    process.exit(1);
  }
}

// Run the script
main();
