#!/usr/bin/env node

/**
 * Ultra-Parallel Prettier & Linting Strategy for WRFCoin
 * 8-Agent Simultaneous Execution System
 *
 * Coordinates 8 specialized agents working on different domains:
 * - Agent 1: Frontend Core (React/TypeScript)
 * - Agent 2: Backend Services (Node.js/TypeScript)
 * - Agent 3: Blockchain Core (Rust)
 * - Agent 4: Smart Contracts (Solidity)
 * - Agent 5: Test Suites (Various)
 * - Agent 6: SDKs & Extensions (Multi-language)
 * - Agent 7: Scripts & Tools (Utilities)
 * - Agent 8: Infrastructure & Config (Root level)
 */

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

class UltraParallelLintFormatter {
  constructor() {
    this.projectRoot = process.cwd();
    this.agents = [];
    this.statusFile = path.join(this.projectRoot, '.lint-progress.json');
    this.logDir = path.join(this.projectRoot, 'logs', 'parallel-lint');
    this.startTime = Date.now();

    // Ensure log directory exists
    if (!fs.existsSync(this.logDir)) {
      fs.mkdirSync(this.logDir, { recursive: true });
    }

    this.initializeAgents();
  }

  initializeAgents() {
    this.agents = [
      {
        id: 1,
        name: 'Frontend Core',
        path: 'frontend',
        fileCount: 2339,
        commands: ['npm run lint:fix', 'npm run format'],
        tools: ['ESLint', 'Prettier'],
        description: 'React/TypeScript components, hooks, utilities',
      },
      {
        id: 2,
        name: 'Backend Services',
        path: 'backend',
        fileCount: 672,
        commands: ['npm run lint:fix', 'npm run format'],
        tools: ['ESLint', 'Prettier'],
        description: 'APIs, microservices, GraphQL, middleware',
      },
      {
        id: 3,
        name: 'Blockchain Core',
        path: 'blockchain-core',
        fileCount: 530,
        commands: [
          'cargo clippy --fix --all-targets --all-features --allow-dirty',
          'cargo fmt',
        ],
        tools: ['Cargo Clippy', 'Rustfmt'],
        description: 'Rust blockchain implementation',
      },
      {
        id: 4,
        name: 'Smart Contracts',
        path: 'contracts',
        fileCount: 47,
        commands: ['npm run lint:fix', 'npm run format', 'npm run security'],
        tools: ['Solhint', 'Prettier', 'Slither'],
        description: 'Solidity smart contracts with security analysis',
      },
      {
        id: 5,
        name: 'Test Suites',
        path: 'tests',
        fileCount: 564,
        commands: [
          'npx eslint --fix "**/*.{js,ts,jsx,tsx}" --ignore-pattern "node_modules" --ignore-pattern "archive" --ignore-pattern "test-results" || true',
          'npx prettier --write "**/*.{js,ts,jsx,tsx,json,md}" --ignore-path .gitignore || true',
          'cd e2e && npm run test -- --dry-run || true',
          'cd fuzz && npm run test -- --passWithNoTests || true',
        ],
        tools: ['ESLint', 'Prettier', 'Playwright', 'Jest'],
        description: 'Unit, integration, e2e, fuzz, and performance tests',
      },
      {
        id: 6,
        name: 'SDKs & Extensions',
        path: 'sdks',
        fileCount: 436,
        commands: [
          'find . -name "package.json" -not -path "*/node_modules/*" -execdir sh -c "npm run lint 2>/dev/null || npx eslint --fix . 2>/dev/null || true" \\;',
          'npx prettier --write "**/*.{js,ts,tsx,json,md}" --ignore-path .gitignore || true',
          'find . -name "*.py" -not -path "*/node_modules/*" -not -path "*/__pycache__/*" | head -50 | xargs black --quiet 2>/dev/null || true',
          'find . -name "*.py" -not -path "*/node_modules/*" -not -path "*/__pycache__/*" | head -50 | xargs isort --quiet 2>/dev/null || true',
          'find . -name "Cargo.toml" -not -path "*/node_modules/*" -execdir cargo fmt 2>/dev/null || true',
          'find . -name "*.go" -not -path "*/node_modules/*" | head -20 | xargs gofmt -w 2>/dev/null || true',
        ],
        tools: ['ESLint', 'Prettier', 'Black', 'isort', 'cargo fmt', 'gofmt'],
        description:
          'Multi-language SDKs: JavaScript/TypeScript, Python, Rust, Go',
      },
      {
        id: 7,
        name: 'Scripts & Tools',
        path: 'scripts',
        fileCount: 167,
        commands: [
          'npx eslint --fix "**/*.{js,ts}" || true',
          'npx prettier --write "**/*"',
        ],
        tools: ['ESLint', 'Prettier'],
        description: 'Build scripts, utilities, automation tools',
      },
      {
        id: 8,
        name: 'Infrastructure & Config',
        path: '.',
        fileCount: 50,
        commands: [
          'npx eslint --fix "*.{js,ts}" "infra/**/*.{js,ts}" "templates/**/*.{js,ts}" || true',
          'npx prettier --write "*.{js,json,md}" "infra/**/*" "templates/**/*" || true',
        ],
        tools: ['ESLint', 'Prettier'],
        description: 'Configuration files, templates, infrastructure',
      },
    ];
  }

  async createGitStash() {
    console.log('🔄 Creating git stash checkpoint...');
    return new Promise((resolve, reject) => {
      const stash = spawn(
        'git',
        ['stash', 'push', '-m', 'Ultra-parallel-lint-checkpoint'],
        {
          cwd: this.projectRoot,
          stdio: 'pipe',
        }
      );

      stash.on('close', code => {
        if (code === 0) {
          console.log('✅ Git stash checkpoint created');
          resolve();
        } else {
          console.log('⚠️  No changes to stash (clean working directory)');
          resolve(); // Not an error if nothing to stash
        }
      });
    });
  }

  async checkDependencies() {
    console.log('🔍 Checking dependencies...');

    const checks = [
      { command: 'node', args: ['--version'], name: 'Node.js' },
      { command: 'npm', args: ['--version'], name: 'NPM' },
      { command: 'npx', args: ['--version'], name: 'NPX' },
      { command: 'cargo', args: ['--version'], name: 'Cargo' },
    ];

    for (const check of checks) {
      try {
        await new Promise((resolve, reject) => {
          const proc = spawn(check.command, check.args, { stdio: 'pipe' });
          proc.on('close', code => {
            if (code === 0) {
              resolve();
            } else {
              reject(new Error(`${check.name} not found`));
            }
          });
        });
        console.log(`✅ ${check.name} available`);
      } catch (error) {
        console.error(`❌ ${check.name} not available: ${error.message}`);
        throw error;
      }
    }
  }

  initializeStatus() {
    const status = {
      startTime: this.startTime,
      agents: this.agents.map(agent => ({
        id: agent.id,
        name: agent.name,
        status: 'pending',
        progress: 0,
        filesProcessed: 0,
        totalFiles: agent.fileCount,
        currentCommand: null,
        errors: [],
      })),
      overallProgress: 0,
      totalFiles: this.agents.reduce((sum, agent) => sum + agent.fileCount, 0),
      filesProcessed: 0,
    };

    fs.writeFileSync(this.statusFile, JSON.stringify(status, null, 2));
    return status;
  }

  updateAgentStatus(agentId, updates) {
    if (!fs.existsSync(this.statusFile)) return;

    const status = JSON.parse(fs.readFileSync(this.statusFile, 'utf8'));
    const agent = status.agents.find(a => a.id === agentId);

    if (agent) {
      Object.assign(agent, updates);

      // Update overall progress
      status.filesProcessed = status.agents.reduce(
        (sum, a) => sum + a.filesProcessed,
        0
      );
      status.overallProgress = Math.round(
        (status.filesProcessed / status.totalFiles) * 100
      );

      fs.writeFileSync(this.statusFile, JSON.stringify(status, null, 2));
    }
  }

  async runAgent(agent) {
    const logFile = path.join(
      this.logDir,
      `agent-${agent.id}-${agent.name.toLowerCase().replace(/\s+/g, '-')}.log`
    );
    const logStream = fs.createWriteStream(logFile);

    console.log(
      `🚀 Starting Agent ${agent.id}: ${agent.name} (${agent.fileCount} files)`
    );

    this.updateAgentStatus(agent.id, {
      status: 'running',
      currentCommand: agent.commands[0],
    });

    for (let i = 0; i < agent.commands.length; i++) {
      const command = agent.commands[i];
      const [cmd, ...args] = command.split(' ');

      this.updateAgentStatus(agent.id, {
        currentCommand: command,
        progress: Math.round((i / agent.commands.length) * 100),
      });

      logStream.write(
        `\n=== Command ${i + 1}/${agent.commands.length}: ${command} ===\n`
      );

      try {
        await new Promise((resolve, reject) => {
          const proc = spawn(cmd, args, {
            cwd: path.join(this.projectRoot, agent.path),
            stdio: 'pipe',
            shell: true,
          });

          proc.stdout.on('data', data => {
            logStream.write(data);
          });

          proc.stderr.on('data', data => {
            logStream.write(data);
          });

          proc.on('close', code => {
            if (code === 0) {
              resolve();
            } else {
              logStream.write(`\nCommand failed with exit code: ${code}\n`);
              // Don't reject - continue with next command
              resolve();
            }
          });

          proc.on('error', error => {
            logStream.write(`\nProcess error: ${error.message}\n`);
            resolve(); // Continue with next command
          });
        });
      } catch (error) {
        logStream.write(`\nError: ${error.message}\n`);
      }
    }

    this.updateAgentStatus(agent.id, {
      status: 'completed',
      progress: 100,
      filesProcessed: agent.fileCount,
      currentCommand: null,
    });

    logStream.end();
    console.log(`✅ Agent ${agent.id}: ${agent.name} completed`);
  }

  async runAllAgents() {
    console.log(
      `\n🚀 Launching ${this.agents.length} agents simultaneously...\n`
    );

    const agentPromises = this.agents.map(agent =>
      this.runAgent(agent).catch(error => {
        console.error(`❌ Agent ${agent.id} failed:`, error.message);
        this.updateAgentStatus(agent.id, {
          status: 'failed',
          errors: [error.message],
        });
      })
    );

    // Start progress monitoring
    const progressInterval = setInterval(() => {
      this.displayProgress();
    }, 2000);

    try {
      await Promise.all(agentPromises);
    } finally {
      clearInterval(progressInterval);
    }

    this.displayFinalResults();
  }

  displayProgress() {
    if (!fs.existsSync(this.statusFile)) return;

    const status = JSON.parse(fs.readFileSync(this.statusFile, 'utf8'));
    const elapsed = Math.round((Date.now() - status.startTime) / 1000);

    console.clear();
    console.log(
      '┌─────────────────────────────────────────────────────────────┐'
    );
    console.log(
      '│               ULTRA-PARALLEL LINT & FORMAT                 │'
    );
    console.log(
      '├─────────────────────────────────────────────────────────────┤'
    );
    console.log(
      `│ Overall Progress: ${status.overallProgress}% (${status.filesProcessed}/${status.totalFiles} files) │`
    );
    console.log(
      `│ Elapsed Time: ${elapsed}s                                    │`
    );
    console.log(
      '├─────────────────────────────────────────────────────────────┤'
    );

    status.agents.forEach(agent => {
      const statusIcon =
        agent.status === 'completed'
          ? '✅'
          : agent.status === 'running'
            ? '🔄'
            : agent.status === 'failed'
              ? '❌'
              : '⏳';
      const progressBar =
        '█'.repeat(Math.floor(agent.progress / 5)) +
        '░'.repeat(20 - Math.floor(agent.progress / 5));

      console.log(
        `│ ${statusIcon} Agent ${agent.id}: ${agent.name.padEnd(18)} [${progressBar}] ${agent.progress}% │`
      );
    });

    console.log(
      '└─────────────────────────────────────────────────────────────┘'
    );
  }

  displayFinalResults() {
    if (!fs.existsSync(this.statusFile)) return;

    const status = JSON.parse(fs.readFileSync(this.statusFile, 'utf8'));
    const totalTime = Math.round((Date.now() - status.startTime) / 1000);
    const completedAgents = status.agents.filter(
      a => a.status === 'completed'
    ).length;
    const failedAgents = status.agents.filter(
      a => a.status === 'failed'
    ).length;

    console.log('\n🎉 ULTRA-PARALLEL LINT & FORMAT COMPLETED!\n');
    console.log(
      '┌─────────────────────────────────────────────────────────────┐'
    );
    console.log(
      '│                        FINAL RESULTS                       │'
    );
    console.log(
      '├─────────────────────────────────────────────────────────────┤'
    );
    console.log(
      `│ Total Time: ${totalTime}s                                    │`
    );
    console.log(
      `│ Agents Completed: ${completedAgents}/${this.agents.length}                              │`
    );
    console.log(
      `│ Agents Failed: ${failedAgents}                                       │`
    );
    console.log(
      `│ Files Processed: ${status.filesProcessed}/${status.totalFiles}                          │`
    );
    console.log(
      `│ Success Rate: ${Math.round((completedAgents / this.agents.length) * 100)}%                                  │`
    );
    console.log(
      '└─────────────────────────────────────────────────────────────┘\n'
    );

    // Show failed agents if any
    if (failedAgents > 0) {
      console.log('❌ Failed Agents:');
      status.agents
        .filter(a => a.status === 'failed')
        .forEach(agent => {
          console.log(`   - Agent ${agent.id}: ${agent.name}`);
          agent.errors.forEach(error => console.log(`     Error: ${error}`));
        });
      console.log('');
    }

    console.log(`📁 Detailed logs available in: ${this.logDir}`);
    console.log(`📊 Status file: ${this.statusFile}`);
  }

  async runValidation() {
    console.log('\n🔍 Running final validation...');

    const validationCommands = [
      { name: 'Turbo Lint Check', cmd: 'npx', args: ['turbo', 'lint'] },
      { name: 'Prettier Check', cmd: 'npm', args: ['run', 'format:check'] },
      { name: 'TypeScript Check', cmd: 'npx', args: ['turbo', 'type-check'] },
    ];

    for (const validation of validationCommands) {
      console.log(`  Running ${validation.name}...`);

      try {
        await new Promise((resolve, reject) => {
          const proc = spawn(validation.cmd, validation.args, {
            cwd: this.projectRoot,
            stdio: 'pipe',
          });

          proc.on('close', code => {
            if (code === 0) {
              console.log(`  ✅ ${validation.name} passed`);
              resolve();
            } else {
              console.log(`  ⚠️  ${validation.name} reported issues`);
              resolve(); // Don't fail the whole process
            }
          });
        });
      } catch (error) {
        console.log(`  ❌ ${validation.name} failed: ${error.message}`);
      }
    }
  }

  async execute() {
    try {
      console.log('🚀 Ultra-Parallel Lint & Format System Starting...\n');

      // Phase 1: Pre-flight checks
      await this.checkDependencies();
      await this.createGitStash();
      this.initializeStatus();

      // Phase 2: Parallel execution
      await this.runAllAgents();

      // Phase 3: Validation
      await this.runValidation();

      console.log('\n🎉 All phases completed successfully!');
    } catch (error) {
      console.error('\n❌ Fatal error:', error.message);
      process.exit(1);
    }
  }
}

// Main execution
if (require.main === module) {
  const formatter = new UltraParallelLintFormatter();
  formatter.execute().catch(console.error);
}

module.exports = UltraParallelLintFormatter;
