/**
 * WebSocket Connection Repair Script
 * Fixes persistent connection error 1006 issues
 */

const fs = require('fs');
const path = require('path');

class WebSocketConnectionRepair {
  constructor() {
    this.fixesApplied = [];
  }

  async repairConnections() {
    console.log('🔧 Repairing WebSocket connections...');

    await this.fixWebSocketServerConfiguration();
    await this.removeConflictingRateLimit();
    await this.simplifyWebSocketUpgrade();
    await this.fixFrontendConnectionLogic();

    console.log('✅ WebSocket connection repair completed');
    this.generateReport();
  }

  async fixWebSocketServerConfiguration() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Remove rate limiting that's blocking connections
      const rateLimitRegex =
        /\/\/ WebSocket Connection Rate Limiting[\s\S]*?handler: \(req, res\) => \{[\s\S]*?\}\s*\}\);/g;
      if (content.match(rateLimitRegex)) {
        content = content.replace(
          rateLimitRegex,
          '// Rate limiting removed for development'
        );
        this.fixesApplied.push('Removed blocking rate limit configuration');
      }

      // Simplify WebSocket server creation
      const wsServerRegex =
        /const wss = new WebSocket\.Server\(\{ server, path: '\/ws' \}\);/;
      const newWsServer = `const wss = new WebSocket.Server({ 
  server,
  path: '/ws',
  perMessageDeflate: false,
  maxPayload: 1024 * 1024
});`;

      if (content.match(wsServerRegex)) {
        content = content.replace(wsServerRegex, newWsServer);
        this.fixesApplied.push('Simplified WebSocket server configuration');
      }

      fs.writeFileSync(serverPath, content);
    }
  }

  async removeConflictingRateLimit() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Remove any middleware that might interfere with WebSocket upgrade
      const middlewareRegex = /app\.use\(wsConnectionLimiter\);/g;
      if (content.match(middlewareRegex)) {
        content = content.replace(
          middlewareRegex,
          '// Rate limiter removed for WebSocket compatibility'
        );
        this.fixesApplied.push(
          'Removed WebSocket connection limiter middleware'
        );
      }

      fs.writeFileSync(serverPath, content);
    }
  }

  async simplifyWebSocketUpgrade() {
    const serverPath = 'backend/server/cross_chain_websocket_server.js';
    if (fs.existsSync(serverPath)) {
      let content = fs.readFileSync(serverPath, 'utf8');

      // Add proper upgrade handling before server.listen
      const upgradeHandler = `
// Simplified WebSocket upgrade handling
server.on('upgrade', (request, socket, head) => {
  console.log('WebSocket upgrade request received');
  
  // Handle the upgrade directly
  wss.handleUpgrade(request, socket, head, (ws) => {
    console.log('WebSocket upgrade successful');
    wss.emit('connection', ws, request);
  });
});
`;

      // Insert before server.listen if not already present
      const serverStartRegex = /(server\.listen\(PORT)/;
      if (
        content.match(serverStartRegex) &&
        !content.includes("server.on('upgrade'")
      ) {
        content = content.replace(serverStartRegex, upgradeHandler + '\n$1');
        this.fixesApplied.push('Added proper WebSocket upgrade handling');
        fs.writeFileSync(serverPath, content);
      }
    }
  }

  async fixFrontendConnectionLogic() {
    const frontendPath = 'frontend/src/services/websocketService.js';
    if (fs.existsSync(frontendPath)) {
      let content = fs.readFileSync(frontendPath, 'utf8');

      // Fix connection retry logic
      const connectFuncRegex =
        /const connect = \(\) => \{[\s\S]*?(?=\n  const)/;
      const newConnectFunc = `const connect = () => {
    if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) {
      return;
    }

    try {
      ws = new WebSocket(getWsUrl());
      
      ws.onopen = () => {
        console.log('WebSocket connected successfully');
        status = 'connected';
        reconnectAttempts = 0;
        clearTimeout(reconnectTimer);
        
        // Subscribe to channels
        subscriptions.forEach(channel => {
          ws.send(JSON.stringify({ type: 'subscribe', channel }));
        });
        
        eventEmitter.emit('connected');
      };

      ws.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);
          eventEmitter.emit('message', data);
          
          if (data.channel) {
            eventEmitter.emit(\`channel:\${data.channel}\`, data);
          }
        } catch (error) {
          console.error('WebSocket message parse error:', error);
        }
      };

      ws.onclose = (event) => {
        console.log('WebSocket closed:', event.code, event.reason);
        status = 'disconnected';
        ws = null;
        
        if (reconnectAttempts < maxReconnectAttempts) {
          reconnectAttempts++;
          console.log(\`Reconnecting (\${reconnectAttempts}/\${maxReconnectAttempts}) in \${reconnectInterval}ms...\`);
          reconnectTimer = setTimeout(connect, reconnectInterval);
        } else {
          console.log(\`Maximum reconnect attempts reached (\${maxReconnectAttempts})\`);
          eventEmitter.emit('maxReconnectsReached');
        }
      };

      ws.onerror = (error) => {
        console.error('WebSocket error:', error);
        eventEmitter.emit('error', error);
      };
      
    } catch (error) {
      console.error('WebSocket connection failed:', error);
      status = 'error';
    }
  };`;

      if (content.match(connectFuncRegex)) {
        content = content.replace(connectFuncRegex, newConnectFunc);
        this.fixesApplied.push('Fixed frontend WebSocket connection logic');
        fs.writeFileSync(frontendPath, content);
      }
    }
  }

  generateReport() {
    console.log('\n📊 WebSocket Connection Repair Report:');
    console.log(`✅ Fixes Applied: ${this.fixesApplied.length}`);
    this.fixesApplied.forEach((fix, index) => {
      console.log(`  ${index + 1}. ${fix}`);
    });
  }
}

async function main() {
  const repair = new WebSocketConnectionRepair();
  await repair.repairConnections();
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { WebSocketConnectionRepair };
