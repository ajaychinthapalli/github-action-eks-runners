resource "aws_eks_cluster" "this" {
  name                           = var.cluster_name
  role_arn                       = var.cluster_role_arn
  version                        = var.cluster_version
  bootstrap_self_managed_addons  = false

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = var.cluster_security_group_id != "" ? [var.cluster_security_group_id] : []
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = "10.100.0.0/16"
    elastic_load_balancing {
      enabled = false
    }
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  zonal_shift_config {
    enabled = false
  }

  tags = var.tags
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = var.node_group_name
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = var.node_capacity_type

  launch_template {
    id      = var.launch_template_id
    version = var.launch_template_version
  }

  labels = {
    "alpha.eksctl.io/cluster-name"   = var.cluster_name
    "alpha.eksctl.io/nodegroup-name" = var.node_group_name
  }

  tags = merge(
    var.tags,
    {
      "alpha.eksctl.io/cluster-name"               = var.cluster_name
      "alpha.eksctl.io/nodegroup-name"             = var.node_group_name
      "alpha.eksctl.io/nodegroup-type"             = "managed"
      "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = var.cluster_name
    }
  )

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  depends_on = [aws_eks_cluster.this]
}
