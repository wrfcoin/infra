# WRFCoin Disaster Recovery Performance Benchmarker

A comprehensive performance analysis and benchmarking suite for WRFCoin's disaster recovery
infrastructure, designed to validate RTO (Recovery Time Objective) and RPO (Recovery Point
Objective) compliance.

## Overview

The DR Performance Benchmarker provides:

- **RTO/RPO Compliance Validation** - Current targets: 15 minutes RTO, 5 minutes RPO
- **Failover Automation Performance Benchmarking** - Tests actual failover execution times
- **Cross-Region Replication Lag Monitoring** - Validates data synchronization performance
- **Performance Bottleneck Identification** - Identifies infrastructure constraints
- **CloudWatch Metrics Integration** - Real-time monitoring and alerting
- **Automated Optimization Recommendations** - AI-powered improvement suggestions

## Architecture

### Core Components

1. **DisasterRecoveryPerformanceBenchmarker** (`disaster-recovery-performance-benchmarker.js`)

   - Main benchmarking engine
   - AWS SDK integration for metrics collection
   - Comprehensive test execution and analysis

2. **DRPerformanceAnalyzer** (`../scripts/analyze-dr-performance.js`)

   - Complete infrastructure analysis
   - Integration with existing DR test scripts
   - Compliance validation and reporting

3. **CloudWatch Dashboard** (`dr-performance-dashboard.tf`)
   - Real-time metrics visualization
   - Custom alarms for RTO/RPO thresholds
   - Automated alerting and response

## Quick Start

### Prerequisites

- Node.js 18+
- AWS CLI configured with appropriate permissions
- Access to primary (us-east-1) and secondary (us-west-2) regions
- Existing DR infrastructure deployed

### Installation

```bash
# Install dependencies
cd infra/monitoring
npm install

# Validate configuration
npm run validate:dr-config
```

### Running Benchmarks

```bash
# Run complete DR performance analysis
npm run analyze:dr-performance

# Run focused performance benchmarking
npm run benchmark:dr

# Start the DR benchmarker service
npm run start:dr-benchmarker
```

## Key Performance Targets

| Metric                 | Target            | Description                         |
| ---------------------- | ----------------- | ----------------------------------- |
| **RTO**                | 15 minutes (900s) | Maximum acceptable downtime         |
| **RPO**                | 5 minutes (300s)  | Maximum acceptable data loss        |
| **Database Failover**  | < 5 minutes       | Aurora cluster failover time        |
| **DNS Failover**       | < 2 minutes       | Route 53 health check + propagation |
| **Kubernetes Scaling** | < 10 minutes      | Secondary cluster scale-up          |
| **S3 Replication**     | < 15 seconds      | Cross-region object replication     |

## Benchmark Test Scenarios

### 1. Baseline Performance Analysis

```javascript
// Analyzes current infrastructure performance
const baseline = await benchmarker.analyzeBaselinePerformance();
```

**Metrics Collected:**

- Database CPU, memory, connections, replication lag
- EKS cluster health and error rates
- Cross-region network latency
- Storage performance (S3, EFS)

### 2. Failover Automation Benchmarking

```bash
# Test individual components
./infra/deployment/disaster-recovery/test-failover.sh health
./infra/deployment/disaster-recovery/test-failover.sh database
./infra/deployment/disaster-recovery/test-failover.sh dns
./infra/deployment/disaster-recovery/test-failover.sh kubernetes
```

**Performance Measurements:**

- Script execution time per component
- Actual vs target failover times
- Success rates and error conditions
- Resource utilization during tests

### 3. Cross-Region Replication Analysis

```javascript
// Tests real S3 cross-region replication performance
const replication = await benchmarker.testS3ReplicationPerformance();
```

**Metrics Analyzed:**

- Database replication lag (primary → secondary)
- S3 cross-region replication time
- ElastiCache Global Datastore sync
- Overall RPO compliance

### 4. Real-Time Performance Monitoring

```javascript
// Continuous monitoring during benchmark execution
const realTimeMetrics = await benchmarker.monitorRealTimeMetrics();
```

**Monitored Resources:**

- CPU utilization across regions
- Memory consumption patterns
- Network throughput and latency
- Disk I/O performance

## CloudWatch Integration

### Custom Metrics

The benchmarker publishes metrics to the `WRFCoin/DR/Performance` namespace:

- `RTOPerformance` - Actual RTO measurements (seconds)
- `RPOPerformance` - Actual RPO measurements (seconds)
- `BenchmarkExecutionTime` - Total benchmark runtime
- `OverallPerformanceScore` - Composite performance score (0-100)
- `DatabaseFailoverTime` - Database-specific failover time
- `DNSFailoverTime` - DNS failover completion time
- `KubernetesFailoverTime` - K8s cluster failover time
- `S3ReplicationTime` - Cross-region S3 replication time
- `BottlenecksDetected` - Count of performance bottlenecks

### Alarms and Thresholds

| Alarm                       | Threshold              | Action                        |
| --------------------------- | ---------------------- | ----------------------------- |
| RTO Performance Degradation | > 720s (80% of target) | SNS alert                     |
| RPO Performance Degradation | > 240s (80% of target) | SNS alert                     |
| Performance Score Low       | < 80%                  | SNS alert + Lambda automation |
| Bottlenecks Detected        | > 0                    | SNS alert                     |

### Dashboard Access

View real-time DR performance metrics at:

```
https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=wrfcoin-dr-performance-benchmarker
```

## Performance Bottleneck Detection

### Common Bottlenecks Identified

1. **RTO Performance Issues**

   - Sequential failover operations (should be parallel)
   - Long DNS TTL causing slow failover
   - Cold start penalties in secondary region
   - Network latency between regions

2. **RPO Performance Issues**

   - Database replication lag spikes
   - S3 cross-region replication delays
   - Network bandwidth constraints
   - Write-heavy workloads causing lag

3. **Resource Constraints**
   - High CPU utilization affecting performance
   - Memory pressure during failover
   - Network bandwidth saturation
   - Storage IOPS limitations

### Optimization Recommendations

The benchmarker automatically generates prioritized recommendations:

```javascript
// Example recommendation output
{
  category: 'RTO_OPTIMIZATION',
  priority: 'HIGH',
  title: 'Optimize Failover Performance',
  actions: [
    'Implement parallel failover processes where possible',
    'Pre-warm secondary infrastructure to reduce startup time',
    'Optimize DNS TTL settings for faster failover',
    'Consider using AWS Application Recovery Controller'
  ],
  expectedImprovement: '20-40% reduction in failover time'
}
```

## Advanced Features

### 1. Adaptive Parameter Tuning

```javascript
// Automatically adjusts parameters based on performance
const optimizer = new AdaptiveOptimizer();
await optimizer.optimizeBasedOnResults(benchmarkResults);
```

### 2. Machine Learning Performance Modeling

```javascript
// Predicts optimal configurations using historical data
const suggestions = await performanceModel.suggestParameters(protocol, results);
```

### 3. Chaos Engineering Integration

```javascript
// Simulates various failure scenarios
await benchmarker.simulateFailureScenarios([
  'primary-region-outage',
  'database-failover',
  'network-partition',
]);
```

## Integration with Existing Infrastructure

### GitHub Actions Workflow

The benchmarker integrates with `.github/workflows/disaster-recovery-test.yml`:

```yaml
- name: Run performance analysis
  run: |
    cd infra/monitoring
    npm run analyze:dr-performance
```

### Terraform Monitoring

Deploy enhanced monitoring with:

```bash
cd infra/terraform
terraform apply -target=aws_cloudwatch_dashboard.dr_performance_benchmarker
```

### Slack Notifications

Performance alerts are sent to configured Slack channels:

```json
{
  "attachments": [
    {
      "color": "danger",
      "title": "🚨 DR Performance Alert",
      "fields": [
        {
          "title": "RTO Compliance",
          "value": "❌ Non-compliant (920s vs 900s target)",
          "short": true
        }
      ]
    }
  ]
}
```

## API Reference

### DisasterRecoveryPerformanceBenchmarker Class

#### Constructor Options

```javascript
const config = {
  primaryRegion: 'us-east-1', // Primary AWS region
  secondaryRegion: 'us-west-2', // Secondary AWS region
  rtoTarget: 900, // RTO target in seconds
  rpoTarget: 300, // RPO target in seconds
  clusterName: 'wrfcoin-production-cluster',
  dbIdentifier: 'wrfcoin-production-database',
  healthEndpoint: 'https://api.wrfcoin.com/health',
};

const benchmarker = new DisasterRecoveryPerformanceBenchmarker(config);
```

#### Methods

- `runComprehensiveBenchmarks()` - Execute full benchmark suite
- `analyzeBaselinePerformance()` - Analyze current infrastructure performance
- `benchmarkFailoverAutomation()` - Test failover script performance
- `analyzeCrossRegionReplication()` - Measure replication lag and performance
- `validateRTORPOCompliance()` - Check compliance against targets
- `identifyPerformanceBottlenecks()` - Find infrastructure constraints
- `generateOptimizationRecommendations()` - Create improvement suggestions

## Troubleshooting

### Common Issues

1. **AWS Permission Errors**

   ```bash
   # Ensure your AWS credentials have the required permissions
   aws sts get-caller-identity
   aws iam get-user
   ```

2. **Network Connectivity**

   ```bash
   # Test connectivity to both regions
   curl -I https://us-east-1.amazonaws.com
   curl -I https://us-west-2.amazonaws.com
   ```

3. **CloudWatch Metrics Missing**
   ```bash
   # Verify log group exists
   aws logs describe-log-groups --log-group-name-prefix "/wrfcoin/disaster-recovery"
   ```

### Debug Mode

Enable debug logging:

```bash
export DEBUG=true
export LOG_LEVEL=debug
npm run benchmark:dr
```

### Performance Tuning

For better benchmark performance:

```bash
# Increase Node.js memory limit
export NODE_OPTIONS="--max-old-space-size=8192"

# Use faster timeout settings
export BENCHMARK_TIMEOUT=300000  # 5 minutes
```

## Monitoring and Alerting

### Key Metrics to Monitor

1. **Performance Score Trends** - Overall DR health
2. **RTO/RPO Compliance History** - Target adherence over time
3. **Component-Specific Performance** - Individual system performance
4. **Bottleneck Detection Rate** - Infrastructure constraint frequency
5. **Recommendation Implementation** - Optimization progress

### Alert Integration

Configure alerts in monitoring systems:

- **PagerDuty**: Critical RTO/RPO violations
- **Slack**: Performance degradation warnings
- **Email**: Weekly performance summary reports
- **SMS**: Emergency-level infrastructure failures

## Best Practices

### Running Benchmarks

1. **Scheduled Testing**: Run comprehensive benchmarks monthly
2. **Pre-Change Validation**: Benchmark before infrastructure changes
3. **Performance Regression**: Test after deployments
4. **Capacity Planning**: Use results for scaling decisions

### Performance Optimization

1. **Prioritize High-Impact Issues**: Focus on RTO/RPO compliance first
2. **Gradual Implementation**: Apply optimizations incrementally
3. **Continuous Monitoring**: Track improvement effectiveness
4. **Regular Reviews**: Update targets based on business requirements

## Contributing

### Development Setup

```bash
# Clone repository
git clone https://github.com/wrfcoin/wrfcoin.git
cd wrfcoin/infra/monitoring

# Install dependencies
npm install

# Run tests
npm test

# Run linter
npm run lint
```

### Adding New Benchmarks

1. Extend the `DisasterRecoveryPerformanceBenchmarker` class
2. Add new test scenarios to the benchmark suite
3. Update CloudWatch metric filters
4. Add corresponding dashboard widgets
5. Update documentation

### Testing

```bash
# Unit tests
npm run test:unit

# Integration tests (requires AWS access)
npm run test:integration

# Performance validation
npm run benchmark:dr -- --validate-only
```

## License

MIT License - see LICENSE file for details.

## Support

For issues and questions:

- **GitHub Issues**: https://github.com/wrfcoin/wrfcoin/issues
- **Documentation**: https://docs.wrfcoin.com/disaster-recovery
- **Team Contact**: infrastructure@wrfcoin.com
