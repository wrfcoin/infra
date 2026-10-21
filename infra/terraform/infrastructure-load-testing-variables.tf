# WRFCoin Load Testing Infrastructure - Variable Definitions
# Task 43 Subtask 14: Set Up Load Testing Infrastructure and Scaling Capabilities

# Environment Configuration
variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string
  default     = "development"
  
  validation {
    condition     = can(regex("^(development|staging|production)$", var.environment))
    error_message = "Environment must be one of: development, staging, production."
  }
}

variable "aws_region" {
  description = "AWS region for infrastructure deployment"
  type        = string
  default     = "us-east-1"
}

# Network Configuration
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.100.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.100.1.0/24", "10.100.2.0/24", "10.100.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.100.101.0/24", "10.100.102.0/24", "10.100.103.0/24"]
}

# Kubernetes Configuration
variable "kubernetes_version" {
  description = "Kubernetes cluster version"
  type        = string
  default     = "1.27"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks that can access the cluster endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Load Generator Configuration
variable "load_generator_min_size" {
  description = "Minimum number of load generator nodes"
  type        = number
  default     = 1
}

variable "load_generator_max_size" {
  description = "Maximum number of load generator nodes"
  type        = number
  default     = 50
}

variable "load_generator_desired_size" {
  description = "Desired number of load generator nodes"
  type        = number
  default     = 2
}

variable "load_generator_instance_types" {
  description = "Instance types for load generator nodes (network optimized)"
  type        = list(string)
  default     = ["c5n.large", "c5n.xlarge", "c5n.2xlarge"]
}

variable "load_generator_capacity_type" {
  description = "Capacity type for load generator nodes (SPOT or ON_DEMAND)"
  type        = string
  default     = "SPOT"
  
  validation {
    condition     = can(regex("^(SPOT|ON_DEMAND)$", var.load_generator_capacity_type))
    error_message = "Capacity type must be either SPOT or ON_DEMAND."
  }
}

variable "k6_version" {
  description = "K6 version to use for load testing"
  type        = string
  default     = "0.45.0"
}

variable "concurrent_users_per_instance" {
  description = "Maximum concurrent users per load generator instance"
  type        = number
  default     = 1000
}

# Target Infrastructure Configuration
variable "target_infra_min_size" {
  description = "Minimum number of target infrastructure nodes"
  type        = number
  default     = 3
}

variable "target_infra_max_size" {
  description = "Maximum number of target infrastructure nodes"
  type        = number
  default     = 30
}

variable "target_infra_desired_size" {
  description = "Desired number of target infrastructure nodes"
  type        = number
  default     = 5
}

variable "target_infra_instance_types" {
  description = "Instance types for target infrastructure nodes"
  type        = list(string)
  default     = ["m5.large", "m5.xlarge", "m5.2xlarge"]
}

variable "monitoring_instance_types" {
  description = "Instance types for monitoring nodes"
  type        = list(string)
  default     = ["m5.large", "m5.xlarge"]
}

# Service Scaling Configuration
variable "main_api_min_replicas" {
  description = "Minimum replicas for Main API service"
  type        = number
  default     = 3
}

variable "main_api_max_replicas" {
  description = "Maximum replicas for Main API service"
  type        = number
  default     = 20
}

variable "main_api_cpu_target" {
  description = "CPU utilization target for Main API auto-scaling"
  type        = number
  default     = 70
}

variable "iot_sensors_min_replicas" {
  description = "Minimum replicas for IoT Sensors service"
  type        = number
  default     = 5
}

variable "iot_sensors_max_replicas" {
  description = "Maximum replicas for IoT Sensors service"
  type        = number
  default     = 30
}

variable "iot_sensors_cpu_target" {
  description = "CPU utilization target for IoT Sensors auto-scaling"
  type        = number
  default     = 60
}

variable "cross_chain_min_replicas" {
  description = "Minimum replicas for Cross-Chain service"
  type        = number
  default     = 2
}

variable "cross_chain_max_replicas" {
  description = "Maximum replicas for Cross-Chain service"
  type        = number
  default     = 15
}

variable "cross_chain_cpu_target" {
  description = "CPU utilization target for Cross-Chain auto-scaling"
  type        = number
  default     = 75
}

variable "compute_networks_min_replicas" {
  description = "Minimum replicas for Compute Networks service"
  type        = number
  default     = 2
}

variable "compute_networks_max_replicas" {
  description = "Maximum replicas for Compute Networks service"
  type        = number
  default     = 25
}

variable "compute_networks_cpu_target" {
  description = "CPU utilization target for Compute Networks auto-scaling"
  type        = number
  default     = 80
}

# Database Configuration
variable "postgres_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "15.3"
}

variable "postgres_family" {
  description = "PostgreSQL parameter group family"
  type        = string
  default     = "postgres15"
}

variable "postgres_major_engine_version" {
  description = "PostgreSQL major engine version"
  type        = string
  default     = "15"
}

variable "postgres_instance_class" {
  description = "PostgreSQL instance class"
  type        = string
  default     = "db.r6g.xlarge"
}

variable "postgres_allocated_storage" {
  description = "Allocated storage for PostgreSQL (GB)"
  type        = number
  default     = 100
}

variable "postgres_max_allocated_storage" {
  description = "Maximum allocated storage for PostgreSQL (GB)"
  type        = number
  default     = 1000
}

variable "postgres_multi_az" {
  description = "Enable Multi-AZ deployment for PostgreSQL"
  type        = bool
  default     = true
}

variable "postgres_db_name" {
  description = "Database name for PostgreSQL"
  type        = string
  default     = "wrfcoin_loadtest"
}

variable "postgres_username" {
  description = "Master username for PostgreSQL"
  type        = string
  default     = "wrfcoin_admin"
}

variable "postgres_maintenance_window" {
  description = "Maintenance window for PostgreSQL"
  type        = string
  default     = "Sun:03:00-Sun:04:00"
}

variable "postgres_backup_window" {
  description = "Backup window for PostgreSQL"
  type        = string
  default     = "02:00-03:00"
}

variable "postgres_read_replica_count" {
  description = "Number of PostgreSQL read replicas"
  type        = number
  default     = 2
}

variable "postgres_read_replica_instance_class" {
  description = "Instance class for PostgreSQL read replicas"
  type        = string
  default     = "db.r6g.large"
}

# Redis Configuration
variable "redis_engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.0"
}

variable "redis_parameter_group" {
  description = "Redis parameter group name"
  type        = string
  default     = "default.redis7"
}

variable "redis_node_type" {
  description = "Redis node type"
  type        = string
  default     = "cache.r6g.large"
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters"
  type        = number
  default     = 3
}

variable "redis_snapshot_window" {
  description = "Redis snapshot window"
  type        = string
  default     = "02:00-03:00"
}

variable "redis_maintenance_window" {
  description = "Redis maintenance window"
  type        = string
  default     = "sun:03:00-sun:04:00"
}

variable "redis_auth_token" {
  description = "Redis authentication token"
  type        = string
  default     = ""
  sensitive   = true
}

# DNS Configuration
variable "route53_zone_id" {
  description = "Route53 hosted zone ID for load testing domain"
  type        = string
  default     = ""
}

# Budget and Cost Management
variable "monthly_budget_limit" {
  description = "Monthly budget limit for load testing infrastructure (USD)"
  type        = string
  default     = "1000"
}

variable "budget_notification_emails" {
  description = "Email addresses for budget notifications"
  type        = list(string)
  default     = ["infrastructure-team@wrfcoin.io"]
}

# Load Testing Parameters
variable "max_concurrent_users" {
  description = "Maximum concurrent users for load testing"
  type        = number
  default     = 50000
}

variable "target_tps" {
  description = "Target transactions per second"
  type        = number
  default     = 10000
}

variable "load_test_duration" {
  description = "Default load test duration in minutes"
  type        = number
  default     = 30
}

variable "ramp_up_duration" {
  description = "Ramp-up duration in minutes"
  type        = number
  default     = 5
}

variable "ramp_down_duration" {
  description = "Ramp-down duration in minutes"
  type        = number
  default     = 2
}

# Feature Flags
variable "enable_spot_instances" {
  description = "Enable spot instances for cost optimization"
  type        = bool
  default     = true
}

variable "enable_multi_region" {
  description = "Enable multi-region deployment"
  type        = bool
  default     = false
}

variable "enable_enhanced_monitoring" {
  description = "Enable enhanced monitoring and observability"
  type        = bool
  default     = true
}

variable "enable_auto_scaling" {
  description = "Enable automatic scaling based on metrics"
  type        = bool
  default     = true
}

variable "enable_cost_optimization" {
  description = "Enable cost optimization features"
  type        = bool
  default     = true
}

# Tagging
variable "additional_tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}