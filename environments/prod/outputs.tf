###############################################################################
# Prod environment outputs (thin layer over module outputs).
###############################################################################

output "cloudfront_domain" {
  description = "CloudFront distribution domain name (frontend entry point)."
  value       = module.frontend.cloudfront_domain
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (used for invalidations in CI/CD)."
  value       = module.frontend.cloudfront_distribution_id
}

output "frontend_bucket" {
  description = "S3 bucket hosting the SPA static assets."
  value       = module.frontend.frontend_bucket_id
}

output "assets_bucket" {
  description = "Private S3 bucket storing generated QR PNGs (presigned URL access)."
  value       = module.data.assets_bucket_id
}

output "templates_table" {
  description = "DynamoDB Templates table name."
  value       = module.data.templates_table_name
}

output "quotas_table" {
  description = "DynamoDB Quotas table name (PK=userId, TTL enabled)."
  value       = module.data.quotas_table_name
}

output "api_endpoint" {
  description = "HTTP API invoke URL (POST /qrs). Custom domain used if configured."
  value       = module.edge.api_endpoint
}

output "api_id" {
  description = "HTTP API ID."
  value       = module.edge.api_id
}

output "cognito_user_pool_id" {
  description = "Cognito User Pool ID."
  value       = module.edge.cognito_user_pool_id
}

output "cognito_client_id" {
  description = "Cognito app client ID (used by the SPA)."
  value       = module.edge.cognito_client_id
}

output "cognito_domain" {
  description = "Cognito Hosted UI domain."
  value       = module.edge.cognito_domain
}

output "lambda_function_name" {
  description = "QR generator Lambda function name."
  value       = module.lambda.lambda_function_name
}

output "lambda_arn" {
  description = "QR generator Lambda ARN."
  value       = module.lambda.lambda_arn
}

output "waf_acl_arn" {
  description = "WAFv2 WebACL ARN protecting the HTTP API."
  value       = module.edge.waf_acl_arn
}

output "sns_alarm_topic_arn" {
  description = "SNS topic ARN for alarm notifications (subscribe PagerDuty here)."
  value       = module.observability.sns_alarm_topic_arn
}

output "dashboard_url" {
  description = "CloudWatch dashboard URL (Golden Signals + Cost + Security)."
  value       = module.observability.dashboard_url
}

output "pipeline_arn" {
  description = "CodePipeline ARN."
  value       = module.cicd.pipeline_arn
}
