###############################################################################
# Global inputs (shared across all environments; defaults match the original
# flat layout). Environment-specific inputs live below and are overridden via
# terraform.tfvars per environment.
###############################################################################

variable "aws_region" {
  description = "AWS region for all regional resources (frontend is global via CloudFront)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used in tags and resource naming."
  type        = string
  default     = "QR-Factory"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.project_name))
    error_message = "project_name must be alphanumeric with hyphens only."
  }
}

variable "access_token_validity_hours" {
  description = "Access token validity in hours (JWT RS256). Architecture requires 1h."
  type        = number
  default     = 1
}

variable "lambda_memory_size" {
  description = "Lambda memory in MB. Architecture requires 512."
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout in seconds. Fail-fast design requires 10."
  type        = number
  default     = 10
}

###############################################################################
# Environment-specific inputs (override via terraform.tfvars).
###############################################################################

variable "environment" {
  description = "Environment name (Prod, Staging, Dev). Drives naming and tags."
  type        = string
  default     = "Prod"
}

variable "cognito_domain_prefix" {
  description = "Globally-unique prefix for the Cognito Hosted UI domain (e.g. https://<prefix>.auth.<region>.amazoncognito.com)."
  type        = string
}

###############################################################################
# API Gateway (I1 - HTTP API)
###############################################################################

variable "api_custom_domain" {
  description = "Custom domain name for the HTTP API (e.g. api.qr-factory.example.com). Leave empty to use the default execute-api URL."
  type        = string
  default     = ""
}

variable "api_custom_domain_zone" {
  description = "Route53 hosted zone name for the API custom domain ACM validation. Required only when api_custom_domain is set."
  type        = string
  default     = ""
}

variable "allowed_origin" {
  description = "Origin allowed by CORS / response security headers. Use the CloudFront distribution domain. Empty = use the distribution output after apply."
  type        = string
  default     = ""
}

###############################################################################
# Lambda (I2 - Compute)
###############################################################################

variable "quota_limit_per_user" {
  description = "Daily QR generation quota per user, enforced by the Quotas DynamoDB table."
  type        = number
  default     = 100
}

###############################################################################
# Observability (I4)
###############################################################################

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days. Architecture requires 30."
  type        = number
  default     = 30
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
  default     = "https://wiki.internal/qr-factory/runbook"
}

###############################################################################
# CI/CD (I5)
###############################################################################

variable "source_provider" {
  description = "Pipeline source provider: github or codecommit."
  type        = string
  default     = "github"

  validation {
    condition     = contains(["github", "codecommit"], var.source_provider)
    error_message = "source_provider must be 'github' or 'codecommit'."
  }
}

variable "github_repo_owner" {
  description = "GitHub repository owner (org or user). Used when source_provider = github."
  type        = string
  default     = ""
}

variable "github_repo_name" {
  description = "GitHub repository name. Used when source_provider = github."
  type        = string
  default     = ""
}

variable "github_branch" {
  description = "Source branch tracked by the pipeline."
  type        = string
  default     = "main"
}

variable "github_connection_arn" {
  description = "ARN of the CodeStar Connections connection to GitHub. Required when source_provider = github."
  type        = string
  default     = ""
}

variable "codecommit_repo_name" {
  description = "CodeCommit repository name. Used when source_provider = codecommit."
  type        = string
  default     = "qr-factory-infra"
}

###############################################################################
# Frontend (FE)
###############################################################################

variable "cloudfront_price_class" {
  description = "CloudFront price class. PriceClass_100 = US/EU only; PriceClass_All = global."
  type        = string
  default     = "PriceClass_100"
}
