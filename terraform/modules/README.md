# Terraform Modules

This directory contains reusable Terraform modules for the GitHub Actions EKS Runners infrastructure.

## Modules

### `eks/`

Creates and manages the EKS cluster and node group.

**Inputs:**
- `cluster_name` - Name of the EKS cluster (default: `github-action-runners`)
- `cluster_version` - Kubernetes version (default: `1.35`)
- `region` - AWS region (required)
- `vpc_id` - VPC ID (required)
- `subnet_ids` - List of subnet IDs (required)
- `cluster_role_arn` - IAM role ARN for cluster (required)
- `node_role_arn` - IAM role ARN for nodes (required)
- `node_instance_type` - EC2 instance type (default: `t3.small`)
- `node_desired_size` - Desired number of nodes (default: `3`)
- `node_min_size` - Minimum number of nodes (default: `3`)
- `node_max_size` - Maximum number of nodes (default: `6`)
- `node_capacity_type` - Capacity type: `ON_DEMAND` or `SPOT` (default: `ON_DEMAND`)
- `launch_template_id` - Launch template ID for nodes (required)
- `tags` - Tags to apply to resources (default: `{}`)

**Outputs:**
- `cluster_id` - EKS cluster ID
- `cluster_arn` - EKS cluster ARN
- `cluster_endpoint` - Cluster endpoint URL
- `cluster_oidc_issuer_url` - OIDC issuer URL
- `node_group_id` - Node group ID
- `node_group_scaling_config` - Current scaling configuration

**Example:**
```hcl
module "eks" {
  source = "./modules/eks"

  cluster_name       = "my-cluster"
  region             = "us-east-2"
  vpc_id             = "vpc-xxxxx"
  subnet_ids         = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
  cluster_role_arn   = "arn:aws:iam::123456789:role/eks-cluster-role"
  node_role_arn      = "arn:aws:iam::123456789:role/eks-node-role"
  launch_template_id = "lt-xxxxx"
}
```

### `cluster-autoscaler/`

Deploys the Cluster Autoscaler for automatic node scaling based on pod demand.

**Inputs:**
- `cluster_name` - Name of the EKS cluster (required)
- `cluster_endpoint` - Cluster API endpoint (required)
- `cluster_ca_certificate` - Base64 encoded CA certificate (required)
- `cluster_auth_token` - Auth token for cluster (required)
- `cluster_oidc_issuer_url` - OIDC issuer URL (required)
- `oidc_provider_arn` - OIDC provider ARN (required)
- `namespace` - Kubernetes namespace (default: `kube-system`)
- `tags` - Tags to apply to resources (default: `{}`)

**Outputs:**
- `cluster_autoscaler_role_arn` - IAM role ARN for Cluster Autoscaler
- `cluster_autoscaler_namespace` - Namespace where Cluster Autoscaler is deployed
- `cluster_autoscaler_service_account_name` - Service account name

**Example:**
```hcl
module "cluster_autoscaler" {
  source = "./modules/cluster-autoscaler"

  cluster_name             = module.eks.cluster_id
  cluster_endpoint         = module.eks.cluster_endpoint
  cluster_ca_certificate   = module.eks.cluster_certificate_authority_data
  cluster_auth_token       = data.aws_eks_auth.cluster.token
  cluster_oidc_issuer_url  = module.eks.cluster_oidc_issuer_url
  oidc_provider_arn        = data.aws_iam_openid_connect_provider.eks.arn
  
  depends_on = [module.eks]
}
```

## Usage

All modules are already integrated in the root `main.tf`. To use them:

1. **Update terraform.tfvars** with your configuration
2. **Run Terraform:**
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

## Scaling Modules

To add new modules (e.g., for Karpenter, monitoring, etc.):

1. Create a new directory under `modules/`
2. Add `variables.tf`, `main.tf`, and `outputs.tf`
3. Reference in the root `main.tf` using `module` blocks
4. Update root `variables.tf` and `outputs.tf` as needed

## Module Structure

Each module should follow this standard structure:
```
modules/
├── module-name/
│   ├── main.tf          # Primary resources
│   ├── variables.tf     # Input variables
│   ├── outputs.tf       # Output values
│   └── README.md        # Module documentation (optional)
```

## Benefits

- **Reusability**: Use modules across multiple projects
- **Maintainability**: Centralized resource definitions
- **Testability**: Modules can be tested independently
- **Flexibility**: Override defaults with custom values
- **Documentation**: Each module is self-documenting
