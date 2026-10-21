# Wrfcoin Production Infrastructure as Code
# Location: infrastructure/terraform/main.tf
# Priority: HIGH - Production deployment capability

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.56"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    bucket = "wrfcoin-terraform-state"
    key    = "production/terraform.tfstate"
    region = "us-east-1"

    dynamodb_table = "wrfcoin-terraform-locks"
    encrypt        = true
  }
}

# Provider configurations
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "wrfcoin"
      Environment = var.environment
      ManagedBy   = "terraform"
      CostCenter  = "blockchain-platform"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

# Local variables
locals {
  name_prefix = "wrfcoin-${var.environment}"

  common_tags = {
    Project     = "wrfcoin"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # Multi-AZ setup for high availability
  availability_zones = data.aws_availability_zones.available.names

  # Network configuration
  vpc_cidr = "10.0.0.0/16"
  private_subnets = [
    "10.0.1.0/24",
    "10.0.2.0/24",
    "10.0.3.0/24"
  ]
  public_subnets = [
    "10.0.101.0/24",
    "10.0.102.0/24",
    "10.0.103.0/24"
  ]
  database_subnets = [
    "10.0.201.0/24",
    "10.0.202.0/24",
    "10.0.203.0/24"
  ]
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# VPC and Networking
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${local.name_prefix}-vpc"
  cidr = local.vpc_cidr

  azs              = local.availability_zones
  private_subnets  = local.private_subnets
  public_subnets   = local.public_subnets
  database_subnets = local.database_subnets

  enable_nat_gateway   = true
  enable_vpn_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Enhanced networking for blockchain workloads
  enable_dhcp_options              = true
  dhcp_options_domain_name_servers = ["AmazonProvidedDNS"]

  tags = local.common_tags
}

# Security Groups
resource "aws_security_group" "blockchain_nodes" {
  name_prefix = "${local.name_prefix}-blockchain-"
  vpc_id      = module.vpc.vpc_id

  # P2P communication
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # Cross-chain bridge
  ingress {
    from_port   = 5001
    to_port     = 5001
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  # API access
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-blockchain-sg"
  })
}

resource "aws_security_group" "database" {
  name_prefix = "${local.name_prefix}-database-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.blockchain_nodes.id]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-database-sg"
  })
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = "1.28"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  # Enhanced security for blockchain workloads
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  # Node groups
  eks_managed_node_groups = merge(
    {
      # Blockchain nodes - optimized for consensus and transaction processing
      blockchain_nodes = {
        min_size     = 3
        max_size     = 10
        desired_size = 3

        instance_types = ["m5.2xlarge"]
        capacity_type  = "ON_DEMAND"

        k8s_labels = {
          workload = "blockchain"
          tier     = "consensus"
        }

        taints = {
          blockchain = {
            key    = "workload"
            value  = "blockchain"
            effect = "NO_SCHEDULE"
          }
        }
      }

      # API and service nodes
      api_nodes = {
        min_size     = 2
        max_size     = 20
        desired_size = 3

        instance_types = ["m5.xlarge"]
        capacity_type  = "SPOT"

        k8s_labels = {
          workload = "api"
          tier     = "service"
        }
      }

      # IoT and sensor data processing
      iot_nodes = {
        min_size     = 2
        max_size     = 15
        desired_size = 2

        instance_types = ["c5.2xlarge"]
        capacity_type  = "ON_DEMAND"

        k8s_labels = {
          workload = "iot"
          tier     = "data-processing"
        }
      }
    },
    var.enable_compute_agent_node_group ? {
      compute_agent_nodes = {
        min_size     = var.compute_agent_min_size
        max_size     = var.compute_agent_max_size
        desired_size = var.compute_agent_desired_size

        instance_types = var.compute_agent_instance_types
        capacity_type  = "ON_DEMAND"

        k8s_labels = {
          workload = "compute-agent"
          tier     = "compute"
        }

        taints = {
          compute_agent = {
            key    = "dedicated"
            value  = "compute-agent"
            effect = "NO_SCHEDULE"
          }
        }

        tags = {
          "k8s.io/cluster-autoscaler/enabled"                      = "true"
          "k8s.io/cluster-autoscaler/${local.name_prefix}-cluster" = "owned"
        }
      }
    } : {}
  )

  tags = local.common_tags
}

# KMS for encryption
resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-key"
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name_prefix}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# RDS PostgreSQL for blockchain data
module "database" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 7.2"

  identifier = "${local.name_prefix}-database"

  engine               = "postgres"
  engine_version       = "15.4"
  major_engine_version = "15"
  family               = "postgres15"

  instance_class        = "db.r6g.2xlarge"
  allocated_storage     = 100
  max_allocated_storage = 1000

  storage_encrypted = true
  kms_key_id        = aws_kms_key.database.arn

  db_name                     = "wrfcoin"
  username                    = "wrfcoin_admin"
  manage_master_user_password = true

  vpc_security_group_ids = [aws_security_group.database.id]
  db_subnet_group_name   = module.vpc.database_subnet_group

  # High availability
  multi_az = true

  # Performance optimization for blockchain workloads
  performance_insights_enabled = true
  monitoring_interval          = 60

  # Backup configuration
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  # Read replicas for scaling
  create_db_option_group    = false
  create_db_parameter_group = true

  parameters = [
    {
      name  = "shared_preload_libraries"
      value = "pg_stat_statements"
    },
    {
      name  = "max_connections"
      value = "1000"
    },
    {
      name  = "work_mem"
      value = "256MB"
    }
  ]

  tags = local.common_tags
}

resource "aws_kms_key" "database" {
  description             = "RDS encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-database-key"
  })
}

# ElastiCache Redis for caching
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "Redis cluster for Wrfcoin caching"

  node_type            = "cache.r6g.xlarge"
  port                 = 6379
  parameter_group_name = "default.redis7"

  num_cache_clusters         = 3
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result

  tags = local.common_tags
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.name_prefix}-redis-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.blockchain_nodes.id]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-sg"
  })
}

resource "random_password" "redis_auth" {
  length  = 32
  special = true
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = var.environment == "production"

  tags = local.common_tags
}

resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  vpc_id      = module.vpc.vpc_id

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
    Name = "${local.name_prefix}-alb-sg"
  })
}

# S3 bucket for blockchain data backup
resource "aws_s3_bucket" "blockchain_backup" {
  bucket = "${local.name_prefix}-blockchain-backup"

  tags = local.common_tags
}

resource "aws_s3_bucket_encryption_configuration" "blockchain_backup" {
  bucket = aws_s3_bucket.blockchain_backup.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "blockchain_backup" {
  bucket = aws_s3_bucket.blockchain_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "s3" {
  description             = "S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-s3-key"
  })
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "blockchain" {
  name              = "/aws/eks/${local.name_prefix}/blockchain"
  retention_in_days = 30

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/eks/${local.name_prefix}/api"
  retention_in_days = 14

  tags = local.common_tags
}

# Route53 for DNS
resource "aws_route53_zone" "main" {
  count = var.create_dns_zone ? 1 : 0
  name  = var.domain_name

  tags = local.common_tags
}

# WAF for security
resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name_prefix}-waf"
  scope = "REGIONAL"

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
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
      sampled_requests_enabled   = true
    }

    action {
      block {}
    }
  }

  # Geo blocking rule (example)
  rule {
    name     = "GeoBlockRule"
    priority = 2

    override_action {
      none {}
    }

    statement {
      geo_match_statement {
        country_codes = ["CN", "RU"] # Block certain countries if needed
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "GeoBlockRule"
      sampled_requests_enabled   = true
    }

    action {
      block {}
    }
  }

  tags = local.common_tags

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true
  }
}

# Auto Scaling for blockchain nodes
resource "aws_autoscaling_policy" "blockchain_scale_up" {
  name                   = "${local.name_prefix}-blockchain-scale-up"
  scaling_adjustment     = 2
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = module.eks.eks_managed_node_groups["blockchain_nodes"].asg_name
}

resource "aws_autoscaling_policy" "blockchain_scale_down" {
  name                   = "${local.name_prefix}-blockchain-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = module.eks.eks_managed_node_groups["blockchain_nodes"].asg_name
}

# CloudWatch alarms for auto scaling
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name_prefix}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EKS"
  period              = "120"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.blockchain_scale_up.arn]

  dimensions = {
    AutoScalingGroupName = module.eks.eks_managed_node_groups["blockchain_nodes"].asg_name
  }
}

resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "${local.name_prefix}-low-cpu"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EKS"
  period              = "120"
  statistic           = "Average"
  threshold           = "30"
  alarm_description   = "This metric monitors ec2 cpu utilization"
  alarm_actions       = [aws_autoscaling_policy.blockchain_scale_down.arn]

  dimensions = {
    AutoScalingGroupName = module.eks.eks_managed_node_groups["blockchain_nodes"].asg_name
  }
}

# Compute-Agent Deployment (infra#36)
# Self-contained module for K8s resources, IRSA, autoscaling, and PDB.
# Gated by the same variable that creates the dedicated EKS node group.
module "compute_agent" {
  source = "./compute-agent"
  count  = var.enable_compute_agent_node_group ? 1 : 0

  environment        = var.environment
  cluster_name       = module.eks.cluster_name
  oidc_provider_arn  = module.eks.oidc_provider_arn
  oidc_provider_url  = module.eks.oidc_provider
  replicas           = var.compute_agent_desired_size
  enable_node_affinity = true
  run_as_user        = 1001
  tags               = local.common_tags
}
