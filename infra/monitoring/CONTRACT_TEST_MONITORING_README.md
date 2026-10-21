# WRFCoin Contract Test Monitoring & Reporting System

## Overview

This comprehensive contract test monitoring system provides real-time visibility into API contract
testing health across the WRFCoin platform. It integrates Pact contract testing with Prometheus
metrics, Grafana dashboards, and automated reporting to ensure API compatibility and catch
integration issues early.

## Architecture

### Components

1. **Contract Test Metrics Collector** (`contract-test-metrics-collector.js`)

   - Collects metrics from Pact contract tests
   - Exposes Prometheus metrics on port 9095
   - Provides REST API for webhook integration
   - Processes test results and generates reports

2. **Enhanced Pact Integration** (`enhanced-pact-integration.js`)

   - Extends existing Pact setup with monitoring
   - Automatic metrics reporting for all contract tests
   - Integration with Jest and other test frameworks

3. **Contract Test Reporter** (`contract-test-reporter.js`)

   - Generates comprehensive test reports (JSON and HTML)
   - Historical trend analysis
   - Coverage analysis and performance metrics

4. **Grafana Dashboard** (`wrfcoin-contract-testing.json`)

   - Real-time contract test visualization
   - Success rate monitoring
   - Performance analysis and failure tracking

5. **Prometheus Alerting** (`contract-test-alerts.yml`)

   - Automated alerts for contract test failures
   - SLO monitoring and burn rate alerts
   - Integration with Alertmanager

6. **Pact Broker Integration**
   - Centralized contract storage and verification
   - Team collaboration on contract changes
   - Webhook notifications for contract events

## Features

### Real-Time Monitoring

- **Contract Test Success Rate**: Track passing vs failing tests
- **Performance Metrics**: Test duration and throughput analysis
- **Error Analysis**: Categorize and track failure types
- **Coverage Tracking**: Monitor API endpoint coverage

### Reporting & Analytics

- **Comprehensive Reports**: Detailed HTML and JSON reports
- **Historical Trends**: Track contract test health over time
- **Coverage Analysis**: Identify untested API endpoints
- **Performance Analysis**: Find slow or problematic tests

### Alerting & Notifications

- **Failure Rate Alerts**: Trigger on high failure rates
- **Coverage Alerts**: Notify on low test coverage
- **Performance Alerts**: Flag slow test execution
- **Broker Health**: Monitor Pact Broker availability

### Integration

- **CI/CD Pipeline**: Automatic metrics collection
- **Jest Integration**: Seamless test framework integration
- **Webhook Support**: Real-time test result reporting
- **Multi-Environment**: Support dev, staging, production

## Installation & Setup

### Quick Start

```bash
cd <repo-root>/infra/monitoring
./deploy-contract-testing-monitoring.sh
```

### Manual Setup

1. **Install Dependencies**

```bash
cd <repo-root>/infra/monitoring
npm install
```

2. **Start Services**

```bash
docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml up -d
```

3. **Verify Installation**

```bash
curl http://localhost:9095/health
curl http://localhost:9292/diagnostic/status/heartbeat
```

## Usage

### Integrating with Existing Tests

```javascript
// tests/contract/api-example.contract.test.js
const { enhancedPactIntegration } = require('./setup/enhanced-pact-integration');

describe('Example API Contract Tests', () => {
  let provider;

  beforeAll(async () => {
    const config = await enhancedPactIntegration.setupPactTest({
      consumer: 'example-consumer',
      provider: 'example-provider',
      testType: 'consumer',
    });
    provider = new MockProvider(config);
  });

  afterAll(async () => {
    await provider.verify();
    await enhancedPactIntegration.generateContractReport();
  });

  it('should handle user creation', async () => {
    await provider
      .given('user database is empty')
      .uponReceiving('a request to create a user')
      .withRequest({
        method: 'POST',
        path: '/users',
        headers: { 'Content-Type': 'application/json' },
        body: { name: 'John Doe', email: 'john@example.com' },
      })
      .willRespondWith({
        status: 201,
        headers: { 'Content-Type': 'application/json' },
        body: { id: 1, name: 'John Doe', email: 'john@example.com' },
      });

    const response = await createUser({ name: 'John Doe', email: 'john@example.com' });
    expect(response.status).toBe(201);
  });
});
```

### CI/CD Integration

```yaml
# .github/workflows/contract-tests.yml
name: Contract Tests
on: [push, pull_request]

jobs:
  contract-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: actions/setup-node@v3
        with:
          node-version: '18'

      - name: Install dependencies
        run: npm ci

      - name: Start monitoring services
        run: |
          cd infra/monitoring
          docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml up -d
          sleep 30

      - name: Run contract tests
        run: npm run test:contract
        env:
          CONTRACT_METRICS_URL: http://localhost:9095
          PACT_BROKER_URL: http://localhost:9292

      - name: Collect final metrics
        run: curl -X POST http://localhost:9095/collect-metrics

      - name: Upload test reports
        uses: actions/upload-artifact@v3
        with:
          name: contract-test-reports
          path: tests/contract/reports/
```

### Manual Testing

```bash
# Run consumer tests
cd tests/contract
npm run test:consumer

# Run provider verification
npm run test:provider

# Generate reports
curl -X POST http://localhost:9095/collect-metrics

# Check metrics
curl http://localhost:9095/metrics | grep pact_
```

## Configuration

### Environment Variables

```bash
# Contract Metrics Collector
CONTRACT_METRICS_PORT=9095
PACT_BROKER_URL=http://localhost:9292
NODE_ENV=production

# Pact Broker
PACT_BROKER_DATABASE_URL=postgresql://user:pass@host/db
PACT_BROKER_LOG_LEVEL=INFO

# Alerting
SLACK_CONTRACT_WEBHOOK_URL=https://hooks.slack.com/...
TEAMS_CONTRACT_WEBHOOK_URL=https://outlook.office.com/...
EMAIL_SMTP_HOST=smtp.gmail.com
```

### Service Ports

- **Contract Metrics Collector**: 9095
- **Pact Broker**: 9292
- **Contract Dashboard**: 8090
- **Webhook Handler**: 9096
- **Grafana**: 3000 (existing)
- **Prometheus**: 9090 (existing)

## Dashboard Usage

### Accessing Dashboards

1. **Main Contract Testing Dashboard**

   - URL: http://localhost:3000/d/contract-testing-monitoring
   - Shows real-time contract test health
   - Filter by consumer, provider, test type

2. **Contract Reports Dashboard**
   - URL: http://localhost:8090
   - Historical reports and trends
   - Detailed failure analysis

### Key Metrics

- **Success Rate**: Percentage of passing tests
- **Test Throughput**: Tests per hour/minute
- **Duration Percentiles**: P50, P95, P99 test durations
- **Coverage**: Percentage of API endpoints covered
- **Error Analysis**: Breakdown by error type

### Alerts Configuration

Alerts are automatically configured for:

- High failure rate (>10% for 2 minutes)
- Critical failure rate (>25% for 1 minute)
- No tests running for 30 minutes
- Long test duration (>30 seconds)
- Pact Broker unavailability
- Low coverage (<70%)

## Troubleshooting

### Common Issues

1. **Metrics Not Appearing**

```bash
# Check metrics collector health
curl http://localhost:9095/health

# Check if metrics are being generated
curl http://localhost:9095/metrics | grep pact_

# Restart metrics collector
docker-compose restart contract-test-metrics
```

2. **Pact Broker Connection Issues**

```bash
# Check Pact Broker health
curl http://localhost:9292/diagnostic/status/heartbeat

# Check database connection
docker-compose logs pact-broker-db

# Reset Pact Broker
docker-compose restart pact-broker pact-broker-db
```

3. **Dashboard Not Loading**

```bash
# Check Grafana status
curl http://localhost:3000/api/health

# Reload dashboards
curl -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/dashboards/reload
```

4. **Tests Not Reporting Metrics**

```bash
# Check test configuration
grep -r "CONTRACT_METRICS_URL" tests/

# Verify integration setup
node -e "console.log(require('./tests/contract/setup/enhanced-pact-integration'))"

# Check network connectivity
curl -X POST http://localhost:9095/contract-test-result -d '{"test":"connectivity"}'
```

### Logs and Debugging

```bash
# View all service logs
docker-compose -f docker-compose.monitoring.yml -f docker-compose.contract-testing.yml logs -f

# View specific service logs
docker-compose logs contract-test-metrics
docker-compose logs pact-broker

# Check test reports
ls -la tests/contract/reports/
cat tests/contract/reports/contract-test-report-*.json
```

### Performance Tuning

1. **Metrics Collection Frequency**

   - Adjust collection interval in `contract-test-metrics-collector.js`
   - Default: 60 seconds

2. **Dashboard Refresh Rate**

   - Modify dashboard refresh interval (default: 30s)
   - Balance between real-time updates and performance

3. **Report Generation**
   - Configure report retention period
   - Limit historical analysis depth for performance

## Monitoring Best Practices

### Test Organization

- Use consistent consumer/provider naming
- Include meaningful test descriptions
- Tag tests with environment and version info

### Metrics Collection

- Report test results immediately after execution
- Include comprehensive error information
- Track both positive and negative test cases

### Dashboard Usage

- Set up appropriate alerts for your team
- Use filters to focus on relevant services
- Monitor trends rather than just current values

### Maintenance

- Regularly review and update alert thresholds
- Clean up old reports and metrics data
- Update dashboard configurations as services evolve

## API Reference

### Contract Metrics Collector API

#### Health Check

```bash
GET http://localhost:9095/health
```

#### Metrics Endpoint

```bash
GET http://localhost:9095/metrics
```

#### Submit Test Result

```bash
POST http://localhost:9095/contract-test-result
Content-Type: application/json

{
  "consumer": "api-client",
  "provider": "user-service",
  "status": "passed",
  "duration": 1.23,
  "testType": "consumer"
}
```

#### Submit Pact Publication

```bash
POST http://localhost:9095/pact-publication
Content-Type: application/json

{
  "consumer": "api-client",
  "provider": "user-service",
  "version": "1.2.3",
  "environment": "staging"
}
```

#### Manual Metrics Collection

```bash
POST http://localhost:9095/collect-metrics
```

## Contributing

### Adding New Metrics

1. Define metric in `contract-test-metrics-collector.js`
2. Add collection logic in appropriate collector method
3. Update dashboard queries if needed
4. Add corresponding alert rules if applicable

### Extending Dashboards

1. Modify `wrfcoin-contract-testing.json`
2. Test changes in local Grafana instance
3. Update deployment scripts if needed

### Adding Alert Rules

1. Add rules to `contract-test-alerts.yml`
2. Test alert conditions
3. Update documentation

## Support

For issues and questions:

- Check troubleshooting section above
- Review service logs for error details
- Consult the WRFCoin development team
- Create issues in the project repository

---

_Last updated: 2025-07-22_ _Version: 1.0.0_
