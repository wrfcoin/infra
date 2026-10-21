#!/bin/bash
# Test AlertManager Alert Firing
# This script sends test alerts through the AlertManager API to verify
# that Slack and Email notifications are properly configured.
#
# Usage:
#   ./test-alertmanager.sh [critical|warning|info|security]
#
# Prerequisites:
#   - AlertManager running on port 9093
#   - SLACK_WEBHOOK_URL configured in environment
#   - SMTP settings configured for email alerts

set -e

ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
SEVERITY="${1:-warning}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=============================================="
echo "  WRFCoin AlertManager Test Suite"
echo "=============================================="
echo ""
echo "AlertManager URL: ${ALERTMANAGER_URL}"
echo "Test Severity: ${SEVERITY}"
echo "Timestamp: ${TIMESTAMP}"
echo ""

# Check if AlertManager is running
echo -n "Checking AlertManager availability... "
if curl -s "${ALERTMANAGER_URL}/-/healthy" > /dev/null 2>&1; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${RED}FAILED${NC}"
    echo "AlertManager is not responding at ${ALERTMANAGER_URL}"
    echo ""
    echo "Start AlertManager with:"
    echo "  docker-compose -f infra/monitoring/docker-compose.monitoring.yml up -d alertmanager"
    exit 1
fi

# Check AlertManager status
echo -n "Checking AlertManager status... "
STATUS=$(curl -s "${ALERTMANAGER_URL}/api/v2/status" 2>/dev/null || echo "error")
if [[ "$STATUS" != "error" ]]; then
    echo -e "${GREEN}OK${NC}"
    # Extract cluster status
    CLUSTER_STATUS=$(echo "$STATUS" | grep -o '"cluster":{[^}]*}' || echo "N/A")
    echo "  Cluster: ${CLUSTER_STATUS:0:50}..."
else
    echo -e "${YELLOW}Unable to fetch status${NC}"
fi

echo ""
echo "----------------------------------------------"
echo "Sending test alert (severity: ${SEVERITY})..."
echo "----------------------------------------------"

# Build alert payload based on severity
case "$SEVERITY" in
    critical)
        ALERT_NAME="TestCriticalAlert"
        SUMMARY="Critical test alert from AlertManager verification"
        DESCRIPTION="This is a critical test alert to verify both Slack and Email notifications are working."
        SERVICE="wrfcoin-core"
        ;;
    security)
        ALERT_NAME="TestSecurityBreach"
        SUMMARY="Security test alert from AlertManager verification"
        DESCRIPTION="This is a security test alert to verify security channel notifications."
        SERVICE="wrfcoin-security"
        ;;
    info)
        ALERT_NAME="TestInfoAlert"
        SUMMARY="Info test alert from AlertManager verification"
        DESCRIPTION="This is an informational test alert for email-only notification."
        SERVICE="wrfcoin-info"
        ;;
    *)
        ALERT_NAME="TestWarningAlert"
        SUMMARY="Warning test alert from AlertManager verification"
        DESCRIPTION="This is a warning test alert to verify Slack notifications."
        SERVICE="wrfcoin-monitoring"
        ;;
esac

# Create alert payload
ALERT_PAYLOAD=$(cat <<EOF
[
  {
    "labels": {
      "alertname": "${ALERT_NAME}",
      "severity": "${SEVERITY}",
      "service": "${SERVICE}",
      "instance": "test-instance:9090",
      "job": "alertmanager-test",
      "environment": "test"
    },
    "annotations": {
      "summary": "${SUMMARY}",
      "description": "${DESCRIPTION}",
      "runbook_url": "https://docs.wrfcoin.com/alerts/${ALERT_NAME}"
    },
    "startsAt": "${TIMESTAMP}",
    "generatorURL": "http://localhost:9090/graph?g0.expr=${ALERT_NAME}"
  }
]
EOF
)

echo ""
echo "Alert payload:"
echo "${ALERT_PAYLOAD}" | head -20
echo ""

# Send alert to AlertManager
echo -n "Posting alert to AlertManager... "
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "${ALERT_PAYLOAD}" \
    "${ALERTMANAGER_URL}/api/v2/alerts" 2>&1)

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "${GREEN}SUCCESS${NC}"
    echo "  HTTP Status: ${HTTP_CODE}"
    echo "  Response: ${BODY:-OK}"
else
    echo -e "${RED}FAILED${NC}"
    echo "  HTTP Status: ${HTTP_CODE}"
    echo "  Response: ${BODY}"
fi

echo ""
echo "----------------------------------------------"
echo "Verifying alert in AlertManager..."
echo "----------------------------------------------"

# Wait a moment for processing
sleep 2

# Check active alerts
echo -n "Fetching active alerts... "
ALERTS=$(curl -s "${ALERTMANAGER_URL}/api/v2/alerts?filter=alertname=${ALERT_NAME}" 2>&1 || echo "error")

if [[ "$ALERTS" != "error" && "$ALERTS" != "[]" && -n "$ALERTS" ]]; then
    echo -e "${GREEN}Found${NC}"
    echo "  Active alerts matching '${ALERT_NAME}':"
    echo "${ALERTS}" | head -5
else
    echo -e "${YELLOW}No active alerts found${NC}"
    echo "  The alert may have been immediately routed and cleared."
fi

echo ""
echo "----------------------------------------------"
echo "Test Complete"
echo "----------------------------------------------"
echo ""
echo "Expected notifications:"
case "$SEVERITY" in
    critical)
        echo "  - Slack: #wrfcoin-alerts-critical"
        echo "  - Email: ${ALERT_EMAIL_TO:-ops@wrfcoin.com}"
        ;;
    security)
        echo "  - Slack: #wrfcoin-security"
        echo "  - Email: ${SECURITY_EMAIL_TO:-security@wrfcoin.com}"
        ;;
    info)
        echo "  - Email: ${ALERT_EMAIL_TO:-ops@wrfcoin.com}"
        ;;
    *)
        echo "  - Slack: #wrfcoin-alerts-warnings"
        ;;
esac
echo ""
echo "Check the respective channels/inboxes to verify delivery."
echo ""

# Resolve the alert (cleanup)
echo -n "Resolving test alert... "
RESOLVE_PAYLOAD=$(cat <<EOF
[
  {
    "labels": {
      "alertname": "${ALERT_NAME}",
      "severity": "${SEVERITY}",
      "service": "${SERVICE}",
      "instance": "test-instance:9090",
      "job": "alertmanager-test",
      "environment": "test"
    },
    "annotations": {
      "summary": "${SUMMARY}",
      "description": "${DESCRIPTION}"
    },
    "startsAt": "${TIMESTAMP}",
    "endsAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "generatorURL": "http://localhost:9090/graph?g0.expr=${ALERT_NAME}"
  }
]
EOF
)

RESOLVE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "${RESOLVE_PAYLOAD}" \
    "${ALERTMANAGER_URL}/api/v2/alerts" 2>&1)

RESOLVE_CODE=$(echo "$RESOLVE_RESPONSE" | tail -1)

if [[ "$RESOLVE_CODE" == "200" ]]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}Warning: Could not resolve alert${NC}"
fi

echo ""
echo "=============================================="
echo "  Test Complete"
echo "=============================================="
echo ""
echo "Available test commands:"
echo "  ./test-alertmanager.sh critical   # Test critical alert (Slack + Email)"
echo "  ./test-alertmanager.sh warning    # Test warning alert (Slack)"
echo "  ./test-alertmanager.sh info       # Test info alert (Email only)"
echo "  ./test-alertmanager.sh security   # Test security alert (Slack + Email)"
echo ""
