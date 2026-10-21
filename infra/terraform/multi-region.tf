# Multi-Region Production Infrastructure for Wrfcoin
# Implements 99.9% uptime SLA with cross-region redundancy

# Secondary region configuration
variable "secondary_aws_region" {
  description = "Secondary AWS region for multi-region deployment"
  type        = string
  default     = "us-west-2"
}

# Primary region setup (existing main.tf)
provider "aws" {
  alias  = "primary"
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "wrfcoin"
      Environment = var.environment
      Region      = "primary"
      ManagedBy   = "terraform"
    }
  }
}

# Secondary region provider
provider "aws" {
  alias  = "secondary"
  region = var.secondary_aws_region

  default_tags {
    tags = {
      Project     = "wrfcoin"
      Environment = var.environment
      Region      = "secondary"
      ManagedBy   = "terraform"
    }
  }
}

# Secondary region locals
locals {
  secondary_name_prefix = "wrfcoin-${var.environment}-secondary"
  
  # Network configuration for secondary region
  secondary_vpc_cidr = "10.1.0.0/16"
  secondary_private_subnets = [
    "10.1.1.0/24",
    "10.1.2.0/24",
    "10.1.3.0/24"
  ]
  secondary_public_subnets = [
    "10.1.101.0/24",
    "10.1.102.0/24",
    "10.1.103.0/24"
  ]
  secondary_database_subnets = [
    "10.1.201.0/24",
    "10.1.202.0/24",
    "10.1.203.0/24"
  ]
}

# Data sources for secondary region
data "aws_availability_zones" "secondary" {
  provider = aws.secondary
  state    = "available"
}

# Secondary region VPC
module "vpc_secondary" {
  providers = {
    aws = aws.secondary
  }
  
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${local.secondary_name_prefix}-vpc"
  cidr = local.secondary_vpc_cidr

  azs              = data.aws_availability_zones.secondary.names
  private_subnets  = local.secondary_private_subnets
  public_subnets   = local.secondary_public_subnets
  database_subnets = local.secondary_database_subnets

  enable_nat_gateway   = true
  enable_vpn_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

# VPC Peering between regions for cross-region communication
resource "aws_vpc_peering_connection" "primary_to_secondary" {
  provider    = aws.primary
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = module.vpc_secondary.vpc_id
  peer_region = var.secondary_aws_region
  auto_accept = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-to-secondary-peering"
  })
}

resource "aws_vpc_peering_connection_accepter" "secondary" {
  provider                  = aws.secondary
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_secondary.id
  auto_accept               = true

  tags = merge(local.common_tags, {
    Name = "${local.secondary_name_prefix}-peering-accepter"
  })
}

# Route tables for cross-region connectivity
resource "aws_route" "primary_to_secondary" {
  provider                  = aws.primary
  count                     = length(module.vpc.private_route_table_ids)
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = local.secondary_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_secondary.id
}

resource "aws_route" "secondary_to_primary" {
  provider                  = aws.secondary
  count                     = length(module.vpc_secondary.private_route_table_ids)
  route_table_id            = module.vpc_secondary.private_route_table_ids[count.index]
  destination_cidr_block    = local.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.primary_to_secondary.id
}

# Secondary region EKS cluster
module "eks_secondary" {
  providers = {
    aws = aws.secondary
  }
  
  source = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  cluster_name    = "${local.secondary_name_prefix}-cluster"
  cluster_version = "1.28"

  vpc_id                         = module.vpc_secondary.vpc_id
  subnet_ids                     = module.vpc_secondary.private_subnets
  cluster_endpoint_public_access = true

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks_secondary.arn
    resources        = ["secrets"]
  }

  # Node groups for secondary region
  eks_managed_node_groups = {
    blockchain_nodes_secondary = {
      min_size     = 2
      max_size     = 8
      desired_size = 2

      instance_types = ["m5.2xlarge"]
      capacity_type  = "ON_DEMAND"

      k8s_labels = {
        workload = "blockchain"
        tier     = "consensus"
        region   = "secondary"
      }
    }

    api_nodes_secondary = {
      min_size     = 2
      max_size     = 15
      desired_size = 2

      instance_types = ["m5.xlarge"]
      capacity_type  = "SPOT"

      k8s_labels = {
        workload = "api"
        tier     = "service"
        region   = "secondary"
      }
    }
  }

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

# KMS for secondary region
resource "aws_kms_key" "eks_secondary" {
  provider                = aws.secondary
  description             = "EKS Secret Encryption - Secondary Region"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name   = "${local.secondary_name_prefix}-eks-key"
    Region = "secondary"
  })
}

# Cross-region database replication
resource "aws_db_instance" "database_replica" {
  provider               = aws.secondary
  identifier             = "${local.secondary_name_prefix}-database-replica"
  replicate_source_db    = module.database.db_instance_identifier
  instance_class         = "db.r6g.xlarge"
  
  auto_minor_version_upgrade = false
  backup_retention_period    = 7
  backup_window             = "03:00-04:00"
  
  # Performance monitoring
  performance_insights_enabled = true
  monitoring_interval          = 60

  tags = merge(local.common_tags, {
    Name   = "${local.secondary_name_prefix}-database-replica"
    Region = "secondary"
  })
}

# Global load balancer for multi-region traffic distribution
resource "aws_route53_health_check" "primary_region" {
  fqdn                            = aws_lb.main.dns_name
  port                           = 443
  type                           = "HTTPS"
  resource_path                  = "/health"
  failure_threshold              = "3"
  request_interval               = "30"
  cloudwatch_alarm_region        = var.aws_region
  cloudwatch_alarm_name          = "${local.name_prefix}-primary-health"
  insufficient_data_health_status = "Failure"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-primary-health-check"
  })
}

resource "aws_route53_health_check" "secondary_region" {
  fqdn                            = aws_lb.secondary.dns_name
  port                           = 443
  type                           = "HTTPS"
  resource_path                  = "/health"
  failure_threshold              = "3"
  request_interval               = "30"
  cloudwatch_alarm_region        = var.secondary_aws_region
  cloudwatch_alarm_name          = "${local.secondary_name_prefix}-secondary-health"
  insufficient_data_health_status = "Failure"

  tags = merge(local.common_tags, {
    Name = "${local.secondary_name_prefix}-secondary-health-check"
  })
}

# Secondary region load balancer
resource "aws_lb" "secondary" {
  provider           = aws.secondary
  name               = "${local.secondary_name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_secondary.id]
  subnets            = module.vpc_secondary.public_subnets

  enable_deletion_protection = var.environment == "production"

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

resource "aws_security_group" "alb_secondary" {
  provider    = aws.secondary
  name_prefix = "${local.secondary_name_prefix}-alb-"
  vpc_id      = module.vpc_secondary.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name   = "${local.secondary_name_prefix}-alb-sg"
    Region = "secondary"
  })
}

# Global DNS with weighted routing for load distribution
resource "aws_route53_record" "api_primary" {
  count   = var.create_dns_zone ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  set_identifier = "primary"
  
  weighted_routing_policy {
    weight = 70  # 70% traffic to primary region
  }

  health_check_id = aws_route53_health_check.primary_region.id

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_secondary" {
  count   = var.create_dns_zone ? 1 : 0
  zone_id = aws_route53_zone.main[0].zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  set_identifier = "secondary"
  
  weighted_routing_policy {
    weight = 30  # 30% traffic to secondary region
  }

  health_check_id = aws_route53_health_check.secondary_region.id

  alias {
    name                   = aws_lb.secondary.dns_name
    zone_id                = aws_lb.secondary.zone_id
    evaluate_target_health = true
  }
}

# CloudWatch alarms for multi-region monitoring
resource "aws_cloudwatch_metric_alarm" "primary_region_health" {
  alarm_name          = "${local.name_prefix}-primary-region-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "Primary region health check failure"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.primary_region.id
  }
}

resource "aws_cloudwatch_metric_alarm" "secondary_region_health" {
  provider            = aws.secondary
  alarm_name          = "${local.secondary_name_prefix}-secondary-region-health"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "Secondary region health check failure"
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts_secondary.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.secondary_region.id
  }
}

# SNS topics for alerting
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = local.common_tags
}

resource "aws_sns_topic" "alerts_secondary" {
  provider = aws.secondary
  name     = "${local.secondary_name_prefix}-alerts"

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

# Cross-region S3 replication for blockchain backups
resource "aws_s3_bucket" "blockchain_backup_secondary" {
  provider = aws.secondary
  bucket   = "${local.secondary_name_prefix}-blockchain-backup"

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

resource "aws_s3_bucket_encryption_configuration" "blockchain_backup_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.blockchain_backup_secondary.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_secondary.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "blockchain_backup_secondary" {
  provider = aws.secondary
  bucket   = aws_s3_bucket.blockchain_backup_secondary.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "s3_secondary" {
  provider                = aws.secondary
  description             = "S3 bucket encryption - Secondary Region"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name   = "${local.secondary_name_prefix}-s3-key"
    Region = "secondary"
  })
}

# S3 cross-region replication configuration
resource "aws_s3_bucket_replication_configuration" "blockchain_backup" {
  role   = aws_iam_role.s3_replication.arn
  bucket = aws_s3_bucket.blockchain_backup.id

  rule {
    id     = "cross_region_replication"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.blockchain_backup_secondary.arn
      storage_class = "STANDARD_IA"
      
      encryption_configuration {
        replica_kms_key_id = aws_kms_key.s3_secondary.arn
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.blockchain_backup]
}

# IAM role for S3 cross-region replication
resource "aws_iam_role" "s3_replication" {
  name = "${local.name_prefix}-s3-replication-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "s3_replication" {
  name = "${local.name_prefix}-s3-replication-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.blockchain_backup.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.blockchain_backup.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${aws_s3_bucket.blockchain_backup_secondary.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = [
          aws_kms_key.s3.arn,
          aws_kms_key.s3_secondary.arn
        ]
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "s3_replication" {
  role       = aws_iam_role.s3_replication.name
  policy_arn = aws_iam_policy.s3_replication.arn
}

# Redis Global Datastore for cross-region replication
resource "aws_elasticache_subnet_group" "redis_secondary" {
  provider   = aws.secondary
  name       = "${local.secondary_name_prefix}-redis-subnet-group"
  subnet_ids = module.vpc_secondary.private_subnets
}

resource "aws_security_group" "redis_secondary" {
  provider    = aws.secondary
  name_prefix = "${local.secondary_name_prefix}-redis-"
  vpc_id      = module.vpc_secondary.vpc_id

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [local.secondary_vpc_cidr]
  }

  tags = merge(local.common_tags, {
    Name   = "${local.secondary_name_prefix}-redis-sg"
    Region = "secondary"
  })
}

resource "aws_elasticache_global_replication_group" "redis_global" {
  global_replication_group_id_suffix = "wrfcoin-global"
  description                         = "Global Redis cluster for Wrfcoin cross-region caching"
  primary_replication_group_id        = aws_elasticache_replication_group.redis.replication_group_id

  tags = local.common_tags
}

resource "aws_elasticache_replication_group" "redis_secondary" {
  provider                     = aws.secondary
  replication_group_id         = "${local.secondary_name_prefix}-redis"
  description                  = "Redis cluster for Wrfcoin caching - Secondary Region"
  global_replication_group_id  = aws_elasticache_global_replication_group.redis_global.global_replication_group_id
  
  node_type                    = "cache.r6g.xlarge"
  num_cache_clusters           = 2
  automatic_failover_enabled   = true
  multi_az_enabled             = true
  
  subnet_group_name            = aws_elasticache_subnet_group.redis_secondary.name
  security_group_ids           = [aws_security_group.redis_secondary.id]

  tags = merge(local.common_tags, {
    Region = "secondary"
  })
}

# Output values for multi-region setup
output "primary_cluster_endpoint" {
  description = "Primary region EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "secondary_cluster_endpoint" {
  description = "Secondary region EKS cluster endpoint"
  value       = module.eks_secondary.cluster_endpoint
}

output "global_api_endpoint" {
  description = "Global API endpoint with multi-region failover"
  value       = var.create_dns_zone ? "https://api.${var.domain_name}" : "Use load balancer DNS names"
}

output "primary_database_endpoint" {
  description = "Primary database endpoint"
  value       = module.database.db_instance_endpoint
}

output "secondary_database_endpoint" {
  description = "Secondary database read replica endpoint"
  value       = aws_db_instance.database_replica.endpoint
}

output "primary_s3_backup_bucket" {
  description = "Primary S3 backup bucket name"
  value       = aws_s3_bucket.blockchain_backup.bucket
}

output "secondary_s3_backup_bucket" {
  description = "Secondary S3 backup bucket name (replica)"
  value       = aws_s3_bucket.blockchain_backup_secondary.bucket
}

output "primary_redis_endpoint" {
  description = "Primary Redis cluster endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "secondary_redis_endpoint" {
  description = "Secondary Redis cluster endpoint"
  value       = aws_elasticache_replication_group.redis_secondary.primary_endpoint_address
}

output "redis_global_replication_group_id" {
  description = "Global Redis replication group ID"
  value       = aws_elasticache_global_replication_group.redis_global.global_replication_group_id
}