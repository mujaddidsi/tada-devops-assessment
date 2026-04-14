# Section B: Network Architecture Diagrams

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

---

## 2. TLS Termination Points

```mermaid
graph LR
    A[Client] -->|TLS 1.3 - Public Internet| B[CloudFront]
    B -->|TLS 1.3 - AWS Backbone| C[NLB]
    C -->|TLS 1.3| D[NGINX]
    D -->|mTLS - Istio managed| E[Payment Pod]

    style A fill:#f9f9f9
    style E fill:#d4edda
```

---

## 3. Rate Limiting Flow

```mermaid
graph TD
    R[Incoming Request] --> W{WAF Check\n10,000 req per 5min per IP}
    W -->|Exceeded| B1[Block - 403 Forbidden]
    W -->|OK| N{NGINX Check\n5,000 RPS per IP}
    N -->|Exceeded| B2[Block - 429 Too Many Requests]
    N -->|OK| P[Payment Pod]
```

---

## 4. DDoS Protection Layers

```mermaid
graph TD
    Attack[DDoS Attack\nMillions of requests] --> Shield[AWS Shield Advanced\nL3/L4 Volumetric Protection\nAutomatic Mitigation]
    Shield --> CF[CloudFront\nAbsorbs traffic globally\n400+ edge locations worldwide]
    CF --> WAF[AWS WAF\nL7 Application DDoS\nRate limiting per IP]
    WAF --> NLB[NLB\nOnly legitimate\ntraffic reaches here]
```

---

## 5. Canary Deployment Flow

```mermaid
graph TD
    R[1000 Requests] --> VS[Istio VirtualService]

    VS -->|Header x-canary: true| C[Canary Pods v1.1\nInternal testers only]
    VS -->|950 requests - 95%| S[Stable Pods v1.0\nProven in production]
    VS -->|50 requests - 5%| C

    C --> CB{Circuit Breaker\nMonitoring errors}
    CB -->|Error rate high| X[Stop canary\nRoute 100% to stable]
    CB -->|Error rate OK| OK[Keep routing 5%\nto canary]
```

---

## 6. Circuit Breaker Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant I as Istio
    participant P1 as Pod 1 healthy
    participant P2 as Pod 2 failing

    C->>I: Request
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (1 of 5)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (2 of 5)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (3 of 5)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (4 of 5)
    I->>P2: Route to Pod 2
    P2-->>I: 500 Error (5 of 5)

    Note over I,P2: Circuit breaker trips!
    Note over P2: Pod 2 ejected for 30 seconds

    C->>I: Next Request
    I->>P1: Route to Pod 1 only
    P1-->>I: 200 OK
    I-->>C: Success - payment processed
```

---

## 7. mTLS Between Services

```mermaid
graph LR
    subgraph Without mTLS
        A1[Any Pod] -->|No encryption - plaintext| B1[Payment Pod]
        C1[Malicious Pod] -->|Accepted - DANGER| B1
    end

    subgraph With mTLS STRICT
        A2[Authorized Pod\nValid Istio certificate] -->|Encrypted and Verified| B2[Payment Pod]
        C2[Malicious Pod\nNo certificate] -->|REJECTED| B2
    end
```

---

## 8. Route 53 Failover Flow

```mermaid
sequenceDiagram
    participant U as User
    participant R as Route 53
    participant SG as Singapore - Primary
    participant JK as Jakarta - Secondary

    U->>R: DNS Query api.payment.tada.id
    R->>SG: Health check every 10 seconds
    SG-->>R: 200 OK - healthy

    R-->>U: Route to Singapore

    Note over SG: Singapore region fails!

    R->>SG: Health check
    SG-->>R: Timeout - no response
    R->>SG: Health check again
    SG-->>R: Timeout - no response x2

    Note over R: Failover triggered after 2 failures

    R-->>U: Now routing to Jakarta
    Note over R,JK: Total failover time approximately 20 seconds
```

---

## 9. Multi-AZ Network Distribution

```mermaid
graph TB
    subgraph Internet
        Client[Users Worldwide]
    end

    subgraph AWS Edge
        CF[CloudFront\n400+ Edge Locations]
        WAF[AWS WAF]
    end

    subgraph ap-southeast-1 Singapore
        NLB[Network Load Balancer\nStatic IP per AZ]

        subgraph AZ-1a
            N1[NGINX Pod]
            P1[Payment Pod]
            P2[Payment Pod]
        end

        subgraph AZ-1b
            N2[NGINX Pod]
            P3[Payment Pod]
            P4[Payment Pod]
        end

        subgraph AZ-1c
            N3[NGINX Pod]
            P5[Payment Pod]
            P6[Payment Pod]
        end
    end

    Client --> CF
    CF --> WAF
    WAF --> NLB
    NLB --> N1
    NLB --> N2
    NLB --> N3
    N1 --> P1
    N1 --> P2
    N2 --> P3
    N2 --> P4
    N3 --> P5
    N3 --> P6
```
