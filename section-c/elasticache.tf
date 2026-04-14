# =============================================================
# ElastiCache Redis - Write-Behind Caching
# Purpose: Reduce DynamoDB write pressure by ~80%
#
# Why Redis in front of DynamoDB?
# DynamoDB at 1M TPS = very expensive ($780/hr for 1.2M WCU)
# Redis can handle 1M+ ops/sec in memory — much faster & cheaper
#
# Write-behind pattern:
# 1. App writes to Redis first (fast, in-memory)
# 2. Redis asynchronously flushes to DynamoDB (slow, persistent)
# 3. If Redis fails, data is not lost — SQS acts as backup
#
# Cluster mode: 3 shards x 2 replicas = 6 nodes total
# Each shard handles ~333K TPS
# Each shard has 1 primary + 1 replica for HA
# =============================================================

resource "aws_elasticache_replication_group" "payment_cache" {
  replication_group_id = "payment-cache"
  description          = "Payment service write-behind cache"

  # Memory-optimized instance — best for caching workloads
  # r7g.2xlarge = 6.38GB memory, low latency, ARM-based
  node_type = "cache.r7g.2xlarge"

  # Cluster mode: 3 shards x 2 replicas
  num_cache_clusters = 6

  parameter_group_name = "default.redis7.cluster.on"
  port                 = 6379

  # Cluster mode configuration
  cluster_mode {
    # 3 shards — each handles ~333K TPS
    num_node_groups = 3
    # 2 replicas per shard (1 primary + 1 replica)
    # If primary fails, replica promoted automatically
    replicas_per_node_group = 2
  }

  # Encrypt data at rest
  at_rest_encryption_enabled = true

  # Encrypt data in transit between app and Redis
  transit_encryption_enabled = true

  # If primary node fails, automatically promote replica
  # Failover happens in ~30 seconds
  automatic_failover_enabled = true

  # Spread primary and replica across multiple AZs
  # If one AZ goes down, other AZ still has data
  multi_az_enabled = true

  # Automatically apply minor version updates
  auto_minor_version_upgrade = true

  tags = {
    Environment = "production"
    Service     = "payment"
  }
}