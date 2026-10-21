#!/usr/bin/env python3
"""
Test script to verify webhook configurations and send test messages
"""

import json
import requests
import os
from datetime import datetime, timezone

def test_webhook_configuration():
    """Test the webhook configuration setup"""
    print("🔍 Checking Webhook Configuration Setup")
    print("=" * 50)
    
    # Check environment variables needed
    env_vars = {
        'SLACK_WEBHOOK_URL': os.getenv('SLACK_WEBHOOK_URL'),
        'DISCORD_WEBHOOK_URL': os.getenv('DISCORD_WEBHOOK_URL'),
        'SMTP_FROM': os.getenv('SMTP_FROM'),
        'SMTP_USERNAME': os.getenv('SMTP_USERNAME'),
        'SMTP_PASSWORD': os.getenv('SMTP_PASSWORD'),
        'WEBHOOK_SECRET': os.getenv('WEBHOOK_SECRET')
    }
    
    print("Environment Variables Status:")
    for var, value in env_vars.items():
        status = "✅ SET" if value else "❌ NOT SET"
        # Only show first few chars for security
        display_value = value[:10] + "..." if value and len(value) > 10 else value or "Not set"
        print(f"  {var}: {status} ({display_value})")
    
    return env_vars

def create_test_alert():
    """Create a test alert payload"""
    return {
        "version": "4",
        "groupKey": "test-alert-group",
        "status": "firing",
        "receiver": "default-receiver",
        "groupLabels": {
            "alertname": "TestAlert"
        },
        "commonLabels": {
            "alertname": "TestAlert",
            "severity": "warning",
            "category": "test"
        },
        "commonAnnotations": {
            "summary": "Test alert for webhook configuration verification",
            "description": "This is a test alert to verify that webhook integrations are working properly"
        },
        "externalURL": "http://localhost:9093",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "TestAlert",
                    "severity": "warning",
                    "category": "test",
                    "service": "wrfcoin-test"
                },
                "annotations": {
                    "summary": "Test alert for webhook configuration verification",
                    "description": "This is a test alert to verify that webhook integrations are working properly",
                    "runbook_url": "https://docs.wrfcoin.com/alerts/test"
                },
                "startsAt": datetime.now(timezone.utc).isoformat(),
                "endsAt": "0001-01-01T00:00:00Z",
                "generatorURL": "http://localhost:9090/graph?g0.expr=up&g0.tab=1"
            }
        ]
    }

def test_slack_webhook(webhook_url):
    """Test Slack webhook"""
    if not webhook_url:
        print("❌ Slack webhook URL not configured")
        return False
    
    print("🔧 Testing Slack Integration...")
    
    # Test message for Slack
    test_message = {
        "text": "🧪 Wrfcoin Monitoring Test",
        "attachments": [
            {
                "color": "good",
                "title": "Webhook Configuration Test",
                "text": "This is a test message to verify Slack integration is working properly.",
                "fields": [
                    {
                        "title": "Status",
                        "value": "✅ Slack webhook operational",
                        "short": True
                    },
                    {
                        "title": "Timestamp",
                        "value": datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC"),
                        "short": True
                    }
                ],
                "footer": "Wrfcoin Monitoring System",
                "ts": int(datetime.now().timestamp())
            }
        ]
    }
    
    try:
        response = requests.post(webhook_url, json=test_message, timeout=10)
        if response.status_code == 200:
            print("✅ Slack webhook test successful!")
            return True
        else:
            print(f"❌ Slack webhook test failed with status {response.status_code}")
            print(f"Response: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Slack webhook test failed with error: {e}")
        return False

def test_discord_webhook(webhook_url):
    """Test Discord webhook"""
    if not webhook_url:
        print("❌ Discord webhook URL not configured")
        return False
    
    print("🔧 Testing Discord Integration...")
    
    # Test message for Discord
    test_message = {
        "embeds": [
            {
                "title": "🧪 Wrfcoin Monitoring Test",
                "description": "This is a test message to verify Discord integration is working properly.",
                "color": 3447003,  # Blue color
                "fields": [
                    {
                        "name": "Status",
                        "value": "✅ Discord webhook operational",
                        "inline": True
                    },
                    {
                        "name": "Timestamp",
                        "value": datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC"),
                        "inline": True
                    }
                ],
                "footer": {
                    "text": "Wrfcoin Monitoring System"
                },
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
        ]
    }
    
    try:
        response = requests.post(webhook_url, json=test_message, timeout=10)
        if response.status_code in [200, 204]:  # Discord returns 204 for successful webhook
            print("✅ Discord webhook test successful!")
            return True
        else:
            print(f"❌ Discord webhook test failed with status {response.status_code}")
            print(f"Response: {response.text}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Discord webhook test failed with error: {e}")
        return False

def test_local_webhook_handler():
    """Test the local webhook handler service"""
    webhook_url = "http://localhost:5001"
    
    print("🔧 Testing Local Webhook Handler...")
    
    # Test health endpoint first
    try:
        health_response = requests.get(f"{webhook_url}/health", timeout=5)
        if health_response.status_code == 200:
            print("✅ Webhook handler health check successful!")
            print(f"   Response: {health_response.json()}")
        else:
            print(f"❌ Webhook handler health check failed with status {health_response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Webhook handler not accessible: {e}")
        print("   Make sure the webhook handler service is running:")
        print("   cd infrastructure/monitoring && docker-compose -f docker-compose.monitoring-complete.yml up -d webhook-receiver")
        return False
    
    # Test webhook endpoint
    test_alert = create_test_alert()
    
    try:
        webhook_response = requests.post(f"{webhook_url}/webhook", json=test_alert, timeout=10)
        if webhook_response.status_code == 200:
            print("✅ Webhook handler test successful!")
            print(f"   Response: {webhook_response.json()}")
            return True
        else:
            print(f"❌ Webhook handler test failed with status {webhook_response.status_code}")
            print(f"   Response: {webhook_response.text}")
            return False
    except requests.exceptions.RequestException as e:
        print(f"❌ Webhook handler test failed: {e}")
        return False

def main():
    """Main test function"""
    print("🚀 Wrfcoin Monitoring Webhook Test Suite")
    print("=" * 60)
    
    # Test configuration
    env_vars = test_webhook_configuration()
    print()
    
    # Test results
    results = {}
    
    # Test Slack
    if env_vars['SLACK_WEBHOOK_URL']:
        results['slack'] = test_slack_webhook(env_vars['SLACK_WEBHOOK_URL'])
    else:
        print("⏭️  Skipping Slack test - webhook URL not configured")
        results['slack'] = None
    print()
    
    # Test Discord
    if env_vars['DISCORD_WEBHOOK_URL']:
        results['discord'] = test_discord_webhook(env_vars['DISCORD_WEBHOOK_URL'])
    else:
        print("⏭️  Skipping Discord test - webhook URL not configured")
        results['discord'] = None
    print()
    
    # Test local webhook handler
    results['webhook_handler'] = test_local_webhook_handler()
    print()
    
    # Summary
    print("📊 Test Results Summary")
    print("=" * 30)
    for service, result in results.items():
        if result is True:
            status = "✅ PASSED"
        elif result is False:
            status = "❌ FAILED"
        else:
            status = "⏭️ SKIPPED"
        print(f"  {service.title()}: {status}")
    
    print()
    print("📋 Configuration Recommendations:")
    
    if not env_vars['SLACK_WEBHOOK_URL']:
        print("  • Set up Slack webhook URL in environment variables")
        print("    Example: export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/....'")
    
    if not env_vars['DISCORD_WEBHOOK_URL']:
        print("  • Set up Discord webhook URL in environment variables")
        print("    Example: export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/....'")
    
    if not env_vars['SMTP_FROM']:
        print("  • Configure email settings for email notifications")
        print("    Set SMTP_FROM, SMTP_USERNAME, SMTP_PASSWORD environment variables")
    
    if not results['webhook_handler']:
        print("  • Start the webhook handler service:")
        print("    cd infrastructure/monitoring && docker-compose -f docker-compose.monitoring-complete.yml up -d")

if __name__ == "__main__":
    main()