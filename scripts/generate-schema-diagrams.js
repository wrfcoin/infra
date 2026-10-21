/**
 * Wrfcoin Schema Relationship Diagram Generator
 * Creates visual diagrams showing relationships between tables in each schema
 */

const fs = require('fs');
const path = require('path');

// Schema relationship definitions
const SCHEMA_RELATIONSHIPS = {
  core: {
    name: 'Core Blockchain Operations',
    tables: {
      blocks: {
        primary_key: 'id',
        relationships: [
          {
            table: 'transactions',
            type: 'one_to_many',
            foreign_key: 'block_id',
          },
          {
            table: 'computational_work_proofs',
            type: 'one_to_many',
            foreign_key: 'block_id',
          },
        ],
      },
      transactions: {
        primary_key: 'id',
        relationships: [
          { table: 'blocks', type: 'many_to_one', foreign_key: 'block_id' },
        ],
      },
      computational_work_proofs: {
        primary_key: 'id',
        relationships: [
          { table: 'blocks', type: 'many_to_one', foreign_key: 'block_id' },
        ],
      },
      trust_anchors: {
        primary_key: 'id',
        relationships: [
          {
            table: 'trust_endorsements',
            type: 'one_to_many',
            foreign_key: 'anchor_id',
          },
        ],
      },
      trust_endorsements: {
        primary_key: 'id',
        relationships: [
          {
            table: 'trust_anchors',
            type: 'many_to_one',
            foreign_key: 'anchor_id',
          },
        ],
      },
      shards: {
        primary_key: 'id',
        relationships: [
          {
            table: 'shard_rebalance_operations',
            type: 'one_to_many',
            foreign_key: 'shard_id',
          },
        ],
      },
      shard_rebalance_operations: {
        primary_key: 'id',
        relationships: [
          { table: 'shards', type: 'many_to_one', foreign_key: 'shard_id' },
        ],
      },
      slash_events: {
        primary_key: 'id',
        relationships: [],
      },
    },
  },

  governance: {
    name: 'Governance & Voting System',
    tables: {
      governance_proposals: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_votes',
            type: 'one_to_many',
            foreign_key: 'proposal_id',
          },
        ],
      },
      governance_votes: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_proposals',
            type: 'many_to_one',
            foreign_key: 'proposal_id',
          },
        ],
      },
      governance_foundation_members: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_foundation_actions',
            type: 'one_to_many',
            foreign_key: 'member_id',
          },
        ],
      },
      governance_foundation_actions: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_foundation_members',
            type: 'many_to_one',
            foreign_key: 'member_id',
          },
        ],
      },
      governance_parameters: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_parameter_history',
            type: 'one_to_many',
            foreign_key: 'parameter_id',
          },
        ],
      },
      governance_parameter_history: {
        primary_key: 'id',
        relationships: [
          {
            table: 'governance_parameters',
            type: 'many_to_one',
            foreign_key: 'parameter_id',
          },
        ],
      },
    },
  },

  rewards: {
    name: 'Achievements & Economic Incentives',
    tables: {
      achievements: {
        primary_key: 'id',
        relationships: [
          {
            table: 'achievement_categories',
            type: 'many_to_one',
            foreign_key: 'category_id',
          },
          {
            table: 'user_achievements',
            type: 'one_to_many',
            foreign_key: 'achievement_id',
          },
          {
            table: 'achievement_progress',
            type: 'one_to_many',
            foreign_key: 'achievement_id',
          },
        ],
      },
      achievement_categories: {
        primary_key: 'id',
        relationships: [
          {
            table: 'achievements',
            type: 'one_to_many',
            foreign_key: 'category_id',
          },
        ],
      },
      user_achievements: {
        primary_key: 'id',
        relationships: [
          {
            table: 'achievements',
            type: 'many_to_one',
            foreign_key: 'achievement_id',
          },
        ],
      },
      mining_rewards: {
        primary_key: 'id',
        relationships: [
          {
            table: 'mining_contributions',
            type: 'one_to_many',
            foreign_key: 'reward_id',
          },
        ],
      },
    },
  },

  iot: {
    name: 'Environmental & Sensor Data',
    tables: {
      environmental_data_submissions: {
        primary_key: 'id',
        relationships: [
          {
            table: 'environmental_attestations',
            type: 'one_to_many',
            foreign_key: 'submission_id',
          },
        ],
      },
      luftdaten_sensors: {
        primary_key: 'id',
        relationships: [
          {
            table: 'luftdaten_measurements',
            type: 'one_to_many',
            foreign_key: 'sensor_id',
          },
        ],
      },
      luftdaten_measurements: {
        primary_key: 'id',
        relationships: [
          {
            table: 'luftdaten_sensors',
            type: 'many_to_one',
            foreign_key: 'sensor_id',
          },
        ],
      },
      ttn_devices: {
        primary_key: 'id',
        relationships: [
          {
            table: 'ttn_measurements',
            type: 'one_to_many',
            foreign_key: 'device_id',
          },
          {
            table: 'ttn_sensors',
            type: 'one_to_many',
            foreign_key: 'device_id',
          },
        ],
      },
      streamr_streams: {
        primary_key: 'id',
        relationships: [
          {
            table: 'streamr_data_points',
            type: 'one_to_many',
            foreign_key: 'stream_id',
          },
          {
            table: 'streamr_subscriptions',
            type: 'one_to_many',
            foreign_key: 'stream_id',
          },
        ],
      },
    },
  },

  crosschain: {
    name: 'Cross-Chain Operations',
    tables: {
      cross_chain_bridges: {
        primary_key: 'id',
        relationships: [
          {
            table: 'bridge_transactions',
            type: 'one_to_many',
            foreign_key: 'bridge_id',
          },
          {
            table: 'cross_chain_transfers',
            type: 'one_to_many',
            foreign_key: 'bridge_id',
          },
        ],
      },
      axelar_chains: {
        primary_key: 'id',
        relationships: [
          {
            table: 'axelar_transfers',
            type: 'one_to_many',
            foreign_key: 'chain_id',
          },
          {
            table: 'axelar_messages',
            type: 'one_to_many',
            foreign_key: 'chain_id',
          },
        ],
      },
      layer_zero_chains: {
        primary_key: 'id',
        relationships: [
          {
            table: 'layer_zero_messages',
            type: 'one_to_many',
            foreign_key: 'chain_id',
          },
          {
            table: 'layer_zero_token_transfers',
            type: 'one_to_many',
            foreign_key: 'chain_id',
          },
        ],
      },
    },
  },

  users: {
    name: 'User, Wallets, and Identity',
    tables: {
      users: {
        primary_key: 'id',
        relationships: [
          {
            table: 'user_operations',
            type: 'one_to_many',
            foreign_key: 'user_id',
          },
          {
            table: 'smart_wallets',
            type: 'one_to_many',
            foreign_key: 'user_id',
          },
          {
            table: 'reputation_events',
            type: 'one_to_many',
            foreign_key: 'user_id',
          },
          {
            table: 'reputation_scores',
            type: 'one_to_one',
            foreign_key: 'user_id',
          },
        ],
      },
      decentralized_identities: {
        primary_key: 'id',
        relationships: [
          {
            table: 'verifiable_credentials',
            type: 'one_to_many',
            foreign_key: 'identity_id',
          },
        ],
      },
    },
  },
};

class SchemaDiagramGenerator {
  constructor() {
    this.outputDir = 'docs/diagrams';
    this.ensureOutputDir();
  }

  ensureOutputDir() {
    if (!fs.existsSync(this.outputDir)) {
      fs.mkdirSync(this.outputDir, { recursive: true });
    }
  }

  generateMermaidDiagram(schemaName, schemaData) {
    let mermaid = `erDiagram\n`;
    mermaid += `    %% ${schemaData.name}\n\n`;

    // Add table definitions
    Object.entries(schemaData.tables).forEach(([tableName, tableData]) => {
      mermaid += `    ${tableName.toUpperCase()} {\n`;
      mermaid += `        ${tableData.primary_key} PK\n`;

      // Add foreign key fields
      tableData.relationships.forEach(rel => {
        if (rel.type.includes('many_to_one')) {
          mermaid += `        ${rel.foreign_key} FK\n`;
        }
      });

      mermaid += `        created_at TIMESTAMP\n`;
      mermaid += `        updated_at TIMESTAMP\n`;
      mermaid += `    }\n\n`;
    });

    // Add relationships
    Object.entries(schemaData.tables).forEach(([tableName, tableData]) => {
      tableData.relationships.forEach(rel => {
        if (rel.type === 'one_to_many') {
          mermaid += `    ${tableName.toUpperCase()} ||--o{ ${rel.table.toUpperCase()} : "has many"\n`;
        } else if (rel.type === 'many_to_one') {
          mermaid += `    ${tableName.toUpperCase()} }o--|| ${rel.table.toUpperCase()} : "belongs to"\n`;
        } else if (rel.type === 'one_to_one') {
          mermaid += `    ${tableName.toUpperCase()} ||--|| ${rel.table.toUpperCase()} : "has one"\n`;
        }
      });
    });

    return mermaid;
  }

  generateDotDiagram(schemaName, schemaData) {
    let dot = `digraph ${schemaName}_schema {\n`;
    dot += `    label="${schemaData.name}";\n`;
    dot += `    rankdir=TB;\n`;
    dot += `    node [shape=record, style=filled, fillcolor=lightblue];\n\n`;

    // Add table nodes
    Object.entries(schemaData.tables).forEach(([tableName, tableData]) => {
      dot += `    ${tableName} [label="{${tableName}|`;
      dot += `{${tableData.primary_key} (PK)`;

      // Add foreign keys
      tableData.relationships.forEach(rel => {
        if (rel.type.includes('many_to_one')) {
          dot += `|${rel.foreign_key} (FK)`;
        }
      });

      dot += `|created_at|updated_at}}"];\n`;
    });

    dot += '\n';

    // Add relationships
    Object.entries(schemaData.tables).forEach(([tableName, tableData]) => {
      tableData.relationships.forEach(rel => {
        if (rel.type === 'one_to_many') {
          dot += `    ${tableName} -> ${rel.table} [label="1:N"];\n`;
        } else if (rel.type === 'many_to_one') {
          dot += `    ${tableName} -> ${rel.table} [label="N:1"];\n`;
        } else if (rel.type === 'one_to_one') {
          dot += `    ${tableName} -> ${rel.table} [label="1:1"];\n`;
        }
      });
    });

    dot += '}';
    return dot;
  }

  generateMarkdownDocs(schemaName, schemaData) {
    let md = `# ${schemaData.name} - Schema Relationships\n\n`;
    md += `## Tables Overview\n\n`;

    Object.entries(schemaData.tables).forEach(([tableName, tableData]) => {
      md += `### \`${schemaName}.${tableName}\`\n\n`;
      md += `**Primary Key:** \`${tableData.primary_key}\`\n\n`;

      if (tableData.relationships.length > 0) {
        md += `**Relationships:**\n`;
        tableData.relationships.forEach(rel => {
          md += `- ${rel.type.replace('_', ' ')} with \`${schemaName}.${rel.table}\``;
          if (rel.foreign_key) {
            md += ` (via \`${rel.foreign_key}\`)`;
          }
          md += '\n';
        });
      } else {
        md += `**Relationships:** None (standalone table)\n`;
      }

      md += '\n';
    });

    return md;
  }

  generateAllDiagrams() {
    console.log('🎨 Generating schema relationship diagrams...\n');

    Object.entries(SCHEMA_RELATIONSHIPS).forEach(([schemaName, schemaData]) => {
      console.log(`📊 Processing schema: ${schemaName}`);

      // Generate Mermaid diagram
      const mermaidContent = this.generateMermaidDiagram(
        schemaName,
        schemaData
      );
      fs.writeFileSync(
        path.join(this.outputDir, `${schemaName}-schema.mermaid`),
        mermaidContent
      );

      // Generate DOT diagram
      const dotContent = this.generateDotDiagram(schemaName, schemaData);
      fs.writeFileSync(
        path.join(this.outputDir, `${schemaName}-schema.dot`),
        dotContent
      );

      // Generate Markdown documentation
      const markdownContent = this.generateMarkdownDocs(schemaName, schemaData);
      fs.writeFileSync(
        path.join(this.outputDir, `${schemaName}-relationships.md`),
        markdownContent
      );

      console.log(`  ✅ Generated diagrams for ${schemaName} schema`);
    });

    this.generateOverviewDiagram();
    this.generateREADME();

    console.log('\n🎉 Schema diagram generation completed!');
    console.log(`📁 Diagrams saved to: ${this.outputDir}/`);
    console.log('📋 Generated files:');
    console.log('  - *.mermaid (for GitHub/GitLab rendering)');
    console.log('  - *.dot (for Graphviz rendering)');
    console.log('  - *-relationships.md (documentation)');
    console.log('  - schema-overview.mermaid (complete system)');
  }

  generateOverviewDiagram() {
    let mermaid = `graph TB\n`;
    mermaid += `    %% Wrfcoin Database Schema Overview\n\n`;

    // Add schema boxes
    Object.entries(SCHEMA_RELATIONSHIPS).forEach(([schemaName, schemaData]) => {
      const tableCount = Object.keys(schemaData.tables).length;
      mermaid += `    ${schemaName.toUpperCase()}["🗂️ ${schemaData.name}<br/>${tableCount} tables"]\n`;
    });

    mermaid += '\n    %% Inter-schema relationships\n';
    mermaid += '    CORE --> REWARDS\n';
    mermaid += '    USERS --> REWARDS\n';
    mermaid += '    IOT --> CORE\n';
    mermaid += '    CROSSCHAIN --> CORE\n';
    mermaid += '    GOVERNANCE --> USERS\n';
    mermaid += '    ANALYTICS --> CORE\n';
    mermaid += '    ORACLE --> CORE\n';

    fs.writeFileSync(
      path.join(this.outputDir, 'schema-overview.mermaid'),
      mermaid
    );
  }

  generateREADME() {
    const readme = `# Wrfcoin Database Schema Diagrams

This directory contains visual representations of the database schema relationships for the Wrfcoin blockchain platform.

## Generated Files

### Schema-Specific Diagrams
${Object.keys(SCHEMA_RELATIONSHIPS)
  .map(
    schema =>
      `- **${schema}**: \`${schema}-schema.mermaid\`, \`${schema}-schema.dot\`, \`${schema}-relationships.md\``
  )
  .join('\n')}

### Overview
- **\`schema-overview.mermaid\`**: Complete system overview showing all schemas and their relationships

## File Formats

### Mermaid Files (*.mermaid)
Entity-Relationship diagrams that can be rendered directly in GitHub, GitLab, and many documentation tools.

To view locally, use:
- [Mermaid Live Editor](https://mermaid.live/)
- VS Code with Mermaid extension
- GitHub/GitLab (automatic rendering)

### DOT Files (*.dot)
Graphviz format diagrams for high-quality rendering.

To render locally:
\`\`\`bash
# Install Graphviz
apt install graphviz  # Ubuntu/Debian
brew install graphviz  # macOS

# Render diagram
dot -Tpng core-schema.dot -o core-schema.png
\`\`\`

### Markdown Files (*-relationships.md)
Human-readable documentation of table relationships and foreign key constraints.

## Usage

### For Developers
- Reference relationship diagrams when writing queries that join across tables
- Use for understanding data flow in the application
- Consult when designing new features that interact with existing schemas

### For AI Agents
- Parse relationship files to generate accurate test fixtures
- Use for automated code generation that respects foreign key constraints
- Reference for building schema-aware database operations

## Schema Organization

The Wrfcoin database is organized into 9 logical schemas:

1. **Core** - Blockchain infrastructure (blocks, transactions, consensus)
2. **Governance** - Democratic governance and voting systems
3. **Rewards** - Achievement tracking and economic incentives
4. **IoT** - Environmental sensors and weather station data
5. **CrossChain** - Bridge protocols and cross-chain transfers
6. **Users** - Identity management and wallet operations
7. **Analytics** - Performance metrics and data analysis
8. **Infra** - System management and deployment
9. **Oracle** - External data integration and services

---

*Generated automatically by the Wrfcoin schema diagram generator*
`;

    fs.writeFileSync(path.join(this.outputDir, 'README.md'), readme);
  }
}

// Run the generator
if (require.main === module) {
  const generator = new SchemaDiagramGenerator();
  generator.generateAllDiagrams();
}

module.exports = SchemaDiagramGenerator;
