# GitHub Actions EKS Runners - Comprehensive Architecture Diagrams

This document contains visual diagrams of the complete GitHub Actions EKS Runners infrastructure and deployment architecture.

---

## 1. Overall System Architecture

High-level overview of how all components interact:

```mermaid
graph TB
    subgraph "GitHub"
        GH["GitHub Repository<br/>with Workflows"]
    end
    
    subgraph "AWS Cloud"
        subgraph "VPC"
            EKS["EKS Control Plane<br/>(Managed by AWS)"]
            SG["Security Group"]
            
            subgraph "Worker Nodes<br/>(t3.small)"
                Node1["Node 1<br/>2vCPU, 2GB RAM"]
                Node2["Node 2<br/>2vCPU, 2GB RAM"]
                Node3["Node 3<br/>2vCPU, 2GB RAM"]
            end
            
            subgraph "Kubernetes Namespaces"
                subgraph "arc-systems"
                    ARC["Actions Runner<br/>Controller Pod"]
                    Listener["Listener Pod"]
                end
                
                subgraph "arc-runners"
                    Runner1["Runner Pod"]
                    Runner2["Runner Pod"]
                    RunnerN["... Runner Pods"]
                end
                
                subgraph "kube-system"
                    CA["Cluster Autoscaler"]
                    DNS["CoreDNS"]
                end
            end
        end
        
        IAM["IAM Roles<br/>(OIDC)"]
        S3["S3 Backend<br/>(Terraform State)"]
    end
    
    subgraph "External Services"
        ArgoCD["ArgoCD<br/>(GitOps)"]
        Docker["Docker Registry"]
    end
    
    GH -->|Webhook Event (PAT Auth)| Listener
    GH -->|Job Status Updates (PAT Auth)| ARC
    ARC -->|Create/Manage| Runner1
    ARC -->|Create/Manage| Runner2
    ARC -->|Create/Manage| RunnerN
    Runner1 -->|Report Status (PAT Auth)| GH
    EKS -->|Manages| Node1
    EKS -->|Manages| Node2
    EKS -->|Manages| Node3
    CA -->|Auto-scales| Node1
    CA -->|Auto-scales| Node2
    CA -->|Auto-scales| Node3
    ArgoCD -->|Deploy| ARC
    Docker -->|Pull Images| Runner1
    IAM -->|IRSA| CA
    S3 -->|State| IAM
```

---

## 2. Kubernetes Cluster Architecture

Detailed view of the Kubernetes cluster internals:

```mermaid
graph LR
    subgraph "EKS Cluster (github-action-runners)"
        subgraph "Control Plane (AWS Managed)"
            API["API Server"]
            ETCD["etcd"]
            Scheduler["Scheduler"]
            Controller["Controller Manager"]
        end
        
        subgraph "arc-systems Namespace"
            ARC_Pod["ARC Pod<br/>Deployment"]
            Listener_Pod["Listener Pod<br/>Statefulset"]
            ARC_Config["RunnerDeployment CRD<br/>RunnerScale CRD"]
            ARC_RBAC["ServiceAccount<br/>ClusterRole<br/>ClusterRoleBinding"]
        end
        
        subgraph "arc-runners Namespace"
            Runner_Pods["Ephemeral Runner Pods<br/>(Created/Destroyed)"]
            Runner_Config["Pod Specs<br/>mounted from ConfigMap"]
        end
        
        subgraph "kube-system Namespace"
            CA_Pod["Cluster Autoscaler<br/>Deployment"]
            CA_RBAC["ServiceAccount<br/>ClusterRole<br/>ClusterRoleBinding"]
            CoreDNS["CoreDNS<br/>Service Discovery"]
            Kubelet["Kubelet on Nodes"]
        end
        
        subgraph "Worker Nodes"
            Node1_Pods["Kubelet<br/>Container Runtime<br/>Pod Network"]
            Node2_Pods["Kubelet<br/>Container Runtime<br/>Pod Network"]
            Node3_Pods["Kubelet<br/>Container Runtime<br/>Pod Network"]
        end
    end
    
    GitHub["GitHub<br/>Webhook Events"]
    
    GitHub -->|Job Requests| Listener_Pod
    Listener_Pod -->|Trigger Scaling| ARC_Pod
    ARC_Pod -->|Create Pods| Runner_Pods
    ARC_Pod -->|Watch Nodes| CA_Pod
    CA_Pod -->|EC2 API| EC2["AWS EC2<br/>Auto Scaling Group"]
    Runner_Pods -->|Schedule on| Node1_Pods
    Runner_Pods -->|Schedule on| Node2_Pods
    Runner_Pods -->|Schedule on| Node3_Pods
    Kubelet -->|Manage| CoreDNS
    ARC_Config -->|Configure| ARC_Pod
    Runner_Config -->|Configure| Runner_Pods
```

---

## 3. CI/CD Pipeline Workflow

The workflow of how GitHub Actions jobs are processed:

```mermaid
sequenceDiagram
    actor Dev as Developer
    participant GH as GitHub
    participant PAT as GitHub API<br/>(PAT Auth)
    participant ARC as ARC Controller
    participant Runner as Runner Pod
    participant Docker as Docker Registry
    participant App as Application
    
    Dev->>GH: Push code / Create PR
    GH->>PAT: Trigger workflow (webhook)
    Note over PAT: Workflow queued
    PAT->>ARC: Check runner capacity (PAT)
    alt Runners available
        ARC->>Runner: Create new runner pod
        Note over Runner: Pod initializes
        Runner->>PAT: Register runner (PAT)
    else No runners available
        ARC->>ARC: Scale up (pending pods trigger CA)
        Note over ARC: Wait for node scaling
    end
    PAT->>Runner: Assign job to runner (PAT)
    Runner->>Runner: Run checkout@v3
    Runner->>Docker: Pull action images
    Docker-->>Runner: Return image layers
    Runner->>App: Execute build/test steps
    App-->>Runner: Return results
    Runner->>GH: Report job status (PAT)
    Note over GH: Job complete
    ARC->>Runner: Pod TTL expired, delete
    Note over Runner: Pod termination
    
```

---

## 4. Cluster Autoscaling Flow

How the cluster automatically scales based on workload:

```mermaid
graph TD
    A["Workflow Job Queued<br/>on GitHub"] --> B["ARC Listener<br/>receives webhook"]
    B --> C["ARC Controller<br/>creates runner pod"]
    C --> D{"Pod can be<br/>scheduled?"}
    
    D -->|Yes: Node available| E["Pod runs<br/>on existing node"]
    E --> F["Job completes"]
    F --> G["Pod TTL expires<br/>or job ends"]
    G --> H["Pod deleted"]
    
    D -->|No: Insufficient resources| I["Pod stays<br/>PENDING"]
    I --> J["Cluster Autoscaler<br/>detects pending pod"]
    J --> K["CA calls AWS EC2 API"]
    K --> L["Auto Scaling Group<br/>launches new node"]
    L --> M["New node joins cluster<br/>via kubelet registration"]
    M --> N["Scheduler places pod<br/>on new node"]
    N --> E
    
    H --> O{"Any pending<br/>pods?"}
    O -->|No| P["CA detects low utilization<br/>after scale-down delay"]
    P --> Q["CA terminates<br/>underutilized node"]
    Q --> R["ASG replaces node<br/>or keeps minimal pool"]
    O -->|Yes| I
```

---

## 5. Infrastructure as Code (Terraform) Deployment

Flow of Terraform applying infrastructure changes:

```mermaid
graph LR
    subgraph "Developer Workflow"
        Dev["Developer<br/>Edit Code/Config"]
        Git["Git Repository<br/>Push to Branch"]
        PR["Create Pull Request"]
    end
    
    subgraph "GitHub Actions CI"
        TFPlan["Terraform Plan<br/>Job (in EC2)"]
        Comment["Post Plan Comment<br/>on PR"]
    end
    
    subgraph "GitHub Actions CD"
        TFApply["Terraform Apply<br/>Job (in EC2)"]
    end
    
    subgraph "AWS"
        OIDC["OIDC Token<br/>Exchange"]
        IAM["IAM Assume Role<br/>(No static keys)"]
        TF["Terraform<br/>Run"]
        EKS["Create/Update<br/>EKS Cluster"]
        ASG["Create/Update<br/>Auto Scaling Group"]
        S3["S3 State File<br/>(Encrypted)"]
        DDB["DynamoDB<br/>State Lock"]
    end
    
    Dev -->|1. Edit| Git
    Git -->|2. Push| PR
    PR -->|3. Trigger| TFPlan
    TFPlan -->|4. OIDC Token| OIDC
    OIDC -->|5. Exchange| IAM
    IAM -->|6. Credentials| TF
    TF -->|7. Refresh| S3
    TF -->|8. Lock State| DDB
    TF -->|9. Plan| EKS
    TF -->|9. Plan| ASG
    TF -->|10. Output Plan| Comment
    Comment -->|11. Review PR| Dev
    Dev -->|12. Approve & Merge| PR
    PR -->|13. Trigger| TFApply
    TFApply -->|14-18. Same as Plan| IAM
    IAM -->|19. Apply Changes| EKS
    IAM -->|19. Apply Changes| ASG
    IAM -->|20. Update State| S3
```

---

## 6. Terraform Module Architecture

Modular organization of Terraform code:

```mermaid
graph TD
    subgraph "Root Module (terraform/)"
        Main["main.tf<br/>Instantiate modules"]
        Vars["variables.tf<br/>Input variables"]
        Outputs["outputs.tf<br/>Expose outputs"]
        Backend["backend.tf<br/>S3 + DynamoDB"]
        TFVars["terraform.tfvars<br/>Variable values"]
    end
    
    subgraph "EKS Module (terraform/modules/eks/)"
        EKS_Main["main.tf<br/>- EKS Cluster<br/>- Node Group<br/>- IAM Roles<br/>- Security Groups"]
        EKS_Vars["variables.tf<br/>- cluster_name<br/>- region<br/>- vpc_id<br/>- subnet_ids<br/>- node config"]
        EKS_Outputs["outputs.tf<br/>- Cluster endpoint<br/>- CA certificate<br/>- OIDC provider"]
    end
    
    subgraph "Cluster Autoscaler Module<br/>(terraform/modules/cluster-autoscaler/)"
        CA_Main["main.tf<br/>- Kubernetes Deployment<br/>- ServiceAccount<br/>- ClusterRole<br/>- Binding<br/>- IAM Role (IRSA)"]
        CA_Vars["variables.tf<br/>- cluster_name<br/>- oidc_provider_arn<br/>- scale settings"]
        CA_Outputs["outputs.tf<br/>- CA Role ARN<br/>- Deployment status"]
    end
    
    Main -->|uses| EKS_Main
    Main -->|uses| CA_Main
    Vars -->|defines| TFVars
    EKS_Main -->|outputs| EKS_Outputs
    CA_Main -->|outputs| CA_Outputs
    EKS_Outputs -->|input to| CA_Main
    Backend -->|stores| S3_State["S3 State File"]
    
    style Main fill:#4A90E2
    style CA_Main fill:#7ED321
    style EKS_Main fill:#BD10E0
```

---

## 7. GitHub Actions Runner Lifecycle

Complete lifecycle of a runner from creation to termination:

```mermaid
stateDiagram-v2
    [*] --> Idle: Runner Pod Ready
    
    Idle --> Assigned: Workflow job assigned
    Assigned --> Running: Runner executes workflow
    Running --> Success: Job completed successfully
    Running --> Failed: Job failed
    
    Success --> Cleanup: Post-job cleanup
    Failed --> Cleanup: Post-job cleanup
    Cleanup --> TTLCheck: Check pod TTL
    
    TTLCheck --> [*]: Pod deleted by controller
    TTLCheck --> Idle: TTL not expired, pod reused
    
    Idle --> Orphan: ARC controller crash<br/>or pod eviction
    Orphan --> [*]: Pod garbage collected
    
    note right of Idle
        Pod idle, waiting for
        job assignment from GitHub
    end note
    
    note right of Running
        Executing GitHub Actions
        workflow steps
    end note
    
    note right of Cleanup
        Running post-job actions
        and cleanup
    end note
    
    note right of TTLCheck
        Default: 15 min TTL
        or configurable
    end note
```

---

## 8. Data Flow: Job Execution

How data flows from GitHub to runner execution and back:

```mermaid
graph LR
    subgraph "GitHub Side"
        Workflow["Workflow YAML<br/>(.github/workflows/)"]
        Secrets["GitHub Secrets<br/>(encrypted)"]
        Webhook["Webhook Event<br/>job queued"]
        PAT["Personal Access Token<br/>(for API calls)"]
    end
    
    subgraph "ARC on EKS"
        Listener["ARC Listener<br/>Pod"]
        Controller["ARC Controller<br/>Pod"]
        ScaleConfig["RunnerScale CRD<br/>minRunners: 1<br/>maxRunners: 10"]
    end
    
    subgraph "Runner Execution"
        RunnerPod["Runner Pod<br/>(ephemeral)"]
        Checkout["Checkout Action<br/>github/checkout@v3"]
        UserSteps["User-defined Steps<br/>build/test/deploy"]
        Teardown["Cleanup & Report"]
    end
    
    subgraph "Storage & Auth"
        Actions["GitHub Actions<br/>Docker Image"]
        Tools["Pre-installed Tools<br/>git, npm, etc."]
        GHToken["GitHub Token (PAT)<br/>(for git operations)"]
    end
    
    Workflow -->|triggers| Webhook
    Secrets -->|inject| RunnerPod
    Webhook -->|poll with PAT| Listener
    Listener -->|scale| Controller
    ScaleConfig -->|limit| Controller
    Controller -->|create| RunnerPod
    RunnerPod -->|pulls| Actions
    RunnerPod -->|executes| Checkout
    Checkout -->|clone| GHToken
    RunnerPod -->|executes| UserSteps
    UserSteps -->|use| Tools
    UserSteps -->|report| Teardown
    Teardown -->|status with PAT| Webhook
    PAT -->|authenticate API calls| Listener
```

---

## 9. Network Architecture

How network traffic flows through the system:

```mermaid
graph TB
    subgraph "GitHub.com"
        GHServers["GitHub Servers<br/>Webhook endpoint"]
    end
    
    subgraph "Internet"
        Internet["Public Internet<br/>HTTPS"]
    end
    
    subgraph "AWS VPC (10.0.0.0/16)"
        subgraph "Public Subnets"
            IGW["Internet Gateway"]
            NatGW["NAT Gateway"]
            LB["Network Load Balancer<br/>(optional)"]
        end
        
        subgraph "Private Subnets (EKS Nodes)"
            SG["Security Group<br/>Allow: 443 ingress<br/>Allow: Kubelet 10250"]
            Node1_Net["Node 1<br/>10.0.1.x"]
            Node2_Net["Node 2<br/>10.0.2.x"]
            Node3_Net["Node 3<br/>10.0.3.x"]
        end
        
        subgraph "Pod Network (172.17.0.0/16)"
            Pods["Pods within cluster<br/>communicate via CNI"]
        end
    end
    
    GHServers -->|HTTPS Webhook| Internet
    Internet -->|443| IGW
    IGW -->|NAT| NatGW
    NatGW -->|Route| Node1_Net
    NatGW -->|Route| Node2_Net
    NatGW -->|Route| Node3_Net
    Node1_Net -->|Kube API| Pods
    Node2_Net -->|Kube API| Pods
    Node3_Net -->|Kube API| Pods
    Pods -->|Pod-to-Pod| Pods
    Node1_Net -->|Pull Images| Internet
```

---

## 10. Cost and Scaling Scenarios

Different cost scenarios based on configuration:

```mermaid
graph LR
    subgraph "On-Demand Only<br/>(Baseline)"
        OD["3 × t3.small On-Demand<br/>~$45/month<br/>Always running"]
    end
    
    subgraph "With Spot (70% savings)"
        Spot["3 × t3.small Spot<br/>~$13/month<br/>Up to 10 total capacity"]
    end
    
    subgraph "Mixed Setup<br/>(Recommended)"
        Mixed["2 × t3.small On-Demand<br/>+ 3 × t3.small Spot<br/>~$35/month<br/>Stable baseline + burst"]
    end
    
    subgraph "Large Scale<br/>(with autoscaling)"
        Large["Min: 1 node<br/>Max: 20 nodes<br/>Pay for what you use<br/>~$5-200/month"]
    end
    
    OD -.->|Add Spot| Spot
    OD -.->|Optimize| Mixed
    Mixed -.->|AutoScale| Large
    
    style OD fill:#FF6B6B
    style Spot fill:#51CF66
    style Mixed fill:#FFD93D
    style Large fill:#6C5CE7
```

---

## 11. Deployment Phases

The four-phase buildout of the complete system:

```mermaid
graph TD
    Phase1["<b>Phase 1: ARC Setup</b><br/>GitHub Actions Runners on EKS<br/>- Install Actions Runner Controller<br/>- Configure runner pods<br/>- Enable webhook polling<br/>Status: Self-hosted CI runners working"]
    
    Phase2["<b>Phase 2: ArgoCD</b><br/>GitOps Continuous Deployment<br/>- Deploy ArgoCD to cluster<br/>- Configure git repo sync<br/>- Declarative deployments<br/>Status: App deployments automated"]
    
    Phase3["<b>Phase 3: GitOps ARC Config</b><br/>ARC scaling via Git<br/>- Manage RunnerScale in git<br/>- ArgoCD syncs scale settings<br/>- minRunners/maxRunners in git<br/>Status: Runner config version controlled"]
    
    Phase4["<b>Phase 4: Infrastructure as Code</b><br/>Terraform manages all infra<br/>- EKS cluster in Terraform<br/>- Node group in Terraform<br/>- Cluster Autoscaler deployed<br/>- GitHub Actions CI/CD for Terraform<br/>Status: Complete GitOps + IaC pipeline"]
    
    Phase1 --> Phase2
    Phase2 --> Phase3
    Phase3 --> Phase4
    
    Phase4 -.-> Complete["<b>COMPLETE SYSTEM</b><br/>GitHub → Terraform → AWS<br/>GitHub → ARC → Runners<br/>Git → ArgoCD → Apps<br/>Self-managed, auto-scaling,<br/>fully version-controlled"]
    
    style Phase1 fill:#A8E6CF
    style Phase2 fill:#FFD3B6
    style Phase3 fill:#FFAAA5
    style Phase4 fill:#FF8B94
    style Complete fill:#FF6B9D
```

---

## 12. OIDC Authentication Flow (Terraform to AWS)

How Terraform authenticates to AWS without storing credentials:

```mermaid
sequenceDiagram
    actor GHA as GitHub Actions
    participant OpenIDConnect as OpenID Connect<br/>(GitHub)
    participant AWS as AWS STS
    participant IAM as AWS IAM
    participant S3 as AWS S3<br/>Terraform State
    
    GHA->>+OpenIDConnect: Request token
    Note over OpenIDConnect: Sign token with<br/>GitHub private key
    OpenIDConnect-->>-GHA: Return JWT token
    
    GHA->>+AWS: Assume role with web identity<br/>(OIDC token)
    Note over AWS: Validate token signature<br/>Check claims (repo, ref, etc)
    AWS->>IAM: Look up role ARN
    IAM-->>AWS: Role found
    AWS-->>-GHA: Temporary credentials<br/>(access key + secret + session token)
    
    GHA->>+S3: terraform apply<br/>Using temporary credentials
    S3->>IAM: Validate credentials
    IAM-->>S3: Credentials valid
    S3-->>-GHA: State file updated
    
    Note over GHA: Credentials auto-expire<br/>No need to rotate
    Note over GHA: No long-lived credentials<br/>stored in GitHub secrets
```

---

## Summary

This project implements a **complete, production-ready GitOps pipeline** with:

1. **Self-hosted CI** - GitHub Actions runners on EKS (ARC)
2. **Automatic Scaling** - Cluster Autoscaler responds to workload
3. **GitOps CD** - ArgoCD syncs from Git
4. **Infrastructure as Code** - Terraform manages all AWS resources
5. **Zero Secrets** - OIDC authentication eliminates credential rotation
6. **Cost Optimization** - Spot instances, auto-scaling, and cleanup

**Key Technologies:**
- **GitHub Actions Runner Controller (ARC)** - Kubernetes-native runner management
- **Amazon EKS** - Managed Kubernetes on AWS
- **Cluster Autoscaler** - Automatic node scaling
- **ArgoCD** - Declarative GitOps deployment
- **Terraform** - Infrastructure as Code
- **AWS OIDC** - Keyless authentication

All components work together to create a self-healing, scalable CI/CD infrastructure that tracks all changes in Git.
