# Section B: Networking & Traffic Management

## Overview

This section describes the full request path from client to pod,
covering TLS termination, rate limiting, DDoS protection,
canary deployments, and circuit breaking at 1M TPS.

---

## 1. Full Request Path

```mermaid
graph TD
    Client[Client / Mobile App] --> CF[CloudFront CDN\nTLS Termination\nStatic Asset Cache]
    CF --> WAF[AWS WAF\nRate Limiting\nSQL Injection Protection\nIP Reputation Filtering]
    WAF --> NLB[Network Load Balancer\nLayer 4 TCP\nCross-Zone Load Balancing\nProxy Protocol v2]
    NLB --> NGINX[NGINX Ingress Controller\nLayer 7 HTTP Routing\nPer-IP Rate Limiting\nKeepalive Tuning]
    NGINX --> Istio[Istio Sidecar - Envoy\nmTLS STRICT\nCircuit Breaker\nCanary Split 95/5]
    Istio --> Pod[Payment Service Pod\nBusiness Logic\nSQS/Kinesis Producer]
```

### What sits at each layer and why?

| Layer | Component | Responsibility |
|-------|-----------|----------------|
| DNS | Route 53 | Latency-based routing, health check failover |
| CDN | CloudFront | TLS termination, static cache, DDoS absorption |
| Firewall | AWS WAF | Rate limiting, SQLi, IP reputation |
| L4 LB | NLB | TCP load balancing, static IPs, Proxy Protocol |
| L7 LB | NGINX Ingress | HTTP routing, per-IP rate limit, keepalive |
| Service Mesh | Istio Sidecar | mTLS, circuit breaker, canary split |
| App | Payment Pod | Business logic, payment processing |

---

## 2. TLS Termination

```mermaid
graph LR
    A[Client] -->|TLS 1.3 - Public| B[CloudFront]
    B -->|TLS 1.3 - AWS Backbone| C[NLB]
    C -->|TLS 1.3| D[NGINX]
    D -->|mTLS - Istio managed| E[Payment Pod]

    style A fill:#f9f9f9
    style E fill:#d4edda
```

- **CloudFront:** Terminates public TLS — offloads handshake from origin
- **NLB → NGINX:** Re-encrypted using TLS 1.3 only
- **NGINX → Pod:** mTLS enforced by Istio sidecar automatically
- **Certificate rotation:** Istio rotates pod certificates every 24 hours

---

## 3. Rate Limiting Strategy

Rate limiting is applied at two layers:

```mermaid
graph TD
    R[Incoming Request] --> W{WAF Check\n10,000 req/5min per IP}
    W -->|Exceeded| B1[Block - 403 Forbidden]
    W -->|OK| N{NGINX Check\n5,000 RPS per IP}
    N -->|Exceeded| B2[Block - 429 Too Many Requests]
    N -->|OK| P[Payment Pod]
```

| Layer | Limit | Action | Purpose |
|-------|-------|--------|---------|
| WAF | 10,000 req / 5 min per IP | Block 403 | Stop DDoS, brute force |
| NGINX | 5,000 RPS per IP | Return 429 | Fine-grained API protection |

---

## 4. DDoS Protection

```mermaid
graph TD
    Attack[DDoS Attack\nMillions of requests] --> Shield[AWS Shield Advanced\nL3/L4 Volumetric DDoS\nAutomatic mitigation]
    Shield --> CF[CloudFront\nAbsorbs traffic globally\n400+ edge locations]
    CF --> WAF[AWS WAF\nL7 Application DDoS\nRate limiting per IP]
    WAF --> NLB[NLB\nOnly legitimate\ntraffic reaches here]
```

Three layers of DDoS protection:
1. **AWS Shield Advanced** — absorbs volumetric L3/L4 attacks automatically
2. **CloudFront** — distributes traffic across 400+ edge locations globally
3. **AWS WAF** — blocks L7 application-level attacks and abusive IPs

---

## 5. Canary Deployment During Spike

```mermaid
graph TD
    R[1000 Requests] --> VS[Istio VirtualService]

    VS -->|Header x-canary: true| C[Canary Pods v1.1\nInternal testers only]
    VS -->|950 requests - 95%| S[Stable Pods v1.0\nProven in production]
    VS -->|50 requests - 5%| C

    C --> CB{Circuit Breaker\nMonitoring errors}
    CB -->|Error rate high| X[Stop canary\nRoute 100% to stable]
    CB -->|Error rate OK| OK[Gradually increase\ncanary percentage]
```

**Why canary during 1M TPS event?**
- Even during peak traffic, hotfixes may need to be deployed
- Canary limits blast radius — only 5% users affected if new version has bugs
- Circuit breaker automatically stops canary if error rate spikes
- Header-based routing allows internal team to test without affecting real users

---

## 6. Circuit Breaking

```mermaid
sequenceDiagram
    participant C as Client
    participant I as Istio
    participant P1 as Pod 1 healthy
    participant P2 as Pod 2 failing

    C->>I: Request
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (1)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (2)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (3)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (4)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (5)

    Note over I: Circuit breaker trips!
    Note over P2: Ejected for 30 seconds

    C->>I: Next Request
    I->>P1: Route to Pod 1 only
    P1-->>I: 200 OK
    I-->>C: Success
```

Circuit breaker configuration:
- **Threshold:** 5 consecutive 5xx errors
- **Eject duration:** 30 seconds (doubles on repeat failures)
- **Max ejection:** 50% of pod pool (system never fully goes down)
- **Recovery:** Single test request after eject period ends

---

## 7. mTLS Between Services

```mermaid
graph LR
    subgraph Without mTLS
        A1[Any Pod] -->|No encryption| B1[Payment Pod]
        C1[Malicious Pod] -->|Accepted!| B1
    end

    subgraph With mTLS STRICT
        A2[Authorized Pod\nValid certificate] -->|Encrypted + Verified| B2[Payment Pod]
        C2[Malicious Pod\nNo certificate] -->|REJECTED| B2
    end
```

- **Mode: STRICT** — all pod-to-pod traffic must use mTLS
- **Zero code changes** — Istio sidecar handles everything automatically
- **Certificate rotation** — every 24 hours, no manual intervention needed

---

## 8. NLB Key Configurations

| Annotation | Value | Why |
|------------|-------|-----|
| nlb-target-type | ip | Direct pod routing, avoids node hop |
| cross-zone-load-balancing | true | Even distribution across AZs |
| proxy-protocol | * | Preserves real client IP for fraud detection |
| connection-draining-timeout | 30s | Allows in-flight payments to complete |
| externalTrafficPolicy | Local | Avoids double network hop |

---

## 9. NGINX Key Tuning Parameters

| Parameter | Value | Why |
|-----------|-------|-----|
| worker-connections | 65535 | Max concurrent connections per worker |
| keep-alive-requests | 10000 | Reuse connections — avoid TCP handshake overhead |
| upstream-keepalive-connections | 1000 | Reuse connections to upstream pods |
| ssl-protocols | TLSv1.3 | Fastest and most secure TLS version |
| ssl-session-cache-size | 100m | Cache TLS sessions — save 80% CPU on handshakes |
| access-log-path | /dev/null | Prevent disk I/O bottleneck at 1M TPS |

---

## 10. Route 53 Failover Flow

```mermaid
sequenceDiagram
    participant U as User
    participant R as Route 53
    participant SG as Singapore - Primary
    participant JK as Jakarta - Secondary

    U->>R: DNS Query
    R->>SG: Health check every 10s
    SG-->>R: 200 OK

    R-->>U: Route to Singapore

    Note over SG: Singapore region fails!

    R->>SG: Health check
    SG-->>R: Timeout
    R->>SG: Health check again
    SG-->>R: Timeout x2

    Note over R: Failover triggered after 2 failures

    R-->>U: Now route to Jakarta
    Note over R,JK: Total failover time ~20 seconds
```

---

## 11. Manifest Files Summary

| File | Type | Purpose |
|------|------|---------|
| `service-nlb.yaml` | Kubernetes Service | Expose payment service via NLB |
| `nginx-configmap.yaml` | ConfigMap + Ingress | NGINX tuning and routing rules |
| `istio-virtualservice.yaml` | Istio VirtualService | Canary traffic split 95/5 |
| `istio-destinationrule.yaml` | Istio DestinationRule | Circuit breaker and connection pool |
| `istio-peerauthentication.yaml` | Istio PeerAuthentication | mTLS STRICT for all pod communication |
| `waf-rules.tf` | Terraform | WAF rules and CloudFront config |
| `route53.tf` | Terraform | DNS routing and health checks |

---

## 12. Key Design Decisions

### Decision 1: NLB over ALB
NLB operates at Layer 4 (TCP) — much faster than ALB (Layer 7).
At 1M TPS, NLB handles millions of connections per second with
minimal latency. HTTP routing is handled by NGINX instead.

### Decision 2: Two layers of rate limiting
WAF handles volumetric attacks (10K req/5min per IP).
NGINX handles fine-grained API abuse (5K RPS per IP).
Two layers ensure no single point of bypass.

### Decision 3: Canary at 5% during spike
Small enough to limit blast radius if new version has issues.
Large enough to get statistically significant error data.
Circuit breaker automatically stops canary if errors spike.

### Decision 4: mTLS STRICT mode
Payment data is highly sensitive — all pod communication
must be encrypted and authenticated.
STRICT mode ensures zero unencrypted traffic within the cluster.
