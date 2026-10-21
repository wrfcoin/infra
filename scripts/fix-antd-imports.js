#!/usr/bin/env node

/**
 * Fix Ant Design Imports Script
 * Automatically replaces all antd imports with custom components
 */

const fs = require('fs');
const path = require('path');

class AntdImportFixer {
  constructor() {
    this.componentsDir = 'frontend/src/components';
    this.fixedFiles = [];
    this.errors = [];
  }

  /**
   * Fix all antd imports in the components directory
   */
  async fixAllAntdImports() {
    console.log('🔧 Fixing Ant Design imports...');

    if (!fs.existsSync(this.componentsDir)) {
      console.error('❌ Components directory not found');
      return;
    }

    await this.processDirectory(this.componentsDir);

    console.log(`✅ Fixed ${this.fixedFiles.length} files`);
    if (this.errors.length > 0) {
      console.log(`⚠️  ${this.errors.length} errors occurred`);
      this.errors.forEach(err => console.log(`   ${err}`));
    }
  }

  /**
   * Process a directory recursively
   */
  async processDirectory(dir) {
    const files = fs.readdirSync(dir);

    for (const file of files) {
      const filePath = path.join(dir, file);
      const stat = fs.statSync(filePath);

      if (stat.isDirectory()) {
        await this.processDirectory(filePath);
      } else if (file.endsWith('.jsx') || file.endsWith('.js')) {
        await this.fixFileImports(filePath);
      }
    }
  }

  /**
   * Fix antd imports in a specific file
   */
  async fixFileImports(filePath) {
    try {
      let content = fs.readFileSync(filePath, 'utf8');
      const originalContent = content;

      // Skip if no antd imports
      if (
        !content.includes('from "antd"') &&
        !content.includes("from 'antd'")
      ) {
        return;
      }

      console.log(`  Fixing: ${filePath}`);

      // Calculate relative path to CustomComponents
      const relativePath = this.getRelativePath(
        filePath,
        'frontend/src/components/common/CustomComponents'
      );

      // Replace antd imports
      content = content.replace(
        /import\s*{[^}]+}\s*from\s*["']antd["'];?/g,
        match => {
          // Extract imported components
          const componentsMatch = match.match(/{\s*([^}]+)\s*}/);
          if (componentsMatch) {
            const components = componentsMatch[1]
              .split(',')
              .map(c => c.trim())
              .filter(c => c.length > 0);

            return `import {\n  ${components.join(',\n  ')}\n} from "${relativePath}";`;
          }
          return match;
        }
      );

      // Remove @ant-design/icons imports and add custom icons
      content = content.replace(
        /import\s*{[^}]+}\s*from\s*["']@ant-design\/icons["'];?/g,
        '// Icons replaced with custom implementations'
      );

      // Add custom icon implementations at the top
      if (content.includes('OutlinedIcon') || content.includes('Outlined')) {
        const iconReplacements = `
// Custom icon replacements
const SendOutlined = () => <span className="icon">📤</span>;
const InfoCircleOutlined = () => <span className="icon">ℹ️</span>;
const LoadingOutlined = () => <span className="icon">⚪</span>;
const CheckCircleOutlined = () => <span className="icon">✅</span>;
const CloseCircleOutlined = () => <span className="icon">❌</span>;
const SyncOutlined = () => <span className="icon">🔄</span>;
const ApiOutlined = () => <span className="icon">🔌</span>;
const GlobalOutlined = () => <span className="icon">🌐</span>;
const LinkOutlined = () => <span className="icon">🔗</span>;
`;

        // Insert after imports
        const importEndIndex = content.lastIndexOf('import');
        const nextLineIndex = content.indexOf('\n', importEndIndex);
        content =
          content.slice(0, nextLineIndex) +
          iconReplacements +
          content.slice(nextLineIndex);
      }

      // Only write if content changed
      if (content !== originalContent) {
        fs.writeFileSync(filePath, content);
        this.fixedFiles.push(filePath);
      }
    } catch (error) {
      this.errors.push(`Error fixing ${filePath}: ${error.message}`);
    }
  }

  /**
   * Calculate relative path between two files
   */
  getRelativePath(fromFile, toFile) {
    const fromDir = path.dirname(fromFile);
    const relativePath = path.relative(fromDir, toFile);

    // Ensure it starts with ./ or ../
    if (!relativePath.startsWith('.')) {
      return './' + relativePath;
    }

    return relativePath;
  }
}

// Run the fixer if called directly
if (require.main === module) {
  const fixer = new AntdImportFixer();
  fixer.fixAllAntdImports().catch(console.error);
}

module.exports = AntdImportFixer;
