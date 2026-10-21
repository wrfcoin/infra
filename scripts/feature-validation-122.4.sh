#!/bin/bash
# Task 122.4: Core Feature Validation Script
# Validates 8 core features of WRFCoin platform

set -e

REPORT_FILE="reports/feature-validation-122.4.json"
TIMESTAMP=$(date -Iseconds)

echo "=================================="
echo "Task 122.4: Core Feature Validation"
echo "Date: $(date)"
echo "=================================="
echo ""

# Initialize results
declare -A RESULTS

test_feature() {
    local name="$1"
    local description="$2"
    local url="$3"
    local expected_code="${4:-200}"

    echo -n "Testing: $name ... "

    HTTP_CODE=$(curl -s -o /tmp/response.txt -w "%{http_code}" "$url" 2>/dev/null || echo "000")

    if [ "$HTTP_CODE" == "$expected_code" ]; then
        echo "PASS (HTTP $HTTP_CODE)"
        RESULTS["$name"]="PASS"
        return 0
    else
        echo "FAIL (Expected $expected_code, got $HTTP_CODE)"
        RESULTS["$name"]="FAIL"
        return 1
    fi
}

# Initialize counters
PASSED=0
FAILED=0
TOTAL=8

echo "Running 8 Core Feature Tests..."
echo ""

# Feature 1: Backend API Health
if test_feature "Backend API Health" "Core API server health check" "http://localhost:3001/health"; then
    ((PASSED++))
else
    ((FAILED++))
fi

# Feature 2: Bridge API Status
if test_feature "Cross-Chain Bridge API" "Bridge connectivity and status" "http://localhost:3001/api/bridge/status"; then
    ((PASSED++))
else
    ((FAILED++))
fi

# Feature 3: Prometheus Monitoring
if test_feature "Prometheus Metrics" "Monitoring system health" "http://127.0.0.1:9090/-/healthy"; then
    ((PASSED++))
else
    ((FAILED++))
fi

# Feature 4: Prometheus API
if test_feature "Prometheus API Query" "Metrics query endpoint" "http://127.0.0.1:9090/api/v1/query?query=up"; then
    ((PASSED++))
else
    ((FAILED++))
fi

# Feature 5: Redis Cache
echo -n "Testing: Redis Cache ... "
if docker exec wrfcoin-redis redis-cli -a "${REDIS_PASSWORD:-wrfcoin_secure_2024}" --no-auth-warning ping 2>/dev/null | grep -q "PONG"; then
    echo "PASS"
    RESULTS["Redis Cache"]="PASS"
    ((PASSED++))
else
    echo "FAIL"
    RESULTS["Redis Cache"]="FAIL"
    ((FAILED++))
fi

# Feature 6: Redis SET/GET operations
echo -n "Testing: Redis SET/GET Operations ... "
SET_RESULT=$(docker exec wrfcoin-redis redis-cli -a "${REDIS_PASSWORD:-wrfcoin_secure_2024}" --no-auth-warning SET test-key "test-value-$(date +%s)" 2>/dev/null)
GET_RESULT=$(docker exec wrfcoin-redis redis-cli -a "${REDIS_PASSWORD:-wrfcoin_secure_2024}" --no-auth-warning GET test-key 2>/dev/null)
if [[ "$SET_RESULT" == "OK" ]] && [[ "$GET_RESULT" == test-value-* ]]; then
    echo "PASS"
    RESULTS["Redis Operations"]="PASS"
    ((PASSED++))
else
    echo "FAIL"
    RESULTS["Redis Operations"]="FAIL"
    ((FAILED++))
fi

# Feature 7: Generic API Endpoint
if test_feature "Generic API Endpoint" "Dynamic API routing" "http://localhost:3001/api/status"; then
    ((PASSED++))
else
    ((FAILED++))
fi

# Feature 8: OPTIONS preflight (CORS)
echo -n "Testing: CORS Preflight ... "
OPTIONS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS http://localhost:3001/health 2>/dev/null || echo "000")
if [ "$OPTIONS_CODE" == "200" ]; then
    echo "PASS (HTTP $OPTIONS_CODE)"
    RESULTS["CORS Preflight"]="PASS"
    ((PASSED++))
else
    echo "FAIL (HTTP $OPTIONS_CODE)"
    RESULTS["CORS Preflight"]="FAIL"
    ((FAILED++))
fi

echo ""
echo "=================================="
echo "Feature Validation Summary"
echo "=================================="
echo "Total Tests: $TOTAL"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Pass Rate: $(( (PASSED * 100) / TOTAL ))%"
echo ""

# Generate JSON report
cat > "$REPORT_FILE" << EOF
{
  "task": "122.4",
  "description": "Core Feature Validation",
  "timestamp": "$TIMESTAMP",
  "summary": {
    "total": $TOTAL,
    "passed": $PASSED,
    "failed": $FAILED,
    "pass_rate": "$(( (PASSED * 100) / TOTAL ))%"
  },
  "features": [
    {"name": "Backend API Health", "status": "${RESULTS['Backend API Health']:-SKIP}"},
    {"name": "Cross-Chain Bridge API", "status": "${RESULTS['Cross-Chain Bridge API']:-SKIP}"},
    {"name": "Prometheus Metrics", "status": "${RESULTS['Prometheus Metrics']:-SKIP}"},
    {"name": "Prometheus API Query", "status": "${RESULTS['Prometheus API Query']:-SKIP}"},
    {"name": "Redis Cache", "status": "${RESULTS['Redis Cache']:-SKIP}"},
    {"name": "Redis Operations", "status": "${RESULTS['Redis Operations']:-SKIP}"},
    {"name": "Generic API Endpoint", "status": "${RESULTS['Generic API Endpoint']:-SKIP}"},
    {"name": "CORS Preflight", "status": "${RESULTS['CORS Preflight']:-SKIP}"}
  ],
  "verdict": "$([ $PASSED -ge 6 ] && echo 'PASS' || echo 'FAIL')"
}
EOF

echo "Report saved to: $REPORT_FILE"
echo ""

# Exit with appropriate code
if [ $PASSED -ge 6 ]; then
    echo "VERDICT: PASS (6+ features working)"
    exit 0
else
    echo "VERDICT: FAIL (Less than 6 features working)"
    exit 1
fi
