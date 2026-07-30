variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  type        = string
}

variable "cluster_ca_certificate" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  type        = string
}

variable "cluster_auth_token" {
  description = "Token to authenticate with the cluster"
  type        = string
  sensitive   = true
}

variable "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the OIDC provider"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace for Cluster Autoscaler"
  type        = string
  default     = "kube-system"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
