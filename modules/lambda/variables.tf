variable "name_prefix" {
  description = "Common prefix used by all named resources (e.g. qr-factory-dev)."
  type        = string
}

variable "lambda_function_name" {
  description = "QR generator Lambda function name (precomputed in root locals, single source of truth)."
  type        = string
}

variable "lambda_log_group" {
  description = "CloudWatch Logs group name for the Lambda (precomputed in root locals, single source of truth)."
  type        = string
}

variable "extra_tags" {
  description = "Extra tags merged on top of the provider default_tags for module resources."
  type        = map(string)
  default     = {}
}

variable "lambda_memory_size" {
  description = "Lambda memory in MB. Architecture requires 512."
  type        = number
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds. Fail-fast design requires 10."
  type        = number
}

variable "quota_limit_per_user" {
  description = "Daily QR generation quota per user, enforced by the Quotas DynamoDB table."
  type        = number
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days. Architecture requires 30."
  type        = number
}

variable "assets_bucket_id" {
  description = "ID of the private assets S3 bucket (from the data module). Used as the ASSETS_BUCKET env var."
  type        = string
}

variable "assets_bucket_arn" {
  description = "ARN of the private assets S3 bucket (from the data module). Used to scope the Lambda S3 policy."
  type        = string
}

variable "templates_table_name" {
  description = "DynamoDB Templates table name (from the data module). Used as the TEMPLATES_TABLE env var."
  type        = string
}

variable "templates_table_arn" {
  description = "ARN of the DynamoDB Templates table (from the data module). Used to scope the Lambda DynamoDB policy."
  type        = string
}

variable "quotas_table_name" {
  description = "DynamoDB Quotas table name (from the data module). Used as the QUOTAS_TABLE env var."
  type        = string
}

variable "quotas_table_arn" {
  description = "ARN of the DynamoDB Quotas table (from the data module). Used to scope the Lambda DynamoDB policy."
  type        = string
}

# IMPORTANT: source_dir and output_path are REQUIRED (no defaults) on purpose.
# When Terraform runs from environments/<env>/, path.root resolves to
# environments/<env>/, NOT the qr-factory-infra/ project root. So a default of
# "${path.root}/src" would point at the wrong directory. Each environment's
# main.tf sets these explicitly to "${path.root}/../../src" and
# "${path.root}/../../build/qr_generator.zip" so the path is correct regardless
# of where the module is invoked from. Making them required avoids silent
# path bugs.
variable "source_dir" {
  description = "Absolute or Terraform-path-resolved directory containing the Lambda handler (Option B: src/ at project root). Set explicitly per environment, e.g. \"${path.root}/../../src\"."
  type        = string
}

variable "output_path" {
  description = "Path where the archive_file data source writes the Lambda zip. Set explicitly per environment, e.g. \"${path.root}/../../build/qr_generator.zip\"."
  type        = string
}
