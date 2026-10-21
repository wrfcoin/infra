#!/usr/bin/env node

/**
 * Environment Configuration Synchronization Script
 * Synchronizes configuration across different deployment environments
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Environment configuration templates
const environmentConfigs = {
  development: {
    apiUrl: 'http://localhost:4001',
    chainId: 1337, // Local development chain
    networkName: 'localhost',
    features: {
      monitoring: false,
      analytics: false,
      errorReporting: false,
      performanceTracking: false,
    },
    database: {
      connectionPoolSize: 5,
      queryTimeout: 30000,
      ssl: false,
    },
    cache: {
      ttl: 300, // 5 minutes
      maxSize: 100,
    },
  },

  staging: {
    apiUrl: 'https://staging.wrfcoin.io',
    chainId: 5, // Goerli testnet
    networkName: 'goerli',
    features: {
      monitoring: true,
      analytics: true,
      errorReporting: true,
      performanceTracking: true,
    },
    database: {
      connectionPoolSize: 10,
      queryTimeout: 60000,
      ssl: true,
    },
    cache: {
      ttl: 600, // 10 minutes
      maxSize: 500,
    },
  },

  production: {
    apiUrl: 'https://wrfcoin.io',
    chainId: 1, // Ethereum mainnet
    networkName: 'mainnet',
    features: {
      monitoring: true,
      analytics: true,
      errorReporting: true,
      performanceTracking: true,
      advancedSecurity: true,
    },
    database: {
      connectionPoolSize: 20,
      queryTimeout: 120000,
      ssl: true,
      readReplicas: true,
    },
    cache: {
      ttl: 1800, // 30 minutes
      maxSize: 1000,
      distributedCache: true,
    },
  },
};

// Security configurations per environment
const securityConfigs = {
  development: {
    cors: {
      origin: ['http://localhost:3000', 'http://localhost:3001'],
      credentials: true,
    },
    rateLimit: {
      windowMs: 15 * 60 * 1000, // 15 minutes
      max: 1000, // requests per window
    },
    encryption: {
      algorithm: 'aes-256-gcm',
      keyRotation: false,
    },
  },

  staging: {
    cors: {
      origin: ['https://staging.wrfcoin.io', 'https://*.vercel.app'],
      credentials: true,
    },
    rateLimit: {
      windowMs: 15 * 60 * 1000,
      max: 500,
    },
    encryption: {
      algorithm: 'aes-256-gcm',
      keyRotation: true,
      rotationInterval: '7d',
    },
  },

  production: {
    cors: {
      origin: ['https://wrfcoin.io', 'https://app.wrfcoin.io'],
      credentials: true,
    },
    rateLimit: {
      windowMs: 15 * 60 * 1000,
      max: 100,
    },
    encryption: {
      algorithm: 'aes-256-gcm',
      keyRotation: true,
      rotationInterval: '24h',
    },
    waf: {
      enabled: true,
      rules: ['sql-injection', 'xss', 'ddos-protection'],
    },
  },
};

async function main() {
  const args = process.argv.slice(2);
  const environment = args
    .find(arg => arg.startsWith('--environment='))
    ?.split('=')[1];
  const version = args.find(arg => arg.startsWith('--version='))?.split('=')[1];

  if (!environment) {
    console.error('❌ Environment is required. Use --environment=<env>');
    process.exit(1);
  }

  if (!environmentConfigs[environment]) {
    console.error(`❌ Unknown environment: ${environment}`);
    console.error(
      `Available environments: ${Object.keys(environmentConfigs).join(', ')}`
    );
    process.exit(1);
  }

  console.log(`🔄 Synchronizing configuration for environment: ${environment}`);
  if (version) {
    console.log(`📦 Version: ${version}`);
  }

  try {
    // Generate environment-specific configuration files
    await generateEnvironmentConfig(environment, version);

    // Update Docker configurations
    await updateDockerConfig(environment);

    // Update Kubernetes manifests
    await updateKubernetesConfig(environment);

    // Update monitoring configurations
    await updateMonitoringConfig(environment);

    // Update security configurations
    await updateSecurityConfig(environment);

    // Generate deployment manifest
    await generateDeploymentManifest(environment, version);

    console.log(
      `✅ Configuration synchronization completed for ${environment}`
    );
  } catch (error) {
    console.error(`❌ Configuration synchronization failed:`, error.message);
    process.exit(1);
  }
}

async function generateEnvironmentConfig(environment, version) {
  console.log(`📝 Generating ${environment} configuration files...`);

  const config = environmentConfigs[environment];
  const configDir = path.join(
    __dirname,
    '..',
    'configs',
    'environments',
    environment
  );

  // Ensure directory exists
  if (!fs.existsSync(configDir)) {
    fs.mkdirSync(configDir, { recursive: true });
  }

  // Generate main configuration file
  const mainConfig = {
    ...config,
    environment,
    version,
    timestamp: new Date().toISOString(),
    build: {
      gitCommit: process.env.GITHUB_SHA || 'unknown',
      buildNumber: process.env.GITHUB_RUN_NUMBER || 'unknown',
      buildDate: new Date().toISOString(),
    },
  };

  fs.writeFileSync(
    path.join(configDir, 'config.json'),
    JSON.stringify(mainConfig, null, 2)
  );

  // Generate environment variables file
  const envVars = [
    `NODE_ENV=${environment === 'development' ? 'development' : 'production'}`,
    `ENVIRONMENT=${environment}`,
    `VERSION=${version || 'latest'}`,
    `API_URL=${config.apiUrl}`,
    `CHAIN_ID=${config.chainId}`,
    `NETWORK_NAME=${config.networkName}`,
    `DATABASE_POOL_SIZE=${config.database.connectionPoolSize}`,
    `DATABASE_QUERY_TIMEOUT=${config.database.queryTimeout}`,
    `CACHE_TTL=${config.cache.ttl}`,
    `CACHE_MAX_SIZE=${config.cache.maxSize}`,
    `MONITORING_ENABLED=${config.features.monitoring}`,
    `ANALYTICS_ENABLED=${config.features.analytics}`,
    `ERROR_REPORTING_ENABLED=${config.features.errorReporting}`,
    `PERFORMANCE_TRACKING_ENABLED=${config.features.performanceTracking}`,
  ];

  fs.writeFileSync(path.join(configDir, '.env'), envVars.join('\n'));

  console.log(`✅ Configuration files generated in ${configDir}`);
}

async function updateDockerConfig(environment) {
  console.log(`🐳 Updating Docker configuration for ${environment}...`);

  const config = environmentConfigs[environment];
  const dockerDir = path.join(__dirname, '..', 'infra', 'docker');

  // Generate environment-specific docker-compose override
  const dockerCompose = {
    version: '3.8',
    services: {
      api: {
        environment: [
          `NODE_ENV=${environment === 'development' ? 'development' : 'production'}`,
          `ENVIRONMENT=${environment}`,
          `DATABASE_POOL_SIZE=${config.database.connectionPoolSize}`,
          `CACHE_TTL=${config.cache.ttl}`,
        ],
        deploy: {
          replicas: environment === 'production' ? 3 : 1,
          resources: {
            limits: {
              memory: environment === 'production' ? '2G' : '1G',
              cpus: environment === 'production' ? '1.0' : '0.5',
            },
          },
        },
      },
      frontend: {
        environment: [
          `NODE_ENV=${environment === 'development' ? 'development' : 'production'}`,
          `NEXT_PUBLIC_API_URL=${config.apiUrl}`,
          `NEXT_PUBLIC_CHAIN_ID=${config.chainId}`,
          `NEXT_PUBLIC_NETWORK_NAME=${config.networkName}`,
        ],
      },
    },
  };

  fs.writeFileSync(
    path.join(dockerDir, `docker-compose.${environment}.yml`),
    JSON.stringify(dockerCompose, null, 2)
  );

  console.log(`✅ Docker configuration updated for ${environment}`);
}

async function updateKubernetesConfig(environment) {
  if (environment === 'development') {
    console.log(
      '⏭️ Skipping Kubernetes configuration for development environment'
    );
    return;
  }

  console.log(`☸️ Updating Kubernetes configuration for ${environment}...`);

  const config = environmentConfigs[environment];
  const k8sDir = path.join(
    __dirname,
    '..',
    'infra',
    'k8s',
    'overlays',
    environment
  );

  // Ensure directory exists
  if (!fs.existsSync(k8sDir)) {
    fs.mkdirSync(k8sDir, { recursive: true });
  }

  // Generate kustomization.yaml
  const kustomization = {
    apiVersion: 'kustomize.config.k8s.io/v1beta1',
    kind: 'Kustomization',
    namespace: `wrfcoin-${environment}`,
    resources: ['../../base'],
    patchesStrategicMerge: ['deployment-patch.yaml', 'service-patch.yaml'],
    configMapGenerator: [
      {
        name: 'app-config',
        literals: [
          `environment=${environment}`,
          `api-url=${config.apiUrl}`,
          `chain-id=${config.chainId}`,
          `network-name=${config.networkName}`,
        ],
      },
    ],
    replicas: [
      {
        name: 'wrfcoin-api',
        count: environment === 'production' ? 3 : 2,
      },
      {
        name: 'wrfcoin-frontend',
        count: environment === 'production' ? 2 : 1,
      },
    ],
  };

  fs.writeFileSync(
    path.join(k8sDir, 'kustomization.yaml'),
    JSON.stringify(kustomization, null, 2)
  );

  console.log(`✅ Kubernetes configuration updated for ${environment}`);
}

async function updateMonitoringConfig(environment) {
  if (!environmentConfigs[environment].features.monitoring) {
    console.log(
      '⏭️ Skipping monitoring configuration (disabled for this environment)'
    );
    return;
  }

  console.log(`📊 Updating monitoring configuration for ${environment}...`);

  const monitoringDir = path.join(
    __dirname,
    '..',
    'infra',
    'monitoring',
    'environments',
    environment
  );

  // Ensure directory exists
  if (!fs.existsSync(monitoringDir)) {
    fs.mkdirSync(monitoringDir, { recursive: true });
  }

  // Generate Prometheus configuration
  const prometheusConfig = {
    global: {
      scrape_interval: environment === 'production' ? '15s' : '30s',
      evaluation_interval: environment === 'production' ? '15s' : '30s',
    },
    scrape_configs: [
      {
        job_name: `wrfcoin-api-${environment}`,
        static_configs: [
          {
            targets: [`api-${environment}.wrfcoin.io:9090`],
          },
        ],
        scrape_interval: '15s',
        metrics_path: '/metrics',
      },
    ],
  };

  fs.writeFileSync(
    path.join(monitoringDir, 'prometheus.yml'),
    JSON.stringify(prometheusConfig, null, 2)
  );

  console.log(`✅ Monitoring configuration updated for ${environment}`);
}

async function updateSecurityConfig(environment) {
  console.log(`🔒 Updating security configuration for ${environment}...`);

  const securityConfig = securityConfigs[environment];
  const securityDir = path.join(
    __dirname,
    '..',
    'configs',
    'security',
    environment
  );

  // Ensure directory exists
  if (!fs.existsSync(securityDir)) {
    fs.mkdirSync(securityDir, { recursive: true });
  }

  // Generate security configuration
  fs.writeFileSync(
    path.join(securityDir, 'security.json'),
    JSON.stringify(securityConfig, null, 2)
  );

  // Generate CORS configuration for nginx/ALB
  const corsConfig = {
    allowedOrigins: securityConfig.cors.origin,
    allowCredentials: securityConfig.cors.credentials,
    allowedMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With'],
    maxAge: 86400, // 24 hours
  };

  fs.writeFileSync(
    path.join(securityDir, 'cors.json'),
    JSON.stringify(corsConfig, null, 2)
  );

  console.log(`✅ Security configuration updated for ${environment}`);
}

async function generateDeploymentManifest(environment, version) {
  console.log(`📋 Generating deployment manifest for ${environment}...`);

  const manifestDir = path.join(__dirname, '..', 'deployments', environment);

  // Ensure directory exists
  if (!fs.existsSync(manifestDir)) {
    fs.mkdirSync(manifestDir, { recursive: true });
  }

  const manifest = {
    environment,
    version: version || 'latest',
    timestamp: new Date().toISOString(),
    configuration: {
      ...environmentConfigs[environment],
      security: securityConfigs[environment],
    },
    deployment: {
      strategy: 'rolling-update',
      maxUnavailable: '25%',
      maxSurge: '25%',
    },
    health: {
      readinessProbe: {
        httpGet: {
          path: '/api/health',
          port: 8080,
        },
        initialDelaySeconds: 30,
        periodSeconds: 10,
      },
      livenessProbe: {
        httpGet: {
          path: '/api/health',
          port: 8080,
        },
        initialDelaySeconds: 60,
        periodSeconds: 30,
      },
    },
    resources: {
      requests: {
        memory: environment === 'production' ? '1Gi' : '512Mi',
        cpu: environment === 'production' ? '500m' : '250m',
      },
      limits: {
        memory: environment === 'production' ? '2Gi' : '1Gi',
        cpu: environment === 'production' ? '1000m' : '500m',
      },
    },
  };

  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const manifestFile = path.join(manifestDir, `deployment-${timestamp}.json`);

  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2));

  // Also create/update the latest manifest
  fs.writeFileSync(
    path.join(manifestDir, 'latest.json'),
    JSON.stringify(manifest, null, 2)
  );

  console.log(`✅ Deployment manifest generated: ${manifestFile}`);
}

// Handle script execution
if (require.main === module) {
  main().catch(error => {
    console.error('❌ Script failed:', error);
    process.exit(1);
  });
}

module.exports = {
  main,
  environmentConfigs,
  securityConfigs,
};
