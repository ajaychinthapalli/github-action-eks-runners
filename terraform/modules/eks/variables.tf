# EKS Cluster and Node Group Module
# This module creates the EKS cluster and managed node group

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the cluster"
  type        = string
}

variable "cluster_security_group_id" {
  description = "Security group ID for the cluster"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the cluster"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the IAM role for EKS nodes"
  type        = string
}

variable "node_group_name" {
  description = "Name of the EKS node group"
  type        = string
  default     = "workers"
}

variable "node_instance_type" {
  description = "EC2 instance type for nodes"
  type        = string
  default     = "t3.small"
}

variable "node_desired_size" {
  description = "Desired number of nodes"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 6
}

variable "node_capacity_type" {
  description = "Type of capacity associated with the EKS Node Group. Valid values: ON_DEMAND, SPOT"
  type        = string
  default     = "ON_DEMAND"
  
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be either ON_DEMAND or SPOT."
  }
}

variable "launch_template_id" {
  description = "ID of the launch template for nodes"
  type        = string
}

variable "launch_template_version" {
  description = "Version of the launch template"
  type        = string
  default     = "1"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "enable_cluster_autoscaler" {
  description = "Enable Cluster Autoscaler for automatic node scaling"
  type        = bool
  default     = true
}
