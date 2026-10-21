/**
 * Advanced DDoS Protection System
 * Multi-layer protection against distributed attacks
 */
const rateLimit = require('express-rate-limit');
const slowDown = require('express-slow-down');

class DDoSProtectionSystem {
  constructor() {
    this.attackPatterns = new Map();
    this.blockedIPs = new Set();
    this.suspiciousActivities = [];
    this.geofenceEnabled = true;
  }

  /**
   * Create adaptive rate limiting middleware
   */
  createAdaptiveRateLimit() {
    return rateLimit({
      windowMs: 15 * 60 * 1000, // 15 minutes
      max: req => {
        // Adaptive limits based on endpoint sensitivity
        const criticalEndpoints = [
          '/api/governance',
          '/api/admin',
          '/api/wallet',
        ];
        const isCritical = criticalEndpoints.some(endpoint =>
          req.path.startsWith(endpoint)
        );

        if (this.blockedIPs.has(req.ip)) return 0;
        if (isCritical) return 5; // Very restrictive for critical endpoints
        if (req.path.startsWith('/api/')) return 100;
        return 1000; // Higher limit for static content
      },
      message: 'Too many requests, please try again later',
      standardHeaders: true,
      legacyHeaders: false,
      skip: req => {
        // Whitelist trusted IPs (node operators, etc.)
        const trustedIPs = ['127.0.0.1', '::1'];
        return trustedIPs.includes(req.ip);
      },
    });
  }

  /**
   * Progressive response slowdown for suspicious activity
   */
  createProgressiveSlowdown() {
    return slowDown({
      windowMs: 15 * 60 * 1000,
      delayAfter: 50,
      delayMs: 500,
      maxDelayMs: 20000,
    });
  }

  /**
   * Real-time attack pattern detection
   */
  detectAttackPatterns(req, res, next) {
    const clientIP = req.ip;
    const timestamp = Date.now();

    // Track request patterns
    if (!this.attackPatterns.has(clientIP)) {
      this.attackPatterns.set(clientIP, []);
    }

    const requests = this.attackPatterns.get(clientIP);
    requests.push({
      path: req.path,
      method: req.method,
      timestamp,
      userAgent: req.get('User-Agent'),
    });

    // Keep only recent requests (last 5 minutes)
    const fiveMinutesAgo = timestamp - 5 * 60 * 1000;
    const recentRequests = requests.filter(r => r.timestamp > fiveMinutesAgo);
    this.attackPatterns.set(clientIP, recentRequests);

    // Analyze patterns
    if (this.isAttackPattern(recentRequests, clientIP)) {
      this.handleSuspiciousActivity(clientIP, req);
      return res.status(429).json({ error: 'Suspicious activity detected' });
    }

    next();
  }

  /**
   * Identify attack patterns
   */
  isAttackPattern(requests, clientIP) {
    if (requests.length < 10) return false;

    // Pattern 1: Too many requests to same endpoint
    const pathCounts = {};
    requests.forEach(req => {
      pathCounts[req.path] = (pathCounts[req.path] || 0) + 1;
    });

    if (Object.values(pathCounts).some(count => count > 20)) {
      console.log(`🚨 Rapid-fire attack detected from ${clientIP}`);
      return true;
    }

    // Pattern 2: Scanning behavior (many different endpoints)
    const uniquePaths = new Set(requests.map(r => r.path));
    if (uniquePaths.size > 50) {
      console.log(`🚨 Scanning behavior detected from ${clientIP}`);
      return true;
    }

    // Pattern 3: Bot-like user agents
    const userAgents = requests.map(r => r.userAgent);
    const botPatterns = ['bot', 'crawler', 'spider', 'scraper'];
    if (
      userAgents.some(ua =>
        botPatterns.some(pattern => ua?.toLowerCase().includes(pattern))
      )
    ) {
      console.log(`🚨 Bot activity detected from ${clientIP}`);
      return true;
    }

    return false;
  }

  /**
   * Handle suspicious activity
   */
  handleSuspiciousActivity(clientIP, req) {
    console.log(`🚨 Blocking suspicious IP: ${clientIP}`);

    this.blockedIPs.add(clientIP);
    this.suspiciousActivities.push({
      ip: clientIP,
      timestamp: Date.now(),
      reason: 'Attack pattern detected',
      lastPath: req.path,
      userAgent: req.get('User-Agent'),
    });

    // Auto-unblock after 1 hour
    setTimeout(
      () => {
        this.blockedIPs.delete(clientIP);
        console.log(`🔓 Auto-unblocked IP: ${clientIP}`);
      },
      60 * 60 * 1000
    );

    // Alert monitoring system
    this.alertMonitoringSystem(clientIP, req);
  }

  /**
   * Geographic access control
   */
  createGeofenceMiddleware() {
    return (req, res, next) => {
      if (!this.geofenceEnabled) return next();

      // Simulate IP geolocation check
      const suspiciousRegions = ['TOR_EXIT_NODE', 'KNOWN_BOTNET'];
      const clientRegion = this.getIPRegion(req.ip);

      if (suspiciousRegions.includes(clientRegion)) {
        console.log(`🚨 Request from suspicious region: ${clientRegion}`);
        return res
          .status(403)
          .json({ error: 'Access denied from this region' });
      }

      next();
    };
  }

  /**
   * Get IP region (simplified)
   */
  getIPRegion(ip) {
    // In real implementation, use MaxMind GeoIP or similar
    if (ip.startsWith('127.') || ip === '::1') return 'LOCAL';
    if (ip.startsWith('10.') || ip.startsWith('192.168.')) return 'PRIVATE';
    return 'UNKNOWN';
  }

  /**
   * Alert monitoring system
   */
  alertMonitoringSystem(clientIP, req) {
    const alert = {
      type: 'DDOS_ATTEMPT',
      severity: 'HIGH',
      timestamp: new Date().toISOString(),
      source: clientIP,
      details: {
        path: req.path,
        userAgent: req.get('User-Agent'),
        method: req.method,
      },
    };

    console.log('🚨 DDoS Alert:', JSON.stringify(alert, null, 2));

    // In real implementation, send to monitoring service
    // this.sendToMonitoring(alert);
  }

  /**
   * Get protection status
   */
  getProtectionStatus() {
    return {
      blockedIPs: this.blockedIPs.size,
      suspiciousActivities: this.suspiciousActivities.length,
      activePatterns: this.attackPatterns.size,
      geofenceEnabled: this.geofenceEnabled,
      lastAlert:
        this.suspiciousActivities[this.suspiciousActivities.length - 1],
    };
  }
}

module.exports = DDoSProtectionSystem;
