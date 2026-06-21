variable "name_prefix" {
  description = "Common prefix used by all named resources (e.g. qr-factory-dev)."
  type        = string
}

variable "extra_tags" {
  description = "Extra tags merged on top of the provider default_tags for module resources."
  type        = map(string)
  default     = {}
}

variable "aws_region" {
  description = "AWS region for all regional resources (frontend is global via CloudFront)."
  type        = string
}

variable "pagerduty_sns_endpoint" {
  description = "PagerDuty SNS integration endpoint (HTTPS). Used as the SNS topic subscription for alarm notifications."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alarm_runbook_url" {
  description = "Runbook URL embedded in CloudWatch alarm descriptions."
  type        = string
}

variable "quota_limit_per_user" {
  description = "Daily QR generation quota per user, enforced by the Quotas DynamoDB table."
  type        = number
}

variable "lambda_function_name" {
  description = "QR generator Lambda function name (from the lambda module). Used as an alarm/dashboard dimension."
  type        = string
}

variable "quotas_table_name" {
  description = "DynamoDB Quotas table name (from the data module). Used as an alarm/dashboard dimension."
  type        = string
}

variable "assets_bucket_id" {
  description = "ID of the private assets S3 bucket (from the data module). Used in the dashboard cost panel."
  type        = string
}

variable "waf_name" {
  description = "WAFv2 WebACL name (from the edge module). Used as an alarm/dashboard dimension."
  type        = string
}

variable "dashboard_name" {
  description = "CloudWatch dashboard name (precomputed and env-scoped in root locals, single source of truth)."
  type        = string
}

variable "sns_topic_name" {
  description = "SNS alarm topic name (precomputed in root locals, single source of truth)."
  type        = string
}
