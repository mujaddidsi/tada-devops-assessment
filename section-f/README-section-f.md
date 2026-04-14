# Section F: Security, Cost & Post-Spike Operations

## Overview

This section describes how to scale down safely without dropping
in-flight transactions, what policies enforce security and prevent
cost overruns during the spike, and which AWS service quotas will
be hit and how to pre-warm them.

---

## 1. Graceful Scale-Down Flow

```mermaid
sequenceDiagram
    participant HPA
    participant K8s as Kubernetes
    participant Pod
    participant LB as Load Balancer
    participant SQS

    Note over HPA: Traffic drops after spike

    HPA->>HPA: Wait 10 min stabilization window
    Note over HPA: stabilizationWindowSeconds: 600

    HPA->>K8s: Scale down 5% of pods
    K8s->>Pod: Send SIGTERM

    Pod->>Pod: preStop hook runs sleep 15s
    Note over Pod: LB updates endpoint list

    LB->>LB: Stop sending new traffic to this pod

    Pod->>SQS: Flush pending writes to SQS
    Pod->>Pod: Finish in-flight requests
    Pod->>Pod: Exit cleanly code 0

    Note over K8s: Karpenter waits 30 min
    Note over K8s: before consolidating nodes
```

### Scale-Down Configuration

| Component | Setting | Value | Reason |
|-----------|---------|-------|--------|
| HPA stabilization | stabilizationWindowSeconds | 600s (10 min) | Wait for traffic to truly drop |
| HPA policy | Percent per period | 5% per 120s | Very gradual reduction |
| Pod termination | terminationGracePeriodSeconds | 60s | Time to finish in-flight requests |
| preStop hook | sleep | 15s | Time for LB to stop routing |
| Karpenter | consolidateAfter | 30m | Wait before removing nodes |

---

## 2. Security Policies (Kyverno)

```mermaid
graph TD
    A[Developer pushes pod spec] --> B[Kubernetes API Server]
    B --> C[Kyverno Admission Webhook]

    C --> D{Policy 1:\nNo privileged containers}
    C --> E{Policy 2:\nResource limits required}
    C --> F{Policy 3:\nRun as non-root}
    C --> G{Policy 4:\nSigned ECR images only}

    D -->|Violation| REJECT[Pod REJECTED ❌]
    E -->|Violation| REJECT
    F -->|Violation| REJECT
    G -->|Violation| REJECT

    D -->|Pass| ALLOW[Pod Created ✅]
    E -->|Pass| ALLOW
    F -->|Pass| ALLOW
    G -->|Pass| ALLOW
```

### Why Each Policy?

| Policy | Risk Prevented | Impact |
|--------|---------------|--------|
| No privileged | Container escape to host node | Critical |
| Resource limits | One pod starving others | High |
| Run as non-root | Privilege escalation if compromised | High |
| Signed images only | Supply chain attack via malicious image | Critical |

---

## 3. Network Policies (Default Deny)

```mermaid
graph LR
    subgraph Allowed Traffic
        NGINX[NGINX Ingress] -->|Policy 2| PS[Payment Service]
        PS -->|Policy 3| PC[Payment Consumer]
        PC -->|Policy 4| AWS[AWS Services\nDynamoDB SQS Kinesis]
        ALL[All Pods] -->|Policy 5| DNS[kube-dns]
        ALL -->|Policy 6| MON[Monitoring\nPrometheus OTel]
    end

    subgraph Blocked Traffic
        OTHER[Other Pods] -. blocked .-> PS
        PC -. blocked .-> INTERNET[Internet]
        PS -. blocked .-> INTERNET
    end
```

### Default Deny Principle

```
Without NetworkPolicy:
Any pod → Any pod → ALLOWED
Compromised monitoring pod → Payment pod → ALLOWED ❌

With Default Deny:
Any pod → Any pod → BLOCKED by default
Only explicitly whitelisted paths → ALLOWED ✅

Result: blast radius of any compromised pod is minimal
```

---

## 4. Secrets Management

```mermaid
sequenceDiagram
    participant Pod
    participant CSI as CSI Driver
    participant SM as AWS Secrets Manager
    participant IRSA as IRSA Role

    Pod->>CSI: Mount secrets-store volume
    CSI->>IRSA: Assume IAM role via service account
    IRSA-->>CSI: Temporary credentials (15 min expiry)
    CSI->>SM: GetSecretValue prod/payment/db-credentials
    SM-->>CSI: Secret value (encrypted)
    CSI->>Pod: Mount as file /mnt/secrets/db_password

    Note over SM: Secret rotates every 30 days
    CSI->>CSI: Re-sync every 60 seconds
    CSI->>Pod: Update mounted file automatically
    Note over Pod: Zero downtime secret rotation ✅
```

### Why Not Kubernetes Secrets?

```
Kubernetes Secrets:
apiVersion: v1
kind: Secret
data:
  password: c3VwZXItc2VjcmV0   ← just base64, NOT encrypted!

Problems:
- Stored in etcd unencrypted (by default)
- Visible to anyone with kubectl get secret
- Appears in git history if committed
- No auto-rotation ❌

CSI Driver + Secrets Manager:
- Fetched directly from AWS at pod start
- Never stored in etcd
- Auto-rotates every 30 days
- IRSA: no hardcoded AWS credentials ✅
```

---

## 5. Cost Control Flow

```mermaid
graph TD
    E[Event starts\n1M TPS] --> K[Karpenter spins up\n300+ EC2 nodes]
    K --> SPEND[Hourly spend rises]

    SPEND --> B{AWS Budget\nmonitor}
    B -->|Below 80%| OK[Continue normally]
    B -->|Above 80% - $400/hr| SNS[SNS Alert]
    B -->|Above 100% - $500/hr| SNS

    SNS --> L[Lambda triggered]
    L --> CAP[Cap Karpenter\nSpot CPU to 2,000]
    L --> SLACK[Notify Slack]
    L --> PD[Create PagerDuty ticket]

    CAP --> HUMAN[Human reviews\nand decides next action]
```

### Cost Guardrails Summary

| Guardrail | Trigger | Action |
|-----------|---------|--------|
| AWS Budget 80% | $400/hr spend | SNS → Lambda |
| Lambda auto-cap | $400/hr spend | Reduce Spot CPU to 2,000 vCPU |
| Karpenter consolidation | Node underutilized 30 min | Remove unused nodes |
| Spot pricing | Spot interruption | Switch to On-Demand automatically |
| Kubecost | Daily cost report | Slack notification per namespace |

### Estimated Cost at 1M TPS

```
At peak (313 nodes c6i.4xlarge):
On-Demand : 94 nodes × $0.68/hr  = $63.92/hr
Spot      : 219 nodes × $0.20/hr = $43.80/hr
Total     : ~$107.72/hr

DynamoDB  : 1.2M WCU × $0.00065/hr = $780/hr
Redis     : 6 nodes r7g.2xlarge    = $12/hr
Kinesis   : 1,000 shards           = $15/hr

Grand total: ~$915/hr during peak
Budget cap : $500/hr for EC2 only
```

---

## 6. AWS Service Quotas

```mermaid
graph TD
    subgraph T-14 Days
        NLB[Request NLB quota\nContact AWS Support\nLongest lead time]
    end

    subgraph T-7 Days
        EC2[EC2 Spot vCPU\n5120 to 50000]
        KIN[Kinesis Shards\n500 to 1000]
        DDB[DynamoDB WCU\n40000 to 2000000]
    end

    subgraph T-1 Day
        VER[Verify all APPROVED]
        LT[Run load test]
        AWS[AWS Support on standby]
    end

    subgraph Day of Event
        MON[Monitor quota usage\nvia CloudWatch]
    end
```

### Quota Requirements Table

| Service | Default Limit | Required | Lead Time | Action |
|---------|--------------|----------|-----------|--------|
| EC2 Spot vCPU | 5,120 | 50,000 | 1-3 days | Script |
| EC2 On-Demand vCPU | 5,120 | 10,000 | 1-3 days | Script |
| Kinesis Shards | 500/region | 1,000 | 1 day | Script |
| DynamoDB WCU | 40,000 | 2,000,000 | 2-3 days | Script |
| NLB Connections | 55,000/AZ | 350,000+/AZ | 5-7 days | AWS Support |
| EKS Node Groups | 30 | 50+ | 1 day | Script |
| CloudFront RPS | Unlimited | — | None needed | — |

---

## 7. Post-Spike Operations

```mermaid
graph TD
    A[Spike event ends] --> B[HPA starts scale-down\nstabilizationWindow: 10 min]
    B --> C[5% pods removed every 2 min]
    C --> D[Karpenter waits 30 min]
    D --> E[Karpenter consolidates\nunderutilized nodes]
    E --> F[Cost returns to baseline]

    F --> G[Post-event tasks]
    G --> H[Review Grafana dashboard\nfor anomalies]
    G --> I[Check DLQ for\nfailed messages]
    G --> J[Replay DLQ messages\nif any]
    G --> K[Write post-mortem\nif any issues]
```

### Post-Event Checklist

```
Immediately after spike:
[ ] Monitor error rate — should return to < 0.1%
[ ] Check DLQ depth — replay any failed messages
[ ] Verify DynamoDB WCU consumption dropping
[ ] Confirm Karpenter consolidation starting

Within 1 hour:
[ ] Review Grafana dashboard for anomalies
[ ] Check Kinesis consumer lag back to normal
[ ] Verify Redis cache hit rate normal
[ ] Confirm Aurora reconciliation caught up

Within 24 hours:
[ ] Write post-mortem document
[ ] Review cost report in Kubecost
[ ] Update runbook with lessons learned
[ ] File AWS Support case if any quota issues
```

---

## 8. Manifest Files Summary

| File | Type | Purpose |
|------|------|---------|
| `graceful-scaledown.yaml` | Kubernetes | HPA + Deployment + Karpenter scale-down config |
| `kyverno-policy.yaml` | Kyverno | Security policies — no privileged, resource limits, non-root, signed images |
| `network-policy.yaml` | Kubernetes | Default deny + explicit allow rules |
| `secrets-store-csi.yaml` | CSI Driver | Secrets from AWS Secrets Manager with auto-rotation |
| `cost-control.tf` | Terraform | AWS Budget + Lambda auto-cap + Spot fleet |
| `quota-checklist.sh` | Bash | Check and request AWS quota increases |

---

## 9. Key Design Decisions

### Decision 1: 10 minute HPA stabilization on scale-down
5 minute default is too aggressive — traffic may spike again.
10 minutes ensures the spike is truly over before reducing capacity.
Combined with 5% per 120s policy, scale-down takes 40+ minutes total.

### Decision 2: Kyverno over OPA/Gatekeeper
Both enforce policies at admission time.
Kyverno uses Kubernetes-native YAML — easier to read and maintain.
OPA requires Rego language — steeper learning curve for the team.
Kyverno also supports image verification natively.

### Decision 3: CSI Driver over Kubernetes Secrets
Kubernetes Secrets are base64 only — not truly encrypted at rest.
CSI Driver fetches secrets at runtime from AWS Secrets Manager.
Auto-rotation means zero manual work and zero rotation downtime.
IRSA eliminates need for any hardcoded AWS credentials.

### Decision 4: Lambda auto-cap at 80% budget
Waiting for 100% budget consumption before acting is too late.
At 80% ($400/hr) Lambda caps Spot fleet before hitting the limit.
Human review required to increase cap — prevents runaway automation.
