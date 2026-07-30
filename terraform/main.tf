module "eks" {
  source = "./modules/eks"

  cluster_name              = var.cluster_name
  cluster_version           = var.cluster_version
  region                    = var.region
  vpc_id                    = var.vpc_id
  cluster_security_group_id = var.cluster_security_group_id
  subnet_ids                = var.subnet_ids
  cluster_role_arn          = var.cluster_role_arn
  node_role_arn             = var.node_role_arn
  node_group_name           = var.node_group_name
  node_instance_type        = var.node_instance_type
  node_desired_size         = var.node_desired_size
  node_min_size             = var.node_min_size
  node_max_size             = var.node_max_size
  node_capacity_type        = var.node_capacity_type
  launch_template_id        = var.launch_template_id
  launch_template_version   = var.launch_template_version
  tags                      = var.tags
}

module "cluster_autoscaler" {
  source = "./modules/cluster-autoscaler"

  cluster_name           = module.eks.cluster_id
  cluster_endpoint       = module.eks.cluster_endpoint
  cluster_ca_certificate = module.eks.cluster_certificate_authority_data
  cluster_auth_token     = data.aws_eks_auth.cluster.token
  cluster_oidc_issuer_url = module.eks.cluster_oidc_issuer_url
  oidc_provider_arn      = data.aws_iam_openid_connect_provider.eks.arn
  tags                   = var.tags

  depends_on = [module.eks]
}

# Get OIDC provider details
data "aws_iam_openid_connect_provider" "eks" {
  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"

  depends_on = [module.eks]
}

data "aws_caller_identity" "current" {}

