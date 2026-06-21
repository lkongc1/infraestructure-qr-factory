###############################################################################
# Dev environment values.
# Copy to terraform.tfvars (or override per environment) and fill in the
# YOURUNIQUE placeholders for the Cognito domain prefix and CI/CD connection.
###############################################################################

environment             = "Dev"
cognito_domain_prefix   = "qr-factory-dev-YOURUNIQUE"
api_custom_domain       = ""
api_custom_domain_zone  = ""
allowed_origin          = "http://localhost:5173"
quota_limit_per_user    = 20
log_retention_days      = 7
pagerduty_sns_endpoint  = ""
alarm_runbook_url       = "https://wiki.internal/runbooks/qr-factory-dev"
source_provider         = "github"
github_repo_owner       = ""
github_repo_name        = ""
github_branch           = "develop"
github_connection_arn   = ""
codecommit_repo_name    = "qr-factory-infra"
cloudfront_price_class  = "PriceClass_100"
