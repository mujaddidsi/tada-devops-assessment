# =============================================================
# Kinesis Data Streams
# Purpose: Ingest 1M TPS without any transaction loss
#
# Why Kinesis and not just SQS?
# SQS max throughput: ~3,000 msg/sec per queue
# Kinesis max throughput: 1MB/s per shard, unlimited shards
# At 1M TPS x 1KB payload = 1GB/s → need 1,000 shards
#
# Shard calculation:
# 1,000,000 TPS x 1KB = 1,000,000 KB/s = ~1GB/s
# Kinesis limit = 1MB/s per shard
# Shards needed = 1,000MB/s ÷ 1MB/s = 1,000 shards
# =============================================================

resource "aws_kinesis_stream" "payment_events" {
  name             = "payment-events"
  shard_count      = 1000
  # Keep data for 24 hours — allows replay if consumer fails
  retention_period = 24

  stream_mode_details {
    # PROVISIONED = pre-allocate shards
    # On-Demand would be too slow to scale for sudden burst
    stream_mode = "PROVISIONED"
  }

  # Encrypt data at rest — required for payment data
  encryption_type = "KMS"
  kms_key_id      = aws_kms_key.payment.arn

  tags = {
    Environment = "production"
    Service     = "payment"
  }
}

# Enhanced Fan-Out Consumer
# Gives each consumer group dedicated 2MB/s per shard
# Without EFO, all consumers share 2MB/s per shard
resource "aws_kinesis_stream_consumer" "payment_processor" {
  name       = "payment-processor-efo"
  stream_arn = aws_kinesis_stream.payment_events.arn
}

# KMS key for Kinesis encryption
resource "aws_kms_key" "payment" {
  description             = "KMS key for payment data encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Environment = "production"
    Service     = "payment"
  }
}