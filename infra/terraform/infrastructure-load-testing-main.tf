# WRFCoin Load Testing Infrastructure - Terraform Main Configuration
# Task 43 Subtask 14: Set Up Load Testing Infrastructure and Scaling Capabilities

# Provider configurations
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
    key    = "load-testing/terraform.tfstate"
    region = var.aws_region
  }
}

provider "aws" {
  region = var.aws_region
  
  default_tags {
    tags = {
      Project     = "WRFCoin"
      Environment = var.environment
      Purpose     = "LoadTesting"
      ManagedBy   = "Terraform"
      CostCenter  = "Infrastructure"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks_cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_cluster.cluster_ca_certificate)
  token                  = module.eks_cluster.cluster_token
}

provider "helm" {
  kubernetes {
    host                   = module.eks_cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_cluster.cluster_ca_certificate)
    token                  = module.eks_cluster.cluster_token
  }
}

# Local values for resource naming and configuration
locals {
  name_prefix = "wrfcoin-${var.environment}-loadtest"
  
  common_tags = {
    Project     = "WRFCoin"
    Environment = var.environment
    Purpose     = "LoadTesting"
    ManagedBy   = "Terraform"
  }

  # Load testing configuration
  load_generator_config = {
    min_size     = var.load_generator_min_size
    max_size     = var.load_generator_max_size
    desired_size = var.load_generator_desired_size
    
    instance_types = var.load_generator_instance_types
    capacity_type  = var.load_generator_capacity_type # SPOT or ON_DEMAND
    
    k6_version = var.k6_version
    concurrent_users_per_instance = var.concurrent_users_per_instance
  }

  # Target infrastructure scaling configuration
  service_scaling_config = {
    main_api = {
      min_replicas = var.main_api_min_replicas
      max_replicas = var.main_api_max_replicas
      cpu_target   = var.main_api_cpu_target
    }
    iot_sensors = {
      min_replicas = var.iot_sensors_min_replicas
      max_replicas = var.iot_sensors_max_replicas
      cpu_target   = var.iot_sensors_cpu_target
    }
    cross_chain = {
      min_replicas = var.cross_chain_min_replicas
      max_replicas = var.cross_chain_max_replicas
      cpu_target   = var.cross_chain_cpu_target
    }
    compute_networks = {
      min_replicas = var.compute_networks_min_replicas
      max_replicas = var.compute_networks_max_replicas
      cpu_target   = var.compute_networks_cpu_target
    }
  }
}

# VPC and Networking for Load Testing
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway     = true
  enable_vpn_gateway     = false
  enable_dns_hostnames   = true
  enable_dns_support     = true

  # VPC Flow Logs for monitoring
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true

  tags = local.common_tags
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# EKS Cluster for Load Testing Infrastructure
module "eks_cluster" {
  source = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster endpoint configuration
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # Cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # IRSA for service accounts
  enable_irsa = true

  # Cluster security group rules
  cluster_security_group_additional_rules = {
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Load testing traffic"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Node security group rules
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  # Managed Node Groups
  eks_managed_node_groups = {
    # Load Generator Nodes - Optimized for network performance
    load_generators = {
      name = "${local.name_prefix}-load-generators"
      
      instance_types = local.load_generator_config.instance_types
      capacity_type  = local.load_generator_config.capacity_type
      
      min_size     = local.load_generator_config.min_size
      max_size     = local.load_generator_config.max_size
      desired_size = local.load_generator_config.desired_size

      # Network optimizations for load testing
      ami_type = "AL2_x86_64"
      platform = "linux"
      
      # Enhanced networking for high throughput
      enable_monitoring = true
      
      # Taints for load generator workloads
      taints = {
        dedicated = {
          key    = "load-generator"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      labels = {
        role = "load-generator"
      }

      # User data for K6 setup
      user_data_template_path = "${path.module}/templates/load-generator-user-data.sh"

      tags = merge(local.common_tags, {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${local.name_prefix}-cluster" = "owned"
      })
    }

    # Target Infrastructure Nodes - For WRFCoin services
    target_infrastructure = {
      name = "${local.name_prefix}-target-infra"
      
      instance_types = var.target_infra_instance_types
      capacity_type  = "ON_DEMAND" # More stable for target services
      
      min_size     = var.target_infra_min_size
      max_size     = var.target_infra_max_size
      desired_size = var.target_infra_desired_size

      ami_type = "AL2_x86_64"
      platform = "linux"
      
      enable_monitoring = true

      labels = {
        role = "target-infrastructure"
      }

      tags = merge(local.common_tags, {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${local.name_prefix}-cluster" = "owned"
      })
    }

    # Monitoring Nodes - For observability stack
    monitoring = {
      name = "${local.name_prefix}-monitoring"
      
      instance_types = var.monitoring_instance_types
      capacity_type  = "ON_DEMAND"
      
      min_size     = 2
      max_size     = 5
      desired_size = 2

      ami_type = "AL2_x86_64"
      platform = "linux"
      
      enable_monitoring = true

      labels = {
        role = "monitoring"
      }

      tags = local.common_tags
    }
  }

  tags = local.common_tags
}

# RDS PostgreSQL for Load Testing Data
module "rds" {
  source = "terraform-aws-modules/rds/aws"
  version = "~> 7.2"

  identifier = "${local.name_prefix}-postgresql"

  engine               = "postgres"
  engine_version       = var.postgres_engine_version
  family               = var.postgres_family
  major_engine_version = var.postgres_major_engine_version
  instance_class       = var.postgres_instance_class

  allocated_storage     = var.postgres_allocated_storage
  max_allocated_storage = var.postgres_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.postgres_db_name
  username = var.postgres_username
  port     = 5432

  multi_az               = var.postgres_multi_az
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [aws_security_group.rds.id]

  maintenance_window              = var.postgres_maintenance_window
  backup_window                   = var.postgres_backup_window
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  create_cloudwatch_log_group     = true

  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = var.environment == "production"

  # Read Replicas for Load Testing
  create_random_password = true
  
  # Performance monitoring
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  create_monitoring_role                = true
  monitoring_interval                   = 60

  tags = local.common_tags
}

# Read Replicas for Load Distribution
resource "aws_db_instance" "postgres_read_replicas" {
  count = var.postgres_read_replica_count

  identifier = "${local.name_prefix}-postgresql-read-${count.index + 1}"

  replicate_source_db = module.rds.db_instance_identifier

  instance_class = var.postgres_read_replica_instance_class
  
  publicly_accessible = false
  
  performance_insights_enabled = true
  monitoring_interval          = 60
  monitoring_role_arn         = module.rds.enhanced_monitoring_iam_role_arn

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-postgresql-read-replica-${count.index + 1}"
    Type = "read-replica"
  })
}

# ElastiCache Redis Cluster for Caching
module "redis" {
  source = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.0"

  cluster_id = "${local.name_prefix}-redis"

  # Redis Cluster mode
  engine               = "redis"
  engine_version       = var.redis_engine_version
  port                 = 6379
  parameter_group_name = var.redis_parameter_group
  node_type           = var.redis_node_type

  # Cluster configuration
  num_cache_clusters         = var.redis_num_cache_clusters
  automatic_failover_enabled = true
  multi_az_enabled          = true

  # Network configuration
  subnet_group_name = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  # Backup and maintenance
  snapshot_retention_limit = 3
  snapshot_window          = var.redis_snapshot_window
  maintenance_window       = var.redis_maintenance_window

  # Encryption
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                = var.redis_auth_token

  tags = local.common_tags
}

# Security Groups
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks_cluster.node_security_group_id]
    description     = "PostgreSQL access from EKS nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds-sg"
  })
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis-sg"
  description = "Security group for Redis cluster"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks_cluster.node_security_group_id]
    description     = "Redis access from EKS nodes"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-redis-sg"
  })
}

# ElastiCache Subnet Group
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.name_prefix}-redis-subnet-group"
  subnet_ids = module.vpc.private_subnets
  
  tags = local.common_tags
}

# Application Load Balancer for Load Testing
module "alb" {
  source = "terraform-aws-modules/alb/aws"
  version = "~> 10.5"

  name = "${local.name_prefix}-alb"

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [aws_security_group.alb.id]

  # Access logging
  access_logs = {
    bucket  = aws_s3_bucket.load_testing_logs.id
    prefix  = "alb-logs"
    enabled = true
  }

  target_groups = [
    {
      name_prefix      = "wrfapi-"
      backend_protocol = "HTTP"
      backend_port     = 4001
      target_type      = "ip"
      health_check = {
        enabled             = true
        healthy_threshold   = 2
        interval            = 30
        matcher             = "200"
        path                = "/health"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }
    },
    {
      name_prefix      = "iot-"
      backend_protocol = "HTTP"
      backend_port     = 3002
      target_type      = "ip"
      health_check = {
        enabled             = true
        healthy_threshold   = 2
        interval            = 30
        matcher             = "200"
        path                = "/health"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }
    }
  ]

  https_listeners = [
    {
      port               = 443
      protocol           = "HTTPS"
      certificate_arn    = aws_acm_certificate_validation.load_testing.certificate_arn
      target_group_index = 0
    }
  ]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    }
  ]

  tags = local.common_tags
}

# Security Group for ALB
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP access"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS access"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

# S3 Bucket for Load Testing Logs and Artifacts
resource "aws_s3_bucket" "load_testing_logs" {
  bucket = "${local.name_prefix}-logs-${random_string.bucket_suffix.result}"

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "load_testing_logs" {
  bucket = aws_s3_bucket.load_testing_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "load_testing_logs" {
  bucket = aws_s3_bucket.load_testing_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "load_testing_logs" {
  bucket = aws_s3_bucket.load_testing_logs.id

  rule {
    id     = "load_testing_logs_lifecycle"
    status = "Enabled"

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "random_string" "bucket_suffix" {
  length  = 8
  special = false
  upper   = false
}

# Route53 for Load Testing Domain
data "aws_route53_zone" "load_testing" {
  count = var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
}

resource "aws_acm_certificate" "load_testing" {
  count = var.route53_zone_id != "" ? 1 : 0
  
  domain_name       = "loadtest-${var.environment}.${data.aws_route53_zone.load_testing[0].name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.common_tags
}

resource "aws_acm_certificate_validation" "load_testing" {
  count = var.route53_zone_id != "" ? 1 : 0
  
  certificate_arn         = aws_acm_certificate.load_testing[0].arn
  validation_record_fqdns = [for record in aws_route53_record.load_testing_validation : record.fqdn]
}

resource "aws_route53_record" "load_testing_validation" {
  for_each = var.route53_zone_id != "" ? {
    for dvo in aws_acm_certificate.load_testing[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.load_testing[0].zone_id
}

resource "aws_route53_record" "load_testing" {
  count = var.route53_zone_id != "" ? 1 : 0
  
  zone_id = data.aws_route53_zone.load_testing[0].zone_id
  name    = "loadtest-${var.environment}"
  type    = "A"

  alias {
    name                   = module.alb.lb_dns_name
    zone_id                = module.alb.lb_zone_id
    evaluate_target_health = true
  }
}

# CloudWatch for Infrastructure Monitoring
resource "aws_cloudwatch_log_group" "load_testing" {
  name              = "/aws/wrfcoin/load-testing/${var.environment}"
  retention_in_days = 14

  tags = local.common_tags
}

# Cost and Usage Reporting
resource "aws_budgets_budget" "load_testing" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  
  cost_filters = {
    Tag = ["Project:WRFCoin", "Purpose:LoadTesting"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                 = 100
    threshold_type             = "PERCENTAGE"
    notification_type            = "FORECASTED"
    subscriber_email_addresses = var.budget_notification_emails
  }

  tags = local.common_tags
}