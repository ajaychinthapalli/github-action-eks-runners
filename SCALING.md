# Scaling Guide for GitHub Actions EKS Runners

This guide covers how to scale the GitHub Actions EKS runner infrastructure for performance and cost efficiency.

## Overview

The runner infrastructure consists of:
- **EKS Cluster**: Managed Kubernetes control plane
- **Worker Nodes**: EC2 instances where runner pods execute (currently `t3.small`)
- **Cluster Autoscaler**: Automatically scales nodes based on demand
- **ARC Runner Scale Set**: Dynamically provisions runner pods (configured via Helm)

## Node Scaling

### Current Configuration

```hcl
node_desired_size = 3     # Current number of running nodes
node_min_size     = 3     # Minimum nodes to maintain
node_max_size     = 6     # Maximum nodes (Cluster Autoscaler limit)
node_capacity_type = "ON_DEMAND"  # Can change to "SPOT" for cost savings
node_instance_type = "t3.small"   # 2 vCPU, 2 GiB memory
```

### Scaling Up (Increasing Capacity)

1. **Increase desired size for immediate scaling:**

   ```bash
   cd terraform
   # Update terraform.tfvars
   echo "node_desired_size = 4" >> terraform.tfvars
   terraform plan
   terraform apply
   ```

   This adds permanent nodes. The Cluster Autoscaler will manage additional temporary scaling.

2. **Increase max size to allow Cluster Autoscaler to scale higher:**

   ```hcl
   node_max_size = 10  # Allows Cluster Autoscaler to provision up to 10 nodes
   ```

3. **Increase per-runner resource limits:**

   Edit `arc-runner-set/values-small.yaml`:
   ```yaml
   template:
     spec:
       containers:
         - name: dind
           resources:
             requests: { cpu: "200m", memory: "200Mi" }  # Increase from 150m/150Mi
             limits: { cpu: "400m", memory: "400Mi" }    # Increase from 300m/300Mi
   ```

### Scaling Down (Reducing Costs)

1. **Reduce desired size:**

   ```hcl
   node_desired_size = 2
   node_min_size     = 2
   ```

2. **Monitor runner queue before scaling down:**

   ```bash
   kubectl logs -n arc-runners -l app=gha-runner-scale-set -f
   ```

3. **Drain nodes gracefully before removal:**

   ```bash
   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
   ```

## Instance Type Selection

### Free Tier Eligible (recommended for development)
- **t3.micro**: 2 vCPU, 1 GiB memory - limited for Docker builds
- **t3.small**: 2 vCPU, 2 GiB memory - default, good balance
- **t4g.small**: 2 vCPU, 2 GiB memory - ARM-based, cheaper

### Production Recommended
- **t3.medium**: 2 vCPU, 4 GiB memory - better for memory-intensive jobs
- **m7i-flex.large**: 2 vCPU, 8 GiB memory - large builds

### GPU Support (for ML workloads)
- **g4dn.xlarge**: 4 vCPU, 16 GiB + NVIDIA T4 GPU
- Requires: `ami_type = "AL2_x86_64_GPU"` and GPU-enabled node group

### Changing Instance Type

1. **Create new node group with desired type:**

   ```bash
   cd terraform
   # Update in terraform.tfvars
   node_instance_type = "t3.medium"
   terraform apply
   ```

2. **Drain old nodes (one at a time):**

   ```bash
   kubectl drain <old-node> --ignore-daemonsets --delete-emptydir-data
   ```

## Spot Instances for Cost Reduction

Spot instances provide **70% cost savings** but can be interrupted with 2-minute notice.

### Enable Spot Instances

Update `terraform.tfvars`:

```hcl
node_capacity_type = "SPOT"
node_max_size      = 10        # Increase max to handle interruptions
```

### Best Practices with Spot

1. **Use mixed capacity types:**

   ```hcl
   # Keep some ON_DEMAND nodes for critical jobs
   node_capacity_type = "ON_DEMAND"  # Default
   # Create second node group with SPOT
   ```

2. **Configure Pod Disruption Budgets:**

   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: runner-pdb
     namespace: arc-runners
   spec:
     maxUnavailable: 1
     selector:
       matchLabels:
         app: runner
   ```

3. **Monitor interruptions:**

   ```bash
   kubectl get events -n arc-runners --sort-by='.lastTimestamp' | grep Evicted
   ```

## Runner Pod Scaling (ARC)

### Current Configuration

```yaml
minRunners: 0         # Minimum runners to keep idle
maxRunners: 5         # Maximum concurrent runners
```

### Scaling the Runner Scale Set

Edit `arc-runner-set/values-small.yaml`:

```yaml
# Increase concurrent runners
maxRunners: 10

# Keep warm runners ready (costs more but faster job start)
minRunners: 1

# Adjust resource limits based on job requirements
template:
  spec:
    containers:
      - name: runner
        resources:
          requests: { cpu: "150m", memory: "150Mi" }
          limits: { cpu: "300m", memory: "300Mi" }
```

### Trigger ArgoCD Sync

```bash
argocd app sync arc-runner-set
```

Or wait for automatic sync (configured every 3 minutes by default).

## Monitoring & Metrics

### Check Cluster Status

```bash
# Node resource utilization
kubectl top nodes

# Pod resource usage
kubectl top pods -n arc-runners

# Check Cluster Autoscaler logs
kubectl logs -n kube-system -l app=cluster-autoscaler -f
```

### CloudWatch Metrics

Enable Container Insights for detailed monitoring:

```bash
# Deploy CloudWatch agent
aws ec2 describe-instances --filters "Name=tag:alpha.eksctl.io/cluster-name,Values=github-action-runners"
```

### Important Metrics

- **Node CPU/Memory**: Monitor via `kubectl top nodes`
- **Pod Pending**: Indicates need to scale nodes
- **Cluster Autoscaler Scaling Activity**: Check logs for scaling decisions
- **Runner Queue Depth**: Check ARC logs for pending runners

## Troubleshooting

### Nodes not scaling up automatically

**Issue**: Runners pending but nodes not increasing

```bash
# Check Cluster Autoscaler logs
kubectl logs -n kube-system deployment/cluster-autoscaler

# Common causes:
# 1. Max nodes reached
# 2. IAM permissions missing
# 3. Insufficient capacity in AZs
```

**Solution**:
```hcl
# Increase max size
node_max_size = 15

# Apply
terraform apply
```

### Runners failing to start

**Issue**: Jobs queued but no runners available

```bash
# Check ARC logs
kubectl logs -n arc-systems -l app=gha-rs-controller -f

# Check runner pod logs
kubectl logs -n arc-runners -l app=gha-runner-scale-set --tail=100
```

**Solution**:
```yaml
# Increase runner limits in values-small.yaml
maxRunners: 20
minRunners: 2
```

### High costs

**Recommendations**:
1. Enable Spot instances (`node_capacity_type = "SPOT"`)
2. Use smaller instance type (`t3.small` instead of `t3.medium`)
3. Reduce `minRunners` to 0 (scale to zero)
4. Set aggressive Cluster Autoscaler scale-down delays

### Nodes not scaling down

**Issue**: Cluster keeps too many nodes

```bash
# Check if pods are preventing scale-down
kubectl get pods --all-namespaces --field-selector=status.phase=Pending

# Check eviction policies
kubectl get pdb --all-namespaces
```

**Solution**: Adjust Cluster Autoscaler scale-down settings in `cluster-autoscaler.tf`

## Cost Estimation

### Monthly costs (rough estimates)

**Current Setup** (3 × t3.small ON_DEMAND):
- 3 nodes × $0.0208/hour × 730 hours = ~$45.50/month
- EKS control plane = $73/month
- **Total: ~$118/month**

**With Spot (10 nodes max)**:
- Mix of ON_DEMAND and SPOT (70% savings)
- Average: ~$50-60/month for nodes + $73 EKS
- **Total: ~$125-130/month** (better burst capacity)

**Scaling to zero** (0 min runners):
- EKS only: $73/month
- Nodes spin up as needed (minimal idle cost)
- **Total: ~$73/month** (best for low-traffic repos)

## Production Checklist

- [ ] Set `node_min_size >= 2` for high availability
- [ ] Enable multi-AZ subnets for node distribution
- [ ] Configure Pod Disruption Budgets
- [ ] Set up CloudWatch alarms for node scaling failures
- [ ] Document custom instance types for team
- [ ] Test Spot instance interruptions in staging
- [ ] Monitor costs via AWS Cost Explorer
- [ ] Regular backup of Terraform state

## Next Steps

1. **Implement autoscaling tiers**:
   - Small jobs: t3.small (default)
   - Large jobs: t3.large or m-series
   
2. **Add Karpenter** (advanced):
   - More sophisticated scheduling than Cluster Autoscaler
   - Better bin-packing for cost optimization
   - Consolidation of underutilized nodes

3. **Multi-region setup**:
   - Replicate to other regions for global CI/CD
   - Use Terraform workspaces for easy management

## References

- [AWS EKS Scaling](https://docs.aws.amazon.com/eks/latest/userguide/autoscaling.html)
- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md)
- [ARC Documentation](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller)
- [EC2 Pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
