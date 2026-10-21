#!/usr/bin/env node

/**
 * WRFCoin Smart Contract Analyzer
 *
 * Parses all Solidity contracts and generates structured data for D3.js network visualization.
 * Creates nodes (contracts) and links (relationships) for the frontend graph component.
 *
 * Features:
 * - Contract categorization by functionality
 * - Inheritance and import relationship mapping
 * - Interface implementation detection
 * - Hub-and-spoke architecture analysis
 * - Performance-optimized JSON output
 */

const fs = require('fs');
const path = require('path');
const glob = require('glob');

// Determine project root from script location
const SCRIPT_DIR = path.dirname(__filename);
const PROJECT_ROOT = path.resolve(SCRIPT_DIR, '..');

// Contract categories with color coding for visualization
const CONTRACT_CATEGORIES = {
  'Core Tokens': {
    color: '#FF6B6B',
    description: 'Core token contracts and basic functionality',
    keywords: ['Token', 'ERC20', 'ERC721', 'WRF'],
  },
  DeFi: {
    color: '#4ECDC4',
    description: 'Decentralized Finance protocols and mechanisms',
    keywords: [
      'AMM',
      'Staking',
      'Yield',
      'Farm',
      'Pool',
      'Swap',
      'DEX',
      'Liquidity',
      'Trading',
    ],
  },
  Governance: {
    color: '#45B7D1',
    description: 'DAO governance and voting mechanisms',
    keywords: [
      'Governance',
      'Voting',
      'Proposal',
      'DAO',
      'Council',
      'Democracy',
    ],
  },
  Security: {
    color: '#96CEB4',
    description: 'Security, access control, and fraud prevention',
    keywords: [
      'Security',
      'Auth',
      'Access',
      'Control',
      'Fraud',
      'Prevention',
      'Monitor',
      'MultiSig',
      'Guard',
    ],
  },
  'Data/Oracles': {
    color: '#FFEAA7',
    description: 'Data feeds, oracles, and external integrations',
    keywords: [
      'Oracle',
      'Data',
      'Weather',
      'Climate',
      'Sensor',
      'Feed',
      'External',
      'Validator',
    ],
  },
  'NFT/Marketplace': {
    color: '#DDA0DD',
    description: 'NFT contracts and marketplace functionality',
    keywords: [
      'NFT',
      'Marketplace',
      'Market',
      'Trade',
      'Auction',
      'Collection',
      'ERC721',
      'ERC1155',
    ],
  },
  'Carbon/Climate': {
    color: '#98D8C8',
    description: 'Carbon credits and climate-related contracts',
    keywords: [
      'Carbon',
      'Credit',
      'Climate',
      'Environmental',
      'Emission',
      'Green',
      'Eco',
    ],
  },
  'Cross-Chain': {
    color: '#F7DC6F',
    description: 'Cross-chain bridges and interoperability',
    keywords: [
      'Bridge',
      'Cross',
      'Chain',
      'Interop',
      'Multi',
      'Relay',
      'Wormhole',
    ],
  },
  Infrastructure: {
    color: '#BB8FCE',
    description: 'Infrastructure and utility contracts',
    keywords: [
      'Utils',
      'Helper',
      'Library',
      'Factory',
      'Registry',
      'Manager',
      'Controller',
      'Proxy',
    ],
  },
  Other: {
    color: '#BDC3C7',
    description: 'Other specialized contracts',
    keywords: [],
  },
};

// Relationship types for link categorization
const RELATIONSHIP_TYPES = {
  IMPORT: 'import',
  INHERIT: 'inheritance',
  INTERFACE: 'interface',
  COMPOSITION: 'composition',
  DEPENDENCY: 'dependency',
};

class ContractAnalyzer {
  constructor(contractsDir = path.join(PROJECT_ROOT, 'contracts')) {
    this.contractsDir = contractsDir;
    this.contracts = new Map();
    this.relationships = [];
    this.parsedData = {
      nodes: [],
      links: [],
      categories: CONTRACT_CATEGORIES,
      metadata: {
        totalContracts: 0,
        analysisTimestamp: new Date().toISOString(),
        contractsDir: contractsDir,
      },
    };
  }

  /**
   * Main analysis function
   */
  async analyze() {
    console.log('🔍 Starting WRFCoin Smart Contract Analysis...');

    try {
      // Find all Solidity files
      const contractFiles = await this.findContractFiles();
      console.log(`📄 Found ${contractFiles.length} contract files`);

      // Parse each contract
      for (const filePath of contractFiles) {
        await this.parseContract(filePath);
      }

      // Build relationships
      this.buildRelationships();

      // Generate final data structure
      this.generateOutput();

      console.log('✅ Analysis complete!');
      console.log(`📊 Parsed ${this.contracts.size} contracts`);
      console.log(`🔗 Found ${this.relationships.length} relationships`);

      return this.parsedData;
    } catch (error) {
      console.error('❌ Analysis failed:', error);
      throw error;
    }
  }

  /**
   * Find all Solidity contract files
   */
  async findContractFiles() {
    const pattern = path.join(this.contractsDir, '**/*.sol');
    const files = glob.sync(pattern, {
      ignore: ['**/node_modules/**', '**/archive/**', '**/templates/**'],
    });

    return files.filter(file => {
      // Exclude test files and templates
      const basename = path.basename(file, '.sol');
      return (
        !basename.includes('Test') &&
        !basename.includes('Mock') &&
        !file.includes('/test/') &&
        !file.includes('/templates/') &&
        !file.includes('/archive/')
      );
    });
  }

  /**
   * Parse individual contract file
   */
  async parseContract(filePath) {
    try {
      const content = fs.readFileSync(filePath, 'utf8');
      const contractName = path.basename(filePath, '.sol');

      // Extract contract information
      const contractInfo = {
        id: contractName,
        name: contractName,
        filePath: filePath,
        relativePath: path.relative(this.contractsDir, filePath),
        category: this.categorizeContract(contractName, content),
        imports: this.extractImports(content),
        inheritance: this.extractInheritance(content),
        interfaces: this.extractInterfaces(content),
        functions: this.extractPublicFunctions(content),
        events: this.extractEvents(content),
        description: this.extractDescription(content),
        size: content.length,
        complexity: this.calculateComplexity(content),
        isLibrary: this.isLibrary(content),
        isInterface: this.isInterface(content),
        isAbstract: this.isAbstract(content),
      };

      this.contracts.set(contractName, contractInfo);
    } catch (error) {
      console.warn(`⚠️  Failed to parse ${filePath}:`, error.message);
    }
  }

  /**
   * Categorize contract based on name and content
   */
  categorizeContract(contractName, content) {
    const nameAndContent = (contractName + ' ' + content).toLowerCase();

    for (const [category, config] of Object.entries(CONTRACT_CATEGORIES)) {
      if (
        config.keywords.some(keyword =>
          nameAndContent.includes(keyword.toLowerCase())
        )
      ) {
        return category;
      }
    }

    return 'Other';
  }

  /**
   * Extract import statements
   */
  extractImports(content) {
    const imports = [];
    const importRegex = /import\s+(?:.*\s+from\s+)?['"]([^'"]+)['"];?/g;
    let match;

    while ((match = importRegex.exec(content)) !== null) {
      const importPath = match[1];

      // Extract contract name from local imports
      if (importPath.startsWith('./') || importPath.startsWith('../')) {
        const contractName = path.basename(importPath, '.sol');
        if (contractName && !contractName.includes('/')) {
          imports.push(contractName);
        }
      }
    }

    return imports;
  }

  /**
   * Extract inheritance relationships
   */
  extractInheritance(content) {
    const inheritance = [];
    const contractRegex = /contract\s+(\w+)\s+is\s+([^{]+)/g;
    let match;

    while ((match = contractRegex.exec(content)) !== null) {
      const parents = match[2]
        .split(',')
        .map(parent => parent.trim().split(' ')[0])
        .filter(parent => parent && parent !== 'is');

      inheritance.push(...parents);
    }

    return inheritance;
  }

  /**
   * Extract interface implementations
   */
  extractInterfaces(content) {
    const interfaces = [];
    const interfaceRegex = /interface\s+(\w+)/g;
    let match;

    while ((match = interfaceRegex.exec(content)) !== null) {
      interfaces.push(match[1]);
    }

    return interfaces;
  }

  /**
   * Extract public function signatures
   */
  extractPublicFunctions(content) {
    const functions = [];
    const functionRegex = /function\s+(\w+)\s*\([^)]*\)\s*(public|external)/g;
    let match;

    while ((match = functionRegex.exec(content)) !== null) {
      functions.push({
        name: match[1],
        visibility: match[2],
      });
    }

    return functions;
  }

  /**
   * Extract events
   */
  extractEvents(content) {
    const events = [];
    const eventRegex = /event\s+(\w+)\s*\(/g;
    let match;

    while ((match = eventRegex.exec(content)) !== null) {
      events.push(match[1]);
    }

    return events;
  }

  /**
   * Extract contract description from comments
   */
  extractDescription(content) {
    const descRegex = /\/\*\*[\s\S]*?\*\s*@dev\s+(.*?)(?:\n\s*\*|$)/;
    const match = content.match(descRegex);
    return match ? match[1].trim() : '';
  }

  /**
   * Calculate contract complexity
   */
  calculateComplexity(content) {
    const functions = (content.match(/function\s+\w+/g) || []).length;
    const modifiers = (content.match(/modifier\s+\w+/g) || []).length;
    const events = (content.match(/event\s+\w+/g) || []).length;
    const lines = content.split('\n').length;

    return {
      functions,
      modifiers,
      events,
      lines,
      score: functions + modifiers * 2 + events * 0.5,
    };
  }

  /**
   * Check if contract is a library
   */
  isLibrary(content) {
    return /library\s+\w+/g.test(content);
  }

  /**
   * Check if contract is an interface
   */
  isInterface(content) {
    return /interface\s+\w+/g.test(content);
  }

  /**
   * Check if contract is abstract
   */
  isAbstract(content) {
    return /abstract\s+contract\s+\w+/g.test(content);
  }

  /**
   * Build relationship graph
   */
  buildRelationships() {
    this.relationships = [];

    for (const [contractName, contract] of this.contracts) {
      // Import relationships
      contract.imports.forEach(importName => {
        if (this.contracts.has(importName)) {
          this.relationships.push({
            source: contractName,
            target: importName,
            type: RELATIONSHIP_TYPES.IMPORT,
            strength: 1,
          });
        }
      });

      // Inheritance relationships
      contract.inheritance.forEach(parent => {
        if (this.contracts.has(parent)) {
          this.relationships.push({
            source: contractName,
            target: parent,
            type: RELATIONSHIP_TYPES.INHERIT,
            strength: 3,
          });
        }
      });

      // Interface relationships
      contract.interfaces.forEach(interfaceName => {
        if (this.contracts.has(interfaceName)) {
          this.relationships.push({
            source: contractName,
            target: interfaceName,
            type: RELATIONSHIP_TYPES.INTERFACE,
            strength: 2,
          });
        }
      });
    }
  }

  /**
   * Generate final output structure
   */
  generateOutput() {
    // Convert contracts to nodes
    this.parsedData.nodes = Array.from(this.contracts.values()).map(
      contract => {
        const categoryConfig = CONTRACT_CATEGORIES[contract.category];

        return {
          id: contract.id,
          name: contract.name,
          category: contract.category,
          color: categoryConfig.color,
          description: contract.description || categoryConfig.description,
          type: this.getContractType(contract),
          size: this.calculateNodeSize(contract),
          complexity: contract.complexity.score,
          functions: contract.functions.length,
          events: contract.events.length,
          isHub: this.isHubContract(contract),
          filePath: contract.relativePath,
          metadata: {
            isLibrary: contract.isLibrary,
            isInterface: contract.isInterface,
            isAbstract: contract.isAbstract,
            lines: contract.complexity.lines,
          },
        };
      }
    );

    // Convert relationships to links
    this.parsedData.links = this.relationships.map(rel => ({
      source: rel.source,
      target: rel.target,
      type: rel.type,
      strength: rel.strength,
      value: rel.strength, // D3.js link strength
    }));

    // Update metadata
    this.parsedData.metadata.totalContracts = this.contracts.size;
    this.parsedData.metadata.totalRelationships = this.relationships.length;
    this.parsedData.metadata.categoryCounts = this.getCategoryCounts();
  }

  /**
   * Determine contract type for visualization
   */
  getContractType(contract) {
    if (contract.isInterface) return 'interface';
    if (contract.isLibrary) return 'library';
    if (contract.isAbstract) return 'abstract';
    if (contract.name === 'WRFToken') return 'core';
    return 'contract';
  }

  /**
   * Calculate node size based on complexity and connections
   */
  calculateNodeSize(contract) {
    const baseSize = 10;
    const complexityMultiplier = Math.min(contract.complexity.score / 10, 3);
    const connectionCount = this.relationships.filter(
      rel => rel.source === contract.name || rel.target === contract.name
    ).length;

    return baseSize + complexityMultiplier + connectionCount;
  }

  /**
   * Check if contract is a hub (highly connected)
   */
  isHubContract(contract) {
    const connectionCount = this.relationships.filter(
      rel => rel.source === contract.name || rel.target === contract.name
    ).length;

    return connectionCount >= 5 || contract.name === 'WRFToken';
  }

  /**
   * Get category distribution
   */
  getCategoryCounts() {
    const counts = {};
    Object.keys(CONTRACT_CATEGORIES).forEach(category => {
      counts[category] = 0;
    });

    this.parsedData.nodes.forEach(node => {
      counts[node.category]++;
    });

    return counts;
  }

  /**
   * Save analysis to file
   */
  async saveToFile(outputPath) {
    const output = JSON.stringify(this.parsedData, null, 2);
    fs.writeFileSync(outputPath, output, 'utf8');
    console.log(`💾 Analysis saved to ${outputPath}`);
  }
}

// CLI interface
if (require.main === module) {
  async function main() {
    const analyzer = new ContractAnalyzer();

    try {
      const data = await analyzer.analyze();

      // Save to file
      const outputPath = path.join(
        __dirname,
        '../backend/data/smart-contracts-graph.json'
      );

      // Ensure data directory exists
      const dataDir = path.dirname(outputPath);
      if (!fs.existsSync(dataDir)) {
        fs.mkdirSync(dataDir, { recursive: true });
      }

      await analyzer.saveToFile(outputPath);

      // Print summary
      console.log('\n📊 Analysis Summary:');
      console.log(`Total Contracts: ${data.metadata.totalContracts}`);
      console.log(`Total Relationships: ${data.metadata.totalRelationships}`);
      console.log('\nCategory Distribution:');

      Object.entries(data.metadata.categoryCounts).forEach(
        ([category, count]) => {
          if (count > 0) {
            console.log(`  ${category}: ${count} contracts`);
          }
        }
      );

      console.log(`\n📁 Output saved to: ${outputPath}`);
    } catch (error) {
      console.error('❌ Analysis failed:', error);
      process.exit(1);
    }
  }

  main();
}

module.exports = ContractAnalyzer;
