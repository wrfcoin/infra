#!/usr/bin/env node

/**
 * Test script for Smart Contracts API endpoints
 *
 * Tests all API endpoints and validates response structure
 */

const http = require('http');

const BASE_URL = 'http://localhost:3001';

// Test utilities
function makeRequest(path) {
  return new Promise((resolve, reject) => {
    const url = `${BASE_URL}${path}`;
    console.log(`🔍 Testing: ${url}`);

    http
      .get(url, res => {
        let data = '';

        res.on('data', chunk => {
          data += chunk;
        });

        res.on('end', () => {
          try {
            const parsed = JSON.parse(data);
            resolve({ status: res.statusCode, data: parsed });
          } catch (error) {
            reject(new Error(`Invalid JSON response: ${error.message}`));
          }
        });
      })
      .on('error', error => {
        reject(error);
      });
  });
}

async function testEndpoint(path, expectedStatus = 200) {
  try {
    const result = await makeRequest(path);

    if (result.status === expectedStatus) {
      console.log(`✅ ${path} - Status: ${result.status}`);
      return result.data;
    } else {
      console.log(
        `❌ ${path} - Expected: ${expectedStatus}, Got: ${result.status}`
      );
      return null;
    }
  } catch (error) {
    console.log(`❌ ${path} - Error: ${error.message}`);
    return null;
  }
}

async function runTests() {
  console.log('🚀 Starting Smart Contracts API Tests\n');

  // Test 1: Health check
  console.log('1. Health Check');
  await testEndpoint('/health');
  console.log('');

  // Test 2: Categories endpoint
  console.log('2. Categories Endpoint');
  const categories = await testEndpoint('/api/smart-contracts/categories');
  if (categories && categories.success) {
    const categoryCount = Object.keys(categories.data.categories || {}).length;
    console.log(`   📊 Found ${categoryCount} categories`);
  }
  console.log('');

  // Test 3: Statistics endpoint
  console.log('3. Statistics Endpoint');
  const stats = await testEndpoint('/api/smart-contracts/stats');
  if (stats && stats.success && stats.data) {
    console.log(`   📊 Total Contracts: ${stats.data.totalContracts}`);
    console.log(`   🔗 Total Relationships: ${stats.data.totalRelationships}`);
    console.log(`   🌟 Hub Contracts: ${stats.data.hubContracts}`);
  }
  console.log('');

  // Test 4: Main graph endpoint
  console.log('4. Main Graph Endpoint');
  const graph = await testEndpoint('/api/smart-contracts/graph');
  if (graph && graph.success && graph.data) {
    console.log(`   📊 Nodes: ${graph.data.nodes?.length || 0}`);
    console.log(`   🔗 Links: ${graph.data.links?.length || 0}`);
    console.log(`   💾 Cached: ${graph.cached}`);

    if (graph.data.nodes && graph.data.nodes.length > 0) {
      console.log(`   🎯 Sample Node: ${graph.data.nodes[0].name}`);
    }
  }
  console.log('');

  // Test 5: Contract details endpoint
  console.log('5. Contract Details Endpoint');
  const contractDetails = await testEndpoint('/api/smart-contracts/WRFToken');
  if (contractDetails && contractDetails.success) {
    console.log(
      `   🎯 Contract: ${contractDetails.data.contract?.name || 'Not found'}`
    );
    console.log(
      `   🔗 Relationships: ${contractDetails.data.relationships?.length || 0}`
    );
  }
  console.log('');

  // Test 6: Search endpoint
  console.log('6. Search Endpoint');
  const searchResults = await testEndpoint(
    '/api/smart-contracts/search?q=Token'
  );
  if (searchResults && searchResults.success) {
    console.log(`   🔍 Search Results: ${searchResults.data?.total || 0}`);
  }
  console.log('');

  // Test 7: Category filter
  console.log('7. Category Filter');
  const categoryFilter = await testEndpoint(
    '/api/smart-contracts/search?category=Core%20Tokens'
  );
  if (categoryFilter && categoryFilter.success) {
    console.log(`   🏷️  Core Tokens: ${categoryFilter.data?.total || 0}`);
  }
  console.log('');

  // Test 8: Invalid endpoints (should return 404)
  console.log('8. Invalid Endpoint (Expected 404)');
  await testEndpoint('/api/smart-contracts/nonexistent', 404);
  console.log('');

  console.log('🏁 Test Suite Complete!');
}

// Run tests
if (require.main === module) {
  runTests().catch(error => {
    console.error('❌ Test suite failed:', error);
    process.exit(1);
  });
}

module.exports = { runTests };
