locals {
  # Lower-cased environment for resource name segments (AWS naming constraints).
  env_lower = lower(var.environment)

  # Common prefix used by all named resources.
  name_prefix = "qr-factory-${local.env_lower}"

  # S3 bucket names are globally unique; suffix with a stable hash of region+env
  # to avoid collisions without forcing the user to invent names.
  name_suffix = substr(md5("${var.aws_region}:${var.project_name}:${var.environment}"), 0, 8)

  # --- Precomputed resource names (single source of truth, passed to modules) ---
  frontend_bucket_name  = "qr-factory-fe-${local.env_lower}-${local.name_suffix}"
  assets_bucket_name    = "qr-factory-assets-${local.env_lower}-${local.name_suffix}"
  artifacts_bucket_name = "qr-factory-artifacts-${local.env_lower}-${local.name_suffix}"

  templates_table_name = "${local.name_prefix}-templates"
  quotas_table_name    = "${local.name_prefix}-quotas"

  lambda_function_name = "${local.name_prefix}-qr-generator"
  lambda_log_group     = "/aws/lambda/${local.name_prefix}-qr-generator"

  api_name       = "${local.name_prefix}-api"
  waf_name       = "${local.name_prefix}-waf"
  pipeline_name  = "${local.name_prefix}-pipeline"
  codebuild_name = "${local.name_prefix}-build"
  dashboard_name = "${local.name_prefix}-dashboard"
  sns_topic_name = "${local.name_prefix}-alarms"

  cognito_user_pool_name = "${local.name_prefix}-users"
  cognito_client_name    = "${local.name_prefix}-client"

  # Pre-built Cognito Hosted UI domain. Single source of truth: derived once
  # here and passed to the frontend module (CSP) so the module never re-derives
  # it from two variables.
  cognito_auth_domain = "https://${var.cognito_domain_prefix}.auth.${var.aws_region}.amazoncognito.com"

  # Extra tags merged on top of provider default_tags where it makes sense.
  extra_tags = {}
}
