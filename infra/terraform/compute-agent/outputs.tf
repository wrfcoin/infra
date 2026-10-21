output "namespace" {
  description = "Kubernetes namespace for the compute-agent"
  value       = kubernetes_namespace.compute_agent.metadata[0].name
}

output "service_account_name" {
  description = "Kubernetes service account name"
  value       = kubernetes_service_account.compute_agent.metadata[0].name
}

output "iam_role_arn" {
  description = "IAM role ARN for the compute-agent (IRSA)"
  value       = aws_iam_role.compute_agent.arn
}

output "deployment_name" {
  description = "Kubernetes deployment name"
  value       = kubernetes_deployment.compute_agent.metadata[0].name
}
