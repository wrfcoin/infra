variable "environment" {
  description = "Environment name"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "production"], var.environment)
    error_message = "Environment must be dev, staging, or production."
  }
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for the compute-agent"
  type        = string
  default     = "wrfcoin-compute-agent"
}

variable "image" {
  description = "Container image for the compute-agent"
  type        = string
  default     = "wrfcoin/compute-agent:latest"
}

variable "replicas" {
  description = "Number of compute-agent replicas"
  type        = number
  default     = 1
}

variable "enable_node_affinity" {
  description = "Pin pods to the dedicated compute-agent node group"
  type        = bool
  default     = false
}

variable "task_api_url" {
  description = "URL of the compute contribution API"
  type        = string
  default     = "http://wrfcoin-compute-contribution.default.svc.cluster.local:6003"
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_provider_url" {
  description = "EKS OIDC provider URL (without https:// prefix)"
  type        = string
}

variable "run_as_user" {
  description = "UID for the non-root container user (1001 matches core4 Dockerfile convention)"
  type        = number
  default     = 1001
}

variable "tags" {
  description = "Additional tags to apply to AWS resources"
  type        = map(string)
  default     = {}
}
