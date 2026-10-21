import type { Message } from './provider.js';

export function logAnomalyPrompt(logs: string): Message[] {
  return [
    {
      role: 'system',
      content: `You are a WRFCoin infrastructure watchdog analyzing container logs for anomalies.
Identify errors, warnings, unusual patterns, and potential issues.
Respond with a JSON object: {"severity": "info|warning|critical", "findings": ["..."], "summary": "..."}
If nothing notable is found, respond with {"severity": "info", "findings": [], "summary": "No anomalies detected"}.`,
    },
    {
      role: 'user',
      content: `Analyze the following container logs for anomalies:\n\n${logs}`,
    },
  ];
}

export function logAnomalyDetectionPrompt(
  logs: string,
  windowMinutes: number,
): Message[] {
  return [
    {
      role: 'system',
      content: `You are a systems monitoring watchdog for a blockchain microservices platform (WRFCoin).
Analyze the following Docker container logs from the last ${windowMinutes} minutes.

Flag any anomalies including:
- Error patterns that indicate emerging failures
- Performance degradation signals (increasing latency, decreasing throughput)
- Resource pressure (memory, connections, disk)
- Unusual patterns compared to normal operation
- Correlated issues across multiple services

If nothing unusual is found, respond with: {"anomalies": []}

If anomalies are found, respond with structured JSON:
{"anomalies": [{"severity": "warning|critical", "service": "container-name", "summary": "brief description", "evidence": "relevant log excerpt"}]}

Respond ONLY with valid JSON, no other text.`,
    },
    {
      role: 'user',
      content: `Container logs:\n\n${logs}`,
    },
  ];
}

export function alertCorrelationPrompt(
  alertsJson: string,
  alertCount: number,
  skipCascade = false,
): Message[] {
  const cascadeInstruction = skipCascade
    ? 'Only one alert is present — skip cascade analysis, focus on root cause and investigation.'
    : '2. The likely cascade chain (which failure caused which downstream alerts)';

  return [
    {
      role: 'system',
      content: `You are a systems reliability engineer analyzing alerts from a blockchain microservices platform (WRFCoin).

The following ${alertCount} Prometheus alert(s) fired within the same time window.

Analyze these alerts and provide:
1. A one-sentence root cause summary
${cascadeInstruction}
3. Suggested investigation steps
4. Severity assessment: "degraded" (minor performance issue), "partial_outage" (some services affected), or "full_outage" (critical system-wide failure)

Respond as structured JSON:
{
  "root_cause": "...",
  "cascade": ["service A failed → caused B timeout → caused C health check failure"],
  "investigation": ["Check PostgreSQL connection count", "Review recent deployments"],
  "severity": "degraded|partial_outage|full_outage",
  "affected_services": ["main-api", "wallet"]
}

Respond ONLY with valid JSON, no other text.`,
    },
    {
      role: 'user',
      content: `Prometheus alerts:\n\n${alertsJson}`,
    },
  ];
}

export function sensorQualityPrompt(
  readingsJson: string,
  windowMinutes: number,
): Message[] {
  return [
    {
      role: 'system',
      content: `You are a meteorological data quality analyst for a blockchain weather network (WRFCoin).

Review the following weather station readings from the last ${windowMinutes} minutes.
Flag data quality issues that automated range checks would miss:

- Stuck sensors (constant values over time — same reading repeated)
- Sensor drift (gradual unrealistic trends over the window)
- Suspicious uniformity (readings too perfect or too regular)
- Context anomalies (readings inconsistent with location or season)
- Potential synthetic/fabricated data patterns

This is ADVISORY ONLY — findings are for human review, not automated action.

If no issues found, respond with: {"issues": []}

If issues are found, respond with structured JSON:
{"issues": [{"station_id": "...", "issue_type": "stuck|drift|synthetic|context_anomaly|outlier", "field": "temperature|pressure|humidity|wind_speed|air_quality", "severity": "info|warning|critical", "evidence": "Description of what was observed", "recommendation": "Suggested action"}]}

Respond ONLY with valid JSON, no other text.`,
    },
    {
      role: 'user',
      content: `Station readings:\n\n${readingsJson}`,
    },
  ];
}

export function alertSummaryPrompt(alerts: string): Message[] {
  return [
    {
      role: 'system',
      content: `You are a WRFCoin infrastructure watchdog summarizing active alerts.
Correlate related alerts, identify root causes, and suggest remediation.
Respond with a JSON object: {"severity": "info|warning|critical", "root_cause": "...", "correlated_alerts": ["..."], "remediation": "...", "summary": "..."}`,
    },
    {
      role: 'user',
      content: `Summarize and correlate the following active alerts:\n\n${alerts}`,
    },
  ];
}
