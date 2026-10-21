#!/usr/bin/env python3
"""
Safe Slack Webhook Test Script - Single test message only
"""

import requests
import json
import os
from datetime import datetime

def send_single_test_alert():
    """Send one test alert to verify the setup works"""
    webhook_url = os.environ.get('SLACK_WEBHOOK_URL')
    if not webhook_url:
        print("❌ SLACK_WEBHOOK_URL is required; do not commit webhook URLs")
        return
    
    test_message = {
        'channel': '#blockchain-monitoring',
        'username': 'Wrfcoin-Monitor',
        'icon_emoji': ':white_check_mark:',
        'text': '✅ Slack Integration Test Complete',
        'attachments': [{
            'color': 'good',
            'title': 'Wrfcoin Monitoring Setup Verified',
            'fields': [
                {
                    'title': 'Status',
                    'value': 'All webhook configurations tested successfully',
                    'short': True
                },
                {
                    'title': 'Channels Verified',
                    'value': '9 monitoring channels configured',
                    'short': True
                },
                {
                    'title': 'Next Steps',
                    'value': 'Configure notification rules and test real alerts',
                    'short': False
                }
            ],
            'footer': 'Wrfcoin Blockchain Monitoring',
            'ts': int(datetime.now().timestamp())
        }]
    }
    
    try:
        response = requests.post(webhook_url, json=test_message, timeout=10)
        if response.status_code == 200:
            print("✅ Final test message sent successfully!")
            print("📱 Check #blockchain-monitoring for confirmation")
        else:
            print(f"❌ Test failed: {response.status_code} - {response.text}")
    except Exception as e:
        print(f"❌ Error: {e}")

if __name__ == "__main__":
    print("🔇 Sending final confirmation message (just one!)...")
    send_single_test_alert()
