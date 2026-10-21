#!/usr/bin/env node

/**
 * SSL Certificate Generator for Wrfcoin Node Discovery
 * Generates self-signed certificates for production-ready secure WebSocket connections
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

class SSLCertificateGenerator {
  constructor() {
    this.certsDir = './certs';
    this.keyPath = path.join(this.certsDir, 'key.pem');
    this.certPath = path.join(this.certsDir, 'cert.pem');
  }

  async generateCertificates() {
    console.log('\n🔒 Generating SSL Certificates for Secure Node Discovery');
    console.log('====================================================');

    // Create certs directory if it doesn't exist
    if (!fs.existsSync(this.certsDir)) {
      fs.mkdirSync(this.certsDir, { recursive: true });
      console.log('📁 Created certificates directory');
    }

    // Check if certificates already exist
    if (fs.existsSync(this.keyPath) && fs.existsSync(this.certPath)) {
      console.log('⚠️  SSL certificates already exist');
      console.log('   Delete ./certs/ directory to regenerate');
      return;
    }

    try {
      // Generate private key
      console.log('🔑 Generating private key...');
      execSync(`openssl genrsa -out ${this.keyPath} 2048`, { stdio: 'pipe' });

      // Generate certificate
      console.log('📜 Generating self-signed certificate...');
      const opensslCommand = `openssl req -new -x509 -key ${this.keyPath} -out ${this.certPath} -days 365 -subj "/C=US/ST=Web3/L=Blockchain/O=Wrfcoin/OU=NodeDiscovery/CN=localhost"`;
      execSync(opensslCommand, { stdio: 'pipe' });

      console.log('✅ SSL certificates generated successfully!');
      console.log(`   Private Key: ${this.keyPath}`);
      console.log(`   Certificate: ${this.certPath}`);
      console.log('');
      console.log('🚀 Node Discovery can now run in production mode with:');
      console.log('   export NODE_ENV=production');
      console.log('   node backend/server/easy_node_discovery.js');
    } catch (error) {
      console.error('❌ Failed to generate SSL certificates:', error.message);
      console.log('');
      console.log('📋 Manual certificate generation:');
      console.log('   1. Install OpenSSL on your system');
      console.log('   2. Run the following commands:');
      console.log(`      openssl genrsa -out ${this.keyPath} 2048`);
      console.log(
        `      openssl req -new -x509 -key ${this.keyPath} -out ${this.certPath} -days 365`
      );
    }
  }

  validateCertificates() {
    if (!fs.existsSync(this.keyPath) || !fs.existsSync(this.certPath)) {
      console.log('❌ SSL certificates not found');
      return false;
    }

    try {
      // Validate certificate
      execSync(`openssl x509 -in ${this.certPath} -text -noout`, {
        stdio: 'pipe',
      });
      console.log('✅ SSL certificates are valid');
      return true;
    } catch (error) {
      console.log('❌ SSL certificates are invalid');
      return false;
    }
  }

  showInstructions() {
    console.log('\n📋 Production Deployment Instructions:');
    console.log('=====================================');
    console.log('');
    console.log('🔒 For Secure Production Mode:');
    console.log('   export NODE_ENV=production');
    console.log('   export WRF_NETWORK=mainnet');
    console.log('   node backend/server/easy_node_discovery.js');
    console.log('');
    console.log('🧪 For Development Mode (default):');
    console.log('   node backend/server/easy_node_discovery.js');
    console.log('');
    console.log('🌐 Environment Variables:');
    console.log('   SSL_CERT_PATH - Custom certificate path');
    console.log('   SSL_KEY_PATH  - Custom private key path');
    console.log('   NODE_ENV      - production/development');
    console.log('   WRF_NETWORK   - mainnet/testnet');
  }
}

// Main execution
async function main() {
  const generator = new SSLCertificateGenerator();

  await generator.generateCertificates();
  generator.validateCertificates();
  generator.showInstructions();
}

// Run if called directly
if (require.main === module) {
  main().catch(console.error);
}

module.exports = SSLCertificateGenerator;
