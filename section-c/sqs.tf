# =============================================================
# SQS Queues - Buffer & Backpressure
# Purpose: Act as buffer between API and payment processors
#          Prevent data loss when downstream services are slow
#
# Why SQS alongside Kinesis?
# Kinesis = high-throughput stream (1M TPS ingestion)
# SQS     = reliable queue with retry and DLQ support
#
# Data flow:
# API → Kinesis (hot path, 1M TPS)
#     → SQS (overflow + retry path)
#         → Consumer Pods
#             → DynamoDB (persistent storage)
#
# Two queues:
#   1. payment-ingest    = main queue for payment processing
#   2. payment-ingest-dlq = dead letter queue for failed messages
# =============================================================

# Dead Letter Queue (DLQ)
# Messages that fail 3 times go here
# Allows investigation without losing data
resource "aws_sqs_queue" "payment_dlq" {
  name = "payment-ingest-dlq"

  # Keep failed messages for 14 days
  # Gives team time to investigate and replay
  message_retention_seconds = 1209600  # 14 days

  # Encrypt messages at rest
  kms_master_key_id = aws_kms_key.payment.arn

  tags = {
    Environment = "production"
    Service     = "payment"
    Type        = "dead-letter-queue"
  }
}

# Main Payment Queue
resource "aws_sqs_queue" "payment_ingest" {
  name = "payment-ingest"

  # How long a message is hidden after being received
  # Consumer has 30 seconds to process before message
  # becomes visible again for retry
  visibility_timeout_seconds = 30

  # Keep unprocessed messages for 1 day
  message_retention_seconds = 86400  # 24 hours

  # Encrypt messages at rest
  kms_master_key_id = aws_kms_key.payment.arn

  # Redrive policy: after 3 failures → send to DLQ
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.payment_dlq.arn
    # Message must fail 3 times before going to DLQ
    maxReceiveCount = 3
  })

  tags = {
    Environment = "production"
    Service     = "payment"
    Type        = "main-queue"
  }
}

# Queue Policy: allow payment service to send messages
resource "aws_sqs_queue_policy" "payment_ingest" {
  queue_url = aws_sqs_queue.payment_ingest.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          AWS = aws_iam_role.payment_service.arn
        }
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.payment_ingest.arn
      }
    ]
  })
}