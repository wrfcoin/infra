#!/usr/bin/env node

/**
 * Unified Database Seeding Script
 * Seeds all essential data: rewards, achievements, governance, and validators
 * Optimized for fast startup and coordinated database initialization
 */

const { execSync } = require('child_process');
const path = require('path');

async function runScript(scriptPath, description) {
  console.log(`🌱 ${description}...`);
  const startTime = Date.now();

  try {
    execSync(`node ${scriptPath}`, {
      stdio: 'inherit',
      cwd: process.cwd(),
    });
    const duration = ((Date.now() - startTime) / 1000).toFixed(1);
    console.log(`✅ ${description} completed in ${duration}s`);
    return true;
  } catch (error) {
    console.error(`❌ ${description} failed:`, error.message);
    return false;
  }
}

async function seedAllData() {
  console.log('🚀 Starting unified database seeding...');
  console.log('====================================');

  const startTime = Date.now();
  const scripts = [
    {
      path: 'scripts/gamified-achievement-system.js',
      description: 'Seeding achievements and rewards data',
    },
  ];

  let successCount = 0;

  for (const script of scripts) {
    const success = await runScript(script.path, script.description);
    if (success) successCount++;
  }

  const totalDuration = ((Date.now() - startTime) / 1000).toFixed(1);

  console.log('====================================');
  console.log(`🎉 Database seeding completed!`);
  console.log(`📊 Success: ${successCount}/${scripts.length} scripts`);
  console.log(`⏱️  Total time: ${totalDuration}s`);

  if (successCount === scripts.length) {
    console.log('✨ All database tables successfully seeded');
    process.exit(0);
  } else {
    console.log('⚠️  Some seeding operations failed - check logs above');
    process.exit(1);
  }
}

// Run the unified seeding
seedAllData().catch(error => {
  console.error('❌ Unified seeding failed:', error);
  process.exit(1);
});
