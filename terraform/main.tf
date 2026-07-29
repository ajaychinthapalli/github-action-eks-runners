resource "aws_eks_cluster" "this" {
  name     = "github-action-runners"
  role_arn = "arn:aws:iam::573631993187:role/EKSGitHubActionRunnersClusterRole"
  version  = "1.35"

  vpc_config {
    subnet_ids         = ["subnet-0c64567346e73d262", "subnet-09f84b244190d486d", "subnet-063a2dce85fd8d00d"]
    security_group_ids = ["sg-0c282bf1819cb9164"]
  }
}

resource "aws_eks_node_group" "workers" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "workers"
  node_role_arn   = "arn:aws:iam::573631993187:role/eksctl-github-action-runners-nodeg-NodeInstanceRole-rq6Xw1wnvMIY"
  subnet_ids      = ["subnet-0c64567346e73d262", "subnet-09f84b244190d486d", "subnet-063a2dce85fd8d00d"]
  instance_types  = ["t3.small"]
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = "ON_DEMAND"
  disk_size       = null

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 2
  }
}
