#!/usr/bin/env python3
"""
Check current webhook configuration and help set up real webhooks
"""

import os
from pathlib import Path
import subprocess
import json

def check_environment_variables():
    """Check current environment variables"""
    print("🔍 Checking Environment Variables")
    print("=" * 40)
    
    # List of required environment variables
    required_vars = [
        'SMTP_FROM',
        'SMTP_USERNAME', 
        'SMTP_PASSWORD',
        'SLACK_WEBHOOK_URL',
        'DISCORD_WEBHOOK_URL',
        'WEBHOOK_SECRET'
    ]
    
    env_status = {}
    for var in required_vars:
        value = os.getenv(var)
        env_status[var] = value
        status = "✅ SET" if value else "❌ NOT SET"
        # Mask sensitive values
        display_value = value[:10] + "..." if value and len(value) > 10 else value or "Not set"
        print(f"  {var}: {status} ({display_value})")
    
    return env_status

def update_alertmanager_config():
    """Update AlertManager config with actual webhook URLs from environment"""
    config_path = str(Path(os.environ.get("WRFCOIN_ROOT", Path(__file__).resolve().parents[2])) / "infra/monitoring/alertmanager-enhanced.yml")
    
    print(f"\n🔧 Checking AlertManager Configuration")
    print("=" * 40)
    
    try:
        with open(config_path, 'r') as f:
            content = f.read()
        
        # Check for placeholder URLs
        if 'YOUR/SLACK/WEBHOOK' in content:
            print("❌ AlertManager config still has placeholder Slack webhook URLs")
            print("   Need to replace 'YOUR/SLACK/WEBHOOK' with actual webhook URLs")
            return False
        elif 'hooks.slack.com' in content:
            print("✅ AlertManager config has Slack webhook URLs configured")
            
        if 'discord.com/api/webhooks' in content:
            print("✅ AlertManager config has Discord webhook URLs configured")
        else:
            print("❌ AlertManager config missing Discord webhook URLs")
            
        return True
        
    except FileNotFoundError:
        print(f"❌ AlertManager config file not found: {config_path}")
        return False

def send_test_email_alert():
    """Send a test alert specifically for email testing"""
    print(f"\n📧 Testing Email Alerts")
    print("=" * 25)
    
    # Check if AlertManager is running
    try:
        import requests
        response = requests.get("http://localhost:9093/api/v1/status", timeout=5)
        if response.status_code == 200:
            print("✅ AlertManager is running")
        else:
            print("❌ AlertManager not responding properly")
            return False
    except Exception as e:
        print(f"❌ Cannot connect to AlertManager: {e}")
        return False
    
    # Send test alert to AlertManager
    test_alert = [{
        "labels": {
            "alertname": "EmailTest",
            "severity": "critical",
            "category": "test",
            "service": "wrfcoin-test"
        },
        "annotations": {
            "summary": "Test email notification from Wrfcoin monitoring",
            "description": "This is a test to verify email notifications are working properly."
        },
        "generatorURL": "http://localhost:9090/test"
    }]
    
    try:
        import requests
        response = requests.post(
            "http://localhost:9093/api/v1/alerts",
            json=test_alert,
            timeout=10
        )
        
        if response.status_code == 200:
            print("✅ Test alert sent to AlertManager")
            print("📬 Check your email for the test notification")
            return True
        else:
            print(f"❌ Failed to send test alert: {response.status_code}")
            return False
            
    except Exception as e:
        print(f"❌ Error sending test alert: {e}")
        return False

def provide_setup_instructions():
    """Provide instructions for setting up webhooks"""
    print(f"\n📋 Webhook Setup Instructions")
    print("=" * 35)
    
    print("To complete your webhook setup:")
    print()
    
    print("1️⃣ **Slack Webhook Setup:**")
    print("   • Go to https://api.slack.com/apps")
    print("   • Create app → Incoming Webhooks → Add to Workspace")
    print("   • Copy webhook URL and run:")
    print("     export SLACK_WEBHOOK_URL='https://hooks.slack.com/services/....'")
    print()
    
    print("2️⃣ **Discord Webhook Setup:**")
    print("   • In Discord: Server Settings → Integrations → Webhooks")
    print("   • Create webhook, copy URL and run:")
    print("     export DISCORD_WEBHOOK_URL='https://discord.com/api/webhooks/....'")
    print()
    
    print("3️⃣ **Email Setup (if not done):**")
    print("   export SMTP_FROM='alerts@wrfcoin.com'")
    print("   export SMTP_USERNAME='your_email@gmail.com'")
    print("   export SMTP_PASSWORD='your_app_password'")
    print()
    
    print("4️⃣ **Update AlertManager Config:**")
    print("   After setting environment variables, update:")
    print("   infrastructure/monitoring/alertmanager-enhanced.yml")
    print("   Replace placeholder URLs with actual webhook URLs")
    print()
    
    print("5️⃣ **Restart Services:**")
    print("   cd infrastructure/monitoring")
    print("   docker-compose -f docker-compose.monitoring-complete.yml restart alertmanager")

def main():
    """Main function"""
    print("🚀 Wrfcoin Webhook Configuration Checker")
    print("=" * 45)
    
    # Check environment variables
    env_vars = check_environment_variables()
    
    # Check AlertManager configuration
    config_ok = update_alertmanager_config()
    
    # If email is configured, test it
    if env_vars.get('SMTP_FROM') and env_vars.get('SMTP_USERNAME'):
        send_test_email_alert()
    else:
        print(f"\n📧 Email not configured - skipping email test")
    
    # Provide setup instructions
    provide_setup_instructions()
    
    print(f"\n🎯 Current Status Summary:")
    print("=" * 25)
    email_configured = bool(env_vars.get('SMTP_FROM'))
    slack_configured = bool(env_vars.get('SLACK_WEBHOOK_URL'))
    discord_configured = bool(env_vars.get('DISCORD_WEBHOOK_URL'))
    
    print(f"📧 Email: {'✅' if email_configured else '❌'}")
    print(f"💬 Slack: {'✅' if slack_configured else '❌'}")
    print(f"🎮 Discord: {'✅' if discord_configured else '❌'}")
    print(f"⚙️  Config: {'✅' if config_ok else '❌'}")

if __name__ == "__main__":
    main()