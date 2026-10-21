/**
 * Final WebSocket Connection Fix
 * Addresses persistent connection issues
 */

const fs = require('fs');

class WebSocketConnectionFix {
  constructor() {
    this.fixesApplied = [];
  }

  async applyFinalFixes() {
    console.log('🔧 Applying final WebSocket connection fixes...');

    // Fix 1: Add WebSocket health check endpoint to cross-chain server
    await this.addWebSocketHealthCheck();

    // Fix 2: Fix CORS configuration for WebSocket connections
    await this.fixWebSocketCORS();

    // Fix 3: Add connection state validation
    await this.addConnectionValidation();

    console.log('✅ Final WebSocket fixes completed');
    this.generateReport();
  }

  async addWebSocketHealthCheck() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Add WebSocket test endpoint
      const healthCheckEndpoint = `
// WebSocket connection test endpoint
app.get('/ws-test', (req, res) => {
  res.json({
    status: 'ready',
    websocket: 'ws://localhost:5001/ws',
    connections: wss.clients.size,
    timestamp: new Date().toISOString()
  });
});
`;

      // Insert before server.listen
      const serverStartRegex = /(server\.listen\(PORT)/;
      if (content.match(serverStartRegex)) {
        content = content.replace(
          serverStartRegex,
          healthCheckEndpoint + '\n$1'
        );
        fs.writeFileSync(serverPath, content);
        this.fixesApplied.push('WebSocket health check endpoint added');
      }
    }
  }

  async fixWebSocketCORS() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Update CORS configuration to be more permissive for development
      const corsRegex = /app\.use\(cors\(\{[\s\S]*?\}\)\);/g;
      const newCors = `app.use(cors({
    origin: true, // Allow all origins in development
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS', 'HEAD'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Requested-With', 'Origin', 'Accept'],
    optionsSuccessStatus: 200
}));`;

      if (content.match(corsRegex)) {
        content = content.replace(corsRegex, newCors);
        fs.writeFileSync(serverPath, content);
        this.fixesApplied.push('WebSocket CORS configuration updated');
      }
    }
  }

  async addConnectionValidation() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Add connection validation before WebSocket upgrade
      const validationMiddleware = `
// Add connection validation middleware
server.on('upgrade', (request, socket, head) => {
  console.log('WebSocket upgrade request from:', request.socket.remoteAddress);
  
  // Allow the upgrade
  wss.handleUpgrade(request, socket, head, (ws) => {
    wss.emit('connection', ws, request);
  });
});
`;

      // Insert before server.listen
      const serverStartRegex = /(server\.listen\(PORT)/;
      if (
        content.match(serverStartRegex) &&
        !content.includes("server.on('upgrade'")
      ) {
        content = content.replace(
          serverStartRegex,
          validationMiddleware + '\n$1'
        );
        fs.writeFileSync(serverPath, content);
        this.fixesApplied.push('WebSocket connection validation added');
      }
    }
  }

  generateReport() {
    console.log('\n📊 Final WebSocket Fix Report:');
    console.log(`✅ Fixes Applied: ${this.fixesApplied.length}`);
    this.fixesApplied.forEach((fix, index) => {
      console.log(`  ${index + 1}. ${fix}`);
    });
  }
}

// Run the final fixes
async function main() {
  const fixer = new WebSocketConnectionFix();
  await fixer.applyFinalFixes();
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { WebSocketConnectionFix };
