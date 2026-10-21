#!/usr/bin/env node

/**
 * Documentation Generation Script
 *
 * Automated script to generate all documentation types:
 * - API documentation from OpenAPI specs
 * - SDK documentation using TypeDoc
 * - Smart contract documentation
 * - GraphQL schema documentation
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// Colors for console output
const colors = {
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  red: '\x1b[31m',
  blue: '\x1b[34m',
  reset: '\x1b[0m',
  bold: '\x1b[1m',
};

function log(message, color = 'reset') {
  console.log(`${colors[color]}${message}${colors.reset}`);
}

function execCommand(command, description) {
  log(`\n🔄 ${description}...`, 'blue');
  try {
    execSync(command, { stdio: 'inherit' });
    log(`✅ ${description} completed successfully`, 'green');
    return true;
  } catch (error) {
    log(`❌ ${description} failed: ${error.message}`, 'red');
    return false;
  }
}

function ensureDirectory(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    log(`📁 Created directory: ${dir}`, 'yellow');
  }
}

function copyFile(src, dest) {
  if (fs.existsSync(src)) {
    fs.copyFileSync(src, dest);
    log(`📋 Copied ${src} to ${dest}`, 'yellow');
  }
}

async function generateDocumentation() {
  log('🚀 Starting WRFCoin Documentation Generation', 'bold');
  log('='.repeat(50), 'blue');

  // Ensure output directories exist
  const outputDirs = [
    'docs/generated',
    'docs/generated/typedoc',
    'docs/generated/contracts',
    'docs/generated/api',
    'docs/generated/graphql',
  ];

  outputDirs.forEach(ensureDirectory);

  let successCount = 0;
  let totalTasks = 0;

  // Task 1: Generate TypeDoc documentation for SDK
  totalTasks++;
  log('\n📚 Step 1: Generating SDK Documentation (TypeDoc)', 'bold');

  if (fs.existsSync('sdk/wrf-sdk-js/src') || fs.existsSync('sdk/js')) {
    if (
      execCommand(
        'npx typedoc --options typedoc.config.js',
        'SDK documentation generation'
      )
    ) {
      successCount++;
    }
  } else {
    log(
      '⚠️  SDK source files not found, skipping TypeDoc generation',
      'yellow'
    );
  }

  // Task 2: Generate smart contract documentation
  totalTasks++;
  log('\n📜 Step 2: Generating Smart Contract Documentation', 'bold');

  if (fs.existsSync('contracts')) {
    if (
      execCommand(
        'npx hardhat docgen',
        'Smart contract documentation generation'
      )
    ) {
      successCount++;
    }
  } else {
    log(
      '⚠️  Contracts directory not found, skipping contract documentation',
      'yellow'
    );
  }

  // Task 3: Validate and copy OpenAPI specification
  totalTasks++;
  log('\n🔌 Step 3: Processing API Documentation', 'bold');

  const openApiPath = 'backend/api/documentation/openapi.yaml';
  if (fs.existsSync(openApiPath)) {
    // Validate OpenAPI spec
    if (
      execCommand(
        `npx @redocly/cli lint ${openApiPath}`,
        'OpenAPI specification validation'
      )
    ) {
      // Copy to generated docs
      copyFile(openApiPath, 'docs/generated/api/openapi.yaml');

      // Generate HTML documentation
      if (
        execCommand(
          `npx @redocly/cli build-docs ${openApiPath} --output docs/generated/api/index.html`,
          'HTML API documentation generation'
        )
      ) {
        successCount++;
      }
    }
  } else {
    log(
      '⚠️  OpenAPI specification not found, skipping API documentation',
      'yellow'
    );
  }

  // Task 4: Generate GraphQL documentation
  totalTasks++;
  log('\n📊 Step 4: Processing GraphQL Documentation', 'bold');

  const graphqlSchemaPath = 'backend/graphql/schema.graphql';
  if (fs.existsSync(graphqlSchemaPath)) {
    // Copy schema to generated docs
    copyFile(graphqlSchemaPath, 'docs/generated/graphql/schema.graphql');

    // Generate introspection JSON
    if (
      execCommand(
        'node scripts/generate-graphql-docs.js',
        'GraphQL schema documentation'
      )
    ) {
      successCount++;
    }
  } else {
    log(
      '⚠️  GraphQL schema not found, skipping GraphQL documentation',
      'yellow'
    );
  }

  // Task 5: Create documentation index
  totalTasks++;
  log('\n🏠 Step 5: Creating Documentation Index', 'bold');

  try {
    const indexContent = generateDocumentationIndex();
    fs.writeFileSync('docs/generated/index.html', indexContent);
    log('✅ Documentation index created successfully', 'green');
    successCount++;
  } catch (error) {
    log(`❌ Failed to create documentation index: ${error.message}`, 'red');
  }

  // Task 6: Install documentation server dependencies
  totalTasks++;
  log('\n🖥️  Step 6: Setting up Documentation Server', 'bold');

  try {
    // Check if js-yaml is installed (needed for OpenAPI parsing)
    execSync('npm list js-yaml', { stdio: 'ignore' });
    log('✅ Documentation server dependencies ready', 'green');
    successCount++;
  } catch (error) {
    if (
      execCommand(
        'npm install js-yaml --save-dev',
        'Installing documentation server dependencies'
      )
    ) {
      successCount++;
    }
  }

  // Summary
  log('\n' + '='.repeat(50), 'blue');
  log(`📊 Documentation Generation Summary`, 'bold');
  log(
    `✅ Successful tasks: ${successCount}/${totalTasks}`,
    successCount === totalTasks ? 'green' : 'yellow'
  );

  if (successCount === totalTasks) {
    log('\n🎉 All documentation generated successfully!', 'green');
    log('\n🚀 To start the documentation server:', 'blue');
    log('   npm run docs:serve', 'bold');
    log('\n🌐 Documentation will be available at:', 'blue');
    log('   http://localhost:3003', 'bold');
  } else {
    log(
      `\n⚠️  ${totalTasks - successCount} task(s) failed. Check the output above for details.`,
      'yellow'
    );
  }

  return successCount === totalTasks;
}

function generateDocumentationIndex() {
  return `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WRFCoin Platform Documentation</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.6;
            color: #333;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 15px;
            padding: 40px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.1);
        }
        
        .header {
            text-align: center;
            margin-bottom: 50px;
        }
        
        .header h1 {
            font-size: 3rem;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            background-clip: text;
            margin-bottom: 10px;
        }
        
        .header p {
            font-size: 1.2rem;
            color: #666;
        }
        
        .docs-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 30px;
            margin-bottom: 40px;
        }
        
        .doc-card {
            background: #f8f9fa;
            border-radius: 10px;
            padding: 30px;
            text-decoration: none;
            color: inherit;
            transition: all 0.3s ease;
            border: 2px solid transparent;
        }
        
        .doc-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 30px rgba(0,0,0,0.1);
            border-color: #667eea;
            text-decoration: none;
            color: inherit;
        }
        
        .doc-card h3 {
            font-size: 1.5rem;
            margin-bottom: 15px;
            color: #2c3e50;
        }
        
        .doc-card p {
            color: #7f8c8d;
            margin-bottom: 20px;
        }
        
        .doc-card .status {
            display: inline-block;
            padding: 5px 12px;
            border-radius: 20px;
            font-size: 12px;
            font-weight: bold;
            text-transform: uppercase;
        }
        
        .status.available { 
            background: #d4edda; 
            color: #155724; 
        }
        
        .status.unavailable { 
            background: #f8d7da; 
            color: #721c24; 
        }
        
        .footer {
            text-align: center;
            margin-top: 50px;
            padding-top: 30px;
            border-top: 2px solid #eee;
            color: #666;
        }
        
        .footer a {
            color: #667eea;
            text-decoration: none;
            font-weight: 600;
        }
        
        .footer a:hover {
            text-decoration: underline;
        }
        
        .generation-info {
            background: #e3f2fd;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 30px;
            border-left: 4px solid #2196f3;
        }
        
        .generation-info h4 {
            color: #1976d2;
            margin-bottom: 10px;
        }
        
        @media (max-width: 768px) {
            .container {
                padding: 20px;
            }
            
            .header h1 {
                font-size: 2rem;
            }
            
            .docs-grid {
                grid-template-columns: 1fr;
                gap: 20px;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🌍 WRFCoin Platform</h1>
            <p>Comprehensive Developer Documentation</p>
        </div>
        
        <div class="generation-info">
            <h4>📅 Documentation Generated</h4>
            <p>This documentation was automatically generated on <strong>${new Date().toLocaleDateString()}</strong> at <strong>${new Date().toLocaleTimeString()}</strong>.</p>
        </div>
        
        <div class="docs-grid">
            <a href="/api-docs" class="doc-card">
                <h3>🔌 REST API Documentation</h3>
                <p>Interactive Swagger UI documentation for all REST API endpoints including blockchain operations, weather data, and wallet management.</p>
                <span class="status available">Available</span>
            </a>
            
            <a href="/graphql" class="doc-card">
                <h3>📊 GraphQL API Documentation</h3>
                <p>GraphQL Playground for exploring the GraphQL API schema, running queries, and testing mutations.</p>
                <span class="status available">Available</span>
            </a>
            
            <a href="/sdk-docs/js" class="doc-card">
                <h3>📚 JavaScript SDK Documentation</h3>
                <p>TypeDoc generated documentation for the JavaScript/TypeScript SDK including all classes, interfaces, and usage examples.</p>
                <span class="status available">Available</span>
            </a>
            
            <a href="/contract-docs" class="doc-card">
                <h3>📜 Smart Contract Documentation</h3>
                <p>Generated documentation for all smart contracts including ABIs, function signatures, and deployment guides.</p>
                <span class="status available">Available</span>
            </a>
            
            <a href="/static/guides/index.html" class="doc-card">
                <h3>📖 Developer Guides</h3>
                <p>Step-by-step guides, tutorials, and examples for integrating with the WRFCoin platform.</p>
                <span class="status available">Available</span>
            </a>
            
            <a href="/static/architecture/index.html" class="doc-card">
                <h3>🏗️ Architecture Documentation</h3>
                <p>System architecture diagrams, component interactions, and technical specifications.</p>
                <span class="status available">Available</span>
            </a>
        </div>
        
        <div class="footer">
            <p>
                <strong>🌱 Building the Future of Climate-Focused Blockchain</strong><br><br>
                📧 Questions? Contact us at <a href="mailto:api@wrfcoin.com">api@wrfcoin.com</a><br>
                🔗 <a href="https://github.com/wrfcoin/core" target="_blank">GitHub Repository</a> | 
                <a href="https://wrfcoin.com" target="_blank">Official Website</a>
            </p>
        </div>
    </div>
</body>
</html>
  `.trim();
}

// Run the documentation generation
if (require.main === module) {
  generateDocumentation()
    .then(success => {
      process.exit(success ? 0 : 1);
    })
    .catch(error => {
      log(`❌ Documentation generation failed: ${error.message}`, 'red');
      process.exit(1);
    });
}

module.exports = { generateDocumentation };
