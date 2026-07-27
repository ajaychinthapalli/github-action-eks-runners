# ARC on EKS — Setup Guide (`github-action-runners`)

Tested, working, end-to-end guide for running GitHub Actions self-hosted runners on Amazon EKS via the Actions Runner Controller (ARC). This reflects the actual working configuration for the `github-action-runners` cluster in `us-east-2`.

## Architecture recap

- **Master nodes**: none to provision. EKS is a managed service — AWS runs the control plane (API server, etcd, scheduler) across multiple AZs.
- **Worker nodes**: 3 × `t3.small` (2 vCPU, 2 GiB each), chosen because the AWS account is Free Tier-restricted and `t3.medium` wasn't eligible.
- **Namespaces**: `arc-systems` (ARC controller + listener pods), `arc-runners` (ephemeral runner job pods).

## Prerequisites

From the AWS Console: **EKS → Clusters → github-action-runners → Connect** launches a CloudShell session with AWS CLI and kubectl already configured for the cluster — no local install needed for those two.

Install `eksctl` and `helm` manually inside that CloudShell session:

```bash
# eksctl
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# Helm 3
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod +x get_helm.sh
./get_helm.sh
helm version
```

## Step 1: Gather the cluster's VPC details

This cluster was created through the AWS Console, not `eksctl` — so `eksctl` can't auto-discover its networking and needs it supplied explicitly.

```bash
aws eks describe-cluster --name github-action-runners --region us-east-2 \
  --query "cluster.resourcesVpcConfig.{VpcId:vpcId,SecurityGroup:clusterSecurityGroupId,Subnets:subnetIds}" \
  --output json
```

```bash
aws ec2 describe-subnets --subnet-ids <subnet-1> <subnet-2> <subnet-3> \
  --query "Subnets[].{ID:SubnetId,AZ:AvailabilityZone,PublicIP:MapPublicIpOnLaunch}" \
  --output table
```

## Step 2: Confirm which instance types the account can launch

```bash
aws ec2 describe-instance-types \
  --filters Name=free-tier-eligible,Values=true \
  --region us-east-2 \
  --query "InstanceTypes[].InstanceType" \
  --output table
```

| Type | vCPUs | Memory | Architecture |
|---|---|---|---|
| t3.micro | 2 | 1 GiB | x86_64 |
| **t3.small (used)** | 2 | 2 GiB | x86_64 |
| t4g.micro | 2 | 1 GiB | ARM |
| t4g.small | 2 | 2 GiB | ARM |
| c7i-flex.large | 2 | 4 GiB | x86_64 |
| m7i-flex.large | 2 | 8 GiB | x86_64 |

`t3.small` was used — same x86_64 family as originally planned, enough memory for a Docker-in-Docker runner pod. `m7i-flex.large` (8 GiB) is the upgrade path if jobs get memory-starved.

## Step 3: Write the ClusterConfig file

```bash
cat > cluster.yaml << 'EOF'
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: github-action-runners
  region: us-east-2

vpc:
  id: "vpc-XXXXXXXX"
  securityGroup: "sg-XXXXXXXX"
  subnets:
    public:
      us-east-2a:
        id: "subnet-AAAAAAAA"
      us-east-2b:
        id: "subnet-BBBBBBBB"
      us-east-2c:
        id: "subnet-CCCCCCCC"

managedNodeGroups:
  - name: workers
    instanceType: t3.small
    desiredCapacity: 3
    minSize: 3
    maxSize: 3
EOF
```

Fill in the real `vpc-...`, `sg-...`, and `subnet-...` values from Step 1.

## Step 4: Create the nodegroup

```bash
eksctl create nodegroup --config-file=cluster.yaml
```

### Troubleshooting hit during setup

- **Stack hangs 20+ minutes then fails**: check the real reason instead of waiting —

  ```bash
  aws cloudformation describe-stack-events \
    --stack-name eksctl-github-action-runners-nodegroup-workers \
    --region us-east-2 \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].{Resource:LogicalResourceId,Status:ResourceStatus,Reason:ResourceStatusReason}" \
    --output table
  ```

  The actual cause here: `AsgInstanceLaunchFailures — InvalidParameterCombination - The specified instance type is not eligible for Free Tier` (from trying `t3.medium`). Fixed by switching to `t3.small` (Step 2).

- **Stack status `ROLLBACK_COMPLETE`**: can only be deleted, not retried in place —

  ```bash
  aws cloudformation delete-stack --stack-name eksctl-github-action-runners-nodegroup-workers --region us-east-2
  aws cloudformation wait stack-delete-complete --stack-name eksctl-github-action-runners-nodegroup-workers --region us-east-2
  ```

- **`eksctl create nodegroup` reports "created 0 nodegroup(s)"**: a nodegroup named `workers` was already registered against the cluster via the EKS API (leftover from a failed attempt) and got excluded —

  ```bash
  aws eks list-nodegroups --cluster-name github-action-runners --region us-east-2
  eksctl delete nodegroup --region=us-east-2 --cluster=github-action-runners --name=workers --drain=false
  ```

## Step 5: Verify the nodes

```bash
aws eks update-kubeconfig --name github-action-runners --region us-east-2
kubectl get nodes
```

All 3 nodes should show `Ready`.

## Step 6: Install the ARC controller

```bash
NAMESPACE="arc-systems"
helm install arc \
  --namespace "${NAMESPACE}" --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

```bash
kubectl get pods -n arc-systems
```

Note the controller's service account name and namespace — needed explicitly in Step 8:

```bash
kubectl get deployment -n arc-systems --show-labels
```

Look for `actions.github.com/controller-service-account-name=arc-gha-rs-controller` and `...-namespace=arc-systems`.

## Step 7: Set up GitHub authentication

```bash
kubectl create namespace arc-runners
kubectl create secret generic gh-pat \
  --namespace arc-runners \
  --from-literal=github_token='<YOUR_PAT>'
```

Classic PAT with `repo` and `admin:org` scopes (or a GitHub App for production use).

## Step 8: Deploy the runner scale set

```bash
cat > values-small.yaml << 'EOF'
githubConfigUrl: "https://github.com/ajaychinthapalli/github-action-eks-runners"

githubConfigSecret: gh-pat

controllerServiceAccount:
  namespace: arc-systems
  name: arc-gha-rs-controller

minRunners: 0
maxRunners: 5

template:
  spec:
    initContainers:
      - name: init-dind-externals
        image: ghcr.io/actions/actions-runner:latest
        command: ["cp", "-r", "/home/runner/externals/.", "/home/runner/tmpDir/"]
        volumeMounts:
          - name: dind-externals
            mountPath: /home/runner/tmpDir
    containers:
      - name: dind
        image: docker:dind
        args:
          - dockerd
          - --host=unix:///var/run/docker.sock
          - --group=$(DOCKER_GROUP_GID)
        env:
          - name: DOCKER_GROUP_GID
            value: "123"
        securityContext:
          privileged: true
        restartPolicy: Always
        resources:
          requests: { cpu: "150m", memory: "150Mi" }
          limits: { cpu: "300m", memory: "300Mi" }
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
          - name: dind-externals
            mountPath: /home/runner/externals
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: DOCKER_HOST
            value: unix:///var/run/docker.sock
          - name: RUNNER_WAIT_FOR_DOCKER_IN_SECONDS
            value: "120"
        resources:
          requests: { cpu: "150m", memory: "150Mi" }
          limits: { cpu: "300m", memory: "300Mi" }
        volumeMounts:
          - name: work
            mountPath: /home/runner/_work
          - name: dind-sock
            mountPath: /var/run
    volumes:
      - name: work
        emptyDir: {}
      - name: dind-sock
        emptyDir: {}
      - name: dind-externals
        emptyDir: {}
EOF
```

```bash
helm install arc-runner-set \
  --namespace arc-runners \
  -f values-small.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### Two gotchas fixed during setup — both baked into the file above

1. **`No gha-rs-controller deployment found using label ...`**: the chart's label-based auto-discovery of the controller failed (likely an RBAC restriction on the identity running `helm`). Fixed by adding `controllerServiceAccount.namespace`/`.name` explicitly, read straight off the controller deployment's own labels.
2. **Duplicate/misplaced `dind` container** (ended up inside `initContainers` instead of `containers`): caused by setting `containerMode.type: "dind"` *at the same time* as a fully custom `template.spec` — the chart auto-injects its own dind pod spec and merges it with the custom one, producing duplicates. Fix: **do not set `containerMode` at all** when hand-writing the full pod template (as done above) — it's one or the other, never both.

## Step 9: Verify

```bash
helm list -A
kubectl get pods -n arc-systems      # controller + listener pod live here
kubectl get pods -n arc-runners      # ephemeral runner job pods land here (only while a job runs)
```

Confirm the pod template merged correctly:

```bash
kubectl get autoscalingrunnerset arc-runner-set -n arc-runners -o jsonpath='{.spec.template.spec.initContainers[*].name}'
echo
kubectl get autoscalingrunnerset arc-runner-set -n arc-runners -o jsonpath='{.spec.template.spec.containers[*].name}'
```

Expect: `initContainers` → `init-dind-externals` only; `containers` → `dind runner`.

Check the listener is healthy:

```bash
kubectl logs -n arc-systems <listener-pod-name>
```

Healthy steady state looks like repeated `"Calculated target runner count" ... "assigned job"=0 decision=0` — this means it's authenticated with GitHub and polling normally while idle.

## Step 10: Test with a real workflow — confirmed working

`.github/workflows/arc-demo.yml` in `ajaychinthapalli/github-action-eks-runners`:

```yaml
name: ARC Demo
on: workflow_dispatch
jobs:
  test:
    runs-on: arc-runner-set
    steps:
      - run: echo "running on EKS via ARC"
```

Trigger manually from the Actions tab, then:

```bash
kubectl get pods -n arc-runners -w
```

**Result from this run**: job executed successfully on `arc-runner-set-lnv6f-runner-7wh2p`, printed `running on EKS via ARC`, and completed cleanly. End-to-end pipeline confirmed working: EKS cluster → `t3.small` worker nodes → ARC controller → runner scale set → live GitHub Actions execution.

## Pod capacity reference (3-node cluster)

**maxPods = ENIs × (IPs per ENI − 1) + 2**

| Instance type | Pods/node | Raw total (× 3 nodes) | Usable for workloads* |
|---|---|---|---|
| t3.small (3 ENIs, 6 IPs/ENI) | 17 | 51 | ~45 |
| m7i-flex.large (upgrade path) | higher | higher | higher |

\*Subtracts ~2 system daemonset pods per node (`aws-node`, `kube-proxy`). Confirm live values with `kubectl describe node <node-name> | grep -A5 Capacity`.

## Production notes

- **Upgrading ARC**: Helm cannot upgrade or delete ARC's CRDs. To upgrade the controller: uninstall the runner scale set(s), uninstall the controller, remove the `actions.github.com` CRDs, then reinstall.
- **Logging**: set up log collection for the controller, listener, and ephemeral runner pods before production use.
- **Namespaces**: keep the controller/listener (`arc-systems`) and runner job pods (`arc-runners`) separate, as configured here.
- **`t3` burstable CPU**: sustained heavy CI workloads can throttle once CPU credits run out — enable "Unlimited" mode (extra cost when bursting) if that becomes an issue, or move to `m7i-flex.large`.
- **Node headroom**: with only 3 nodes, losing one to maintenance/an AZ issue removes roughly a third of capacity — consider `minSize: 3, maxSize: 5` for headroom during rollouts.

## Sources

- [Non eksctl-created clusters — Eksctl User Guide](https://docs.aws.amazon.com/eks/latest/eksctl/unowned-clusters.html)
- [Get started with Actions Runner Controller](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/get-started)
- [Deploying runner scale sets with ARC](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets)
- [Authenticate to the GitHub API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)
- [gha-runner-scale-set values.yaml](https://github.com/actions/actions-runner-controller/blob/master/charts/gha-runner-scale-set/values.yaml)
- [Choose an optimal EC2 node instance type (max pods)](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html)
- [Amazon EKS one-click cluster access through CloudShell](https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-eks-one-click-cluster-access/)
