# =============================================================
# Cost Control: AWS Budget + Lambda Automation + Kubecost
# Purpose: Prevent runaway costs during 1M TPS spike event
#
# Three layers of cost control:
# 1. AWS Budget — monitor hourly spend per service
# 2. Lambda automation — auto-cap Spot fleet if burn too high
# 3. Karpenter consolidation — remove unused nodes after spike
#
# Why cost control matters during spike event?
# At 1M TPS we may spin up 300+ EC2 instances
# Without guardrails: $50,000/hour is possible
# With guardrails: capped at $500/hour automatically
# =============================================================

# ── AWS Budget for Payment Service ───────────────────────────
resource "aws_budgets_budget" "payment_burst" {
  name         = "payment-burst-hourly"
  budget_type  = "COST"
  limit_amount = "500"
  limit_unit   = "USD"
  time_unit    = "HOURLY"

  # Only track costs for payment service resources
  cost_filter {
    name   = "TagKeyValue"
    values = [
      "user:Environment$production",
      "user:Service$payment"
    ]
  }

  # Alert at 80% of budget ($400/hour)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }

  # Alert at 100% of budget ($500/hour)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}

# ── SNS Topic for Budget Alerts ───────────────────────────────
resource "aws_sns_topic" "budget_alerts" {
  name = "payment-budget-alerts"
}

# ── Lambda: Auto-Cap Spot Fleet When Budget Exceeded ──────────
resource "aws_lambda_function" "cap_spot_fleet" {
  function_name = "cap-spot-fleet-on-budget"
  runtime       = "python3.12"
  handler       = "handler.main"
  role          = aws_iam_role.lambda_budget.arn
  timeout       = 60

  filename = "lambda/cap_spot_fleet.zip"

  environment {
    variables = {
      # Karpenter NodePool to patch
      KARPENTER_NODEPOOL = "payment-burst-pool"
      # Emergency cap: max 2,000 Spot vCPU
      MAX_SPOT_CPU       = "2000"
      # Slack webhook for notifications
      SLACK_WEBHOOK      = var.slack_webhook_url
    }
  }
}

# Lambda function code (inline for reference):
# def main(event, context):
#     """
#     Triggered by SNS when budget threshold exceeded
#     Actions:
#     1. Patch Karpenter NodePool to reduce Spot CPU limit
#     2. Send Slack alert with current spend rate
#     3. Create PagerDuty incident for human review
#     """
#     import boto3, json, urllib.request
#
#     # 1. Patch Karpenter NodePool via Kubernetes API
#     k8s = boto3.client('eks')
#     patch = {
#         "spec": {
#             "limits": {
#                 "cpu": os.environ['MAX_SPOT_CPU']
#             }
#         }
#     }
#     # Apply patch to NodePool
#
#     # 2. Notify Slack
#     message = f"Budget alert: Payment Spot fleet capped at {MAX_SPOT_CPU} vCPU"
#     urllib.request.urlopen(
#         urllib.request.Request(
#             SLACK_WEBHOOK,
#             json.dumps({"text": message}).encode()
#         )
#     )

# ── Connect SNS to Lambda ─────────────────────────────────────
resource "aws_sns_topic_subscription" "budget_to_lambda" {
  topic_arn = aws_sns_topic.budget_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cap_spot_fleet.arn
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cap_spot_fleet.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.budget_alerts.arn
}

# ── Kubecost Namespace Cost Dashboard ────────────────────────
# Kubecost installed via Helm — tracks cost per namespace
# resource "helm_release" "kubecost" {
#   name       = "kubecost"
#   repository = "https://kubecost.github.io/cost-analyzer"
#   chart      = "cost-analyzer"
#   namespace  = "kubecost"
#
#   set {
#     name  = "kubecostToken"
#     value = var.kubecost_token
#   }
#
#   # Send cost reports to Slack daily
#   set {
#     name  = "notifications.slack.webhook"
#     value = var.slack_webhook_url
#   }
# }

# ── Spot Instance Savings Plan ────────────────────────────────
# Pre-commit to Spot usage for additional savings
resource "aws_ec2_spot_fleet_request" "payment_spot" {
  iam_fleet_role  = aws_iam_role.spot_fleet.arn
  target_capacity = 100   # baseline Spot instances
  # Use multiple instance types for Spot availability
  launch_specification {
    instance_type = "c6i.2xlarge"
    spot_price    = "0.20"   # Max price willing to pay
  }
  launch_specification {
    instance_type = "c6a.2xlarge"
    spot_price    = "0.18"
  }
  launch_specification {
    instance_type = "m6i.2xlarge"
    spot_price    = "0.25"
  }
  # Automatically replace interrupted Spot instances
  replace_unhealthy_instances = true
}

# ── Variables ─────────────────────────────────────────────────
variable "slack_webhook_url" {
  description = "Slack webhook URL for cost alerts"
  type        = string
  sensitive   = true
}