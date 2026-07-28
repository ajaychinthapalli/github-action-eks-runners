
# ARC + ArgoCD on EKS — Setup Guide (`github-action-runners`)

Tested, working, end-to-end guide covering all three phases built so far on the `github-action-runners` cluster in `us-east-2`: **Part 1** — GitHub Actions self-hosted runners via the Actions Runner Controller (ARC), for CI. **Part 2** — ArgoCD for GitOps-style continuous deployment. **Part 3** — handing the ARC runner scale set itself over to GitOps, so `minRunners`/`maxRunners` are managed via a Git-tracked values file.

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

## Part 2: ArgoCD — GitOps Continuous Deployment

With CI (ARC) working, the next phase adds ArgoCD for GitOps-style continuous deployment: ArgoCD watches a Git repo of Kubernetes manifests and auto-syncs the cluster to match, rather than deploying via manual `kubectl`/`helm` commands. This is the second leg of the target architecture (GitHub + ArgoCD + Terraform + EKS).

### Step 11: Install ArgoCD via Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd

helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 9.5.0 \
  --wait
```

```bash
kubectl get pods -n argocd
```

Expect `argocd-server`, `argocd-repo-server`, `argocd-application-controller`, `argocd-dex-server`, `argocd-redis`, and the ApplicationSet/notifications controllers all `Running`.

### Step 12: Get the initial admin password

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d
echo
```

### Step 13: Install the `argocd` CLI

```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
argocd version --client
```

### Step 14: Port-forward and log in

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
```

Leave this running in its own terminal/tab — it's a blocking foreground process. In a separate tab:

```bash
argocd login localhost:8081 --username admin --password <password-from-step-12> --insecure
argocd app list
```

An empty app list (not an error) is the expected result before any apps are registered.

### Step 15: Add manifests to the GitOps repo

Using the same repo as the ARC test workflow (`ajaychinthapalli/github-action-eks-runners`), plain YAML to start (simplest to validate the sync loop before moving to Helm/Kustomize):

```bash
mkdir -p manifests
cat > manifests/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-demo
  namespace: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: argocd-demo
  template:
    metadata:
      labels:
        app: argocd-demo
    spec:
      containers:
        - name: nginx
          image: nginxdemos/hello:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "100m"
              memory: "128Mi"
EOF

cat > manifests/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: argocd-demo
  namespace: demo-app
spec:
  selector:
    app: argocd-demo
  ports:
    - port: 80
      targetPort: 80
EOF

git add manifests/
git commit -m "Add ArgoCD demo manifests"
git push
```

### Step 16: Create the destination namespace and register the app

```bash
kubectl create namespace demo-app

argocd app create argocd-demo \
  --repo https://github.com/ajaychinthapalli/github-action-eks-runners.git \
  --path manifests \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace demo-app \
  --sync-policy automated \
  --self-heal
```

`--sync-policy automated --self-heal` is the core GitOps behavior: every Git push auto-deploys, and manual `kubectl` drift gets reverted back to match Git.

### Step 17: Verify

```bash
argocd app get argocd-demo
kubectl get pods -n demo-app
```

**Result from this run**: app created and synced successfully, confirming the GitOps loop (Git push → ArgoCD detects → auto-deploys) works end to end on this cluster.

### Step 18: Access the ArgoCD UI

AWS CloudShell has no browser-preview feature (unlike Google Cloud Shell or Cloud9), so a port-forward run inside CloudShell can't be opened in a local browser. Two working options:

- **Run port-forward from your local machine instead of CloudShell** (recommended — no extra AWS cost, nothing publicly exposed):

  ```bash
  # On your local machine, with AWS CLI configured for this account
  aws eks update-kubeconfig --name github-action-runners --region us-east-2
  kubectl port-forward svc/argocd-server -n argocd 8081:443
  ```

  Then open `https://localhost:8081` in a local browser, accept the self-signed cert warning, and log in with `admin` / the password from Step 12.

- **Expose via a LoadBalancer Service** (reachable from anywhere, but costs a bit and is publicly exposed unless the security group is restricted):

  ```bash
  kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
  kubectl get svc argocd-server -n argocd
  ```

### Troubleshooting hit during ArgoCD setup

- **`Unable to listen on port 8080/8081/8082: address already in use`**: a previous `port-forward` process was still bound to that port (sometimes as a zombie that no longer responds). Find and kill it:

  ```bash
  ss -ltnp | grep <port>
  kill -9 <PID>
  # or, if unsure which PID:
  pkill -9 -f "port-forward svc/argocd-server"
  ```

  Then start a fresh `port-forward` in its own tab.

- **`argocd` CLI commands hang with no output**: almost always means the port-forward tunnel died silently (matches the `broken pipe` warnings that can appear in its log). Kill and restart the tunnel, then re-run `argocd login` before retrying the stuck command.

- **`kubectl port-forward` log shows `Forwarding from 127.0.0.1:8081 -> 8080`** even though `443` was requested: this is normal — kubectl logs the pod's *target* port, not the *service* port you specified. Not an error.

- **`argocd app get <name>` fails with `PermissionDenied`, but `argocd app list` works fine**: this is ArgoCD's RBAC layer returning a misleading error — it means the app **doesn't exist yet** rather than an actual permissions problem. Confirm with `argocd app list`; if the app is missing from that list, the fix is to create it, not to debug RBAC/accounts.

- **Port-forward dies entirely between sessions** (`connection refused` instead of hanging): CloudShell sessions can time out and kill foreground processes like `port-forward`. Just restart it (`kubectl port-forward svc/argocd-server -n argocd 8081:443`) and re-run `argocd login` — sessions and tokens don't survive a dead tunnel.

## Part 3: Handing the runner scale set itself over to GitOps

Once ArgoCD is running, `arc-runner-set` (originally installed via manual `helm install` in Step 8) can be brought under GitOps management too — so changing `minRunners`/`maxRunners` becomes a Git edit instead of a `helm upgrade` command.

### Step 19: Push the Helm values file into the repo

```bash
mkdir -p arc-runner-set
cp values-small.yaml arc-runner-set/values-small.yaml
git add arc-runner-set/
git commit -m "Add ARC runner scale set values for GitOps"
git push
```

`githubConfigSecret: gh-pat` inside this file is safe to commit — it's only a reference to the *name* of a Kubernetes Secret that already exists in `arc-runners`, not the PAT value itself. That secret is created separately via `kubectl create secret` and isn't tracked in Git, so it needs to be recreated by hand if it's ever deleted — a good candidate for External Secrets Operator later (see "What's next").

### Step 20: Uninstall the manual Helm release

```bash
helm list -A
helm uninstall arc-runner-set -n arc-runners
```

Running both a manual Helm release and an ArgoCD-managed Application under the same name at once causes conflicts — this has to be one or the other.

### Step 21: Create the ArgoCD Application (Helm chart + values from Git)

```bash
cat > arc-runner-set-app.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: arc-runner-set
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: ghcr.io/actions/actions-runner-controller-charts
      chart: gha-runner-scale-set
      targetRevision: 0.14.2
      helm:
        valueFiles:
          - $values/arc-runner-set/values-small.yaml
    - repoURL: https://github.com/ajaychinthapalli/github-action-eks-runners.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: arc-runners
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f arc-runner-set-app.yaml
```

This uses ArgoCD's multi-source pattern: `sources[0]` pulls the chart directly from its OCI registry, `sources[1]` supplies the values file from Git via the `$values` alias. No app-of-apps layer was set up on top of this (deliberately skipped for now) — this Application was applied once, directly.

### Step 22: Verify the handoff

```bash
argocd app list
argocd app get arc-runner-set
kubectl get pods -n arc-systems
```

**Result from this run**: `arc-runner-set` shows `Healthy` / `Synced` in the ArgoCD UI, confirming the handoff from manual Helm to GitOps completed successfully.

### Step 23: Update min/max runners via the values file (confirmed working)

```bash
sed -i 's/^minRunners:.*/minRunners: 1/' arc-runner-set/values-small.yaml
sed -i 's/^maxRunners:.*/maxRunners: 10/' arc-runner-set/values-small.yaml

git add arc-runner-set/values-small.yaml
git commit -m "Adjust runner scale set min/max runners"
git push

argocd app sync arc-runner-set
kubectl get autoscalingrunnerset arc-runner-set -n arc-runners -o jsonpath='{.spec.minRunners}{" / "}{.spec.maxRunners}'
```

No more `helm upgrade` needed for this kind of change — edit the file, push, and ArgoCD applies it (immediately if you force `argocd app sync`, otherwise within its ~3-minute poll interval). Note: `minRunners: 1` keeps one runner pod alive permanently rather than only during a job, which costs standing node capacity.


## Production notes

- **Upgrading ARC**: Helm cannot upgrade or delete ARC's CRDs. To upgrade the controller: uninstall the runner scale set(s), uninstall the controller, remove the `actions.github.com` CRDs, then reinstall.
- **Logging**: set up log collection for the controller, listener, and ephemeral runner pods before production use.
- **Namespaces**: keep the controller/listener (`arc-systems`) and runner job pods (`arc-runners`) separate, as configured here.
- **`t3` burstable CPU**: sustained heavy CI workloads can throttle once CPU credits run out — enable "Unlimited" mode (extra cost when bursting) if that becomes an issue, or move to `m7i-flex.large`.
- **Node headroom**: with only 3 nodes, losing one to maintenance/an AZ issue removes roughly a third of capacity — consider `minSize: 3, maxSize: 5` for headroom during rollouts.
- **ArgoCD UI exposure**: if using the LoadBalancer option from Step 18, restrict the security group to trusted IPs rather than leaving `argocd-server` open to the internet.
- **ArgoCD admin password**: rotate it after first login (`argocd account update-password`) rather than leaving the initial auto-generated one in place long-term.

## What's next (not yet built)

- Migrate `cluster.yaml` (currently applied by hand via `eksctl`) into Terraform with remote state, so cluster/node group changes go through version control too — the last of the four legs (GitHub + ArgoCD + Terraform + EKS).
- Move to an App-of-Apps ArgoCD pattern once there's more than one app/environment to manage (deliberately skipped for now — `arc-runner-set` and `argocd-demo` were each applied as standalone Applications).
- Replace the raw `kubectl create secret` for the GitHub PAT with External Secrets Operator pulling from AWS Secrets Manager.

## Sources

- [Non eksctl-created clusters — Eksctl User Guide](https://docs.aws.amazon.com/eks/latest/eksctl/unowned-clusters.html)
- [Get started with Actions Runner Controller](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/get-started)
- [Deploying runner scale sets with ARC](https://docs.github.com/en/actions/tutorials/use-actions-runner-controller/deploy-runner-scale-sets)
- [Authenticate to the GitHub API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)
- [gha-runner-scale-set values.yaml](https://github.com/actions/actions-runner-controller/blob/master/charts/gha-runner-scale-set/values.yaml)
- [Choose an optimal EC2 node instance type (max pods)](https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html)
- [Amazon EKS one-click cluster access through CloudShell](https://aws.amazon.com/about-aws/whats-new/2026/04/amazon-eks-one-click-cluster-access/)
- [Install ArgoCD on Amazon EKS: Complete GitOps Guide](https://computingforgeeks.com/argocd-eks-gitops-complete-guide/)
- [GitOps with ArgoCD on AWS EKS — Production Setup](https://itdefined.org/blogs/details/83/gitops-with-argocd-on-aws-eks:-the-production-grade-setup/)
