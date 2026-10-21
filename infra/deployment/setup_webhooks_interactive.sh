#!/bin/bash
WRFCOIN_SCRIPT_ROOT="${WRFCOIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

echo "🚀 Wrfcoin Webhook Interactive Setup"
echo "===================================="

# Function to safely prompt for input
prompt_for_value() {
    local var_name=$1
    local description=$2
    local is_secret=${3:-false}
    
    echo ""
    echo "📝 Setting up: $description"
    echo "Variable: $var_name"
    
    if [ "$is_secret" = true ]; then
        echo "Enter value (will be hidden): "
        read -s value
    else
        echo "Enter value: "
        read value
    fi
    
    if [ -n "$value" ]; then
        export $var_name="$value"
        echo "✅ $var_name set successfully"
        
        # Add to .bashrc for persistence
        if ! grep -q "export $var_name=" ~/.bashrc; then
            echo "export $var_name=\"$value\"" >> ~/.bashrc
            echo "📝 Added to ~/.bashrc for persistence"
        fi
    else
        echo "⏭️  Skipped $var_name"
    fi
}

echo ""
echo "This script will help you set up webhook integrations for:"
echo "📧 Email notifications (SMTP)"
echo "💬 Slack notifications" 
echo "🎮 Discord notifications"
echo ""
echo "Press Enter to continue or Ctrl+C to exit..."
read

# Check current environment
echo "🔍 Checking current environment variables..."
env_vars=("SMTP_FROM" "SMTP_USERNAME" "SMTP_PASSWORD" "SLACK_WEBHOOK_URL" "DISCORD_WEBHOOK_URL" "WEBHOOK_SECRET")

for var in "${env_vars[@]}"; do
    value=$(printenv $var)
    if [ -n "$value" ]; then
        echo "✅ $var: ${value:0:10}..."
    else
        echo "❌ $var: Not set"
    fi
done

echo ""
echo "📧 EMAIL SETUP"
echo "============="
prompt_for_value "SMTP_FROM" "Email address for sending alerts (e.g., alerts@wrfcoin.com)"
prompt_for_value "SMTP_USERNAME" "SMTP username (usually your email)"
prompt_for_value "SMTP_PASSWORD" "SMTP password (use app password for Gmail)" true

echo ""
echo "💬 SLACK SETUP"
echo "=============="
echo "To get Slack webhook URL:"
echo "1. Go to https://api.slack.com/apps"
echo "2. Create app → Incoming Webhooks → Add to Workspace"
echo "3. Copy the webhook URL"
prompt_for_value "SLACK_WEBHOOK_URL" "Slack webhook URL"

echo ""
echo "🎮 DISCORD SETUP"
echo "==============="
echo "To get Discord webhook URL:"
echo "1. In Discord: Server Settings → Integrations → Webhooks"
echo "2. Create webhook and copy URL"
prompt_for_value "DISCORD_WEBHOOK_URL" "Discord webhook URL"

echo ""
echo "🔐 SECURITY SETUP"
echo "================"
prompt_for_value "WEBHOOK_SECRET" "Webhook secret key (any secure string)" true

echo ""
echo "🔧 UPDATING ALERTMANAGER CONFIG"
echo "==============================="

# Update AlertManager configuration
config_file="${WRFCOIN_SCRIPT_ROOT}/infra/monitoring/alertmanager-enhanced.yml"

if [ -f "$config_file" ]; then
    echo "📝 Updating AlertManager configuration..."
    
    # Create backup
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
    echo "📦 Backup created"
    
    # Replace placeholder URLs if we have real ones
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        sed -i "s|https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK|$SLACK_WEBHOOK_URL|g" "$config_file"
        echo "✅ Updated Slack webhook URLs in config"
    fi
    
    echo "✅ AlertManager config updated"
else
    echo "❌ AlertManager config file not found: $config_file"
fi

echo ""
echo "🚀 RESTARTING SERVICES"
echo "====================="

cd "${WRFCOIN_SCRIPT_ROOT}/infra/monitoring"

# Check if Docker is accessible
if docker ps >/dev/null 2>&1; then
    echo "🔄 Restarting AlertManager..."
    docker-compose -f docker-compose.monitoring-complete.yml restart alertmanager
    echo "✅ AlertManager restarted"
    
    echo "🔄 Restarting webhook handler..."
    docker-compose -f docker-compose.monitoring-complete.yml restart webhook-receiver
    echo "✅ Webhook handler restarted"
else
    echo "⚠️  Cannot access Docker. You may need to run:"
    echo "   sudo docker-compose -f docker-compose.monitoring-complete.yml restart alertmanager"
    echo "   sudo docker-compose -f docker-compose.monitoring-complete.yml restart webhook-receiver"
fi

echo ""
echo "🧪 TESTING SETUP"
echo "==============="

# Test webhook handler
echo "Testing webhook handler..."
if curl -s http://localhost:5001/health >/dev/null; then
    echo "✅ Webhook handler is responding"
else
    echo "❌ Webhook handler not responding"
fi

# Test AlertManager
echo "Testing AlertManager..."
if curl -s http://localhost:9093/api/v1/status >/dev/null; then
    echo "✅ AlertManager is responding"
else
    echo "❌ AlertManager not responding"
fi

echo ""
echo "🎉 SETUP COMPLETE!"
echo "================="
echo "Your webhook configuration is now set up."
echo ""
echo "🔗 Access your monitoring:"
echo "  • AlertManager: http://localhost:9093"
echo "  • Grafana: http://localhost:3000"
echo "  • Webhook Handler: http://localhost:5001/health"
echo ""
echo "📧 To test notifications, run:"
echo "  python3 ${WRFCOIN_SCRIPT_ROOT}/send_test_alert.py"
echo ""
echo "📋 Current environment variables:"
for var in "${env_vars[@]}"; do
    value=$(printenv $var)
    if [ -n "$value" ]; then
        echo "  ✅ $var: Set"
    else
        echo "  ❌ $var: Not set"
    fi
done