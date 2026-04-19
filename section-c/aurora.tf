# =============================================================
# Aurora PostgreSQL - Reconciliation Database
# Purpose: Store finalized/reconciled payment records
#          for reporting, auditing, and accounting
#
# Why Aurora for reconciliation and not DynamoDB?
# DynamoDB = fast writes, simple queries (hot path)
# Aurora    = complex queries, joins, reporting (reconciliation)
#
# Data flow:
# API → Kinesis/SQS → Consumer Pods → DynamoDB (hot, real-time)
#                                   → Aurora (reconciliation, T+1)
#
# Aurora is NOT in the critical payment path
# It receives data AFTER DynamoDB confirms the transaction
# So Aurora slowness never affects payment processing speed
# =============================================================

# Aurora PostgreSQL Cluster
resource "aws_rds_cluster" "payment_aurora" {
  cluster_identifier = "payment-aurora-cluster"
  engine             = "aurora-postgresql"
  engine_version     = "15.4"

  # Multi-AZ: spread across 3 AZs for high availability
  availability_zones = [
    "ap-southeast-1a",
    "ap-southeast-1b",
    "ap-southeast-1c"
  ]

  database_name   = "payment_reconciliation"
  master_username = var.db_username
  # Password stored in AWS Secrets Manager — never hardcoded
  manage_master_user_password = true

  # Automated backups: keep 7 days of backups
  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"  # 3-4 AM low traffic

  # Encrypt all data at rest
  storage_encrypted = true
  kms_key_id        = aws_kms_key.payment.arn

  # Enable deletion protection — prevent accidental deletion
  deletion_protection = true

  # Enhanced monitoring every 30 seconds
  enabled_cloudwatch_logs_exports = [
    "postgresql",
    "upgrade"
  ]

  tags = {
    Environment = "production"
    Service     = "payment"
    Type        = "reconciliation"
  }
}

# Aurora Instances (1 writer + 2 readers)
# Writer: handles all INSERT/UPDATE from consumer pods
resource "aws_rds_cluster_instance" "payment_aurora_writer" {
  identifier         = "payment-aurora-writer"
  cluster_identifier = aws_rds_cluster.payment_aurora.id
  instance_class     = "db.r6g.2xlarge"
  engine             = aws_rds_cluster.payment_aurora.engine

  # Place writer in AZ-1a
  availability_zone = "ap-southeast-1a"

  # Enhanced monitoring
  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = {
    Role = "writer"
  }
}

# Reader 1: handles SELECT queries for reporting
resource "aws_rds_cluster_instance" "payment_aurora_reader_1" {
  identifier         = "payment-aurora-reader-1"
  cluster_identifier = aws_rds_cluster.payment_aurora.id
  instance_class     = "db.r6g.2xlarge"
  engine             = aws_rds_cluster.payment_aurora.engine

  # Place reader in different AZ from writer
  availability_zone = "ap-southeast-1b"

  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = {
    Role = "reader"
  }
}

# Reader 2: additional read replica for reporting load
resource "aws_rds_cluster_instance" "payment_aurora_reader_2" {
  identifier         = "payment-aurora-reader-2"
  cluster_identifier = aws_rds_cluster.payment_aurora.id
  instance_class     = "db.r6g.2xlarge"
  engine             = aws_rds_cluster.payment_aurora.engine

  availability_zone = "ap-southeast-1c"

  monitoring_interval = 30
  monitoring_role_arn = aws_iam_role.rds_monitoring.arn

  tags = {
    Role = "reader"
  }
}

# Variables
variable "db_username" {
  description = "Aurora master username"
  type        = string
  sensitive   = true
}