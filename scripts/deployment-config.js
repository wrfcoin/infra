// Deployment configuration for different networks
const deploymentConfig = {
  // Local development (Hardhat Network)
  localhost: {
    dependencies: {
      deployed: false, // Will deploy fresh instances
      participantTypeRegistry: null,
      stakeCalculator: null,
      socialVerification: null,
      wrfToken: null, // Will use existing WRFToken if available
      slashingMechanism: null,
    },
    tokens: {
      usdc: null, // No USDC on localhost
      usdt: null,
      dai: null,
    },
    layawayConfig: {
      multiMethodPeriod: 30 * 24 * 60 * 60, // 30 days
      singleMethodPeriod: 60 * 24 * 60 * 60, // 60 days
      unverifiedPeriod: 90 * 24 * 60 * 60, // 90 days
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  // Ethereum Mainnet
  mainnet: {
    dependencies: {
      deployed: true,
      // These would be filled in with actual deployed addresses
      participantTypeRegistry: '0x0000000000000000000000000000000000000000',
      stakeCalculator: '0x0000000000000000000000000000000000000000',
      socialVerification: '0x0000000000000000000000000000000000000000',
      wrfToken: '0x0000000000000000000000000000000000000000', // Actual WRFToken
      slashingMechanism: '0x0000000000000000000000000000000000000000',
    },
    tokens: {
      usdc: '0xA0b86a33E6441986C3190e7f5b44f8a77a5e4b61', // USDC on Ethereum
      usdt: '0xdac17f958d2ee523a2206206994597c13d831ec7', // USDT on Ethereum
      dai: '0x6b175474e89094c44da98b954eedeac495271d0f', // DAI on Ethereum
    },
    layawayConfig: {
      multiMethodPeriod: 30 * 24 * 60 * 60, // 30 days
      singleMethodPeriod: 60 * 24 * 60 * 60, // 60 days
      unverifiedPeriod: 90 * 24 * 60 * 60, // 90 days
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  // Polygon Mainnet
  polygon: {
    dependencies: {
      deployed: true,
      participantTypeRegistry: '0x0000000000000000000000000000000000000000',
      stakeCalculator: '0x0000000000000000000000000000000000000000',
      socialVerification: '0x0000000000000000000000000000000000000000',
      wrfToken: '0x0000000000000000000000000000000000000000',
      slashingMechanism: '0x0000000000000000000000000000000000000000',
    },
    tokens: {
      usdc: '0x2791bca1f2de4661ed88a30c99a7a9449aa84174', // USDC on Polygon
      usdt: '0xc2132d05d31c914a87c6611c10748aeb04b58e8f', // USDT on Polygon
      dai: '0x8f3cf7ad23cd3cadbd9735aff958023239c6a063', // DAI on Polygon
    },
    layawayConfig: {
      multiMethodPeriod: 30 * 24 * 60 * 60, // 30 days
      singleMethodPeriod: 60 * 24 * 60 * 60, // 60 days
      unverifiedPeriod: 90 * 24 * 60 * 60, // 90 days
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  // Binance Smart Chain
  bsc: {
    dependencies: {
      deployed: true,
      participantTypeRegistry: '0x0000000000000000000000000000000000000000',
      stakeCalculator: '0x0000000000000000000000000000000000000000',
      socialVerification: '0x0000000000000000000000000000000000000000',
      wrfToken: '0x0000000000000000000000000000000000000000',
      slashingMechanism: '0x0000000000000000000000000000000000000000',
    },
    tokens: {
      usdc: '0x8ac76a51cc950d9822d68b83fe1ad97b32cd580d', // USDC on BSC
      usdt: '0x55d398326f99059ff775485246999027b3197955', // USDT on BSC
      dai: '0x1af3f329e8be154074d8769d1ffa4ee058b1dbc3', // DAI on BSC
    },
    layawayConfig: {
      multiMethodPeriod: 30 * 24 * 60 * 60, // 30 days
      singleMethodPeriod: 60 * 24 * 60 * 60, // 60 days
      unverifiedPeriod: 90 * 24 * 60 * 60, // 90 days
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  // Avalanche
  avalanche: {
    dependencies: {
      deployed: true,
      participantTypeRegistry: '0x0000000000000000000000000000000000000000',
      stakeCalculator: '0x0000000000000000000000000000000000000000',
      socialVerification: '0x0000000000000000000000000000000000000000',
      wrfToken: '0x0000000000000000000000000000000000000000',
      slashingMechanism: '0x0000000000000000000000000000000000000000',
    },
    tokens: {
      usdc: '0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e', // USDC on Avalanche
      usdt: '0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7', // USDT on Avalanche
      dai: '0xd586e7f844cea2f87f50152665bcbc2c279d8d70', // DAI on Avalanche
    },
    layawayConfig: {
      multiMethodPeriod: 30 * 24 * 60 * 60, // 30 days
      singleMethodPeriod: 60 * 24 * 60 * 60, // 60 days
      unverifiedPeriod: 90 * 24 * 60 * 60, // 90 days
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  // Testnets
  sepolia: {
    dependencies: {
      deployed: false, // Deploy fresh for testing
    },
    tokens: {
      usdc: null,
      usdt: null,
      dai: null,
    },
    layawayConfig: {
      multiMethodPeriod: 1 * 60 * 60, // 1 hour for testing
      singleMethodPeriod: 2 * 60 * 60, // 2 hours for testing
      unverifiedPeriod: 3 * 60 * 60, // 3 hours for testing
      slashingMultiplier: 20000, // 2x (200%)
    },
  },

  mumbai: {
    dependencies: {
      deployed: false, // Deploy fresh for testing
    },
    tokens: {
      usdc: null,
      usdt: null,
      dai: null,
    },
    layawayConfig: {
      multiMethodPeriod: 1 * 60 * 60, // 1 hour for testing
      singleMethodPeriod: 2 * 60 * 60, // 2 hours for testing
      unverifiedPeriod: 3 * 60 * 60, // 3 hours for testing
      slashingMultiplier: 20000, // 2x (200%)
    },
  },
};

// Helper functions
const getNetworkConfig = networkName => {
  const config = deploymentConfig[networkName];
  if (!config) {
    throw new Error(`No configuration found for network: ${networkName}`);
  }
  return config;
};

const isTestNetwork = networkName => {
  return ['localhost', 'sepolia', 'mumbai', 'goerli'].includes(networkName);
};

const getLayawayPeriodsInDays = config => {
  return {
    multiMethod: config.multiMethodPeriod / (24 * 60 * 60),
    singleMethod: config.singleMethodPeriod / (24 * 60 * 60),
    unverified: config.unverifiedPeriod / (24 * 60 * 60),
  };
};

module.exports = {
  deploymentConfig,
  getNetworkConfig,
  isTestNetwork,
  getLayawayPeriodsInDays,
};
