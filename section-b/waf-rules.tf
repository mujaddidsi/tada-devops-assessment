# =============================================================
# AWS WAF Web ACL
# Purpose: Protect payment API from common web attacks
#
# WAF is attached to CloudFront distribution
# Every request passes through WAF before reaching NLB
#
# Three rules defined:
#   1. Rate limiting  — block IPs sending too many requests
#   2. SQL injection  — block database attack attempts
#   3. IP reputation  — block known malicious IP addresses
#
# Why Terraform for WAF?
# WAF rules must be version-controlled and reproducible
# Terraform lets us track changes and roll back if needed
# =============================================================

# Create WAF Web ACL
resource "aws_wafv2_web_acl" "payment_waf" {
  name  = "payment-waf"
  scope = "CLOUDFRONT"  # Attach to CloudFront, not regional

  # Default: allow all requests that don't match any rule
  default_action {
    allow {}
  }

  # ── Rule 1: Rate Limiting Per IP ─────────────────────────
  # Block IPs that send more than 10,000 requests per 5 minutes
  # Protects against:
  #   - DDoS attacks from single IP
  #   - Brute force attacks
  #   - Credential stuffing
  rule {
    name     = "rate-limit-per-ip"
    priority = 1  # Check this rule first

    action {
      block {}  # Block the request, return 403
    }

    statement {
      rate_based_statement {
        # Maximum requests per 5 minute window per IP
        limit              = 10000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
    }
  }

  # ── Rule 2: SQL Injection Protection ─────────────────────
  # Use AWS managed rule set for SQL injection detection
  # Automatically updated by AWS when new attack patterns emerge
  # Protects against attempts to manipulate payment database
  rule {
    name     = "sqli-protection"
    priority = 2

    # none = use the rule group's own actions (block/allow)
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "SQLiProtection"
    }
  }

  # ── Rule 3: IP Reputation List ────────────────────────────
  # Block IPs known to be malicious (botnets, Tor exit nodes,
  # scanners, crawlers that have exhibited malicious behavior)
  # AWS maintains and updates this list automatically
  rule {
    name     = "ip-reputation"
    priority = 3

    action {
      block {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "IPReputation"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "PaymentWAF"
  }
}

# Attach WAF to CloudFront distribution
resource "aws_cloudfront_distribution" "payment" {
  web_acl_id = aws_wafv2_web_acl.payment_waf.arn

  origin {
    domain_name = "api.payment.tada.id"
    origin_id   = "payment-nlb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.3"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "payment-nlb"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      cookies {
        forward = "none"
      }
    }
  }

  enabled = true

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = false
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1.3_2022"
  }
}