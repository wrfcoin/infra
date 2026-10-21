#!/usr/bin/env python3
"""
Send a test alert to the webhook handler to demonstrate the system
"""

import json
import requests
from datetime import datetime, timezone

def send_test_alert():
    """Send a test alert to the webhook handler"""
    webhook_url = "http://localhost:5001/webhook"
    
    # Create a realistic test alert
    test_alert_payload = {
        "version": "4",
        "groupKey": "test-blockchain-alert",
        "status": "firing",
        "receiver": "default-receiver",
        "groupLabels": {
            "alertname": "BlockchainSystemTest"
        },
        "commonLabels": {
            "alertname": "BlockchainSystemTest",
            "severity": "warning",
            "category": "test",
            "service": "wrfcoin-blockchain"
        },
        "commonAnnotations": {
            "summary": "🧪 Wrfcoin Blockchain Monitoring System Test",
            "description": "This is a test alert to verify the monitoring webhook system is operational. All integrations should receive this message.",
            "runbook_url": "https://docs.wrfcoin.com/monitoring/test-alerts"
        },
        "externalURL": "http://localhost:9093",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "BlockchainSystemTest",
                    "severity": "warning",
                    "category": "test",
                    "service": "wrfcoin-blockchain",
                    "instance": "localhost:8080",
                    "job": "wrfcoin-monitoring-test"
                },
                "annotations": {
                    "summary": "🧪 Wrfcoin Blockchain Monitoring System Test",
                    "description": "This is a test alert to verify the monitoring webhook system is operational. All integrations should receive this message.",
                    "runbook_url": "https://docs.wrfcoin.com/monitoring/test-alerts",
                    "trace_query": "service.name=wrfcoin-blockchain operation.name=test_operation"
                },
                "startsAt": datetime.now(timezone.utc).isoformat(),
                "endsAt": "0001-01-01T00:00:00Z",
                "generatorURL": "http://localhost:9090/graph?g0.expr=up&g0.tab=1",
                "fingerprint": "test-alert-fingerprint-123"
            }
        ]
    }
    
    print("🚀 Sending test alert to webhook handler...")
    print(f"📡 Target: {webhook_url}")
    print(f"📋 Alert: {test_alert_payload['alerts'][0]['labels']['alertname']}")
    
    try:
        response = requests.post(
            webhook_url, 
            json=test_alert_payload, 
            timeout=30,
            headers={'Content-Type': 'application/json'}
        )
        
        if response.status_code == 200:
            result = response.json()
            print("✅ Test alert sent successfully!")
            print(f"📊 Response: {result}")
            print("\n📨 Expected behavior:")
            print("  • Webhook handler processes and enriches the alert")
            print("  • Alert forwarded to configured Slack/Discord channels")
            print("  • Email notifications sent (if SMTP configured)")
            print("  • Trace correlation performed")
            print("  • Alert appears in Grafana/AlertManager")
            return True
        else:
            print(f"❌ Failed to send test alert!")
            print(f"   Status code: {response.status_code}")
            print(f"   Response: {response.text}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Error sending test alert: {e}")
        return False

def send_critical_test_alert():
    """Send a critical test alert to demonstrate escalation"""
    webhook_url = "http://localhost:5001/webhook/critical"
    
    critical_alert_payload = {
        "version": "4",
        "groupKey": "critical-test-alert",
        "status": "firing",
        "receiver": "critical-blockchain-alerts",
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "CriticalSystemTest",
                    "severity": "critical",
                    "category": "blockchain_core",
                    "service": "wrfcoin-blockchain"
                },
                "annotations": {
                    "summary": "🚨 CRITICAL: Blockchain Monitoring System Test",
                    "description": "This is a CRITICAL test alert to verify high-priority alert handling and escalation procedures.",
                    "runbook_url": "https://docs.wrfcoin.com/monitoring/critical-alerts"
                },
                "startsAt": datetime.now(timezone.utc).isoformat(),
                "endsAt": "0001-01-01T00:00:00Z"
            }
        ]
    }
    
    print("\n🚨 Sending CRITICAL test alert...")
    print(f"📡 Target: {webhook_url}")
    
    try:
        response = requests.post(
            webhook_url, 
            json=critical_alert_payload, 
            timeout=30,
            headers={'Content-Type': 'application/json'}
        )
        
        if response.status_code == 200:
            print("✅ Critical test alert sent successfully!")
            print("📊 Expected enhanced processing:")
            print("  • Immediate trace correlation (30-minute window)")
            print("  • Multiple notification channels activated")
            print("  • Enhanced logging and escalation")
            return True
        else:
            print(f"❌ Failed to send critical test alert!")
            print(f"   Status code: {response.status_code}")
            return False
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Error sending critical test alert: {e}")
        return False

def main():
    """Main function"""
    print("🧪 Wrfcoin Monitoring Alert Test Suite")
    print("=" * 50)
    
    # Send regular test alert
    success1 = send_test_alert()
    
    # Send critical test alert
    success2 = send_critical_test_alert()
    
    print("\n" + "=" * 50)
    if success1 and success2:
        print("✅ All test alerts sent successfully!")
        print("\n📋 Next steps:")
        print("  1. Check your Slack/Discord channels for test messages")
        print("  2. Verify email notifications (if configured)")
        print("  3. Check AlertManager at http://localhost:9093")
        print("  4. Review Grafana dashboards at http://localhost:3000")
        print("  5. Examine traces at http://localhost:16686")
    else:
        print("❌ Some test alerts failed to send")
        print("  Check the webhook handler logs for details")

if __name__ == "__main__":
    main()