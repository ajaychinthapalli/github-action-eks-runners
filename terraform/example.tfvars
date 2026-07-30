# Example configuration for using Spot instances to reduce costs
# Spot instances can provide up to 70% savings but may be interrupted
# Uncomment and modify the node_capacity_type and node_max_size values below

# cluster_name                = "github-action-runners"
# cluster_version             = "1.35"
# region                      = "us-east-2"
# vpc_id                      = "vpc-0c64567346e73d262"
# cluster_security_group_id   = "sg-your-security-group-id"
# subnet_ids                  = ["subnet-0c64567346e73d262", "subnet-09f84b244190d486d", "subnet-063a2dce85fd8d00d"]
# cluster_role_arn            = "arn:aws:iam::573631993187:role/EKSGitHubActionRunnersClusterRole"
# node_role_arn               = "arn:aws:iam::573631993187:role/eksctl-github-action-runners-nodeg-NodeInstanceRole-rq6Xw1wnvMIY"
# node_group_name             = "workers"
# node_instance_type          = "t3.small"
# node_desired_size           = 3
# node_min_size               = 3
# node_max_size               = 10                # Increased for Spot scaling
# node_capacity_type          = "SPOT"            # Use Spot instances for cost savings
# launch_template_id          = "lt-000151662f18394c5"
# launch_template_version     = "1"
#
# tags = {
#   "Environment" = "production"
#   "ManagedBy"   = "Terraform"
#   "CostCenter"  = "engineering"
# }
