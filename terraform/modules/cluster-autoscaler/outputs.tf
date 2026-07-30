output "cluster_autoscaler_role_arn" {
  description = "ARN of the Cluster Autoscaler IAM role"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "cluster_autoscaler_namespace" {
  description = "Namespace where Cluster Autoscaler is deployed"
  value       = kubernetes_namespace.cluster_autoscaler.metadata[0].name
}

output "cluster_autoscaler_service_account_name" {
  description = "Service account name for Cluster Autoscaler"
  value       = kubernetes_service_account.cluster_autoscaler.metadata[0].name
}
