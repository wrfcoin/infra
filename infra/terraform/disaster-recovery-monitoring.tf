# Disaster Recovery Monitoring and Alerting
# Location: infra/terraform/disaster-recovery-monitoring.tf
# Purpose: Comprehensive monitoring for DR metrics and SLA compliance

# CloudWatch Dashboard for DR metrics
resource "aws_cloudwatch_dashboard" "disaster_recovery" {
  dashboard_name = "${local.name_prefix}-disaster-recovery"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/Route53", "HealthCheckStatus", "HealthCheckId", aws_route53_health_check.primary_region.id],
            [".", ".", ".", aws_route53_health_check.secondary_region.id]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Regional Health Check Status"
          view   = "timeSeries"
          yAxis = {
            left = {
              min = 0
              max = 1
            }
          }
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", module.database.db_cluster_identifier],
            [".", "CPUUtilization", ".", "."],
            [".", "FreeableMemory", ".", "."]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Database Performance Metrics"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/EKS", "cluster_failed_request_count", "cluster_name", module.eks.cluster_name],
            [".", "cluster_request_total", ".", "."]
          ]
          period = 300
          stat   = "Sum"
          region = var.aws_region
          title  = "EKS Cluster Health"
          view   = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/ElastiCache", "CPUUtilization", "ReplicationGroupId", aws_elasticache_replication_group.redis.replication_group_id],
            [".", "DatabaseMemoryUsagePercentage", ".", "."],
            [".", "NetworkBytesIn", ".", "."],
            [".", "NetworkBytesOut", ".", "."]
          ]
          period = 300
          stat   = "Average"
          region = var.aws_region
          title  = "Redis Performance"
          view   = "timeSeries"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 12
        width  = 24
        height = 6

        properties = {
          query   = "SOURCE '/aws/eks/${local.name_prefix}/blockchain' | fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 100"
          region  = var.aws_region
          title   = "Recent Blockchain Errors"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Custom metrics for DR testing
resource "aws_cloudwatch_log_metric_filter" "dr_test_success" {
  name           = "${local.name_prefix}-dr-test-success"
  log_group_name = aws_cloudwatch_log_group.dr_tests.name
  pattern        = "[timestamp, level=\"INFO\", component=\"DR-Test\", message=\"*completed successfully*\"]"

  metric_transformation {
    name      = "DRTestSuccess"
    namespace = "Wrfcoin/DisasterRecovery"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "dr_test_failure" {
  name           = "${local.name_prefix}-dr-test-failure"
  log_group_name = aws_cloudwatch_log_group.dr_tests.name
  pattern        = "[timestamp, level=\"ERROR\", component=\"DR-Test\", message=\"*failed*\"]"

  metric_transformation {
    name      = "DRTestFailure"
    namespace = "Wrfcoin/DisasterRecovery"
    value     = "1"
  }
}

resource "aws_cloudwatch_log_metric_filter" "failover_duration" {
  name           = "${local.name_prefix}-failover-duration"
  log_group_name = aws_cloudwatch_log_group.dr_tests.name
  pattern        = "[timestamp, level=\"INFO\", component=\"DR-Test\", message=\"*failover completed in*\", duration, ...]"

  metric_transformation {
    name      = "FailoverDuration"
    namespace = "Wrfcoin/DisasterRecovery"
    value     = "$duration"
    unit      = "Seconds"
  }
}

# Log group for DR test results
resource "aws_cloudwatch_log_group" "dr_tests" {
  name              = "/wrfcoin/disaster-recovery/tests"
  retention_in_days = 90

  tags = local.common_tags
}

# Uptime monitoring using CloudWatch Synthetics
resource "aws_synthetics_canary" "api_uptime" {
  name                 = "${local.name_prefix}-api-uptime"
  artifact_s3_location = "s3://${aws_s3_bucket.synthetics_artifacts.bucket}/"
  execution_role_arn   = aws_iam_role.synthetics_execution.arn
  handler              = "apiCanaryBlueprint.handler"
  zip_file            = "synthetics/api-uptime-canary.zip"
  runtime_version     = "syn-nodejs-puppeteer-6.2"

  run_config {
    timeout_in_seconds    = 60
    memory_in_mb         = 960
    active_tracing       = true
  }

  schedule {
    expression                = "rate(5 minutes)"
    duration_in_seconds      = 0
  }

  failure_retention_period = 30
  success_retention_period = 30

  tags = local.common_tags
}

# S3 bucket for synthetics artifacts
resource "aws_s3_bucket" "synthetics_artifacts" {
  bucket        = "${local.name_prefix}-synthetics-artifacts"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_encryption_configuration" "synthetics_artifacts" {
  bucket = aws_s3_bucket.synthetics_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# IAM role for Synthetics execution
resource "aws_iam_role" "synthetics_execution" {
  name = "${local.name_prefix}-synthetics-execution"

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

  tags = local.common_tags
}

resource "aws_iam_role_policy" "synthetics_execution" {
  name = "${local.name_prefix}-synthetics-execution"
  role = aws_iam_role.synthetics_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetBucketLocation",
          "s3:ListAllMyBuckets",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "xray:PutTraceSegments"
        ]
        Resource = "*"
      }
    ]
  })
}

# SLA compliance tracking
resource "aws_cloudwatch_metric_alarm" "sla_compliance" {
  alarm_name          = "${local.name_prefix}-sla-compliance"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "SuccessPercent"
  namespace           = "CloudWatchSynthetics"
  period              = "300"
  statistic           = "Average"
  threshold           = "99.9"
  alarm_description   = "SLA compliance below 99.9%"
  alarm_actions       = [aws_sns_topic.sla_alerts.arn]
  treat_missing_data  = "breaching"

  dimensions = {
    CanaryName = aws_synthetics_canary.api_uptime.name
  }

  tags = local.common_tags
}

# DR-specific alarms
resource "aws_cloudwatch_metric_alarm" "rto_exceeded" {
  alarm_name          = "${local.name_prefix}-rto-exceeded"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "FailoverDuration"
  namespace           = "Wrfcoin/DisasterRecovery"
  period              = "300"
  statistic           = "Maximum"
  threshold           = "900"  # 15 minutes RTO
  alarm_description   = "DR failover time exceeded RTO of 15 minutes"
  alarm_actions       = [aws_sns_topic.sla_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "dr_test_failure" {
  alarm_name          = "${local.name_prefix}-dr-test-failure"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "DRTestFailure"
  namespace           = "Wrfcoin/DisasterRecovery"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "DR test failure detected"
  alarm_actions       = [aws_sns_topic.sla_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "cross_region_replication_lag" {
  alarm_name          = "${local.name_prefix}-replication-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "ReplicationLag"
  namespace           = "AWS/RDS"
  period              = "60"
  statistic           = "Average"
  threshold           = "300"  # 5 minutes RPO
  alarm_description   = "Cross-region replication lag exceeded RPO of 5 minutes"
  alarm_actions       = [aws_sns_topic.sla_alerts.arn]

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.database_replica.id
  }

  tags = local.common_tags
}

# SNS topic for SLA alerts
resource "aws_sns_topic" "sla_alerts" {
  name = "${local.name_prefix}-sla-alerts"

  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "sla_email" {
  topic_arn = aws_sns_topic.sla_alerts.arn
  protocol  = "email"
  endpoint  = var.sla_alert_email
}

# EventBridge rule for automated DR responses
resource "aws_cloudwatch_event_rule" "regional_failure" {
  name        = "${local.name_prefix}-regional-failure"
  description = "Trigger automated response on regional failure"

  event_pattern = jsonencode({
    source      = ["aws.route53"]
    detail-type = ["Route 53 Health Check Status Changed"]
    detail = {
      status-list = ["FAILURE"]
      health-check-id = [aws_route53_health_check.primary_region.id]
    }
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "dr_lambda" {
  rule      = aws_cloudwatch_event_rule.regional_failure.name
  target_id = "TriggerDRResponse"
  arn       = aws_lambda_function.dr_automation.arn
}

# Lambda function for automated DR responses
resource "aws_lambda_function" "dr_automation" {
  filename         = "dr-automation.zip"
  function_name    = "${local.name_prefix}-dr-automation"
  role            = aws_iam_role.dr_lambda_execution.arn
  handler         = "index.handler"
  runtime         = "python3.11"
  timeout         = 300

  environment {
    variables = {
      SECONDARY_REGION = var.secondary_aws_region
      SNS_TOPIC_ARN   = aws_sns_topic.sla_alerts.arn
      CLUSTER_NAME    = module.eks.cluster_name
    }
  }

  tags = local.common_tags
}

# IAM role for DR Lambda function
resource "aws_iam_role" "dr_lambda_execution" {
  name = "${local.name_prefix}-dr-lambda-execution"

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

  tags = local.common_tags
}

resource "aws_iam_role_policy" "dr_lambda_execution" {
  name = "${local.name_prefix}-dr-lambda-execution"
  role = aws_iam_role.dr_lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "sns:Publish",
          "eks:DescribeCluster",
          "eks:UpdateClusterConfig",
          "autoscaling:UpdateAutoScalingGroup",
          "route53:ChangeResourceRecordSets",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dr_automation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.regional_failure.arn
}

# Outputs for DR monitoring
output "dr_dashboard_url" {
  description = "CloudWatch dashboard URL for DR metrics"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.disaster_recovery.dashboard_name}"
}

output "synthetics_canary_name" {
  description = "CloudWatch Synthetics canary name"
  value       = aws_synthetics_canary.api_uptime.name
}

output "sla_alerts_topic_arn" {
  description = "SNS topic ARN for SLA alerts"
  value       = aws_sns_topic.sla_alerts.arn
}