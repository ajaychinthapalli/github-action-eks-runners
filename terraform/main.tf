resource "aws_eks_cluster" "this" {
  name                           = "github-action-runners"
  role_arn                       = "arn:aws:iam::573631993187:role/EKSGitHubActionRunnersClusterRole"
  version                        = "1.35"
  bootstrap_self_managed_addons  = false

  vpc_config {
    subnet_ids              = ["subnet-0c64567346e73d262", "subnet-09f84b244190d486d", "subnet-063a2dce85fd8d00d"]
    security_group_ids      = ["sg-0c282bf1819cb9164"]
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

  tags = {}
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "workers"
  node_role_arn   = "arn:aws:iam::573631993187:role/eksctl-github-action-runners-nodeg-NodeInstanceRole-rq6Xw1wnvMIY"
  subnet_ids      = ["subnet-0c64567346e73d262", "subnet-09f84b244190d486d", "subnet-063a2dce85fd8d00d"]
  instance_types  = ["t3.small"]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"

  launch_template {
    id      = "lt-000151662f18394c5"
    version = "1"
  }

  labels = {
    "alpha.eksctl.io/cluster-name"   = "github-action-runners"
    "alpha.eksctl.io/nodegroup-name" = "workers"
  }

  tags = {
    "alpha.eksctl.io/cluster-name"                = "github-action-runners"
    "alpha.eksctl.io/eksctl-version"               = "0.229.0"
    "alpha.eksctl.io/nodegroup-name"                = "workers"
    "alpha.eksctl.io/nodegroup-type"                = "managed"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name"  = "github-action-runners"
  }

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }
}
