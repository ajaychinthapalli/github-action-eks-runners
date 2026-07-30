# Spot Instances Configuration Guide

This guide explains how to use AWS Spot Instances to reduce costs for your GitHub Actions runners.

## Overview

Spot Instances are unused EC2 capacity available at discounts up to 70% compared to On-Demand pricing. The trade-off is that AWS can interrupt instances with 2-minute notice when capacity is needed.

**Cost Comparison** (t3.small in us-east-2):
- On-Demand: ~$0.0208/hour = ~$152/month
- Spot: ~$0.0061/hour = ~$45/month (70% savings)

## When to Use Spot Instances

### ✅ Good Use Cases
- CI/CD pipelines (can be re-run if interrupted)
- Batch processing jobs
- Development/testing runners
- Non-critical background tasks
- Repositories with low-priority jobs

### ❌ Not Recommended
- Production deployments
- Long-running stateful jobs
- Database operations
- Financial transactions
- Anything with strict SLA requirements

## Configuration

### Option 1: Full Spot Setup (Fastest to Reduce Costs)

Update `terraform/terraform.tfvars`:

```hcl
node_capacity_type = "SPOT"
node_desired_size  = 2    # Start with fewer permanent nodes
node_min_size      = 2    # Always keep 2 nodes for availability
node_max_size      = 10   # Allow scaling up to handle burst
```

Apply:
```bash
cd terraform
terraform apply -var-file="terraform.tfvars"
```

**Cost Impact**: ~$90/month for nodes + $73 EKS = ~$163/month

### Option 2: Hybrid Setup (Recommended for Production)

Mix On-Demand and Spot nodes for reliability:

Create `terraform/terraform.prod.tfvars`:

```hcl
# 2 permanent On-Demand nodes for baseline capacity
node_capacity_type = "ON_DEMAND"
node_desired_size  = 2
node_min_size      = 2
node_max_size      = 4

# Then add a second node group with Spot instances
```

For the second node group, you would need to add to modules or root main.tf:

```hcl
module "eks_spot" {
  source = "./modules/eks"
  
  cluster_name    = var.cluster_name
  node_group_name = "workers-spot"
  capacity_type   = "SPOT"
  desired_size    = 2
  min_size        = 0
  max_size        = 10
  
  # ... other configuration
}
```

**Cost Impact**: ~$45 (4 On-Demand) + ~$61 (10 Spot) = ~$106/month

### Option 3: Spot-Only for Dev/Test (Maximum Savings)

Update `terraform.tfvars`:

```hcl
node_capacity_type = "SPOT"
node_desired_size  = 1    # Minimal permanent capacity
node_min_size      = 0    # Scale to zero when idle
node_max_size      = 5    # Scale up as needed
```

**Cost Impact**: ~$36/month for nodes + $73 EKS = ~$109/month

## Implementation Steps

### 1. Update Terraform Configuration

Edit `terraform/terraform.tfvars`:

```diff
- node_capacity_type = "ON_DEMAND"
+ node_capacity_type = "SPOT"
```

### 2. Plan the Changes

```bash
cd terraform
terraform plan
```

Review the changes - you should see the node group capacity type changing.

### 3. Apply with Downtime Awareness

```bash
# This will drain and replace nodes, which may interrupt runners
terraform apply

# Monitor the process:
kubectl get nodes -w
kubectl get pods -n arc-runners -w
```

### 4. Verify Spot Instances

```bash
# Check if nodes are Spot instances
aws ec2 describe-instances \
  --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=github-action-runners" \
  --query 'Reservations[].Instances[].{InstanceId:InstanceId,InstanceType:InstanceType,InstanceLifecycle:InstanceLifecycle}'

# Should show "InstanceLifecycle: spot" for Spot instances
```

## Handling Interruptions

### Graceful Pod Eviction

Configure Pod Disruption Budgets (PDB) to allow graceful shutdown:

```yaml
# Create in the arc-runners namespace
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: runner-pdb
  namespace: arc-runners
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: gha-runner-scale-set
```

Apply:
```bash
kubectl apply -f runner-pdb.yaml
```

### Cluster Autoscaler Configuration

The Cluster Autoscaler will:
1. Try to drain nodes before termination
2. Reschedule pods to other nodes
3. Scale up new nodes if needed

Current configuration in `modules/cluster-autoscaler/main.tf`:
```hcl
"--skip-nodes-with-local-storage=false"  # Allow eviction of local storage
```

### ARC Runner Configuration

Update `arc-runner-set/values-small.yaml` to handle interruptions:

```yaml
minRunners: 0   # Scale down when jobs complete (saves money)
maxRunners: 10  # Allow burst to handle interruptions

# Add pod disruption budget
template:
  spec:
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - gha-runner-scale-set
              topologyKey: kubernetes.io/hostname
```

## Monitoring Spot Interruptions

### Check for Evicted Pods

```bash
kubectl get events -n arc-runners --sort-by='.lastTimestamp' | grep Evicted
```

### View Spot Interruption Notices

EC2 Instance Metadata Service provides 2-minute warning:

```bash
# On a Spot instance node
curl http://169.254.169.254/latest/meta-data/spot/instance-action
```

### CloudWatch Metrics

Enable CloudWatch Container Insights to track interruptions:

```bash
# Check Spot Fleet Interruption Rate
aws ec2 describe-spot-price-history \
  --instance-types t3.small \
  --product-descriptions "Linux/UNIX" \
  --region us-east-2
```

## Cost Monitoring

### Estimate Monthly Savings

```bash
# Current monthly cost
echo "On-Demand: $(echo '4 * 0.0208 * 730' | bc) / month"

# With Spot
echo "Spot: $(echo '4 * 0.0061 * 730' | bc) / month"

# Savings
echo "Savings: $(echo '4 * (0.0208 - 0.0061) * 730' | bc) / month"
```

### AWS Cost Explorer

1. Go to AWS Console → Cost Explorer
2. Filter by instance type: `t3.small`
3. Compare On-Demand vs Spot costs
4. Set up Cost Anomaly Detection alerts

### Terraform Costs

Get estimated monthly costs:

```bash
# Install infracost (https://www.infracost.io)
infracost breakdown --path terraform/

# Shows cost before/after Spot vs On-Demand
```

## Troubleshooting

### Runners keep getting interrupted

**Symptoms**: Jobs fail frequently, nodes terminating unexpectedly

**Solutions**:
1. Check Spot price history - maybe pricing is high
2. Use On-Demand during peak hours, Spot during off-hours
3. Enable diversification across instance types
4. Increase PDB `maxUnavailable` to allow more pod eviction

### Cluster Autoscaler can't scale up

**Symptoms**: Pods pending, not scaling new nodes

**Possible Causes**:
- Spot capacity exhausted in region
- Max nodes reached
- Insufficient IAM permissions

**Solutions**:
```bash
# Check Cluster Autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler -f

# Try different instance type
# Edit terraform.tfvars:
node_instance_type = "t3.medium"  # Try different size
```

### Spot interruptions cause CI failures

**Solutions**:
1. Configure job retry logic in GitHub Actions
2. Use `continue-on-error` for non-critical steps
3. Implement exponential backoff for API calls
4. Consider mixed On-Demand/Spot setup

## Best Practices

### 1. Start with Baseline On-Demand Capacity

Keep minimum On-Demand nodes to ensure availability:

```hcl
node_capacity_type = "ON_DEMAND"
node_min_size      = 2  # Baseline capacity
node_max_size      = 10 # Allow growth

# Add second node group for Spot burst
```

### 2. Set Appropriate PDB Values

```yaml
spec:
  maxUnavailable: 1  # Allow 1 pod to be evicted
  minAvailable: 2    # Keep at least 2 runners available
```

### 3. Monitor Interruption Rates

Track Spot interruption frequency for your region:

```bash
aws ec2 describe-spot-price-history \
  --instance-types t3.small t3.medium \
  --region us-east-2 \
  --start-time $(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%S.000Z) \
  --product-descriptions "Linux/UNIX"
```

### 4. Use Taints and Tolerations

Mark Spot nodes specially:

```hcl
# In EKS module, add to node group:
labels = {
  "workload-type" = "spot"
}

# Then in pod specs:
tolerations:
  - key: "workload-type"
    operator: "Equal"
    value: "spot"
    effect: "NoSchedule"
```

### 5. Region/AZ Diversification

Use multiple availability zones to reduce interruption impact:

```hcl
subnet_ids = [
  "subnet-xxxxx",  # us-east-2a
  "subnet-yyyyy",  # us-east-2b
  "subnet-zzzzz"   # us-east-2c
]
```

## Rollback to On-Demand

If Spot causes issues:

```hcl
# In terraform.tfvars
node_capacity_type = "ON_DEMAND"
```

Apply:
```bash
terraform apply
```

Nodes will be replaced with On-Demand instances.

## References

- [AWS Spot Instances](https://aws.amazon.com/ec2/spot/)
- [Spot Instance Interruption Notices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-interruptions.html)
- [EKS Spot Integration](https://docs.aws.amazon.com/eks/latest/userguide/spot-instances.html)
- [Cluster Autoscaler Spot Support](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md)
