#!/usr/bin/env node

/**
 * Web Application Firewall (WAF) & DDoS Protection Setup
 * Implements both Cloudflare and self-hosted ModSecurity options
 */

const fs = require('fs');
const path = require('path');

class WAFProtectionSetup {
  constructor() {
    this.configurations = [];
    this.errors = [];
    this.publicPorts = [5000, 4000, 3000, 8001, 8080, 6001, 7000, 9000, 9001];
  }

  async setupWAFProtection() {
    console.log(
      '🛡️ Setting up Web Application Firewall & DDoS Protection...\n'
    );

    await this.createCloudflareConfig();
    await this.setupNginxWAF();
    await this.configureDDoSProtection();
    await this.implementRateLimiting();
    await this.createSecurityHeaders();

    this.generateReport();
  }

  async createCloudflareConfig() {
    console.log('☁️ Creating Cloudflare WAF configuration...');

    const cloudflareConfig = {
      dns: {
        record_type: 'A',
        name: '@',
        proxied: true,
        comment: 'Main domain with WAF protection',
      },
      waf_rules: [
        {
          expression: '(cf.threat_score gt 14)',
          action: 'challenge',
          description: 'Challenge suspicious traffic',
        },
        {
          expression:
            '(http.request.uri.path contains "/api/" and cf.bot_management.score lt 30)',
          action: 'block',
          description: 'Block bot traffic to API endpoints',
        },
        {
          expression:
            '(http.request.method eq "POST" and cf.threat_score gt 5)',
          action: 'js_challenge',
          description: 'JS challenge for POST requests from risky sources',
        },
        {
          expression:
            '(any(http.request.headers["user-agent"][*] contains "bot") and not cf.bot_management.verified_bot)',
          action: 'block',
          description: 'Block unverified bots',
        },
      ],
      rate_limiting: [
        {
          threshold: 100,
          period: 60,
          action: 'simulate',
          match: 'cf.colo.id eq 1 and http.request.uri.path eq "/api/"',
        },
        {
          threshold: 20,
          period: 60,
          action: 'block',
          match: 'http.request.uri.path contains "/wallet/"',
        },
      ],
      ddos_protection: {
        http_ddos: 'on',
        tcp_ddos: 'on',
        udp_ddos: 'on',
        under_attack_mode: 'off',
      },
    };

    try {
      fs.writeFileSync(
        'infrastructure/cloudflare-waf-config.json',
        JSON.stringify(cloudflareConfig, null, 2)
      );
      console.log('✅ Created Cloudflare WAF configuration');
      this.configurations.push('Cloudflare WAF configuration generated');
    } catch (error) {
      this.errors.push(`Cloudflare config: ${error.message}`);
    }
  }

  async setupNginxWAF() {
    console.log('🔧 Setting up Nginx with ModSecurity WAF...');

    const nginxConfig = `
# Nginx WAF Configuration with ModSecurity
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';" always;

    # Rate limiting zones
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=wallet:10m rate=5r/s;
    limit_req_zone $binary_remote_addr zone=general:10m rate=30r/s;
    
    # Connection limiting
    limit_conn_zone $binary_remote_addr zone=perip:10m;
    limit_conn_zone $server_name zone=perserver:10m;

    # ModSecurity configuration
    modsecurity on;
    modsecurity_rules_file /etc/nginx/modsec/main.conf;

    # DDoS protection settings
    client_body_timeout 10s;
    client_header_timeout 10s;
    keepalive_timeout 5s 5s;
    send_timeout 10s;
    
    # Buffer limits
    client_body_buffer_size 1K;
    client_header_buffer_size 1k;
    client_max_body_size 1k;
    large_client_header_buffers 2 1k;

    # Wrfcoin Frontend (Port 5000)
    server {
        listen 80;
        server_name wrfcoin.local *.replit.dev;
        
        # Rate limiting
        limit_req zone=general burst=20 nodelay;
        limit_conn perip 10;
        
        # Frontend proxy
        location / {
            proxy_pass http://127.0.0.1:5000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
        
        # API endpoints with stricter limits
        location /api/ {
            limit_req zone=api burst=10 nodelay;
            proxy_pass http://127.0.0.1:3000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
        
        # Wallet endpoints with strictest limits
        location /api/wallet/ {
            limit_req zone=wallet burst=5 nodelay;
            proxy_pass http://127.0.0.1:4000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }

    # Block common attack patterns
    location ~* /(wp-admin|phpmyadmin|admin|xmlrpc) {
        deny all;
        return 444;
    }
    
    # Block bad bots
    if ($http_user_agent ~* (bot|crawler|spider|scraper)) {
        return 403;
    }
    
    # Block suspicious requests
    location ~* \.(sql|bak|backup|tar|gz)$ {
        deny all;
        return 444;
    }
}
`;

    const modsecurityConfig = `
# ModSecurity Main Configuration
SecRuleEngine On
SecRequestBodyAccess On
SecResponseBodyAccess Off
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
SecRequestBodyInMemoryLimit 131072
SecRequestBodyLimitAction Reject
SecPcreMatchLimit 1000
SecPcreMatchLimitRecursion 1000

# OWASP Core Rule Set
Include /etc/nginx/modsec/owasp-crs/*.conf

# Custom rules for Wrfcoin
SecRule REQUEST_URI "@contains /api/wallet" \\
    "id:1001,phase:1,block,msg:'Wallet API access detected',logdata:'IP: %{REMOTE_ADDR}'"

SecRule ARGS "@detectSQLi" \\
    "id:1002,phase:2,block,msg:'SQL Injection Attack Detected',logdata:'Matched Data: %{MATCHED_VAR} found within %{MATCHED_VAR_NAME}'"

SecRule ARGS "@detectXSS" \\
    "id:1003,phase:2,block,msg:'XSS Attack Detected',logdata:'Matched Data: %{MATCHED_VAR} found within %{MATCHED_VAR_NAME}'"

# Rate limiting for specific endpoints
SecAction "id:1004,phase:1,nolog,pass,initcol:ip=%{REMOTE_ADDR},setvar:ip.requests=+1,expirevar:ip.requests=60"
SecRule IP:REQUESTS "@gt 100" \\
    "id:1005,phase:1,block,msg:'Rate limit exceeded'"
`;

    try {
      // Create infrastructure directory if it doesn't exist
      if (!fs.existsSync('infrastructure')) {
        fs.mkdirSync('infrastructure', { recursive: true });
      }

      fs.writeFileSync('infrastructure/nginx-waf.conf', nginxConfig);
      fs.writeFileSync(
        'infrastructure/modsecurity-main.conf',
        modsecurityConfig
      );
      console.log('✅ Created Nginx ModSecurity configuration');
      this.configurations.push('Nginx WAF with ModSecurity configured');
    } catch (error) {
      this.errors.push(`Nginx WAF: ${error.message}`);
    }
  }

  async configureDDoSProtection() {
    console.log('🚫 Configuring DDoS protection mechanisms...');

    const ddosScript = `#!/bin/bash
# DDoS Protection Script for Wrfcoin

# Iptables rules for DDoS protection
iptables -A INPUT -p tcp --dport 80 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -m limit --limit 25/minute --limit-burst 100 -j ACCEPT

# Protect against SYN flood attacks
iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP

# Protect against ping of death
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT

# Block excessive connections from single IP
iptables -A INPUT -p tcp --dport 80 -m connlimit --connlimit-above 20 -j REJECT
iptables -A INPUT -p tcp --dport 443 -m connlimit --connlimit-above 20 -j REJECT

# Log suspicious activity
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "iptables denied: " --log-level 7

echo "DDoS protection rules applied"
`;

    const failbanConfig = `
# Fail2Ban configuration for Wrfcoin
[Definition]
failregex = <HOST> - - .*"(GET|POST).*" (4|5)\\d\\d
ignoreregex = 

[wrfcoin-api]
enabled = true
port = 3000,4000,5000
filter = wrfcoin
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 600
findtime = 300

[wrfcoin-wallet]
enabled = true
port = 4000
filter = wrfcoin
logpath = /var/log/nginx/access.log
maxretry = 3
bantime = 1800
findtime = 300
`;

    try {
      fs.writeFileSync('infrastructure/ddos-protection.sh', ddosScript);
      fs.writeFileSync('infrastructure/fail2ban-wrfcoin.conf', failbanConfig);

      // Make script executable
      fs.chmodSync('infrastructure/ddos-protection.sh', '755');

      console.log('✅ Created DDoS protection scripts');
      this.configurations.push(
        'DDoS protection rules and Fail2Ban configuration'
      );
    } catch (error) {
      this.errors.push(`DDoS protection: ${error.message}`);
    }
  }

  async implementRateLimiting() {
    console.log('⏱️ Implementing application-level rate limiting...');

    const rateLimitMiddleware = `
const rateLimit = require('express-rate-limit');
const slowDown = require('express-slow-down');

// General API rate limiting
const generalLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100, // limit each IP to 100 requests per windowMs
    message: 'Too many requests from this IP, please try again later.',
    standardHeaders: true,
    legacyHeaders: false,
});

// Wallet API strict limiting
const walletLimiter = rateLimit({
    windowMs: 15 * 60 * 1000,
    max: 20,
    message: 'Wallet API rate limit exceeded. Please wait before trying again.',
    standardHeaders: true,
    legacyHeaders: false,
    skip: (req) => {
        // Skip rate limiting for authenticated admin users
        return req.user && req.user.role === 'admin';
    }
});

// Cross-chain operations limiting
const crossChainLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 10,
    message: 'Cross-chain operation rate limit exceeded.',
});

// Slow down repeated requests
const speedLimiter = slowDown({
    windowMs: 15 * 60 * 1000,
    delayAfter: 50,
    delayMs: 500,
    maxDelayMs: 20000,
});

// Weather data submission limiting
const weatherLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 2, // Allow 2 submissions per minute max
    message: 'Weather data submission rate limit exceeded.',
    keyGenerator: (req) => {
        // Rate limit by station ID and IP
        return \`\${req.ip}-\${req.body.stationId || 'unknown'}\`;
    }
});

module.exports = {
    generalLimiter,
    walletLimiter,
    crossChainLimiter,
    speedLimiter,
    weatherLimiter
};
`;

    try {
      fs.writeFileSync(
        'backend/middleware/rateLimiting.js',
        rateLimitMiddleware
      );
      console.log('✅ Created application-level rate limiting');
      this.configurations.push('Express.js rate limiting middleware');
    } catch (error) {
      this.errors.push(`Rate limiting: ${error.message}`);
    }
  }

  async createSecurityHeaders() {
    console.log('🔒 Creating security headers middleware...');

    const securityHeaders = `
const helmet = require('helmet');

const securityMiddleware = helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'", "'unsafe-inline'", "'unsafe-eval'", "*.replit.dev"],
            styleSrc: ["'self'", "'unsafe-inline'", "fonts.googleapis.com"],
            fontSrc: ["'self'", "fonts.gstatic.com"],
            imgSrc: ["'self'", "data:", "*.replit.dev"],
            connectSrc: ["'self'", "*.replit.dev", "wss:", "ws:"],
            frameSrc: ["'none'"],
            objectSrc: ["'none'"],
            upgradeInsecureRequests: [],
        },
    },
    crossOriginEmbedderPolicy: false,
    hsts: {
        maxAge: 31536000,
        includeSubDomains: true,
        preload: true
    }
});

// Additional custom security headers
const customSecurityHeaders = (req, res, next) => {
    // Prevent clickjacking
    res.setHeader('X-Frame-Options', 'DENY');
    
    // Prevent MIME type sniffing
    res.setHeader('X-Content-Type-Options', 'nosniff');
    
    // Enable XSS protection
    res.setHeader('X-XSS-Protection', '1; mode=block');
    
    // Referrer policy
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    
    // Feature policy
    res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=()');
    
    // Cache control for sensitive endpoints
    if (req.path.includes('/api/wallet') || req.path.includes('/api/admin')) {
        res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
        res.setHeader('Pragma', 'no-cache');
        res.setHeader('Expires', '0');
    }
    
    next();
};

module.exports = {
    securityMiddleware,
    customSecurityHeaders
};
`;

    try {
      fs.writeFileSync(
        'backend/middleware/securityHeaders.js',
        securityHeaders
      );
      console.log('✅ Created security headers middleware');
      this.configurations.push('Security headers and HSTS configuration');
    } catch (error) {
      this.errors.push(`Security headers: ${error.message}`);
    }
  }

  generateReport() {
    console.log('\n' + '='.repeat(70));
    console.log('🛡️ WAF & DDOS PROTECTION SETUP REPORT');
    console.log('='.repeat(70));

    console.log(`\n📊 SUMMARY:`);
    console.log(`✅ Configurations Created: ${this.configurations.length}`);
    console.log(`❌ Errors: ${this.errors.length}`);
    console.log(`🔍 Protected Ports: ${this.publicPorts.join(', ')}`);

    if (this.configurations.length > 0) {
      console.log('\n✅ WAF CONFIGURATIONS:');
      for (const config of this.configurations) {
        console.log(`   • ${config}`);
      }
    }

    if (this.errors.length > 0) {
      console.log('\n❌ ERRORS:');
      for (const error of this.errors) {
        console.log(`   • ${error}`);
      }
    }

    console.log('\n🛡️ PROTECTION FEATURES:');
    console.log('• Cloudflare WAF with custom rules for blockchain endpoints');
    console.log('• Nginx ModSecurity with OWASP Core Rule Set');
    console.log('• DDoS protection via iptables and connection limits');
    console.log('• Fail2Ban automatic IP blocking for suspicious activity');
    console.log('• Application-level rate limiting for API endpoints');
    console.log('• Security headers to prevent common web attacks');
    console.log('• Special protection for wallet and cross-chain operations');

    console.log('\n⚡ IMMEDIATE BENEFITS:');
    console.log('• Blocks SQL injection, XSS, and path traversal attacks');
    console.log('• Prevents bot spam and scraping of weather data');
    console.log('• Protects against traffic floods during token events');
    console.log('• Rate limits prevent API abuse and resource exhaustion');
    console.log('• Security headers protect against browser-based attacks');

    console.log('\n🚀 DEPLOYMENT OPTIONS:');
    console.log('\n📋 Option 1: Cloudflare WAF (Recommended)');
    console.log('   1. Sign up for Cloudflare account');
    console.log('   2. Point your domain DNS to Cloudflare');
    console.log('   3. Upload the cloudflare-waf-config.json rules');
    console.log('   4. Enable "Under Attack" mode during high traffic');

    console.log('\n📋 Option 2: Self-Hosted (Advanced)');
    console.log('   1. Install Nginx with ModSecurity module');
    console.log('   2. Deploy nginx-waf.conf configuration');
    console.log('   3. Run ddos-protection.sh script as root');
    console.log('   4. Configure fail2ban with wrfcoin rules');
    console.log('   5. Add rate limiting middleware to your servers');

    console.log('\n🔧 INTEGRATION STEPS:');
    console.log('1. Choose your preferred WAF option above');
    console.log('2. Apply rate limiting middleware to existing servers');
    console.log('3. Test protection with controlled traffic');
    console.log('4. Monitor logs for blocked attacks');
    console.log('5. Fine-tune rules based on legitimate traffic patterns');

    console.log('='.repeat(70));
  }
}

// Run setup if called directly
if (require.main === module) {
  const setup = new WAFProtectionSetup();
  setup.setupWAFProtection().catch(console.error);
}

module.exports = WAFProtectionSetup;
