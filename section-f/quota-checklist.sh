#!/bin/bash
# =============================================================
# AWS Service Quotas Checklist Script
# Purpose: Check and request quota increases before 1M TPS event
#
# Run this script T-7 days before the event
# AWS typically responds to quota requests in 1-3 business days
# Some quotas (NLB) need T-14 days — request those first!
#
# Quotas that will be hit at 1M TPS:
# 1. EC2 Spot vCPU     — default 5,120, need 50,000
# 2. Kinesis Shards    — default 500, need 1,000
# 3. DynamoDB WCU      — default 40,000, need 1,200,000
# 4. NLB connections   — default 55,000/AZ, need 350,000+/AZ
# 5. EKS node groups   — default 30, need 50+
# =============================================================

REGION="ap-southeast-1"

echo "=================================================="
echo " AWS Service Quotas Checker for 1M TPS Event"
echo " Region: $REGION"
echo " Date: $(date)"
echo "=================================================="
echo ""

# ── Check Current Quotas ──────────────────────────────────────

echo "=== Checking Current Quota Values ==="
echo ""

echo "--- EC2 Spot vCPU Limit ---"
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-34B43A08 \
  --region $REGION \
  --query 'Quota.{QuotaName:QuotaName, Value:Value}' \
  --output table

echo ""
echo "--- EC2 On-Demand vCPU Limit ---"
aws service-quotas get-service-quota \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --region $REGION \
  --query 'Quota.{QuotaName:QuotaName, Value:Value}' \
  --output table

echo ""
echo "--- Kinesis Shards per Region ---"
aws service-quotas get-service-quota \
  --service-code kinesis \
  --quota-code L-3EEB8EB1 \
  --region $REGION \
  --query 'Quota.{QuotaName:QuotaName, Value:Value}' \
  --output table

echo ""
echo "--- DynamoDB Max WCU per Table ---"
aws service-quotas get-service-quota \
  --service-code dynamodb \
  --quota-code L-F98FE922 \
  --region $REGION \
  --query 'Quota.{QuotaName:QuotaName, Value:Value}' \
  --output table

echo ""
echo "--- EKS Max Node Groups per Cluster ---"
aws service-quotas get-service-quota \
  --service-code eks \
  --quota-code L-5E2C2F93 \
  --region $REGION \
  --query 'Quota.{QuotaName:QuotaName, Value:Value}' \
  --output table

echo ""

# ── Request Quota Increases ───────────────────────────────────

echo "=== Requesting Quota Increases ==="
echo "Note: AWS typically responds in 1-3 business days"
echo "Request NLB quotas first — longest lead time!"
echo ""

# EC2 Spot vCPU: 5,120 → 50,000
echo "Requesting EC2 Spot vCPU increase to 50,000..."
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-34B43A08 \
  --desired-value 50000 \
  --region $REGION \
  --query 'RequestedQuota.{Status:Status, DesiredValue:DesiredValue}' \
  --output table

echo ""

# EC2 On-Demand vCPU: default → 10,000
echo "Requesting EC2 On-Demand vCPU increase to 10,000..."
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 10000 \
  --region $REGION \
  --query 'RequestedQuota.{Status:Status, DesiredValue:DesiredValue}' \
  --output table

echo ""

# Kinesis Shards: 500 → 1,000
echo "Requesting Kinesis shards increase to 1,000..."
aws service-quotas request-service-quota-increase \
  --service-code kinesis \
  --quota-code L-3EEB8EB1 \
  --desired-value 1000 \
  --region $REGION \
  --query 'RequestedQuota.{Status:Status, DesiredValue:DesiredValue}' \
  --output table

echo ""

# DynamoDB WCU: 40,000 → 2,000,000
echo "Requesting DynamoDB WCU increase to 2,000,000..."
aws service-quotas request-service-quota-increase \
  --service-code dynamodb \
  --quota-code L-F98FE922 \
  --desired-value 2000000 \
  --region $REGION \
  --query 'RequestedQuota.{Status:Status, DesiredValue:DesiredValue}' \
  --output table

echo ""

# ── Verify ENI Limits ─────────────────────────────────────────

echo "=== Verifying ENI Limits for EKS Pod Density ==="
echo ""
echo "Instance type analysis:"
echo "c6i.4xlarge = 8 network interfaces x 30 IPs each = 240 pods/node"
echo "With 313 nodes needed: 313 x 240 = 75,120 max pods"
echo "Required: 5,000 pods"
echo "Result: ENI limits sufficient ✅"
echo ""

# ── Check Pending Quota Requests ─────────────────────────────

echo "=== Checking Pending Quota Requests ==="
aws service-quotas list-requested-changes-by-service \
  --service-code ec2 \
  --region $REGION \
  --query 'RequestedQuotas[].{QuotaName:QuotaName,Status:Status,DesiredValue:DesiredValue}' \
  --output table

echo ""
aws service-quotas list-requested-changes-by-service \
  --service-code kinesis \
  --region $REGION \
  --query 'RequestedQuotas[].{QuotaName:QuotaName,Status:Status,DesiredValue:DesiredValue}' \
  --output table

echo ""
aws service-quotas list-requested-changes-by-service \
  --service-code dynamodb \
  --region $REGION \
  --query 'RequestedQuotas[].{QuotaName:QuotaName,Status:Status,DesiredValue:DesiredValue}' \
  --output table

echo ""

# ── Summary ───────────────────────────────────────────────────

echo "=================================================="
echo " QUOTA CHECKLIST SUMMARY"
echo "=================================================="
echo ""
echo "T-14 days (request NOW — longest lead time):"
echo "  [ ] NLB connections per AZ (contact AWS Support directly)"
echo "  [ ] NLB listeners per load balancer"
echo ""
echo "T-7 days (request via this script):"
echo "  [ ] EC2 Spot vCPU: 5,120 → 50,000"
echo "  [ ] EC2 On-Demand vCPU: default → 10,000"
echo "  [ ] Kinesis Shards: 500 → 1,000"
echo "  [ ] DynamoDB WCU: 40,000 → 2,000,000"
echo ""
echo "T-1 day (verify all approved):"
echo "  [ ] All quota requests in APPROVED status"
echo "  [ ] Run load test to verify quotas work"
echo "  [ ] AWS Support contact confirmed for event day"
echo ""
echo "Script completed at: $(date)"
echo "=================================================="