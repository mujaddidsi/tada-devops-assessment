# =============================================================
# Route 53 - Latency-Based Routing + Health Checks
# Purpose: Route users to the nearest/fastest region
#          and automatically failover if a region goes down
#
# Why latency-based routing for 1M TPS?
# Users in Jakarta should not be routed to US servers
# Users in Singapore get lower latency than US
# Automatic failover if primary region has issues
#
# Setup:
#   Primary region  : ap-southeast-1 (Singapore) — closest to ID
#   Secondary region: ap-southeast-3 (Jakarta)   — backup
# =============================================================

# ── Health Check ─────────────────────────────────────────────
# Route 53 checks if our payment API is healthy
# If unhealthy → automatically stop routing traffic there
resource "aws_route53_health_check" "payment_primary" {
  # The endpoint to check
  fqdn          = "api-primary.payment.tada.id"
  port          = 443
  type          = "HTTPS"

  # Path that returns 200 if service is healthy
  resource_path = "/health"

  # Check every 10 seconds
  # 2 consecutive failures = unhealthy
  # 2 consecutive success  = healthy again
  failure_threshold = 2
  request_interval  = 10

  # Check from 3 different AWS regions
  # All 3 must agree the endpoint is down before failover
  # Prevents false positives from single region network issues
  regions = [
    "ap-southeast-1",  # Singapore
    "us-east-1",       # Virginia
    "eu-west-1"        # Ireland
  ]

  # Measure latency for CloudWatch metrics
  measure_latency = true

  tags = {
    Name        = "payment-primary-health-check"
    Environment = "production"
    Service     = "payment"
  }
}

resource "aws_route53_health_check" "payment_secondary" {
  fqdn              = "api-secondary.payment.tada.id"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health"
  failure_threshold = 2
  request_interval  = 10

  regions = [
    "ap-southeast-1",
    "us-east-1",
    "eu-west-1"
  ]

  measure_latency = true

  tags = {
    Name        = "payment-secondary-health-check"
    Environment = "production"
    Service     = "payment"
  }
}

# ── DNS Records with Latency-Based Routing ───────────────────
# Primary: ap-southeast-1 (Singapore)
# Users closest to Singapore get routed here first
resource "aws_route53_record" "payment_primary" {
  zone_id = var.route53_zone_id
  name    = "api.payment.tada.id"
  type    = "A"

  # Latency routing: Route 53 measures which region
  # is fastest for each user and routes accordingly
  latency_routing_policy {
    region = "ap-southeast-1"
  }

  # Unique identifier for this record
  set_identifier = "primary-ap-southeast-1"

  # If health check fails → Route 53 stops sending
  # traffic here and routes to secondary instead
  health_check_id = aws_route53_health_check.payment_primary.id

  alias {
    name                   = aws_cloudfront_distribution.payment.domain_name
    zone_id                = aws_cloudfront_distribution.payment.hosted_zone_id
    evaluate_target_health = true
  }
}

# Secondary: ap-southeast-3 (Jakarta)
# Failover target if Singapore region goes down
resource "aws_route53_record" "payment_secondary" {
  zone_id = var.route53_zone_id
  name    = "api.payment.tada.id"
  type    = "A"

  latency_routing_policy {
    region = "ap-southeast-3"
  }

  set_identifier  = "secondary-ap-southeast-3"
  health_check_id = aws_route53_health_check.payment_secondary.id

  alias {
    name                   = aws_cloudfront_distribution.payment_secondary.domain_name
    zone_id                = aws_cloudfront_distribution.payment_secondary.hosted_zone_id
    evaluate_target_health = true
  }
}

# ── Variables ─────────────────────────────────────────────────
variable "route53_zone_id" {
  description = "Route 53 Hosted Zone ID for payment.tada.id"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ACM Certificate ARN for api.payment.tada.id"
  type        = string
}