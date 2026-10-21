/**
 * Security Hardening Implementation
 * Applies practical security measures to improve system hardening
 */

const fs = require('fs');
const path = require('path');

class SecurityHardening {
  constructor() {
    this.appliedMeasures = [];
  }

  async implementHardening() {
    console.log('🔧 Implementing Security Hardening Measures');
    console.log('=============================================');

    await this.addSecurityHeaders();
    await this.implementRateLimiting();
    await this.addInputValidation();
    await this.enhanceLogging();
    await this.addTransferLimits();

    this.generateImplementationReport();
  }

  async addSecurityHeaders() {
    console.log('\n🛡️ Adding Security Headers...');

    const securityMiddleware = `
/**
 * Enhanced Security Middleware
 * Implements comprehensive security headers and protection
 */

const helmet = require('helmet');
const rateLimit = require('express-rate-limit');

// Security headers configuration
const securityHeaders = helmet({
    contentSecurityPolicy: {
        directives: {
            defaultSrc: ["'self'"],
            scriptSrc: ["'self'", "'unsafe-inline'", "https://cdn.jsdelivr.net"],
            styleSrc: ["'self'", "'unsafe-inline'", "https://fonts.googleapis.com"],
            fontSrc: ["'self'", "https://fonts.gstatic.com"],
            imgSrc: ["'self'", "data:", "https:"],
            connectSrc: ["'self'", "wss:", "ws:"],
            objectSrc: ["'none'"],
            mediaSrc: ["'self'"],
            frameSrc: ["'none'"]
        }
    },
    hsts: {
        maxAge: 31536000,
        includeSubDomains: true,
        preload: true
    },
    noSniff: true,
    xssFilter: true,
    referrerPolicy: { policy: "strict-origin-when-cross-origin" }
});

// Rate limiting configuration
const apiLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100, // limit each IP to 100 requests per windowMs
    message: {
        error: 'Too many requests from this IP, please try again later',
        retryAfter: '15 minutes'
    },
    standardHeaders: true,
    legacyHeaders: false
});

const strictApiLimiter = rateLimit({
    windowMs: 5 * 60 * 1000, // 5 minutes
    max: 20, // limit sensitive endpoints
    message: {
        error: 'Rate limit exceeded for sensitive operations',
        retryAfter: '5 minutes'
    }
});

module.exports = {
    securityHeaders,
    apiLimiter,
    strictApiLimiter
};`;

    try {
      fs.writeFileSync('backend/middleware/security.js', securityMiddleware);
      this.appliedMeasures.push('✅ Security headers middleware created');
    } catch (error) {
      this.appliedMeasures.push(
        '❌ Failed to create security middleware: ' + error.message
      );
    }
  }

  async implementRateLimiting() {
    console.log('\n🚦 Implementing Rate Limiting...');

    const rateLimitConfig = `
/**
 * Rate Limiting Configuration
 * Protects against abuse and DoS attacks
 */

const rateLimit = require('express-rate-limit');

// General API rate limiting
const generalLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 100,
    message: 'Rate limit exceeded'
});

// WebSocket connection limiting
const wsConnectionLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 10, // 10 connections per minute per IP
    message: 'WebSocket connection limit exceeded'
});

// Cross-chain transfer limiting
const transferLimiter = rateLimit({
    windowMs: 60 * 60 * 1000, // 1 hour
    max: 50, // 50 transfers per hour
    message: 'Transfer rate limit exceeded'
});

// Weather data submission limiting
const weatherLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 2, // 2 submissions per minute (one every 30 seconds)
    message: 'Weather submission rate limit exceeded'
});

module.exports = {
    generalLimiter,
    wsConnectionLimiter,
    transferLimiter,
    weatherLimiter
};`;

    try {
      fs.writeFileSync('backend/middleware/rateLimiting.js', rateLimitConfig);
      this.appliedMeasures.push('✅ Rate limiting configuration created');
    } catch (error) {
      this.appliedMeasures.push(
        '❌ Failed to create rate limiting: ' + error.message
      );
    }
  }

  async addInputValidation() {
    console.log('\n🔍 Adding Input Validation...');

    const validationMiddleware = `
/**
 * Input Validation Middleware
 * Validates and sanitizes user inputs
 */

const { body, param, query, validationResult } = require('express-validator');
const DOMPurify = require('dompurify');
const { JSDOM } = require('jsdom');

const window = new JSDOM('').window;
const purify = DOMPurify(window);

// Common validation rules
const validateAddress = body('address')
    .isLength({ min: 42, max: 42 })
    .matches(/^0x[a-fA-F0-9]{40}$/)
    .withMessage('Invalid Ethereum address format');

const validateAmount = body('amount')
    .isFloat({ min: 0.0001, max: 1000000 })
    .withMessage('Amount must be between 0.0001 and 1,000,000');

const validateChain = body('chain')
    .isIn(['ethereum', 'polygon', 'bsc', 'avalanche', 'arbitrum', 'optimism'])
    .withMessage('Unsupported blockchain network');

// Sanitization middleware
const sanitizeInput = (req, res, next) => {
    // Sanitize string inputs
    for (const key in req.body) {
        if (typeof req.body[key] === 'string') {
            req.body[key] = purify.sanitize(req.body[key]);
        }
    }
    next();
};

// Error handling for validation
const handleValidationErrors = (req, res, next) => {
    const errors = validationResult(req);
    if (!errors.isEmpty()) {
        return res.status(400).json({
            success: false,
            message: 'Validation failed',
            errors: errors.array()
        });
    }
    next();
};

module.exports = {
    validateAddress,
    validateAmount,
    validateChain,
    sanitizeInput,
    handleValidationErrors
};`;

    try {
      fs.writeFileSync(
        'backend/middleware/validation.js',
        validationMiddleware
      );
      this.appliedMeasures.push('✅ Input validation middleware created');
    } catch (error) {
      this.appliedMeasures.push(
        '❌ Failed to create validation middleware: ' + error.message
      );
    }
  }

  async enhanceLogging() {
    console.log('\n📝 Enhancing Security Logging...');

    const securityLogger = `
/**
 * Security Logging Configuration
 * Comprehensive logging for security events
 */

const winston = require('winston');
const DailyRotateFile = require('winston-daily-rotate-file');

// Security event logger
const securityLogger = winston.createLogger({
    level: 'info',
    format: winston.format.combine(
        winston.format.timestamp(),
        winston.format.errors({ stack: true }),
        winston.format.json()
    ),
    defaultMeta: { service: 'wrfcoin-security' },
    transports: [
        new DailyRotateFile({
            filename: 'logs/security-%DATE%.log',
            datePattern: 'YYYY-MM-DD',
            maxSize: '20m',
            maxFiles: '14d'
        }),
        new winston.transports.Console({
            format: winston.format.simple()
        })
    ]
});

// Security event types
const logSecurityEvent = (eventType, details, req = null) => {
    const logData = {
        eventType,
        timestamp: new Date().toISOString(),
        details,
        ip: req ? req.ip : null,
        userAgent: req ? req.get('User-Agent') : null
    };

    securityLogger.info('Security Event', logData);
};

// Specific logging functions
const logFailedAuth = (ip, reason) => {
    logSecurityEvent('FAILED_AUTH', { ip, reason });
};

const logSuspiciousActivity = (activity, details) => {
    logSecurityEvent('SUSPICIOUS_ACTIVITY', { activity, details });
};

const logRateLimitExceeded = (ip, endpoint) => {
    logSecurityEvent('RATE_LIMIT_EXCEEDED', { ip, endpoint });
};

const logCrossChainTransfer = (fromChain, toChain, amount, transferId) => {
    logSecurityEvent('CROSS_CHAIN_TRANSFER', { fromChain, toChain, amount, transferId });
};

module.exports = {
    securityLogger,
    logSecurityEvent,
    logFailedAuth,
    logSuspiciousActivity,
    logRateLimitExceeded,
    logCrossChainTransfer
};`;

    try {
      if (!fs.existsSync('logs')) {
        fs.mkdirSync('logs');
      }
      fs.writeFileSync('backend/middleware/securityLogger.js', securityLogger);
      this.appliedMeasures.push('✅ Security logging system created');
    } catch (error) {
      this.appliedMeasures.push(
        '❌ Failed to create security logging: ' + error.message
      );
    }
  }

  async addTransferLimits() {
    console.log('\n💰 Adding Transfer Amount Limits...');

    const transferSecurity = `
/**
 * Transfer Security Limits
 * Implements daily and per-transaction limits for cross-chain transfers
 */

class TransferLimitManager {
    constructor() {
        this.dailyLimits = new Map(); // IP -> daily transfer amount
        this.transferLimits = {
            maxPerTransaction: 10000, // 10,000 WRF per transaction
            maxDailyPerIP: 50000, // 50,000 WRF per day per IP
            maxHourlyPerIP: 10000, // 10,000 WRF per hour per IP
        };
    }

    checkTransferLimit(ip, amount) {
        const today = new Date().toDateString();
        const hour = new Date().getHours();
        const key = \`\${ip}-\${today}\`;
        const hourKey = \`\${ip}-\${today}-\${hour}\`;

        // Check per-transaction limit
        if (amount > this.transferLimits.maxPerTransaction) {
            return {
                allowed: false,
                reason: \`Transaction amount \${amount} exceeds maximum \${this.transferLimits.maxPerTransaction}\`
            };
        }

        // Check daily limit
        const dailyTotal = this.dailyLimits.get(key) || 0;
        if (dailyTotal + amount > this.transferLimits.maxDailyPerIP) {
            return {
                allowed: false,
                reason: \`Daily limit exceeded. Current: \${dailyTotal}, Requested: \${amount}, Limit: \${this.transferLimits.maxDailyPerIP}\`
            };
        }

        // Check hourly limit
        const hourlyTotal = this.dailyLimits.get(hourKey) || 0;
        if (hourlyTotal + amount > this.transferLimits.maxHourlyPerIP) {
            return {
                allowed: false,
                reason: \`Hourly limit exceeded. Current: \${hourlyTotal}, Requested: \${amount}, Limit: \${this.transferLimits.maxHourlyPerIP}\`
            };
        }

        return { allowed: true };
    }

    recordTransfer(ip, amount) {
        const today = new Date().toDateString();
        const hour = new Date().getHours();
        const key = \`\${ip}-\${today}\`;
        const hourKey = \`\${ip}-\${today}-\${hour}\`;

        this.dailyLimits.set(key, (this.dailyLimits.get(key) || 0) + amount);
        this.dailyLimits.set(hourKey, (this.dailyLimits.get(hourKey) || 0) + amount);
    }

    getDailyUsage(ip) {
        const today = new Date().toDateString();
        const key = \`\${ip}-\${today}\`;
        return this.dailyLimits.get(key) || 0;
    }

    getHourlyUsage(ip) {
        const today = new Date().toDateString();
        const hour = new Date().getHours();
        const hourKey = \`\${ip}-\${today}-\${hour}\`;
        return this.dailyLimits.get(hourKey) || 0;
    }
}

module.exports = TransferLimitManager;`;

    try {
      fs.writeFileSync(
        'backend/middleware/transferLimits.js',
        transferSecurity
      );
      this.appliedMeasures.push('✅ Transfer security limits implemented');
    } catch (error) {
      this.appliedMeasures.push(
        '❌ Failed to create transfer limits: ' + error.message
      );
    }
  }

  generateImplementationReport() {
    console.log('\n📋 Security Hardening Implementation Report');
    console.log('=============================================');

    console.log('\n🔧 Applied Security Measures:');
    this.appliedMeasures.forEach(measure => {
      console.log(`  ${measure}`);
    });

    console.log('\n🎯 Next Steps for Full Implementation:');
    console.log('1. Install required dependencies:');
    console.log(
      '   npm install helmet express-rate-limit express-validator dompurify jsdom winston winston-daily-rotate-file'
    );
    console.log('');
    console.log('2. Update server files to use new middleware');
    console.log('3. Configure environment variables for security settings');
    console.log('4. Test rate limiting and validation');
    console.log('5. Monitor security logs for effectiveness');

    console.log('\n🛡️ Security Improvements:');
    console.log('• Comprehensive security headers (CSP, HSTS, XSS protection)');
    console.log(
      '• Multi-tier rate limiting (API, WebSocket, transfers, weather)'
    );
    console.log('• Input validation and sanitization');
    console.log('• Security event logging with rotation');
    console.log('• Cross-chain transfer amount limits');
    console.log('• Daily and hourly transfer caps');

    console.log('\n✅ Security hardening framework created successfully!');
  }
}

// Execute security hardening
const hardening = new SecurityHardening();
hardening.implementHardening().catch(console.error);
