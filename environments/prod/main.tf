###############################################################################
# Prod environment root module.
#
# Wires the 6 child modules in dependency order (DAG):
#   data -----> lambda ----> edge --------> observability
#   data -----------------> observability
#   frontend -> edge
#   frontend -> cicd
#   data.aws_caller_identity -> cicd
#
# Source paths are relative to this file (environments/prod/), so
# "../../modules/<name>" resolves to qr-factory-infra/modules/<name>.
###############################################################################

# I3 - Data: private assets S3 bucket + DynamoDB Templates/Quotas tables.
# No upstream module deps; consumes only precomputed names from locals.
module "data" {
  source = "../../modules/data"

  assets_bucket_name   = local.assets_bucket_name
  templates_table_name = local.templates_table_name
  quotas_table_name    = local.quotas_table_name

  extra_tags = local.extra_tags
}

# FE - Frontend: SPA on S3 served via CloudFront (OAC + security headers).
# No upstream module deps; consumes only precomputed names from locals.
module "frontend" {
  source = "../../modules/frontend"

  name_prefix            = local.name_prefix
  frontend_bucket_name   = local.frontend_bucket_name
  cloudfront_price_class = var.cloudfront_price_class
  cognito_auth_domain    = local.cognito_auth_domain

  extra_tags = local.extra_tags
}

# I2 - Compute: QR generator Lambda (Python 3.11, arm64, Powertools).
# Consumes data module outputs (bucket + table ids/arns/names).
module "lambda" {
  source = "../../modules/lambda"

  name_prefix          = local.name_prefix
  lambda_function_name = local.lambda_function_name
  lambda_log_group     = local.lambda_log_group

  lambda_memory_size     = var.lambda_memory_size
  lambda_timeout_seconds = var.lambda_timeout_seconds
  quota_limit_per_user   = var.quota_limit_per_user
  log_retention_days     = var.log_retention_days

  assets_bucket_id     = module.data.assets_bucket_id
  assets_bucket_arn    = module.data.assets_bucket_arn
  templates_table_name = module.data.templates_table_name
  templates_table_arn  = module.data.templates_table_arn
  quotas_table_name    = module.data.quotas_table_name
  quotas_table_arn     = module.data.quotas_table_arn

  # Explicit paths: path.root resolves to environments/prod/, so ../../ reaches
  # qr-factory-infra/ project root where src/ and build/ live. See
  # modules/lambda/variables.tf for why these are required (no defaults).
  source_dir  = "${path.root}/../../src"
  output_path = "${path.root}/../../build/qr_generator.zip"

  extra_tags = local.extra_tags
}

# I1 - Edge: Cognito + WAF + HTTP API. Consumes frontend (cloudfront_domain)
# and lambda (invoke_arn, function_name) outputs.
module "edge" {
  source = "../../modules/edge"

  name_prefix = local.name_prefix

  aws_region                  = var.aws_region
  cognito_domain_prefix       = var.cognito_domain_prefix
  cognito_user_pool_name      = local.cognito_user_pool_name
  cognito_client_name         = local.cognito_client_name
  access_token_validity_hours = var.access_token_validity_hours

  api_name               = local.api_name
  waf_name               = local.waf_name
  api_custom_domain      = var.api_custom_domain
  api_custom_domain_zone = var.api_custom_domain_zone
  allowed_origin         = var.allowed_origin
  log_retention_days     = var.log_retention_days

  cloudfront_domain    = module.frontend.cloudfront_domain
  lambda_invoke_arn    = module.lambda.lambda_invoke_arn
  lambda_function_name = module.lambda.lambda_function_name

  extra_tags = local.extra_tags
}

# I4 - Observability: SNS + alarms + dashboard. Consumes lambda, edge, data.
module "observability" {
  source = "../../modules/observability"

  name_prefix = local.name_prefix

  aws_region             = var.aws_region
  pagerduty_sns_endpoint = var.pagerduty_sns_endpoint
  alarm_runbook_url      = var.alarm_runbook_url
  quota_limit_per_user   = var.quota_limit_per_user

  lambda_function_name = module.lambda.lambda_function_name
  quotas_table_name    = module.data.quotas_table_name
  assets_bucket_id     = module.data.assets_bucket_id
  waf_name             = module.edge.waf_name

  dashboard_name = local.dashboard_name
  sns_topic_name = local.sns_topic_name

  extra_tags = local.extra_tags
}

# I5 - CI/CD: CodePipeline + CodeBuild + roles. Consumes frontend + account.
module "cicd" {
  source = "../../modules/cicd"

  name_prefix = local.name_prefix

  aws_region   = var.aws_region
  project_name = var.project_name
  environment  = var.environment

  source_provider       = var.source_provider
  github_repo_owner     = var.github_repo_owner
  github_repo_name      = var.github_repo_name
  github_branch         = var.github_branch
  github_connection_arn = var.github_connection_arn
  codecommit_repo_name  = var.codecommit_repo_name

  frontend_bucket_arn         = module.frontend.frontend_bucket_arn
  cloudfront_distribution_arn = module.frontend.cloudfront_distribution_arn
  account_id                  = data.aws_caller_identity.current.account_id

  artifacts_bucket_name = local.artifacts_bucket_name
  pipeline_name         = local.pipeline_name
  codebuild_name        = local.codebuild_name

  extra_tags = local.extra_tags
}
