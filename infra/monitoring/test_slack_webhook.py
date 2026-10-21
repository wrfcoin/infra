#!/usr/bin/env python3
"""
Comprehensive Slack Webhook Test Script for Wrfcoin Monitoring
Tests all webhook configurations and provides diagnostic information
"""

import requests
import json
import os
import time
from datetime import datetime

SLACK_WEBHOOK_URL = os.environ.get('SLACK_WEBHOOK_URL')

# Channel configurations from alertmanager-enhanced.yml
CHANNELS = [
    '#blockchain-monitoring',
    '#blockchain-critical',
    '#cross-chain-monitoring',
    '#security-alerts',
    '#infrastructure-monitoring',
    '#weather-monitoring',
    '#api-monitoring',
    '#observability',
    '#monitoring-warnings',
]

def test_webhook_url(webhook_url, channel='#test'):
    """Test a single webhook URL"""
    test_message = {
        'text': f'🧪 Webhook Test from Wrfcoin Monitoring - {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}',
        'channel': channel,
        'username': 'Wrfcoin-Monitor',
        'icon_emoji': ':gear:',
        'attachments': [{
            'color': 'good',
            'title': 'Webhook Configuration Test',
            'fields': [
                {
                    'title': 'Test Type',
                    'value': 'Slack Webhook Connectivity',
                    'short': True
                },
                {
                    'title': 'Target Channel',
                    'value': channel,
                    'short': True
                },
                {
                    'title': 'Timestamp',
                    'value': datetime.now().isoformat(),
                    'short': False
                }
            ]
        }]
    }
    
    try:
        response = requests.post(webhook_url, json=test_message, timeout=10)
        return {
            'url': webhook_url,
            'channel': channel,
            'status_code': response.status_code,
            'response_text': response.text,
            'success': response.status_code == 200,
            'error': None
        }
    except Exception as e:
        return {
            'url': webhook_url,
            'channel': channel,
            'status_code': None,
            'response_text': None,
            'success': False,
            'error': str(e)
        }

def test_alertmanager_style_message(webhook_url, channel='#test'):
    """Test with AlertManager-style message format"""
    alertmanager_message = {
        'channel': channel,
        'title': 'Wrfcoin Alert: TestBlockchainAlert',
        'text': '''
*Alert:* Test blockchain monitoring alert
*Description:* This is a test alert to verify AlertManager integration
*Severity:* warning
*Category:* blockchain_core
*Trace Query:* `service.name=wrfcoin-blockchain`
*Jaeger URL:* http://localhost:16686/search?service=wrfcoin-blockchain&tags=test
*Runbook:* https://docs.wrfcoin.com/alerts/blockchain-core
        '''
    }
    
    try:
        response = requests.post(webhook_url, json=alertmanager_message, timeout=10)
        return {
            'url': webhook_url,
            'channel': channel,
            'status_code': response.status_code,
            'response_text': response.text,
            'success': response.status_code == 200,
            'error': None,
            'message_type': 'alertmanager_style'
        }
    except Exception as e:
        return {
            'url': webhook_url,
            'channel': channel,
            'status_code': None,
            'response_text': None,
            'success': False,
            'error': str(e),
            'message_type': 'alertmanager_style'
        }

def test_local_webhook_handler():
    """Test the local webhook handler"""
    try:
        # Test health endpoint
        health_response = requests.get('http://localhost:5001/health', timeout=5)
        health_success = health_response.status_code == 200
        
        # Test webhook endpoint with sample alert
        sample_alert = {
            'alerts': [{
                'labels': {
                    'alertname': 'WebhookTest',
                    'severity': 'warning',
                    'category': 'blockchain_core',
                    'service': 'wrfcoin-blockchain'
                },
                'annotations': {
                    'summary': 'Webhook handler test alert',
                    'description': 'Testing webhook handler functionality'
                },
                'startsAt': datetime.now().isoformat() + 'Z',
                'endsAt': '',
                'generatorURL': 'http://prometheus:9090/graph'
            }]
        }
        
        webhook_response = requests.post('http://localhost:5001/webhook', json=sample_alert, timeout=15)
        webhook_success = webhook_response.status_code == 200
        
        return {
            'health_check': {
                'success': health_success,
                'status_code': health_response.status_code,
                'response': health_response.text if health_success else None
            },
            'webhook_test': {
                'success': webhook_success,
                'status_code': webhook_response.status_code,
                'response': webhook_response.text if webhook_success else None
            }
        }
    except Exception as e:
        return {
            'health_check': {'success': False, 'error': str(e)},
            'webhook_test': {'success': False, 'error': str(e)}
        }

def main():
    """Main test function"""
    print("🚀 Starting Wrfcoin Slack Webhook Test Suite")
    print("=" * 60)

    if not SLACK_WEBHOOK_URL:
        print("❌ SLACK_WEBHOOK_URL is required; do not commit webhook URLs")
        return
    
    # Test local webhook handler first
    print("\n1. Testing Local Webhook Handler...")
    print("-" * 40)
    
    local_test = test_local_webhook_handler()
    if local_test['health_check']['success']:
        print("✅ Local webhook handler health check: PASSED")
    else:
        print("❌ Local webhook handler health check: FAILED")
        print(f"   Error: {local_test['health_check'].get('error', 'Unknown error')}")
    
    if local_test['webhook_test']['success']:
        print("✅ Local webhook handler processing: PASSED")
    else:
        print("❌ Local webhook handler processing: FAILED")
        print(f"   Error: {local_test['webhook_test'].get('error', 'Unknown error')}")
    
    # Test Slack webhook URLs
    print("\n2. Testing Slack Webhook URLs...")
    print("-" * 40)
    
    all_results = []
    
    for channel in CHANNELS:
        print(f"\nTesting {channel}...")

        # Test basic message
        basic_result = test_webhook_url(SLACK_WEBHOOK_URL, channel)
        all_results.append(basic_result)

        if basic_result['success']:
            print(f"✅ Basic message to {channel}: PASSED")
        else:
            print(f"❌ Basic message to {channel}: FAILED")
            print(f"   Status: {basic_result['status_code']}")
            print(f"   Response: {basic_result['response_text']}")
            print(f"   Error: {basic_result['error']}")

        # Test AlertManager-style message
        time.sleep(1)  # Rate limit protection
        alertmanager_result = test_alertmanager_style_message(SLACK_WEBHOOK_URL, channel)
        all_results.append(alertmanager_result)

        if alertmanager_result['success']:
            print(f"✅ AlertManager-style message to {channel}: PASSED")
        else:
            print(f"❌ AlertManager-style message to {channel}: FAILED")
            print(f"   Status: {alertmanager_result['status_code']}")
            print(f"   Response: {alertmanager_result['response_text']}")
            print(f"   Error: {alertmanager_result['error']}")
    
    # Summary
    print("\n3. Test Summary")
    print("-" * 40)
    
    successful_tests = sum(1 for result in all_results if result['success'])
    total_tests = len(all_results)
    
    print(f"Total tests run: {total_tests}")
    print(f"Successful tests: {successful_tests}")
    print(f"Failed tests: {total_tests - successful_tests}")
    print(f"Success rate: {(successful_tests/total_tests)*100:.1f}%")
    
    # Recommendations
    print("\n4. Recommendations")
    print("-" * 40)
    
    failed_tests = [result for result in all_results if not result['success']]
    if failed_tests:
        print("\n⚠️  Issues Found:")
        for result in failed_tests:
            if result['response_text'] == 'channel_not_found':
                print(f"   • Channel {result['channel']} not found - verify channel exists and bot is added")
            elif result['response_text'] == 'invalid_payload':
                print(f"   • Invalid payload format for {result['channel']}")
            elif result['error']:
                print(f"   • Network/connection error for {result['channel']}: {result['error']}")
            else:
                print(f"   • Unknown error for {result['channel']}: {result['response_text']}")
        
        print("\n🔧 Suggested Actions:")
        print("   1. Verify Slack channels exist and are spelled correctly")
        print("   2. Ensure the Slack bot is added to all target channels")
        print("   3. Check if the webhook URL is still valid in your Slack workspace")
        print("   4. Verify webhook URL permissions in Slack app settings")
        print("   5. Test with a simpler message format first")
    else:
        print("✅ All tests passed! Slack webhook configuration is working correctly.")
    
    print("\n" + "=" * 60)
    print("🏁 Slack Webhook Test Suite Complete")

if __name__ == "__main__":
    main()
