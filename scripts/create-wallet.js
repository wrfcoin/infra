/**
 * Wrfcoin Wallet Generator
 * Creates new wallets with proper seed phrases for testnet transactions
 */

const crypto = require('crypto');
const fs = require('fs');

// BIP39 word list (first 100 words for demo)
const BIP39_WORDS = [
  'abandon',
  'ability',
  'able',
  'about',
  'above',
  'absent',
  'absorb',
  'abstract',
  'absurd',
  'abuse',
  'access',
  'accident',
  'account',
  'accuse',
  'achieve',
  'acid',
  'acoustic',
  'acquire',
  'across',
  'act',
  'action',
  'actor',
  'actress',
  'actual',
  'adapt',
  'add',
  'addict',
  'address',
  'adjust',
  'admit',
  'adult',
  'advance',
  'advice',
  'aerobic',
  'affair',
  'afford',
  'afraid',
  'again',
  'age',
  'agent',
  'agree',
  'ahead',
  'aim',
  'air',
  'airport',
  'aisle',
  'alarm',
  'album',
  'alcohol',
  'alert',
  'alien',
  'all',
  'alley',
  'allow',
  'almost',
  'alone',
  'alpha',
  'already',
  'also',
  'alter',
  'always',
  'amateur',
  'amazing',
  'among',
  'amount',
  'amused',
  'analyst',
  'anchor',
  'ancient',
  'anger',
  'angle',
  'angry',
  'animal',
  'ankle',
  'announce',
  'annual',
  'another',
  'answer',
  'antenna',
  'antique',
  'anxiety',
  'any',
  'apart',
  'apology',
  'appear',
  'apple',
  'approve',
  'april',
  'area',
  'arena',
  'argue',
  'arm',
  'armed',
  'armor',
  'army',
  'around',
  'arrange',
  'arrest',
  'arrive',
  'arrow',
  'art',
  'artist',
  'artwork',
  'ask',
  'aspect',
  'assault',
  'asset',
  'assist',
  'assume',
  'asthma',
  'athlete',
  'atom',
  'attack',
  'attend',
  'attitude',
  'attract',
  'auction',
  'audit',
  'august',
  'aunt',
  'author',
  'auto',
  'autumn',
  'average',
  'avocado',
  'avoid',
  'awake',
  'aware',
  'away',
  'awesome',
];

function generateSeedPhrase(words = 12) {
  if (words !== 12 && words !== 24) {
    throw new Error('Seed phrase must be 12 or 24 words');
  }

  const selectedWords = [];
  for (let i = 0; i < words; i++) {
    const randomIndex = crypto.randomInt(0, BIP39_WORDS.length);
    selectedWords.push(BIP39_WORDS[randomIndex]);
  }

  return selectedWords.join(' ');
}

function generateWalletAddress() {
  // Generate a Wrfcoin testnet address compatible with Rust blockchain core
  // Format: "wrf" + 40 hex characters = 43 total characters
  const addressBytes = crypto.randomBytes(20);
  return 'wrf' + addressBytes.toString('hex');
}

function generatePrivateKey() {
  return crypto.randomBytes(32).toString('hex');
}

function createWallet(seedWords = 12) {
  const seedPhrase = generateSeedPhrase(seedWords);
  const address = generateWalletAddress();
  const privateKey = generatePrivateKey();

  const wallet = {
    address,
    privateKey,
    seedPhrase,
    network: 'wrfcoin-testnet',
    balance: '0.00 WRF',
    created: new Date().toISOString(),
  };

  return wallet;
}

async function saveWallet(wallet, filename) {
  const walletDir = './wallets';
  if (!fs.existsSync(walletDir)) {
    fs.mkdirSync(walletDir, { recursive: true });
  }

  const filepath = `${walletDir}/${filename}.json`;
  fs.writeFileSync(filepath, JSON.stringify(wallet, null, 2));

  console.log(`✅ Wallet saved to: ${filepath}`);
  return filepath;
}

async function createTestnetWallets() {
  console.log('🔐 Creating Wrfcoin Testnet Wallets...\n');

  // Create primary wallet (12 words)
  console.log('Creating Primary Wallet (12-word seed phrase)...');
  const primaryWallet = createWallet(12);
  console.log(`📝 Seed Phrase: ${primaryWallet.seedPhrase}`);
  console.log(`💳 Address: ${primaryWallet.address}`);
  console.log(`🔑 Private Key: ${primaryWallet.privateKey.substring(0, 8)}...`);

  await saveWallet(primaryWallet, 'primary-wallet');

  console.log('\n---\n');

  // Create secondary wallet (24 words)
  console.log('Creating Secondary Wallet (24-word seed phrase)...');
  const secondaryWallet = createWallet(24);
  console.log(`📝 Seed Phrase: ${secondaryWallet.seedPhrase}`);
  console.log(`💳 Address: ${secondaryWallet.address}`);
  console.log(
    `🔑 Private Key: ${secondaryWallet.privateKey.substring(0, 8)}...`
  );

  await saveWallet(secondaryWallet, 'secondary-wallet');

  console.log('\n🎯 Ready for testnet transactions!');
  console.log(
    '💰 You can now transfer your earned WRF tokens between these wallets'
  );

  return { primaryWallet, secondaryWallet };
}

if (require.main === module) {
  createTestnetWallets().catch(console.error);
}

module.exports = {
  createWallet,
  generateSeedPhrase,
  generateWalletAddress,
  createTestnetWallets,
};
