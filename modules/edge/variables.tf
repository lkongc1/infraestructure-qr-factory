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

variable "cognito_domain_prefix" {
  description = "Globally-unique prefix for the Cognito Hosted UI domain (e.g. https://<prefix>.auth.<region>.amazoncognito.com)."
  type        = string
}

variable "cognito_user_pool_name" {
  description = "Name of the Cognito User Pool (precomputed in root locals, single source of truth)."
  type        = string
}

variable "cognito_client_name" {
  description = "Name of the Cognito app client (precomputed in root locals, single source of truth)."
  type        = string
}

variable "access_token_validity_hours" {
  description = "Access token validity in hours (JWT RS256). Architecture requires 1h."
  type        = number
}

variable "api_name" {
  description = "HTTP API name (precomputed in root locals, single source of truth)."
  type        = string
}

variable "waf_name" {
  description = "WAFv2 WebACL name (precomputed in root locals, single source of truth)."
  type        = string
}

variable "api_custom_domain" {
  description = "Custom domain name for the HTTP API (e.g. api.qr-factory.example.com). Leave empty to use the default execute-api URL."
  type        = string
}

variable "api_custom_domain_zone" {
  description = "Route53 hosted zone name for the API custom domain ACM validation. Required only when api_custom_domain is set."
  type        = string
}

variable "allowed_origin" {
  description = "Origin allowed by CORS / response security headers. Use the CloudFront distribution domain. Empty = use the distribution output after apply."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days. Architecture requires 30."
  type        = number
}

variable "cloudfront_domain" {
  description = "CloudFront distribution domain name (from the frontend module). Used for CORS and Cognito callback/logout URLs."
  type        = string
}

variable "lambda_invoke_arn" {
  description = "Invoke ARN of the QR generator Lambda (from the lambda module). Used by the HTTP API integration."
  type        = string
}

variable "lambda_function_name" {
  description = "Name of the QR generator Lambda (from the lambda module). Used by the lambda:InvokeFunction permission."
  type        = string
}
