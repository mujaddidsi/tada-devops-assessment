# Payment Platform — Incident Runbook

## Overview

This runbook covers the pre-event checklist, automated
diagnostics, manual escalation steps, rollback procedure,
and post-mortem template for the 1M TPS payment platform.

---

## Pre-Event Checklist (T-24 Hours Before Spike)

### Infrastructure Verification
- [ ] Karpenter NodePool CPU limit set to 10,000 vCPU
- [ ] DynamoDB pre-provisioned to 1,200,000 WCU
- [ ] Kinesis stream confirmed at 1,000 shards
- [ ] Pause pods (20 replicas) deployed and Running
- [ ] HPA minReplicas set to 10 for payment-service
- [ ] PDB minAvailable confirmed at 70%

### AWS Quotas Verification
- [ ] EC2 Spot vCPU limit: 50,000 (request increase if needed)
- [ ] Kinesis shard limit: 1,000 per region
- [ ] DynamoDB WCU limit: 2,000,000 per table
- [ ] NLB connection limit confirmed with AWS support

### Monitoring Verification
- [ ] Grafana dashboard pinned on main screen
- [ ] PagerDuty escalation chain confirmed
- [ ] All on-call engineers acknowledged and available
- [ ] AlertManager routes tested with test alert
- [ ] Slack channels #payments-alerts and #payments-surge-event active

### Load Test Verification
- [ ] WAF rate limits tested — 429 returned correctly
- [ ] Circuit breaker tested — ejects pod after 5 errors
- [ ] HPA scale-up tested — responds within 15 seconds
- [ ] Karpenter node provisioning tested — new node in less than 90s

---

## Automated Diagnostic Script

Run this script immediately when an alert fires:

```bash
#!/bin/bash
# incident-diagnostics.sh
# Run on alert trigger to get full system snapshot

NS="payments"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="incident-${TIMESTAMP}.txt"

echo "=== INCIDENT DIAGNOSTICS - ${TIMESTAMP} ===" | tee $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== HPA Status ===" | tee -a $OUTPUT_FILE
kubectl get hpa -n $NS | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Pod Status ===" | tee -a $OUTPUT_FILE
kubectl get pods -n $NS \
  --sort-by='.status.startTime' | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Failed Pods ===" | tee -a $OUTPUT_FILE
kubectl get pods -n $NS \
  --field-selector=status.phase=Failed | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Top Pods by CPU ===" | tee -a $OUTPUT_FILE
kubectl top pods -n $NS \
  --sort-by=cpu | head -20 | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Node Status ===" | tee -a $OUTPUT_FILE
kubectl get nodes | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Node Pressure ===" | tee -a $OUTPUT_FILE
kubectl describe nodes | grep -A5 "Conditions:" | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Karpenter Nodes ===" | tee -a $OUTPUT_FILE
kubectl get nodes -l karpenter.sh/provisioner-name \
  --sort-by='.metadata.creationTimestamp' | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== SQS Queue Depth ===" | tee -a $OUTPUT_FILE
aws sqs get-queue-attributes \
  --queue-url $SQS_URL \
  --attribute-names \
    ApproximateNumberOfMessages \
    ApproximateNumberOfMessagesNotVisible | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== SQS DLQ Depth ===" | tee -a $OUTPUT_FILE
aws sqs get-queue-attributes \
  --queue-url $DLQ_URL \
  --attribute-names ApproximateNumberOfMessages | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Kinesis Consumer Lag ===" | tee -a $OUTPUT_FILE
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name GetRecords.IteratorAgeMilliseconds \
  --statistics Maximum \
  --period 60 \
  --start-time $(date -d '5 minutes ago' -u +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --dimensions Name=StreamName,Value=payment-events | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== DynamoDB Throttle Events ===" | tee -a $OUTPUT_FILE
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name WriteThrottleEvents \
  --statistics Sum \
  --period 60 \
  --start-time $(date -d '5 minutes ago' -u +%FT%TZ) \
  --end-time $(date -u +%FT%TZ) \
  --dimensions Name=TableName,Value=payment_events | tee -a $OUTPUT_FILE

echo "" | tee -a $OUTPUT_FILE
echo "=== Diagnostics saved to ${OUTPUT_FILE} ==="
```

---

## Incident Response Steps

### Level 1 — Auto-Detection (0-2 minutes)

```
Alert fires in Prometheus
      │
      ▼
AlertManager routes to PagerDuty
      │
      ▼
On-call engineer paged
      │
      ▼
Engineer runs diagnostic script above
      │
      ▼
Identify issue category (see below)
```

### Level 2 — Issue Categories and Actions

#### Issue: High Error Rate (greater than 1%)

```
1. Check which service is throwing errors:
   kubectl logs -n payments -l app=payment-service --tail=100

2. Check if DynamoDB is throttling:
   See DynamoDB throttle events in diagnostic output

3. If DynamoDB throttling:
   Increase WCU immediately:
   aws dynamodb update-table \
     --table-name payment_events \
     --provisioned-throughput \
       ReadCapacityUnits=600000,WriteCapacityUnits=2000000

4. If pod errors:
   Check pod logs for specific error
   Consider rollback if new deployment caused issue
```

#### Issue: High Latency (p99 greater than 500ms)

```
1. Open Jaeger UI and search recent traces
2. Identify which span is slowest
3. If DynamoDB slow:
   Check WCU consumption vs provisioned
   Check for hot partitions in CloudWatch
4. If Redis slow:
   Check Redis cluster metrics
   Failover to DynamoDB direct if needed
5. If NGINX slow:
   Check upstream keepalive connections
   Scale NGINX pods if CPU is above 80%
```

#### Issue: Pods Not Scaling (TPS high but replicas not increasing)

```
1. Check HPA status:
   kubectl describe hpa payment-service-hpa -n payments

2. Check if metrics are available:
   kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1

3. Check Karpenter logs:
   kubectl logs -n karpenter -l app=karpenter --tail=100

4. If nodes not provisioning:
   Check EC2 Spot capacity in region
   Switch to On-Demand temporarily:
   kubectl patch nodepool payment-burst-pool \
     --type merge \
     -p '{"spec":{"template":{"spec":{"requirements":[
       {"key":"karpenter.sh/capacity-type",
        "operator":"In","values":["on-demand"]}
     ]}}}}'
```

#### Issue: SQS DLQ Growing

```
1. Check what messages are failing:
   aws sqs receive-message \
     --queue-url $DLQ_URL \
     --max-number-of-messages 10

2. Identify error pattern from message body

3. If temporary issue (DB overload):
   Wait for DB to recover
   Replay DLQ messages back to main queue

4. If code bug:
   Rollback deployment
   Fix bug and redeploy
   Replay DLQ messages
```

---

## Rollback Procedure

### Step 1: Shift traffic to stable version

```bash
# Route 100% traffic to stable — stop canary immediately
kubectl patch virtualservice payment-service-vs \
  -n payments \
  --type merge \
  -p '{
    "spec": {
      "http": [{
        "route": [{
          "destination": {
            "host": "payment-service",
            "subset": "stable"
          },
          "weight": 100
        }]
      }]
    }
  }'
```

### Step 2: Rollback pod deployment

```bash
# Check rollout history
kubectl rollout history deployment/payment-service -n payments

# Rollback to previous version
kubectl rollout undo deployment/payment-service -n payments

# Verify rollback is complete
kubectl rollout status deployment/payment-service -n payments
```

### Step 3: Database failover (if Aurora issue)

```bash
# Force Aurora failover to reader instance
aws rds failover-db-cluster \
  --db-cluster-identifier payment-aurora-cluster \
  --target-db-instance-identifier payment-aurora-reader-1
```

### Step 4: Enable CloudFront cache for error pages

```bash
# Serve static error page from CloudFront edge
# Reduces origin load during incident
aws cloudfront create-invalidation \
  --distribution-id $CF_DIST_ID \
  --paths "/*"
```

---

## Escalation Matrix

| Time | Action | Who |
|------|--------|-----|
| 0 min | Alert fires, auto-diagnostic runs | PagerDuty |
| 2 min | On-call engineer acknowledges | L1 Engineer |
| 10 min | Issue not resolved — escalate | L2 Senior Engineer |
| 20 min | Issue not resolved — escalate | L3 Engineering Manager |
| 30 min | Major incident declared | All hands |

---

## Post-Mortem Template

```
## Incident Post-Mortem

### Incident Summary
- Date/Time     :
- Duration      :
- Severity      :
- Services Affected:
- Impact (users affected, transactions lost):

### Timeline
| Time  | Event |
|-------|-------|
| HH:MM | Alert fired |
| HH:MM | Engineer acknowledged |
| HH:MM | Root cause identified |
| HH:MM | Fix applied |
| HH:MM | Incident resolved |

### Root Cause
(What caused the incident?)

### Contributing Factors
(What made it worse or harder to detect?)

### Resolution
(What fixed the incident?)

### Action Items
| Action | Owner | Due Date |
|--------|-------|----------|
|        |       |          |

### Lessons Learned
(What did we learn? What would we do differently?)

### Detection Time
- Time from incident start to alert        : X minutes
- Time from alert to acknowledgment        : X minutes
- Time from acknowledgment to resolution   : X minutes

### What Went Well
-

### What Went Poorly
-
```
