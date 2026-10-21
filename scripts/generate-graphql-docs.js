#!/usr/bin/env node

/**
 * GraphQL Documentation Generator
 *
 * Generates documentation for GraphQL schema including:
 * - Schema introspection
 * - Type definitions
 * - Query and mutation documentation
 * - Usage examples
 */

const fs = require('fs');
const path = require('path');

function generateGraphQLDocs() {
  console.log('📊 Generating GraphQL documentation...');

  const schemaPath = path.join(__dirname, '../backend/graphql/schema.graphql');
  const outputDir = path.join(__dirname, '../docs/generated/graphql');

  if (!fs.existsSync(schemaPath)) {
    console.log('❌ GraphQL schema file not found');
    return false;
  }

  // Ensure output directory exists
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  try {
    const schemaContent = fs.readFileSync(schemaPath, 'utf8');

    // Parse schema and extract types
    const types = parseGraphQLSchema(schemaContent);

    // Generate HTML documentation
    const htmlContent = generateGraphQLHTML(types, schemaContent);

    // Write documentation files
    fs.writeFileSync(path.join(outputDir, 'index.html'), htmlContent);
    fs.writeFileSync(path.join(outputDir, 'schema.graphql'), schemaContent);

    // Generate JSON representation
    const jsonSchema = {
      types: types,
      schema: schemaContent,
      generatedAt: new Date().toISOString(),
    };

    fs.writeFileSync(
      path.join(outputDir, 'schema.json'),
      JSON.stringify(jsonSchema, null, 2)
    );

    console.log('✅ GraphQL documentation generated successfully');
    return true;
  } catch (error) {
    console.error(
      '❌ Failed to generate GraphQL documentation:',
      error.message
    );
    return false;
  }
}

function parseGraphQLSchema(schema) {
  const types = {
    queries: [],
    mutations: [],
    types: [],
    enums: [],
    scalars: [],
  };

  // Simple regex-based parsing (in production, use a proper GraphQL parser)
  const lines = schema.split('\n');
  let currentType = null;
  let currentSection = null;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();

    if (line.startsWith('type Query')) {
      currentSection = 'queries';
      currentType = { name: 'Query', fields: [] };
    } else if (line.startsWith('type Mutation')) {
      currentSection = 'mutations';
      currentType = { name: 'Mutation', fields: [] };
    } else if (line.match(/^type\s+(\w+)/)) {
      const match = line.match(/^type\s+(\w+)/);
      currentSection = 'types';
      currentType = { name: match[1], fields: [] };
    } else if (line.match(/^enum\s+(\w+)/)) {
      const match = line.match(/^enum\s+(\w+)/);
      currentSection = 'enums';
      currentType = { name: match[1], values: [] };
    } else if (line.match(/^scalar\s+(\w+)/)) {
      const match = line.match(/^scalar\s+(\w+)/);
      types.scalars.push({ name: match[1] });
    } else if (line === '}' && currentType) {
      types[currentSection].push(currentType);
      currentType = null;
      currentSection = null;
    } else if (currentType && line.includes(':')) {
      const field = parseField(line);
      if (field) {
        if (currentSection === 'enums') {
          currentType.values.push(field.name);
        } else {
          currentType.fields.push(field);
        }
      }
    }
  }

  return types;
}

function parseField(line) {
  const match = line.match(/(\w+)(\([^)]*\))?\s*:\s*(.+)/);
  if (match) {
    return {
      name: match[1],
      args: match[2] || '',
      type: match[3],
      description: '',
    };
  }
  return null;
}

function generateGraphQLHTML(types, schema) {
  return `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WRFCoin GraphQL API Documentation</title>
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
            background: #f8f9fa;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 40px;
            border-radius: 10px;
            text-align: center;
            margin-bottom: 30px;
        }
        
        .header h1 {
            font-size: 2.5rem;
            margin-bottom: 10px;
        }
        
        .nav {
            background: white;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 30px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        .nav ul {
            list-style: none;
            display: flex;
            flex-wrap: wrap;
            gap: 20px;
        }
        
        .nav a {
            color: #667eea;
            text-decoration: none;
            font-weight: 600;
            padding: 10px 15px;
            border-radius: 5px;
            transition: all 0.2s ease;
        }
        
        .nav a:hover {
            background: #667eea;
            color: white;
        }
        
        .section {
            background: white;
            border-radius: 8px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        .section h2 {
            color: #2c3e50;
            margin-bottom: 20px;
            padding-bottom: 10px;
            border-bottom: 2px solid #eee;
        }
        
        .type-card {
            background: #f8f9fa;
            border-radius: 6px;
            padding: 20px;
            margin-bottom: 20px;
            border-left: 4px solid #667eea;
        }
        
        .type-card h3 {
            color: #2c3e50;
            margin-bottom: 15px;
        }
        
        .field {
            background: white;
            padding: 10px 15px;
            margin: 5px 0;
            border-radius: 4px;
            border-left: 3px solid #28a745;
            font-family: 'Courier New', monospace;
        }
        
        .field-name {
            color: #e83e8c;
            font-weight: bold;
        }
        
        .field-type {
            color: #6f42c1;
        }
        
        .schema-section {
            background: #2d3748;
            color: #e2e8f0;
            padding: 20px;
            border-radius: 6px;
            overflow-x: auto;
        }
        
        .schema-section pre {
            margin: 0;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            line-height: 1.4;
        }
        
        .endpoint {
            background: #e3f2fd;
            border: 1px solid #2196f3;
            border-radius: 4px;
            padding: 10px 15px;
            margin: 10px 0;
            font-family: monospace;
        }
        
        .footer {
            text-align: center;
            margin-top: 50px;
            padding: 30px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        
        @media (max-width: 768px) {
            .nav ul {
                flex-direction: column;
            }
            
            .container {
                padding: 10px;
            }
            
            .header {
                padding: 20px;
            }
            
            .header h1 {
                font-size: 1.8rem;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 GraphQL API Documentation</h1>
            <p>WRFCoin Platform GraphQL Schema Reference</p>
        </div>
        
        <div class="nav">
            <ul>
                <li><a href="#overview">Overview</a></li>
                <li><a href="#queries">Queries</a></li>
                <li><a href="#mutations">Mutations</a></li>
                <li><a href="#types">Types</a></li>
                <li><a href="#enums">Enums</a></li>
                <li><a href="#schema">Full Schema</a></li>
            </ul>
        </div>
        
        <div id="overview" class="section">
            <h2>🌍 Overview</h2>
            <p>The WRFCoin GraphQL API provides a comprehensive interface for interacting with the climate-focused blockchain platform. This API supports:</p>
            <ul style="margin: 20px 0; padding-left: 20px;">
                <li><strong>Weather Data Operations</strong> - Submit and query environmental sensor data</li>
                <li><strong>Blockchain Queries</strong> - Access transaction and block information</li>
                <li><strong>Wallet Management</strong> - Handle wallet operations and balance queries</li>
                <li><strong>NFT Operations</strong> - Mint, transfer, and query NFTs</li>
                <li><strong>Governance</strong> - DAO proposals and voting mechanisms</li>
                <li><strong>Carbon Credits</strong> - Environmental impact tracking and trading</li>
            </ul>
            
            <div class="endpoint">
                <strong>GraphQL Endpoint:</strong> POST http://localhost:4000/graphql
            </div>
            
            <p style="margin-top: 20px;">
                <strong>Authentication:</strong> Most operations require authentication via JWT token in the Authorization header.
            </p>
        </div>
        
        <div id="queries" class="section">
            <h2>🔍 Queries</h2>
            ${generateTypeSection(types.queries, 'Query operations for reading data from the platform')}
        </div>
        
        <div id="mutations" class="section">
            <h2>✏️ Mutations</h2>
            ${generateTypeSection(types.mutations, 'Mutation operations for modifying data on the platform')}
        </div>
        
        <div id="types" class="section">
            <h2>📋 Types</h2>
            ${generateTypeSection(types.types, 'Custom types used throughout the GraphQL schema')}
        </div>
        
        <div id="enums" class="section">
            <h2>🏷️ Enums</h2>
            ${generateEnumSection(types.enums)}
        </div>
        
        <div id="schema" class="section">
            <h2>📜 Full Schema</h2>
            <p>Complete GraphQL schema definition:</p>
            <div class="schema-section">
                <pre>${schema.replace(/</g, '&lt;').replace(/>/g, '&gt;')}</pre>
            </div>
        </div>
        
        <div class="footer">
            <p>
                <strong>WRFCoin GraphQL API Documentation</strong><br>
                Generated on ${new Date().toLocaleDateString()} at ${new Date().toLocaleTimeString()}<br>
                <a href="/" style="color: #667eea;">← Back to Documentation Home</a>
            </p>
        </div>
    </div>
</body>
</html>
  `.trim();
}

function generateTypeSection(types, description) {
  if (!types || types.length === 0) {
    return `<p style="color: #7f8c8d; font-style: italic;">No ${description.toLowerCase()} defined.</p>`;
  }

  return `
    <p>${description}</p>
    ${types
      .map(
        type => `
      <div class="type-card">
        <h3>${type.name}</h3>
        ${
          type.fields && type.fields.length > 0
            ? `
          <div>
            ${type.fields
              .map(
                field => `
              <div class="field">
                <span class="field-name">${field.name}</span>${field.args}: <span class="field-type">${field.type}</span>
              </div>
            `
              )
              .join('')}
          </div>
        `
            : '<p style="color: #7f8c8d; font-style: italic;">No fields defined.</p>'
        }
      </div>
    `
      )
      .join('')}
  `;
}

function generateEnumSection(enums) {
  if (!enums || enums.length === 0) {
    return `<p style="color: #7f8c8d; font-style: italic;">No enums defined.</p>`;
  }

  return enums
    .map(
      enumType => `
    <div class="type-card">
      <h3>${enumType.name}</h3>
      ${
        enumType.values && enumType.values.length > 0
          ? `
        <div>
          ${enumType.values
            .map(
              value => `
            <div class="field">
              <span class="field-name">${value}</span>
            </div>
          `
            )
            .join('')}
        </div>
      `
          : '<p style="color: #7f8c8d; font-style: italic;">No values defined.</p>'
      }
    </div>
  `
    )
    .join('');
}

// Run the script if called directly
if (require.main === module) {
  const success = generateGraphQLDocs();
  process.exit(success ? 0 : 1);
}

module.exports = { generateGraphQLDocs };
