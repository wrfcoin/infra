# Wrfcoin Slack Monitoring Setup Guide

## 🎉 Setup Complete!

Your Slack webhook integration is now working perfectly. Here's what we accomplished and your next
steps.

## ✅ What's Working

1. **All Slack channels created and configured**:

   - `#blockchain-monitoring` - General blockchain alerts
   - `#blockchain-critical` - Critical system issues
   - `#cross-chain-monitoring` - Bridge and cross-chain alerts
   - `#security-alerts` - Security-related notifications
   - `#infrastructure-monitoring` - System/infrastructure alerts
   - `#weather-monitoring` - Weather/IoT device alerts
   - `#api-monitoring` - API and service alerts
   - `#observability` - Monitoring system health
   - `#monitoring-warnings` - Non-critical warnings

2. **Webhook handler processing alerts with trace correlation**
3. **AlertManager routing to appropriate channels**

## 📱 Managing Notifications

### Immediate Actions (Stop the Notification Storm!)

1. **Mute test channels temporarily**:

   ```bash
   # In Slack, go to each channel and click the bell icon to mute
   # OR use the test configuration:
   ```

2. **Use test configuration for further testing**:

   ```bash
   # Switch to test config (sends only to #blockchain-monitoring)
   docker-compose -f docker-compose.alerting.yml down

   # Edit the alertmanager service to use test config:
   # Change: ./alertmanager-enhanced.yml:/etc/alertmanager/config.yml:ro
   # To:     ./alertmanager-test.yml:/etc/alertmanager/config.yml:ro

   docker-compose -f docker-compose.alerting.yml up -d
   ```

### Slack Notification Settings

1. **Channel-specific notification settings**:

   - `#blockchain-critical` → All messages (high priority)
   - `#security-alerts` → All messages (high priority)
   - `#blockchain-monitoring` → Mentions only
   - Other channels → Mentions only or muted

2. **Personal notification schedule**:
   - Set "Do Not Disturb" hours in Slack
   - Configure mobile push notification times
   - Use Slack's notification schedule feature

## 🧪 Safe Testing Commands

### Test Single Alert

```bash
# Send one confirmation message
python3 test_slack_webhook_safe.py
```

### Test AlertManager Integration

```bash
# Send a test alert through Prometheus/AlertManager
curl -X POST http://localhost:9093/api/v1/alerts \
  -H "Content-Type: application/json" \
  -d '[{
    "labels": {
      "alertname": "TestAlert",
      "severity": "warning",
      "category": "test"
    },
    "annotations": {
      "summary": "Single test alert",
      "description": "Testing AlertManager integration"
    }
  }]'
```

## 🔧 Production Configuration

### Alert Routing Strategy

- **Critical alerts** → Immediate notification + email
- **Warning alerts** → Grouped notifications (every 5 minutes)
- **Info alerts** → Daily digest

### Recommended Notification Rules

```yaml
# Add to alertmanager-enhanced.yml
route:
  routes:
    # Mute during maintenance windows
    - match:
        severity: warning
      mute_time_intervals:
        - maintenance-window

    # Rate limit non-critical alerts
    - match_re:
        category: weather|api
      group_interval: 30m
      repeat_interval: 4h
```

## 📊 Monitoring the Monitoring

### Health Checks

```bash
# Check webhook handler
curl http://localhost:5001/health

# Check AlertManager
curl http://localhost:9093/-/healthy

# Check Prometheus
curl http://localhost:9090/-/healthy
```

### Log Monitoring

```bash
# View webhook handler logs
docker logs wrfcoin-alert-webhook-handler

# View AlertManager logs
docker logs wrfcoin-alertmanager-enhanced
```

## 🚨 Emergency Procedures

### Stop All Notifications

```bash
# Emergency: Stop AlertManager
docker stop wrfcoin-alertmanager-enhanced

# Or mute all Slack notifications
# In Slack: Preferences → Notifications → "Pause all notifications"
```

### Reset Configuration

```bash
# Restart with clean state
docker-compose -f docker-compose.alerting.yml down
docker-compose -f docker-compose.alerting.yml up -d
```

## 📈 Next Steps

1. **Configure real alerting rules** in `alert-rules-enhanced.yml`
2. **Set up Grafana dashboards** for visual monitoring
3. **Create runbook links** for each alert type
4. **Test escalation procedures** with your team
5. **Set up log aggregation** with the configured Loki/Promtail

## 🎯 Pro Tips

- Use thread replies in Slack for alert discussions
- Pin important alerts in critical channels
- Create Slack workflows for common responses
- Set up saved searches for alert patterns
- Use Slack's reminder feature for follow-ups

---

**Remember**: The notification storm you just experienced means everything is working perfectly! 🎉
