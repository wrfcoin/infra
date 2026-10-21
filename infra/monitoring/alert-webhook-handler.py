#!/usr/bin/env python3
"""
Wrfcoin Blockchain Alert Webhook Handler
Processes AlertManager webhooks and enriches them with trace correlation data
"""

import json
import logging
import os
import requests
import time
import hmac
import hashlib
from datetime import datetime, timedelta
from flask import Flask, request, jsonify
from typing import Dict, List, Optional, Any
from urllib.parse import quote, urlencode

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Configuration
JAEGER_QUERY_URL = os.getenv('JAEGER_QUERY_URL', 'http://localhost:16686')
TEMPO_QUERY_URL = os.getenv('TEMPO_QUERY_URL', 'http://localhost:3200')
GRAFANA_URL = os.getenv('GRAFANA_URL', 'http://localhost:3000')
SLACK_WEBHOOK_URL = os.getenv('SLACK_WEBHOOK_URL', '')
DISCORD_WEBHOOK_URL = os.getenv('DISCORD_WEBHOOK_URL', '')
WEBHOOK_HMAC_SECRET = os.getenv('WEBHOOK_HMAC_SECRET', '')
MAX_SKEW_SECONDS = int(os.getenv('WEBHOOK_MAX_SKEW_SECONDS', '300'))


def verify_hmac_request(req) -> bool:
    if not WEBHOOK_HMAC_SECRET:
        logger.error("WEBHOOK_HMAC_SECRET is not configured")
        return False

    timestamp = req.headers.get('X-WRF-Timestamp', '')
    signature = req.headers.get('X-WRF-Signature', '')
    if not timestamp or not signature:
        return False

    try:
        ts = int(timestamp)
    except ValueError:
        return False

    now = int(time.time())
    if abs(now - ts) > MAX_SKEW_SECONDS:
        return False

    body = req.get_data(cache=True, as_text=False) or b''
    signed_payload = timestamp.encode('utf-8') + b'.' + body
    digest = hmac.new(
        WEBHOOK_HMAC_SECRET.encode('utf-8'),
        signed_payload,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(digest, signature)

class TraceCorrelator:
    """Correlates alerts with distributed traces"""
    
    def __init__(self, jaeger_url: str, tempo_url: str):
        self.jaeger_url = jaeger_url
        self.tempo_url = tempo_url
        
    def get_related_traces(self, alert: Dict[str, Any], time_window_minutes: int = 15) -> Optional[Dict]:
        """
        Find traces related to the alert timeframe and context
        """
        try:
            # Extract alert timing
            starts_at = datetime.fromisoformat(alert['startsAt'].replace('Z', '+00:00'))
            end_time = starts_at + timedelta(minutes=time_window_minutes)
            start_time = starts_at - timedelta(minutes=time_window_minutes)
            
            # Build trace query based on alert labels
            service_name = self._extract_service_name(alert)
            operation_name = self._extract_operation_name(alert)
            
            # Query Jaeger for traces
            trace_data = self._query_jaeger_traces(
                service_name, operation_name, start_time, end_time, alert
            )
            
            if trace_data:
                return {
                    'backend': 'jaeger',
                    'traces': trace_data,
                    'query_url': self._build_jaeger_url(service_name, operation_name, start_time, end_time, alert)
                }
            
            # Fallback to Tempo if Jaeger fails
            tempo_data = self._query_tempo_traces(service_name, start_time, end_time, alert)
            if tempo_data:
                return {
                    'backend': 'tempo',
                    'traces': tempo_data,
                    'query_url': self._build_tempo_url(service_name, start_time, end_time)
                }
                
            return None
            
        except Exception as e:
            logger.error(f"Error correlating traces for alert: {e}")
            return None
    
    def _extract_service_name(self, alert: Dict[str, Any]) -> str:
        """Extract service name from alert labels"""
        labels = alert.get('labels', {})
        
        # Try common label patterns
        if 'service' in labels:
            return labels['service']
        elif 'job' in labels:
            return labels['job']
        elif 'category' in labels:
            category_map = {
                'blockchain_core': 'wrfcoin-blockchain',
                'consensus': 'wrfcoin-blockchain',
                'cross_chain': 'wrfcoin-bridge',
                'api': 'wrfcoin-api',
                'weather': 'wrfcoin-weather',
                'security': 'wrfcoin-security',
                'network': 'wrfcoin-blockchain'
            }
            return category_map.get(labels['category'], 'wrfcoin-blockchain')
        
        return 'wrfcoin-blockchain'  # Default fallback
    
    def _extract_operation_name(self, alert: Dict[str, Any]) -> Optional[str]:
        """Extract operation name from alert context"""
        labels = alert.get('labels', {})
        annotations = alert.get('annotations', {})
        
        # Try to extract from trace query annotation
        trace_query = annotations.get('trace_query', '')
        if 'operation.name' in trace_query:
            # Extract operation name from trace query
            parts = trace_query.split('operation.name=')
            if len(parts) > 1:
                return parts[1].split(' ')[0].strip('"\'')
        
        # Map alert names to operations
        alert_name = labels.get('alertname', '')
        operation_map = {
            'BlockProductionStalled': 'block_processing',
            'HighBlockProcessingTime': 'block_processing',
            'ConsensusRoundTimeout': 'consensus_round',
            'CrossChainBridgeFailure': 'bridge_transfer',
            'HSMOperationFailure': 'hsm_operation',
            'WeatherDataQualityDegraded': 'data_validation'
        }
        
        return operation_map.get(alert_name)
    
    def _query_jaeger_traces(self, service: str, operation: Optional[str], 
                           start_time: datetime, end_time: datetime, 
                           alert: Dict[str, Any]) -> Optional[List[Dict]]:
        """Query Jaeger for traces"""
        try:
            # Build Jaeger query parameters
            params = {
                'service': service,
                'start': int(start_time.timestamp() * 1000000),  # microseconds
                'end': int(end_time.timestamp() * 1000000),
                'limit': 50
            }
            
            if operation:
                params['operation'] = operation
            
            # Add tags from alert context
            tags = self._build_trace_tags(alert)
            if tags:
                params['tags'] = json.dumps(tags)
            
            # Query Jaeger API
            response = requests.get(
                f"{self.jaeger_url}/api/traces",
                params=params,
                timeout=10
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('data', [])
            else:
                logger.warning(f"Jaeger query failed: {response.status_code}")
                return None
                
        except Exception as e:
            logger.error(f"Error querying Jaeger: {e}")
            return None
    
    def _query_tempo_traces(self, service: str, start_time: datetime, 
                          end_time: datetime, alert: Dict[str, Any]) -> Optional[List[Dict]]:
        """Query Tempo for traces"""
        try:
            # Build TraceQL query
            query_parts = [f'{{ .service.name = "{service}" }}']
            
            # Add additional filters from alert
            labels = alert.get('labels', {})
            if 'validator_id' in labels:
                query_parts.append(f'.validator_id = "{labels["validator_id"]}"')
            
            traceql_query = ' && '.join(query_parts)
            
            params = {
                'q': traceql_query,
                'start': int(start_time.timestamp()),
                'end': int(end_time.timestamp())
            }
            
            response = requests.get(
                f"{self.tempo_url}/api/search",
                params=params,
                timeout=10
            )
            
            if response.status_code == 200:
                return response.json().get('traces', [])
            else:
                logger.warning(f"Tempo query failed: {response.status_code}")
                return None
                
        except Exception as e:
            logger.error(f"Error querying Tempo: {e}")
            return None
    
    def _build_trace_tags(self, alert: Dict[str, Any]) -> Dict[str, str]:
        """Build trace tags from alert context"""
        labels = alert.get('labels', {})
        tags = {}
        
        # Map alert labels to trace tags
        tag_mappings = {
            'validator_id': 'validator.id',
            'source_chain': 'source.chain',
            'target_chain': 'target.chain',
            'device_id': 'device.id',
            'location': 'location'
        }
        
        for label_key, tag_key in tag_mappings.items():
            if label_key in labels:
                tags[tag_key] = labels[label_key]
        
        return tags
    
    def _build_jaeger_url(self, service: str, operation: Optional[str], 
                         start_time: datetime, end_time: datetime, 
                         alert: Dict[str, Any]) -> str:
        """Build Jaeger UI URL for the traces"""
        params = {
            'service': service,
            'start': int(start_time.timestamp() * 1000000),
            'end': int(end_time.timestamp() * 1000000)
        }
        
        if operation:
            params['operation'] = operation
        
        # Add tags
        tags = self._build_trace_tags(alert)
        if tags:
            tag_params = [f"{k}={v}" for k, v in tags.items()]
            params['tags'] = '{"' + '","'.join(tag_params) + '"}'
        
        return f"{self.jaeger_url}/search?" + urlencode(params)
    
    def _build_tempo_url(self, service: str, start_time: datetime, end_time: datetime) -> str:
        """Build Tempo UI URL for the traces"""
        query = f'{{ .service.name = "{service}" }}'
        params = {
            'q': query,
            'start': int(start_time.timestamp() * 1000),
            'end': int(end_time.timestamp() * 1000)
        }
        
        return f"{self.tempo_url}/explore?" + urlencode(params)

class AlertEnricher:
    """Enriches alerts with additional context and trace correlation"""
    
    def __init__(self, trace_correlator: TraceCorrelator):
        self.trace_correlator = trace_correlator
    
    def enrich_alert(self, alert: Dict[str, Any]) -> Dict[str, Any]:
        """Enrich alert with trace correlation and additional context"""
        enriched_alert = alert.copy()
        
        try:
            # Add trace correlation
            trace_info = self.trace_correlator.get_related_traces(alert)
            if trace_info:
                enriched_alert['trace_correlation'] = trace_info
            
            # Add severity score
            enriched_alert['severity_score'] = self._calculate_severity_score(alert)
            
            # Add impact assessment
            enriched_alert['impact_assessment'] = self._assess_impact(alert)
            
            # Add suggested actions
            enriched_alert['suggested_actions'] = self._suggest_actions(alert)
            
            return enriched_alert
            
        except Exception as e:
            logger.error(f"Error enriching alert: {e}")
            return alert
    
    def _calculate_severity_score(self, alert: Dict[str, Any]) -> int:
        """Calculate numerical severity score (1-10)"""
        labels = alert.get('labels', {})
        severity = labels.get('severity', 'warning')
        category = labels.get('category', 'unknown')
        
        base_scores = {
            'critical': 8,
            'warning': 5,
            'info': 2
        }
        
        category_multipliers = {
            'security': 1.5,
            'blockchain_core': 1.3,
            'consensus': 1.3,
            'cross_chain': 1.2,
            'api': 1.0,
            'network': 1.1,
            'weather': 0.8,
            'performance': 0.9
        }
        
        base_score = base_scores.get(severity, 3)
        multiplier = category_multipliers.get(category, 1.0)
        
        return min(10, int(base_score * multiplier))
    
    def _assess_impact(self, alert: Dict[str, Any]) -> Dict[str, Any]:
        """Assess the potential impact of the alert"""
        labels = alert.get('labels', {})
        category = labels.get('category', 'unknown')
        severity = labels.get('severity', 'warning')
        
        impact_map = {
            'security': {
                'user_impact': 'High - potential security breach',
                'business_impact': 'Critical - reputation and compliance risk',
                'technical_impact': 'Variable - depends on exploit'
            },
            'blockchain_core': {
                'user_impact': 'High - transaction processing affected',
                'business_impact': 'High - network functionality compromised',
                'technical_impact': 'High - core blockchain operations'
            },
            'consensus': {
                'user_impact': 'Medium - potential network instability',
                'business_impact': 'High - network consensus at risk',
                'technical_impact': 'High - validator operations affected'
            },
            'cross_chain': {
                'user_impact': 'Medium - cross-chain transfers affected',
                'business_impact': 'Medium - interoperability features limited',
                'technical_impact': 'Medium - bridge operations impacted'
            }
        }
        
        return impact_map.get(category, {
            'user_impact': 'Low - minimal user impact expected',
            'business_impact': 'Low - operational concern only',
            'technical_impact': 'Low - monitoring or metrics issue'
        })
    
    def _suggest_actions(self, alert: Dict[str, Any]) -> List[str]:
        """Suggest immediate actions based on alert type"""
        labels = alert.get('labels', {})
        alert_name = labels.get('alertname', '')
        category = labels.get('category', '')
        
        action_map = {
            'BlockProductionStalled': [
                "Check validator status and connectivity",
                "Verify consensus mechanism health",
                "Review recent network partition alerts",
                "Check validator resource usage (CPU, memory, disk)"
            ],
            'ConsensusRoundTimeout': [
                "Investigate validator performance issues",
                "Check network latency between validators",
                "Review validator resource allocation",
                "Verify time synchronization across nodes"
            ],
            'CrossChainBridgeFailure': [
                "Check bridge liquidity levels",
                "Verify external chain connectivity",
                "Review recent bridge transactions for patterns",
                "Check multisig wallet status"
            ],
            'HSMOperationFailure': [
                "IMMEDIATE: Verify HSM physical security",
                "Check HSM network connectivity",
                "Review HSM operation logs",
                "Contact HSM vendor support if needed"
            ],
            'HighAPIErrorRate': [
                "Check database connectivity and performance",
                "Review recent deployments for regressions",
                "Scale API instances if resource constrained",
                "Analyze error patterns in application logs"
            ]
        }
        
        # Default actions by category
        category_actions = {
            'security': [
                "Review security logs immediately",
                "Check for unauthorized access attempts",
                "Verify all security mechanisms are functioning"
            ],
            'performance': [
                "Check system resource utilization",
                "Review recent configuration changes",
                "Consider scaling resources if needed"
            ]
        }
        
        actions = action_map.get(alert_name, category_actions.get(category, [
            "Review alert details and recent changes",
            "Check system logs for error patterns",
            "Monitor alert progression"
        ]))
        
        return actions

# Initialize components
trace_correlator = TraceCorrelator(JAEGER_QUERY_URL, TEMPO_QUERY_URL)
alert_enricher = AlertEnricher(trace_correlator)

@app.route('/webhook', methods=['POST'])
def handle_webhook():
    """Handle AlertManager webhook"""
    try:
        if not verify_hmac_request(request):
            return jsonify({'error': 'Unauthorized webhook request'}), 401

        data = request.get_json()
        
        if not data:
            return jsonify({'error': 'No data provided'}), 400
        
        # Process each alert
        enriched_alerts = []
        for alert in data.get('alerts', []):
            enriched_alert = alert_enricher.enrich_alert(alert)
            enriched_alerts.append(enriched_alert)
        
        # Log enriched alerts
        logger.info(f"Processed {len(enriched_alerts)} alerts")
        
        # Send to downstream systems
        if SLACK_WEBHOOK_URL:
            send_to_slack(enriched_alerts)
        
        if DISCORD_WEBHOOK_URL:
            send_to_discord(enriched_alerts)
        
        return jsonify({
            'status': 'success',
            'processed_alerts': len(enriched_alerts)
        })
        
    except Exception as e:
        logger.error(f"Error processing webhook: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/webhook/critical', methods=['POST'])
def handle_critical_webhook():
    """Handle critical alerts with enhanced processing"""
    try:
        if not verify_hmac_request(request):
            return jsonify({'error': 'Unauthorized webhook request'}), 401

        data = request.get_json()
        
        # Enhanced processing for critical alerts
        for alert in data.get('alerts', []):
            if alert.get('labels', {}).get('severity') == 'critical':
                # Immediate trace correlation
                trace_info = trace_correlator.get_related_traces(alert, time_window_minutes=30)
                
                # Log critical alert with trace context
                logger.critical(f"CRITICAL ALERT: {alert.get('labels', {}).get('alertname')} - "
                              f"Trace correlation: {trace_info is not None}")
                
                # Send immediate notifications
                send_critical_notification(alert, trace_info)
        
        return jsonify({'status': 'critical_processed'})
        
    except Exception as e:
        logger.error(f"Error processing critical webhook: {e}")
        return jsonify({'error': str(e)}), 500

def send_to_slack(alerts: List[Dict[str, Any]]):
    """Send enriched alerts to Slack"""
    if not SLACK_WEBHOOK_URL:
        return
    
    try:
        for alert in alerts:
            trace_info = alert.get('trace_correlation', {})
            
            message = {
                "text": f"Wrfcoin Alert: {alert.get('labels', {}).get('alertname')}",
                "attachments": [{
                    "color": "danger" if alert.get('labels', {}).get('severity') == 'critical' else "warning",
                    "fields": [
                        {
                            "title": "Summary",
                            "value": alert.get('annotations', {}).get('summary', ''),
                            "short": False
                        },
                        {
                            "title": "Severity Score",
                            "value": str(alert.get('severity_score', 'Unknown')),
                            "short": True
                        }
                    ]
                }]
            }
            
            if trace_info:
                message["attachments"][0]["fields"].append({
                    "title": "Trace Analysis",
                    "value": f"<{trace_info.get('query_url', '')}|View {trace_info.get('backend', 'traces').title()}>",
                    "short": True
                })
            
            requests.post(SLACK_WEBHOOK_URL, json=message, timeout=10)
            
    except Exception as e:
        logger.error(f"Error sending to Slack: {e}")

def send_to_discord(alerts: List[Dict[str, Any]]):
    """Send enriched alerts to Discord"""
    if not DISCORD_WEBHOOK_URL:
        return
    
    try:
        for alert in alerts:
            trace_info = alert.get('trace_correlation', {})
            
            embed = {
                "title": alert.get('labels', {}).get('alertname', 'Alert'),
                "description": alert.get('annotations', {}).get('summary', ''),
                "color": 16711680 if alert.get('labels', {}).get('severity') == 'critical' else 16753920,
                "fields": [
                    {
                        "name": "Severity Score",
                        "value": str(alert.get('severity_score', 'Unknown')),
                        "inline": True
                    }
                ]
            }
            
            if trace_info:
                embed["url"] = trace_info.get('query_url', '')
                embed["fields"].append({
                    "name": "Trace Backend",
                    "value": trace_info.get('backend', 'Unknown').title(),
                    "inline": True
                })
            
            requests.post(DISCORD_WEBHOOK_URL, json={"embeds": [embed]}, timeout=10)
            
    except Exception as e:
        logger.error(f"Error sending to Discord: {e}")

def send_critical_notification(alert: Dict[str, Any], trace_info: Optional[Dict]):
    """Send immediate notification for critical alerts"""
    logger.critical(f"CRITICAL ALERT TRIGGERED: {alert}")
    # Additional critical alert handling can be added here

@app.route('/health', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat(),
        'jaeger_url': JAEGER_QUERY_URL,
        'tempo_url': TEMPO_QUERY_URL
    })

@app.route('/metrics', methods=['GET'])
def metrics():
    """Prometheus metrics endpoint"""
    return jsonify({
        'webhook_requests_total': 0,
        'webhook_errors_total': 0,
        'trace_correlations_total': 0
    })

if __name__ == '__main__':
    port = int(os.getenv('PORT', 5001))
    debug = os.getenv('DEBUG', 'false').lower() == 'true'
    
    logger.info(f"Starting Wrfcoin Alert Webhook Handler on port {port}")
    logger.info(f"Jaeger URL: {JAEGER_QUERY_URL}")
    logger.info(f"Tempo URL: {TEMPO_QUERY_URL}")
    
    app.run(host='0.0.0.0', port=port, debug=debug)
