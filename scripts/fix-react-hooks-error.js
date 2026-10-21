#!/usr/bin/env node

/**
 * Fix React Hooks Error Script
 * Addresses the useState null error in IntegrationsContext
 */

const fs = require('fs');
const path = require('path');

class ReactHooksFixer {
  constructor() {
    this.fixedFiles = [];
    this.errors = [];
  }

  /**
   * Fix React hooks import and usage issues
   */
  async fixReactHooksErrors() {
    console.log('🔧 Fixing React hooks errors...');

    // Fix IntegrationsContext
    await this.fixIntegrationsContext();

    // Check for other potential React issues
    await this.checkForReactIssues();

    console.log(`✅ Fixed ${this.fixedFiles.length} files`);
    if (this.errors.length > 0) {
      console.log(`⚠️  ${this.errors.length} issues found`);
      this.errors.forEach(err => console.log(`   ${err}`));
    }
  }

  /**
   * Fix the IntegrationsContext file
   */
  async fixIntegrationsContext() {
    const filePath = 'frontend/src/contexts/IntegrationsContext.jsx';

    try {
      let content = fs.readFileSync(filePath, 'utf8');
      const originalContent = content;

      // Ensure proper React import
      if (!content.includes('import React,')) {
        content = content.replace(/import\s+React\s*,?\s*{/, 'import React, {');
      }

      // Add proper error boundaries and null checks
      const fixedProviderFunction = `
// IntegrationsProvider component with proper error handling
export const IntegrationsProvider = ({ children }) => {
  // Add null checks for React hooks
  if (typeof React === 'undefined' || !React.useState) {
    console.error('React is not properly loaded');
    return children;
  }

  const [integrations, setIntegrations] = React.useState({});
  const [isLoading, setIsLoading] = React.useState(true);

  // Toggle integration status
  const toggleIntegration = React.useCallback((integrationName) => {
    setIntegrations(prev => ({
      ...prev,
      [integrationName]: {
        ...prev[integrationName],
        enabled: !prev[integrationName]?.enabled
      }
    }));
  }, []);

  // Toggle category status  
  const toggleCategory = React.useCallback((categoryName) => {
    setIntegrations(prev => {
      const newIntegrations = { ...prev };
      const categoryIntegrations = Object.keys(newIntegrations).filter(key => 
        newIntegrations[key]?.category === categoryName
      );
      
      const allEnabled = categoryIntegrations.every(key => 
        newIntegrations[key]?.enabled
      );
      
      categoryIntegrations.forEach(key => {
        if (newIntegrations[key]) {
          newIntegrations[key].enabled = !allEnabled;
        }
      });
      
      return newIntegrations;
    });
  }, []);

  // Update integrations data
  const updateIntegrations = React.useCallback((newIntegrations) => {
    setIntegrations(newIntegrations);
  }, []);

  // Load integrations from storage
  React.useEffect(() => {
    const loadIntegrations = async () => {
      try {
        const stored = localStorage.getItem('wrfcoin_integrations');
        if (stored) {
          const parsedIntegrations = JSON.parse(stored);
          setIntegrations(parsedIntegrations);
        } else {
          // Default integrations
          const defaultIntegrations = {
            crossChain: { enabled: true, category: 'blockchain' },
            aiMl: { enabled: true, category: 'ai' },
            iot: { enabled: true, category: 'sensors' },
            governance: { enabled: true, category: 'dao' }
          };
          setIntegrations(defaultIntegrations);
        }
      } catch (error) {
        console.error('Error loading integrations:', error);
        setIntegrations({});
      } finally {
        setIsLoading(false);
      }
    };

    loadIntegrations();
  }, []);

  // Save integrations to storage
  React.useEffect(() => {
    if (!isLoading && Object.keys(integrations).length > 0) {
      try {
        localStorage.setItem('wrfcoin_integrations', JSON.stringify(integrations));
      } catch (error) {
        console.error('Error saving integrations:', error);
      }
    }
  }, [integrations, isLoading]);

  const contextValue = React.useMemo(() => ({
    integrations,
    toggleIntegration,
    toggleCategory,
    updateIntegrations,
    isLoading
  }), [integrations, toggleIntegration, toggleCategory, updateIntegrations, isLoading]);

  return (
    <IntegrationsContext.Provider value={contextValue}>
      {children}
    </IntegrationsContext.Provider>
  );
};`;

      // Replace the existing provider if it exists
      const providerRegex =
        /export const IntegrationsProvider[\s\S]*?(?=export|$)/;
      if (providerRegex.test(content)) {
        content = content.replace(providerRegex, fixedProviderFunction);
      } else {
        content += '\n' + fixedProviderFunction;
      }

      // Only write if content changed
      if (content !== originalContent) {
        fs.writeFileSync(filePath, content);
        this.fixedFiles.push(filePath);
        console.log(`  Fixed: ${filePath}`);
      }
    } catch (error) {
      this.errors.push(`Error fixing ${filePath}: ${error.message}`);
    }
  }

  /**
   * Check for other React-related issues
   */
  async checkForReactIssues() {
    const issues = [];

    // Check package.json for React version conflicts
    try {
      const packagePath = 'frontend/package.json';
      if (fs.existsSync(packagePath)) {
        const packageContent = JSON.parse(fs.readFileSync(packagePath, 'utf8'));

        if (
          packageContent.dependencies?.react !==
          packageContent.devDependencies?.react
        ) {
          issues.push(
            'React version mismatch between dependencies and devDependencies'
          );
        }
      }
    } catch (error) {
      issues.push('Could not check package.json for React issues');
    }

    if (issues.length > 0) {
      console.log('🔍 Additional issues found:');
      issues.forEach(issue => console.log(`   - ${issue}`));
    }
  }
}

// Run the fixer if called directly
if (require.main === module) {
  const fixer = new ReactHooksFixer();
  fixer.fixReactHooksErrors().catch(console.error);
}

module.exports = ReactHooksFixer;
