output "cluster_id" {
  description = "The ID/name of the EKS cluster"
  value       = aws_eks_cluster.this.id
}

output "cluster_arn" {
  description = "The Amazon Resource Name (ARN) of the cluster"
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = try(aws_eks_cluster.this.vpc_config[0].cluster_security_group_id, "")
}

output "cluster_version" {
  description = "The Kubernetes server version for the cluster"
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = try(aws_eks_cluster.this.identity[0].oidc[0].issuer, "")
}

output "node_group_id" {
  description = "EKS node group id"
  value       = aws_eks_node_group.workers.id
}

output "node_group_arn" {
  description = "Amazon Resource Name (ARN) of the EKS Node Group"
  value       = aws_eks_node_group.workers.arn
}

output "node_group_status" {
  description = "Status of the EKS Node Group. One of: CREATING, ACTIVE, UPDATING, DELETING, FAILED"
  value       = aws_eks_node_group.workers.status
}

output "node_group_scaling_config" {
  description = "Current scaling configuration of the node group"
  value = {
    current_size = aws_eks_node_group.workers.scaling_config[0].desired_size
    min_size     = aws_eks_node_group.workers.scaling_config[0].min_size
    max_size     = aws_eks_node_group.workers.scaling_config[0].max_size
  }
}

output "cluster_autoscaler_role_arn" {
  description = "ARN of the Cluster Autoscaler IAM role"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this.id}"
}
