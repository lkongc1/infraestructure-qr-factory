###############################################################################
# I4 - OBSERVABILITY
# - SNS topic for PagerDuty alarm notifications
# - CloudWatch metric alarms (Latency P99, Error rate, Throttles, Quota usage,
#   Concurrent executions, WAF BlockedCount, BotBlockedCount, DDB throttles)
# - CloudWatch dashboard (Golden Signals + Cost + Security panels)
#
# Logs and most metrics are emitted by the Lambda via Powertools EMF (no extra
# cost). Only the alarms, dashboard and SNS are defined here. Dimensions that
# used to reference resources directly (Lambda function, Quotas table, WAF,
# assets bucket) are now module inputs so this module has no hard resource
# dependency and stays reusable.
###############################################################################

# --- SNS topic + PagerDuty subscription ------------------------------------

resource "aws_sns_topic" "alarms" {
  name = var.sns_topic_name

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count     = length(var.pagerduty_sns_endpoint) > 0 ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "https"
  endpoint  = var.pagerduty_sns_endpoint
}

# --- Alarms ----------------------------------------------------------------

# Lambda error rate (errors relative to invocations).
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.name_prefix}-lambda-errors"
  alarm_description   = "QR generator Lambda error rate above 1%. Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# Lambda throttles.
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${var.name_prefix}-lambda-throttles"
  alarm_description   = "QR generator Lambda throttles detected. Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# Lambda duration P99 (fail-fast: alert if P99 > 8s on a 10s timeout).
resource "aws_cloudwatch_metric_alarm" "lambda_duration_p99" {
  alarm_name          = "${var.name_prefix}-lambda-duration-p99"
  alarm_description   = "QR generator P99 latency above 8s (timeout is 10s). Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 5
  threshold           = 8000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# Lambda concurrent executions (account saturation guard).
resource "aws_cloudwatch_metric_alarm" "lambda_concurrent" {
  alarm_name          = "${var.name_prefix}-lambda-concurrent"
  alarm_description   = "QR generator concurrent executions above 900 (near account limit). Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/Lambda"
  metric_name         = "ConcurrentExecutions"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = var.lambda_function_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# Quota usage (EMF metric emitted by Lambda; alert when users near their cap).
resource "aws_cloudwatch_metric_alarm" "quota_usage" {
  alarm_name          = "${var.name_prefix}-quota-usage-high"
  alarm_description   = "A user is consuming >= 90% of the daily QR quota. Runbook: ${var.alarm_runbook_url}"
  namespace           = "QRFactory"
  metric_name         = "QuotaUsage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = floor(var.quota_limit_per_user * 0.9)
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# WAF blocked requests (BlockedCount across all blocking rules).
resource "aws_cloudwatch_metric_alarm" "waf_blocked" {
  alarm_name          = "${var.name_prefix}-waf-blocked-high"
  alarm_description   = "WAF blocked request volume is abnormally high (possible attack). Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 500
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = var.waf_name
    Region = var.aws_region
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# WAF bot control blocked (BotBlockedCount).
resource "aws_cloudwatch_metric_alarm" "waf_bot_blocked" {
  alarm_name          = "${var.name_prefix}-waf-bot-blocked-high"
  alarm_description   = "Bot Control is blocking a high volume of requests. Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = var.waf_name
    Rule   = "bot-control"
    Region = var.aws_region
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# DynamoDB throttles (Quotas table is the hot path due to atomic counters).
resource "aws_cloudwatch_metric_alarm" "ddb_quotas_throttles" {
  alarm_name          = "${var.name_prefix}-ddb-quotas-throttles"
  alarm_description   = "Quotas table is being throttled (atomic counter hot shard). Runbook: ${var.alarm_runbook_url}"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ThrottledRequests"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = var.quotas_table_name
  }

  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}

# --- Dashboard: Golden Signals + Cost + Security ---------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.dashboard_name

  dashboard_body = jsonencode({
    widgets = [
      # --- Golden Signals: Latency ---
      {
        type = "metric"
        x    = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Latency (Golden Signal)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", var.lambda_function_name, { stat = "p99", label = "P99" }],
            [".", ".", ".", ".", { stat = "p50", label = "P50" }],
            [".", ".", ".", ".", { stat = "p95", label = "P95" }],
          ]
          period = 60
        }
      },
      # --- Golden Signals: Traffic ---
      {
        type = "metric"
        x    = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Traffic (Invocations)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name],
            [".", "ConcurrentExecutions", "FunctionName", var.lambda_function_name],
          ]
          period = 60
        }
      },
      # --- Golden Signals: Errors ---
      {
        type = "metric"
        x    = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "Errors (Golden Signal)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.lambda_function_name],
            [".", "Throttles", "FunctionName", var.lambda_function_name],
          ]
          period = 60
        }
      },
      # --- Golden Signals: Saturation ---
      {
        type = "metric"
        x    = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Saturation (DDB + Concurrency)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/DynamoDB", "ThrottledRequests", "TableName", var.quotas_table_name],
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.quotas_table_name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.quotas_table_name],
          ]
          period = 300
        }
      },
      # --- Cost panels ---
      {
        type = "metric"
        x    = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Cost Drivers (Lambda + S3 + DDB)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.lambda_function_name, { label = "Lambda Invocations" }],
            ["AWS/S3", "BucketSizeBytes", "BucketName", var.assets_bucket_id, "StorageType", "StandardStorage"],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.quotas_table_name],
          ]
          period = 300
        }
      },
      {
        type = "metric"
        x    = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Quota Usage (EMF)"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["QRFactory", "QuotaUsage"],
            ["QRFactory", "QuotaRemaining"],
          ]
          period = 300
        }
      },
      # --- Security panels ---
      {
        type = "metric"
        x    = 0, y = 18, width = 12, height = 6
        properties = {
          title  = "Security: WAF Blocked"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_name, "Region", var.aws_region],
            ["AWS/WAFV2", "AllowedRequests", "WebACL", var.waf_name, "Region", var.aws_region],
          ]
          period = 300
        }
      },
      {
        type = "metric"
        x    = 12, y = 18, width = 12, height = 6
        properties = {
          title  = "Security: Bot Control + Custom Rule"
          region = var.aws_region
          view   = "timeSeries"
          metrics = [
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_name, "Rule", "bot-control", "Region", var.aws_region],
            ["AWS/WAFV2", "BlockedRequests", "WebACL", var.waf_name, "Rule", "block-javascript-scheme-in-body", "Region", var.aws_region],
          ]
          period = 300
        }
      },
    ]
  })

  tags = merge(var.extra_tags, { Layer = "I4-Observability" })
}
