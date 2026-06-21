output "cognito_user_pool_id" {
  description = "Cognito User Pool ID."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  description = "Cognito app client ID (used by the SPA)."
  value       = aws_cognito_user_pool_client.spa.id
}

output "cognito_domain" {
  description = "Cognito Hosted UI domain."
  value       = "https://${var.cognito_domain_prefix}.auth.${var.aws_region}.amazoncognito.com"
}

output "api_endpoint" {
  description = "HTTP API invoke URL (POST /qrs). Custom domain used if configured."
  value       = local.use_custom_domain ? "https://${var.api_custom_domain}/qrs" : aws_apigatewayv2_api.http_api.api_endpoint
}

output "api_id" {
  description = "HTTP API ID."
  value       = aws_apigatewayv2_api.http_api.id
}

output "waf_acl_arn" {
  description = "WAFv2 WebACL ARN protecting the HTTP API."
  value       = aws_wafv2_web_acl.api.arn
}

output "waf_name" {
  description = "WAFv2 WebACL name (used as an alarm/dashboard dimension by observability)."
  value       = var.waf_name
}
