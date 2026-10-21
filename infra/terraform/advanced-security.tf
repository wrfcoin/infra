# Advanced Security Infrastructure for Wrfcoin
# Implements zero-trust architecture with comprehensive security controls

# AWS WAF for application-layer protection
resource "aws_wafv2_web_acl" "wrfcoin_waf" {
  name  = "${local.name_prefix}-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rate limiting rule
  rule {
    name     = "RateLimitRule"
    priority = 1

    override_action {
      none {}
    }

    statement {
      rate_based_statement {
        limit              = 10000
        aggregate_key_type = "IP"

        scope_down_statement {
          geo_match_statement {
            country_codes = ["US", "CA", "GB", "DE", "FR", "AU", "JP"]
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
    }

    action {
      block {}
    }
  }

  # SQL injection protection
  rule {
    name     = "SQLInjectionRule"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        excluded_rule {
          name = "SizeRestrictions_BODY"
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLInjectionRule"
    }

    action {
      block {}
    }
  }

  # Bot control rule
  rule {
    name     = "BotControlRule"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesBotControlRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "BotControlRule"
    }

    action {
      block {}
    }
  }

  tags = local.common_tags
}

# GuardDuty for threat detection
resource "aws_guardduty_detector" "wrfcoin_guardduty" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = local.common_tags
}

# Security Hub for centralized security findings
resource "aws_securityhub_account" "wrfcoin_security_hub" {
  enable_default_standards = true
}

# Inspector V2 for vulnerability assessment
resource "aws_inspector2_enabler" "wrfcoin_inspector" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]
}

# KMS keys for encryption
resource "aws_kms_key" "wrfcoin_main" {
  description             = "Main encryption key for Wrfcoin platform"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowEKSAccess"
        Effect = "Allow"
        Principal = {
          AWS = module.eks.cluster_iam_role_arn
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "wrfcoin_main" {
  name          = "alias/${local.name_prefix}-main"
  target_key_id = aws_kms_key.wrfcoin_main.key_id
}

# Separate KMS key for secrets
resource "aws_kms_key" "wrfcoin_secrets" {
  description             = "Encryption key for Wrfcoin secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "wrfcoin_secrets" {
  name          = "alias/${local.name_prefix}-secrets"
  target_key_id = aws_kms_key.wrfcoin_secrets.key_id
}

# Secrets Manager for sensitive configuration
resource "aws_secretsmanager_secret" "database_credentials" {
  name                    = "${local.name_prefix}-database-credentials"
  description             = "Database credentials for Wrfcoin"
  kms_key_id             = aws_kms_key.wrfcoin_secrets.arn
  recovery_window_in_days = 7

  replica {
    region = var.secondary_aws_region
  }

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "database_credentials" {
  secret_id = aws_secretsmanager_secret.database_credentials.id
  secret_string = jsonencode({
    username = "wrfcoin_admin"
    password = random_password.database_password.result
  })
}

resource "random_password" "database_password" {
  length  = 32
  special = true
}

# HSM Cluster for hardware security
resource "aws_cloudhsm_v2_cluster" "wrfcoin_hsm" {
  count      = var.environment == "production" ? 1 : 0
  hsm_type   = "hsm1.medium"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-hsm-cluster"
  })
}

resource "aws_cloudhsm_v2_hsm" "wrfcoin_hsm" {
  count               = var.environment == "production" ? length(local.availability_zones) : 0
  cluster_id          = aws_cloudhsm_v2_cluster.wrfcoin_hsm[0].cluster_id
  availability_zone   = local.availability_zones[count.index]
  ip_address         = cidrhost(local.private_subnets[count.index], 10)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-hsm-${count.index + 1}"
  })
}

# Certificate Manager for TLS certificates
resource "aws_acm_certificate" "wrfcoin_cert" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

# CloudTrail for audit logging
resource "aws_cloudtrail" "wrfcoin_audit" {
  name                          = "${local.name_prefix}-cloudtrail"
  s3_bucket_name               = aws_s3_bucket.audit_logs.id
  s3_key_prefix                = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail        = true
  enable_logging               = true
  enable_log_file_validation   = true
  kms_key_id                   = aws_kms_key.wrfcoin_main.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["${aws_s3_bucket.audit_logs.arn}/*"]
    }

    data_resource {
      type   = "AWS::KMS::Key"
      values = [aws_kms_key.wrfcoin_main.arn]
    }
  }

  tags = local.common_tags
}

# S3 bucket for audit logs
resource "aws_s3_bucket" "audit_logs" {
  bucket        = "${local.name_prefix}-audit-logs-${random_id.bucket_suffix.hex}"
  force_destroy = false

  tags = local.common_tags
}

resource "random_id" "bucket_suffix" {
  byte_length = 8
}

resource "aws_s3_bucket_versioning" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_encryption" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = aws_kms_key.wrfcoin_main.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_s3_bucket_public_access_block" "audit_logs" {
  bucket = aws_s3_bucket.audit_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for enhanced monitoring
resource "aws_iam_role" "security_monitoring" {
  name = "${local.name_prefix}-security-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = ["ec2.amazonaws.com", "lambda.amazonaws.com"]
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "security_monitoring_policy" {
  role       = aws_iam_role.security_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

# Lambda function for security automation
resource "aws_lambda_function" "security_response" {
  filename         = "security_response.zip"
  function_name    = "${local.name_prefix}-security-response"
  role            = aws_iam_role.security_response.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 300
  kms_key_arn     = aws_kms_key.wrfcoin_main.arn

  environment {
    variables = {
      ENVIRONMENT = var.environment
      KMS_KEY_ID  = aws_kms_key.wrfcoin_main.key_id
    }
  }

  tags = local.common_tags
}

resource "aws_iam_role" "security_response" {
  name = "${local.name_prefix}-security-response"

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

# Config for compliance monitoring
resource "aws_config_configuration_recorder" "wrfcoin_config" {
  name     = "${local.name_prefix}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_config_delivery_channel.wrfcoin_config]
}

resource "aws_config_delivery_channel" "wrfcoin_config" {
  name           = "${local.name_prefix}-config-delivery"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket
}

resource "aws_s3_bucket" "config_logs" {
  bucket        = "${local.name_prefix}-config-logs-${random_id.config_bucket_suffix.hex}"
  force_destroy = false

  tags = local.common_tags
}

resource "random_id" "config_bucket_suffix" {
  byte_length = 8
}

resource "aws_iam_role" "config" {
  name = "${local.name_prefix}-config"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/ConfigRole"
}

# Output security resources
output "security_resources" {
  description = "Security infrastructure outputs"
  value = {
    waf_arn                    = aws_wafv2_web_acl.wrfcoin_waf.arn
    guardduty_detector_id      = aws_guardduty_detector.wrfcoin_guardduty.id
    main_kms_key_id           = aws_kms_key.wrfcoin_main.key_id
    secrets_kms_key_id        = aws_kms_key.wrfcoin_secrets.key_id
    hsm_cluster_id            = var.environment == "production" ? aws_cloudhsm_v2_cluster.wrfcoin_hsm[0].cluster_id : null
    certificate_arn           = aws_acm_certificate.wrfcoin_cert.arn
    cloudtrail_arn            = aws_cloudtrail.wrfcoin_audit.arn
    audit_bucket              = aws_s3_bucket.audit_logs.bucket
    security_response_function = aws_lambda_function.security_response.function_name
  }
}

# Data sources
data "aws_caller_identity" "current" {}

# Variables
variable "domain_name" {
  description = "Domain name for Wrfcoin platform"
  type        = string
  default     = "wrfcoin.com"
}