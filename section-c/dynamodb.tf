# =============================================================
# DynamoDB Table for Payment Events
# Purpose: Store 1M TPS payment transactions with zero loss
#
# Why DynamoDB and not PostgreSQL/MySQL?
# PostgreSQL max writes: ~10,000-50,000 TPS
# DynamoDB max writes: unlimited (scales automatically)
# At 1M TPS we need a database that scales horizontally
#
# Hot partition problem:
# If we use payment_id as partition key, popular merchants
# will create "hot partitions" — one partition gets all traffic
# Solution: add random shard prefix (0-199) to distribute evenly
#
# Partition key design:
# BAD:  payment_id (hot partition risk)
# GOOD: SHARD-042#payment_id (evenly distributed)
# =============================================================

resource "aws_dynamodb_table" "payment_events" {
  name         = "payment_events"
  billing_mode = "PROVISIONED"

  # Pre-provision 1.2M WCU (20% headroom over 1M TPS)
  # Why PROVISIONED and not PAY_PER_REQUEST?
  # PAY_PER_REQUEST has 30 min warm-up for 2x previous peak
  # For sudden burst event, it would throttle badly
  # PROVISIONED is ready from second zero
  write_capacity = 1200000
  read_capacity  = 600000

  # Partition key: shard prefix + payment ID
  # 200 shards distributes 1M TPS across 200 partitions
  # Each partition handles ~5,000 TPS — well within limits
  hash_key  = "shard_id"   # SHARD-042#uuid-prefix
  range_key = "event_id"   # timestamp#uuid

  attribute {
    name = "shard_id"
    type = "S"  # String
  }

  attribute {
    name = "event_id"
    type = "S"  # String
  }

  attribute {
    name = "merchant_id"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "N"  # Number (Unix timestamp)
  }

  # GSI 1: Query by merchant
  # Example: "Show all transactions for merchant X today"
  global_secondary_index {
    name            = "merchant-index"
    hash_key        = "merchant_id"
    range_key       = "created_at"
    projection_type = "ALL"
    write_capacity  = 100000
    read_capacity   = 100000
  }

  # GSI 2: Query by status
  # Example: "Show all PENDING transactions for reconciliation"
  global_secondary_index {
    name            = "status-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
    write_capacity  = 100000
    read_capacity   = 100000
  }

  # TTL: automatically delete records after 30 days
  # Keeps table size manageable and reduces storage cost
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  # Point-in-time recovery: restore table to any point
  # in the last 35 days — critical for payment data
  point_in_time_recovery {
    enabled = true
  }

  # Encrypt all data at rest using KMS
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.payment.arn
  }

  tags = {
    Environment = "production"
    Service     = "payment"
  }
}