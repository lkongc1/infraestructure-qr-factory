###############################################################################
# Prod environment values.
# Copy to terraform.tfvars (or override per environment) and fill in the
# YOURUNIQUE placeholder for the Cognito domain prefix and the CI/CD connection.
###############################################################################

environment             = "Prod"
cognito_domain_prefix   = "qr-factory-prod-YOURUNIQUE"
api_custom_domain       = "api.qr-factory.example.com"
api_custom_domain_zone  = "qr-factory.example.com"
allowed_origin          = ""
quota_limit_per_user    = 100
log_retention_days      = 30
pagerduty_sns_endpoint  = ""
alarm_runbook_url       = "https://wiki.internal/runbooks/qr-factory"
source_provider         = "github"
github_repo_owner       = ""
github_repo_name        = ""
github_branch           = "main"
github_connection_arn   = ""
codecommit_repo_name    = "qr-factory-infra"
cloudfront_price_class  = "PriceClass_All"
