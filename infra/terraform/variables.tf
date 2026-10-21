# Terraform Variables for Wrfcoin Infrastructure
# Location: infrastructure/terraform/variables.tf

variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "domain_name" {
  description = "Domain name for the application"
  type        = string
  default     = "wrfcoin.com"
}

variable "create_dns_zone" {
  description = "Whether to create Route53 hosted zone"
  type        = bool
  default     = false
}

variable "blockchain_node_count" {
  description = "Number of blockchain nodes to run"
  type        = number
  default     = 3

  validation {
    condition     = var.blockchain_node_count >= 3 && var.blockchain_node_count <= 50
    error_message = "Blockchain node count must be between 3 and 50."
  }
}

variable "enable_monitoring" {
  description = "Enable CloudWatch monitoring and logging"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 7
}

variable "database_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.r6g.2xlarge"
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type"
  type        = string
  default     = "cache.r6g.xlarge"
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for critical resources"
  type        = bool
  default     = true
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the application"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssl_certificate_arn" {
  description = "ARN of SSL certificate for HTTPS"
  type        = string
  default     = ""
}

variable "enable_auto_scaling" {
  description = "Enable auto scaling for EKS node groups"
  type        = bool
  default     = true
}

variable "enable_compute_agent_node_group" {
  description = "Enable a dedicated EKS node group for compute-agent workloads"
  type        = bool
  default     = false
}

variable "compute_agent_instance_types" {
  description = "Instance types for compute-agent nodes"
  type        = list(string)
  default     = ["c5.2xlarge"]
}

variable "compute_agent_min_size" {
  description = "Minimum number of compute-agent nodes"
  type        = number
  default     = 1
}

variable "compute_agent_desired_size" {
  description = "Desired number of compute-agent nodes"
  type        = number
  default     = 1
}

variable "compute_agent_max_size" {
  description = "Maximum number of compute-agent nodes"
  type        = number
  default     = 5
}

variable "blockchain_storage_size" {
  description = "Storage size in GB for blockchain data"
  type        = number
  default     = 500
}

variable "max_blockchain_nodes" {
  description = "Maximum number of blockchain nodes for auto scaling"
  type        = number
  default     = 10
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Multi-region variables
variable "secondary_aws_region" {
  description = "Secondary AWS region for failover"
  type        = string
  default     = "us-west-2"
}

variable "db_replica_instance_class" {
  description = "RDS instance class for read replica"
  type        = string
  default     = "db.r6g.xlarge"
}

variable "waf_rate_limit" {
  description = "WAF rate limit per IP (requests per 5 minutes)"
  type        = number
  default     = 2000
}

variable "alert_email" {
  description = "Email address for critical alerts"
  type        = string
  default     = "alerts@wrfcoin.com"
}

variable "cpu_scale_up_threshold" {
  description = "CPU threshold for scaling up (%)"
  type        = number
  default     = 80
}

variable "cpu_scale_down_threshold" {
  description = "CPU threshold for scaling down (%)"
  type        = number
  default     = 30
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS clusters"
  type        = string
  default     = "1.28"
}

variable "cross_region_backup" {
  description = "Enable cross-region backup replication"
  type        = bool
  default     = true
}
