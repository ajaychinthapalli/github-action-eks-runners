# Terraform Infrastructure Documentation

This document describes the Terraform infrastructure for the GitHub Actions EKS Runners.

## Overview

The infrastructure is organized into modular Terraform code:

```
terraform/
├── backend.tf              # Terraform backend configuration and providers
├── main.tf                 # Root module that uses other modules
├── variables.tf            # Root module input variables
├── outputs.tf              # Root module outputs
├── terraform.tfvars        # Variable values for your environment
├── example.tfvars          # Example configuration with Spot instances
└── modules/
    ├── eks/                # EKS cluster and node group module
    └── cluster-autoscaler/ # Cluster Autoscaler module
```

## File Purposes

### `backend.tf`
Configures Terraform backend (S3 + DynamoDB for remote state) and AWS/Kubernetes providers.

**Key Points:**
- State stored in S3 with encryption and locking
- Kubernetes provider configured to access cluster after creation
- Requires AWS credentials with OIDC or static keys

### `main.tf`
Instantiates modules to create the actual infrastructure.

**Contains:**
- `module.eks` - Creates EKS cluster and node group
- `module.cluster_autoscaler` - Deploys Cluster Autoscaler for auto-scaling
- `data.aws_iam_openid_connect_provider` - Gets OIDC provider for pod authentication

### `variables.tf`
Defines all input variables with validation and defaults.

**Key Variables:**
- Infrastructure configuration (cluster name, region, VPC, subnets)
- Node configuration (instance type, scaling settings, capacity type)
- IAM role ARNs
- Launch template configuration

### `outputs.tf`
Exposes important cluster information after creation.

**Key Outputs:**
- Cluster endpoint and CA certificate
- Node group status and scaling configuration
- kubectl configuration command
- Cluster Autoscaler role ARN

### `terraform.tfvars`
**WARNING:** Contains sensitive IDs and secrets. **Never commit to public repositories.**

Provides values for variables defined in `variables.tf`:
```hcl
cluster_name = "github-action-runners"
region       = "us-east-2"
vpc_id       = "vpc-xxxxx"
subnet_ids   = ["subnet-xxxxx", "subnet-yyyyy", "subnet-zzzzz"]
# ... etc
```

To use a different environment, create `terraform.prod.tfvars` and apply with:
```bash
terraform apply -var-file="terraform.prod.tfvars"
```

### `example.tfvars`
Example configuration for reference. Shows how to enable Spot instances and other common options.

## Quick Start

### 1. Initialize Terraform

```bash
cd terraform
terraform init
```

This will:
- Download provider plugins
- Configure remote state backend
- Create DynamoDB lock table if needed

### 2. Review and Update Configuration

Edit `terraform.tfvars` with your values:
```bash
vim terraform.tfvars
```

Critical fields to update:
- `vpc_id`, `subnet_ids` - From your AWS account
- `cluster_role_arn`, `node_role_arn` - From your AWS account
- `launch_template_id` - From your AWS account

### 3. Plan Changes

```bash
terraform plan
```

This shows what will be created/modified. Review carefully.

### 4. Apply Configuration

```bash
terraform apply
```

Confirms and applies changes. Monitor the progress.

### 5. Configure kubectl

After successful apply, run:
```bash
$(terraform output -raw configure_kubectl)
```

Or manually:
```bash
aws eks update-kubeconfig --region us-east-2 --name github-action-runners
```

## Common Tasks

### Scale Nodes

Update `terraform.tfvars`:
```hcl
node_desired_size = 5  # Change from 3 to 5
```

Apply:
```bash
terraform plan
terraform apply
```

### Change Instance Type

Update `terraform.tfvars`:
```hcl
node_instance_type = "t3.medium"  # Change from t3.small
```

Apply:
```bash
terraform apply
```

The new nodes will be created, old ones drained and terminated.

### Enable Spot Instances

Update `terraform.tfvars`:
```hcl
node_capacity_type = "SPOT"
node_max_size      = 10  # Increase max for burst capacity
```

Apply:
```bash
terraform apply
```

### Update Tags

Update `terraform.tfvars`:
```hcl
tags = {
  "Environment" = "production"
  "ManagedBy"   = "Terraform"
  "CostCenter"  = "engineering"
}
```

Apply:
```bash
terraform apply
```

## Outputs Reference

After `terraform apply`, important outputs are displayed:

```
cluster_id = "github-action-runners"
cluster_endpoint = "https://XXXXX.eks.us-east-2.amazonaws.com"
cluster_oidc_issuer_url = "https://oidc.eks.us-east-2.amazonaws.com/id/XXXXX"
node_group_scaling_config = {
  current_size = 3
  max_size = 6
  min_size = 3
}
configure_kubectl = "aws eks update-kubeconfig --region us-east-2 --name github-action-runners"
```

Retrieve outputs anytime with:
```bash
terraform output
terraform output cluster_id
terraform output -json
```

## State Management

**IMPORTANT:** Terraform state contains sensitive information (certificates, tokens, ARNs).

### Viewing State

```bash
# List all resources in state
terraform state list

# Show detailed state for a resource
terraform state show module.eks.aws_eks_cluster.this

# DO NOT run: terraform show
# This prints entire state including sensitive data
```

### Backing Up State

The S3 backend automatically versions your state. To download:
```bash
aws s3 cp s3://github-action-runners-tfstate/eks/terraform.tfstate ./backup/
```

### Recovering State

If corrupted, restore from S3 backup:
```bash
aws s3 cp ./backup/terraform.tfstate s3://github-action-runners-tfstate/eks/
```

## Troubleshooting

### "Error acquiring the backend lock"

Another apply is in progress. Wait and retry:
```bash
# Or force unlock (dangerous - only if you're sure):
terraform force-unlock <LOCK-ID>
```

### "Error: Error creating Cluster: InvalidRequestException: No subnets found"

Update `terraform.tfvars` with correct subnet IDs:
```bash
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=vpc-xxxxx \
  --query "Subnets[].SubnetId"
```

### "Error: Error creating node group: InvalidRequestException: NodeRole cannot have empty"

Verify `node_role_arn` in `terraform.tfvars` is correct and attached to nodes.

### Node group stuck in CREATING state

Check node group events:
```bash
aws eks describe-nodegroup \
  --cluster-name github-action-runners \
  --nodegroup-name workers \
  --query 'nodegroup.health'
```

## Best Practices

1. **Version Lock**: Commit `.terraform.lock.hcl` to version control
2. **Variable Segregation**: Use separate `*.tfvars` files for dev/staging/prod
3. **State Security**: 
   - Enable S3 bucket versioning
   - Restrict IAM access to S3 state bucket
   - Enable S3 encryption
4. **Change Reviews**: Always review `terraform plan` output before apply
5. **Tagging**: Use consistent tags for cost allocation and organization
6. **Module Testing**: Test module changes in a dev environment first

## References

- [AWS EKS Terraform Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster)
- [Kubernetes Terraform Provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs)
- [Terraform State Management](https://www.terraform.io/language/state)
- [Cluster Autoscaler Docs](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md)
