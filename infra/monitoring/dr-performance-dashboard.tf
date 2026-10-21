# DR Performance Benchmarker Integration Dashboard
# Location: infra/monitoring/dr-performance-dashboard.tf
# Purpose: Extended monitoring for DR performance benchmarking and RTO/RPO tracking

# Custom metrics namespace for DR performance benchmarker
locals {
  dr_benchmarker_namespace = "WRFCoin/DR/Performance"
  performance_log_group    = "/wrfcoin/disaster-recovery/performance"
}

# CloudWatch Log Group for performance benchmarker
resource "aws_cloudwatch_log_group" "dr_performance_logs" {
  name              = local.performance_log_group
  retention_in_days = 90
  
  tags = {
    Name        = "${local.name_prefix}-dr-performance-logs"
    Component   = "DisasterRecovery"
    Environment = var.environment
    Purpose     = "PerformanceBenchmarking"
  }
}

# Custom metrics for RTO/RPO tracking
resource "aws_cloudwatch_log_metric_filter" "rto_performance" {
  name           = "${local.name_prefix}-rto-performance"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level, component=\"RTO\", actual_time, target_time, ...]"

  metric_transformation {
    name      = "RTOPerformance"
    namespace = local.dr_benchmarker_namespace
    value     = "$actual_time"
    unit      = "Seconds"
    
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "rpo_performance" {
  name           = "${local.name_prefix}-rpo-performance"  
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level, component=\"RPO\", actual_lag, target_lag, ...]"

  metric_transformation {
    name      = "RPOPerformance"
    namespace = local.dr_benchmarker_namespace
    value     = "$actual_lag"
    unit      = "Seconds"
    
    default_value = "0"
  }
}

# Benchmark execution metrics
resource "aws_cloudwatch_log_metric_filter" "benchmark_execution_time" {
  name           = "${local.name_prefix}-benchmark-execution-time"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"BENCHMARK\", message=\"*completed in*\", duration, ...]"

  metric_transformation {
    name      = "BenchmarkExecutionTime"
    namespace = local.dr_benchmarker_namespace  
    value     = "$duration"
    unit      = "Seconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "performance_score" {
  name           = "${local.name_prefix}-performance-score"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"SCORE\", overall_score, rto_score, rpo_score, ...]"

  metric_transformation {
    name      = "OverallPerformanceScore"
    namespace = local.dr_benchmarker_namespace
    value     = "$overall_score"
    unit      = "Percent"
  }
}

# Component-specific failover time metrics
resource "aws_cloudwatch_log_metric_filter" "database_failover_time" {
  name           = "${local.name_prefix}-database-failover-time"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"DATABASE\", message=\"*failover completed*\", duration, ...]"

  metric_transformation {
    name      = "DatabaseFailoverTime"
    namespace = local.dr_benchmarker_namespace
    value     = "$duration"
    unit      = "Seconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "dns_failover_time" {
  name           = "${local.name_prefix}-dns-failover-time"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"DNS\", message=\"*failover completed*\", duration, ...]"

  metric_transformation {
    name      = "DNSFailoverTime"
    namespace = local.dr_benchmarker_namespace
    value     = "$duration"
    unit      = "Seconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "k8s_failover_time" {
  name           = "${local.name_prefix}-k8s-failover-time"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"KUBERNETES\", message=\"*failover completed*\", duration, ...]"

  metric_transformation {
    name      = "KubernetesFailoverTime"
    namespace = local.dr_benchmarker_namespace
    value     = "$duration"
    unit      = "Seconds"
  }
}

# Cross-region replication performance metrics
resource "aws_cloudwatch_log_metric_filter" "s3_replication_time" {
  name           = "${local.name_prefix}-s3-replication-time"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"INFO\", component=\"S3_REPLICATION\", replication_time, ...]"

  metric_transformation {
    name      = "S3ReplicationTime"
    namespace = local.dr_benchmarker_namespace
    value     = "$replication_time"
    unit      = "Seconds"
  }
}

# Performance bottleneck detection
resource "aws_cloudwatch_log_metric_filter" "bottleneck_detected" {
  name           = "${local.name_prefix}-bottleneck-detected"
  log_group_name = aws_cloudwatch_log_group.dr_performance_logs.name
  pattern        = "[timestamp, level=\"WARN\", component=\"BOTTLENECK\", severity, ...]"

  metric_transformation {
    name      = "BottlenecksDetected"
    namespace = local.dr_benchmarker_namespace
    value     = "1"
    unit      = "Count"
  }
}

# Comprehensive DR Performance Dashboard
resource "aws_cloudwatch_dashboard" "dr_performance_benchmarker" {
  dashboard_name = "${local.name_prefix}-dr-performance-benchmarker"

  dashboard_body = jsonencode({
    widgets = [
      # RTO/RPO Compliance Overview
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            [local.dr_benchmarker_namespace, "RTOPerformance"],
            [".", "RPOPerformance"]
          ]
          period = 300
          stat   = "Maximum"
          region = var.aws_region
          title  = "RTO/RPO Performance Tracking"
          view   = "timeSeries"
          annotations = {
            horizontal = [
              {
                label = "RTO Target (15min)"
                value = 900
                color = "#d62728"
              },
              {
                label = "RPO Target (5min)"  
                value = 300
                color = "#ff7f0e"
              }
            ]
          }
          yAxis = {
            left = {
              min = 0
              max = 1200
            }
          }
        }
      },
      
      # Overall Performance Score
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            [local.dr_benchmarker_namespace, "OverallPerformanceScore"]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Overall DR Performance Score"
          view   = "singleValue"
          setPeriodToTimeRange = true
          annotations = {
            horizontal = [
              {
                label = "Target Score"
                value = 90
                color = "#2ca02c"
              }
            ]
          }
        }
      },

      # Component Failover Performance
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 24
        height = 6

        properties = {
          metrics = [
            [local.dr_benchmarker_namespace, "DatabaseFailoverTime"],
            [".", "DNSFailoverTime"],
            [".", "KubernetesFailoverTime"]
          ]
          period = 300
          stat   = "Maximum"
          region = var.aws_region
          title  = "Component Failover Times"
          view   = "timeSeries"
          annotations = {
            horizontal = [
              {
                label = "RTO Target"
                value = 900
                color = "#d62728"
              }
            ]
          }
        }
      },

      # Cross-Region Replication Performance
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/RDS", "ReplicationLag", "DBInstanceIdentifier", aws_db_instance.database_replica.id],
            [local.dr_benchmarker_namespace, "S3ReplicationTime"]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Cross-Region Replication Performance"
          view   = "timeSeries"
          annotations = {
            horizontal = [
              {
                label = "RPO Target"
                value = 300
                color = "#ff7f0e"
              }
            ]
          }
        }
      },

      # Benchmark Execution Metrics
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6

        properties = {
          metrics = [
            [local.dr_benchmarker_namespace, "BenchmarkExecutionTime"],
            [".", "BottlenecksDetected"]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "Benchmark Execution & Issues"
          view   = "timeSeries"
        }
      },

      # Performance Trend Analysis
      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 24
        height = 6

        properties = {
          metrics = [
            [local.dr_benchmarker_namespace, "RTOPerformance", { "stat": "Average" }],
            [".", "RPOPerformance", { "stat": "Average" }]
          ]
          period = 3600  # 1 hour periods for trend analysis
          stat   = "Average"
          region = var.aws_region
          title  = "Performance Trends (Hourly)"
          view   = "timeSeries"
          setPeriodToTimeRange = true
        }
      },

      # Recent Performance Logs
      {
        type   = "log"
        x      = 0
        y      = 24
        width  = 24
        height = 6

        properties = {
          query   = "SOURCE '${local.performance_log_group}' | fields @timestamp, component, message | filter level like /INFO|WARN|ERROR/ | sort @timestamp desc | limit 100"
          region  = var.aws_region
          title   = "Recent DR Performance Events"
        }
      }
    ]
  })

  tags = {
    Name        = "${local.name_prefix}-dr-performance-dashboard"
    Component   = "DisasterRecovery"
    Environment = var.environment
    Purpose     = "PerformanceBenchmarking"
  }
}

# Enhanced alarms for performance benchmarker
resource "aws_cloudwatch_metric_alarm" "rto_performance_degradation" {
  alarm_name          = "${local.name_prefix}-rto-performance-degradation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "RTOPerformance"
  namespace           = local.dr_benchmarker_namespace
  period              = "300"
  statistic           = "Maximum"
  threshold           = "720"  # 12 minutes (80% of 15min target)
  alarm_description   = "RTO performance approaching target threshold"
  alarm_actions       = [aws_sns_topic.dr_performance_alerts.arn]
  ok_actions          = [aws_sns_topic.dr_performance_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = {
    Name      = "${local.name_prefix}-rto-performance-alarm"
    Severity  = "Medium"
    Component = "DisasterRecovery"
  }
}

resource "aws_cloudwatch_metric_alarm" "rpo_performance_degradation" {
  alarm_name          = "${local.name_prefix}-rpo-performance-degradation"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "RPOPerformance"
  namespace           = local.dr_benchmarker_namespace
  period              = "300"
  statistic           = "Maximum"
  threshold           = "240"  # 4 minutes (80% of 5min target)
  alarm_description   = "RPO performance approaching target threshold"
  alarm_actions       = [aws_sns_topic.dr_performance_alerts.arn]
  ok_actions          = [aws_sns_topic.dr_performance_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = {
    Name      = "${local.name_prefix}-rpo-performance-alarm"
    Severity  = "Medium"
    Component = "DisasterRecovery"
  }
}

resource "aws_cloudwatch_metric_alarm" "performance_score_low" {
  alarm_name          = "${local.name_prefix}-performance-score-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "OverallPerformanceScore"
  namespace           = local.dr_benchmarker_namespace
  period              = "300"
  statistic           = "Average"
  threshold           = "80"  # 80% performance score
  alarm_description   = "Overall DR performance score below acceptable threshold"
  alarm_actions       = [aws_sns_topic.dr_performance_alerts.arn]
  treat_missing_data  = "breaching"

  tags = {
    Name      = "${local.name_prefix}-performance-score-alarm"
    Severity  = "High"
    Component = "DisasterRecovery"
  }
}

resource "aws_cloudwatch_metric_alarm" "bottlenecks_detected" {
  alarm_name          = "${local.name_prefix}-performance-bottlenecks"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "BottlenecksDetected"
  namespace           = local.dr_benchmarker_namespace
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Performance bottlenecks detected in DR infrastructure"
  alarm_actions       = [aws_sns_topic.dr_performance_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = {
    Name      = "${local.name_prefix}-bottleneck-alarm"
    Severity  = "Medium"
    Component = "DisasterRecovery"
  }
}

# SNS topic for performance alerts
resource "aws_sns_topic" "dr_performance_alerts" {
  name = "${local.name_prefix}-dr-performance-alerts"

  tags = {
    Name        = "${local.name_prefix}-dr-performance-alerts"
    Component   = "DisasterRecovery"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "dr_performance_email" {
  topic_arn = aws_sns_topic.dr_performance_alerts.arn
  protocol  = "email"
  endpoint  = var.dr_alert_email
}

# EventBridge rule for automated performance issue response
resource "aws_cloudwatch_event_rule" "performance_degradation" {
  name        = "${local.name_prefix}-performance-degradation"
  description = "Trigger automated response on DR performance degradation"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    detail-type   = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
      alarmName = [
        aws_cloudwatch_metric_alarm.rto_performance_degradation.alarm_name,
        aws_cloudwatch_metric_alarm.rpo_performance_degradation.alarm_name,
        aws_cloudwatch_metric_alarm.performance_score_low.alarm_name
      ]
    }
  })

  tags = {
    Name        = "${local.name_prefix}-performance-event-rule"
    Component   = "DisasterRecovery"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "performance_automation" {
  rule      = aws_cloudwatch_event_rule.performance_degradation.name
  target_id = "TriggerPerformanceResponse"
  arn       = aws_lambda_function.dr_performance_automation.arn
}

# Lambda function for automated performance response
resource "aws_lambda_function" "dr_performance_automation" {
  filename         = "dr-performance-automation.zip"
  function_name    = "${local.name_prefix}-dr-performance-automation"
  role            = aws_iam_role.dr_performance_lambda.arn
  handler         = "index.handler"
  runtime         = "python3.11"
  timeout         = 300

  environment {
    variables = {
      SNS_TOPIC_ARN         = aws_sns_topic.dr_performance_alerts.arn
      PERFORMANCE_LOG_GROUP = local.performance_log_group
      RTO_TARGET           = "900"
      RPO_TARGET           = "300"
    }
  }

  tags = {
    Name        = "${local.name_prefix}-dr-performance-lambda"
    Component   = "DisasterRecovery"
    Environment = var.environment
  }
}

# IAM role for performance automation Lambda
resource "aws_iam_role" "dr_performance_lambda" {
  name = "${local.name_prefix}-dr-performance-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${local.name_prefix}-dr-performance-lambda-role"
    Component   = "DisasterRecovery"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "dr_performance_lambda_policy" {
  name = "${local.name_prefix}-dr-performance-lambda-policy"
  role = aws_iam_role.dr_performance_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream", 
          "logs:PutLogEvents",
          "logs:FilterLogEvents"
        ]
        Resource = [
          "arn:aws:logs:${var.aws_region}:*:log-group:/aws/lambda/${local.name_prefix}-dr-performance-automation*",
          "arn:aws:logs:${var.aws_region}:*:log-group:${local.performance_log_group}*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.dr_performance_alerts.arn
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_performance_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dr_performance_automation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.performance_degradation.arn
}

# Outputs for DR performance monitoring
output "dr_performance_dashboard_url" {
  description = "CloudWatch dashboard URL for DR performance metrics"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.dr_performance_benchmarker.dashboard_name}"
}

output "dr_performance_log_group" {
  description = "CloudWatch log group for DR performance benchmarker"
  value       = aws_cloudwatch_log_group.dr_performance_logs.name
}

output "dr_performance_alerts_topic" {
  description = "SNS topic ARN for DR performance alerts"
  value       = aws_sns_topic.dr_performance_alerts.arn
}

# Variables for configuration
variable "dr_alert_email" {
  description = "Email address for DR performance alerts"
  type        = string
  default     = "devops@wrfcoin.com"
}

variable "environment" {
  description = "Environment name (production, staging, etc.)"
  type        = string
  default     = "production"
}